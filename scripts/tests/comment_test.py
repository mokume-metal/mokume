#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/comment.sh と scripts/agent-comment-guard.sh の検査 (#18)。

守りたいのは 4 つ:
  1. 素の gh でコメントしようとしたら差し戻される (付け忘れの経路を塞ぐ)
  2. ラッパー経由なら、どの AI が書いたかの署名が自動で付く
  3. 投稿の直前に、宛先の近況が 1 行で名乗られる (#1327)
  4. 素の gh で既存の本文を書き換えようとしたら、scripts/edit-body.sh へ差し戻される
     (#2615。ラッパーそのものの検査は edit_body_test.py)

gh は PATH のスタブに差し替えるので、ネットワークも認証も要らない。
**ラッパーを起動する検査はすべてスタブを噛ませる** — 3 が宛先を読みに行くので、
素の PATH のまま走らせると検査が実ネットワークを叩く。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
COMMENT = REPO / "scripts" / "comment.sh"
EDIT_BODY = REPO / "scripts" / "edit-body.sh"
GUARD = REPO / "scripts" / "agent-comment-guard.sh"

# エージェント検出に関わる環境変数。テストの中では毎回まっさらにしてから
# 必要なものだけ立てる (このテスト自体がエージェントのセッションから走るため、
# 素の環境を引き継ぐと「検出できた」のか「呼び出し元の env が漏れた」のか区別できない)
AGENT_ENV = [
    "MOKUME_AGENT_NAME",
    "MOKUME_AGENT_URL",
    "CLAUDECODE",
    "CLAUDE_CODE_ENTRYPOINT",
    "AI_AGENT",
    "CODEX_SANDBOX",
    "CODEX_SANDBOX_NETWORK_DISABLED",
    "CODEX_HOME",
    # 署名のモデルの名乗りに効く (#3149)。呼び出し元のセッションの記録を読ませない
    "MOKUME_AGENT_MODEL",
    "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CONFIG_DIR",
]


# 署名の 1 行と、署名の無い本文を差し戻すときの文面の頭 (#3149)
SIGNATURE_LINE = "<sub>🤖 Assisted by [Claude Code](https://claude.com/claude-code)</sub>"
UNSIGNED = "エージェントの署名が要ります"
SIGNATURE_KEY_IN_REASON = "<sub>🤖 Assisted by"


# --- gh が持つ「本文を伴う口」の数え上げ (#708) --------------------------
#
# ガードは以前「gh が発言を伴うサブコマンドを増やしたらここに足す」と書いていた。
# 数え上げないと決めた記述が残っている間は、掛かっているかを現物を読まずに疑える —
# #708 はそうして起票された (診断は外れており、close / reopen は #127 が塞いでいた)。
#
# **代わりに gh 自身から口を導き、この表と照合する。** 下の
# test_body_bearing_surfaces_are_enumerated が gh の --help を読んで
# 導出集合を作るので、gh が口を増やした日に赤くなって分類を促す。
#
# 導出を手元で再現する (gh 2.98.0 で 15 行):
#
#   for g in issue pr; do
#     for s in $(gh $g --help | sed -n 's/^  \([a-z-]*\):.*/\1/p'); do
#       printf '%s %s %s\n' "$g" "$s" \
#         "$(gh $g $s --help | grep -oE -- '--(body-file|comments|comment|body)' | sort -u | tr '\n' ' ')"
#     done
#   done
#
# 行の意味: (グループ, サブコマンド): (gh が与える本文系フラグ, 扱い, 代表コマンド, 理由)
#
# **署名の境界は「エージェントが新しく書く文か」の 1 本 (#3149)。** スレッドへの発言は
# scripts/comment.sh へ回し ("deny")、新しく作る Issue / PR の本文は署名が無ければ差し戻す
# ("deny-unsigned")。既存の本文の書き換え (edit) は、読んだ後の改訂を黙って消すので
# scripts/edit-body.sh へ回す (#2615。"deny-body")。マージコミットの本文は対象にしない。
BODY_BEARING_SURFACES = {
    ("issue", "comment"): (
        {"--body", "--body-file"},
        "deny",
        'gh issue comment 42 --body "発言"',
        "スレッドへの発言そのもの",
    ),
    ("issue", "close"): (
        {"--comment"},
        "deny",
        'gh issue close 42 --comment "対応済み"',
        "閉じながらの発言も発言 (#123)",
    ),
    ("issue", "reopen"): (
        {"--comment"},
        "deny",
        'gh issue reopen 42 --comment "やり直す"',
        "開け直しながらの発言も発言 (#708 が踏んだ形)",
    ),
    ("issue", "create"): (
        {"--body", "--body-file"},
        "deny-unsigned",
        'gh issue create --title "題" --body "本文"',
        "新しく作る Issue の本文。署名が無ければ差し戻す (#3149)",
    ),
    ("issue", "edit"): (
        {"--body", "--body-file"},
        "deny-body",
        "gh issue edit 42 --body-file body.md",
        "既存本文の書き換え。発言ではないが、読んだ後の改訂を黙って消す (#2615)",
    ),
    ("issue", "view"): (
        {"--comments"},
        "pass",
        "gh issue view 42 --comments",
        "読み取り。-c の意味の衝突は test_c_option_meaning_something_else_passes",
    ),
    ("pr", "comment"): (
        {"--body", "--body-file"},
        "deny",
        "gh pr comment 42 --body-file body.md",
        "スレッドへの発言そのもの",
    ),
    ("pr", "close"): (
        {"--comment"},
        "deny",
        'gh pr close 42 --comment "閉じる"',
        "閉じながらの発言も発言 (#123)",
    ),
    ("pr", "reopen"): (
        {"--comment"},
        "deny",
        'gh pr reopen 42 --comment "取り消す"',
        "開け直しながらの発言も発言",
    ),
    ("pr", "review"): (
        {"--body", "--body-file", "--comment"},
        "deny",
        'gh pr review 42 --comment --body "見ました"',
        "本文を伴うレビューは発言。--comment はレビュー種別で本文ではない",
    ),
    ("pr", "create"): (
        {"--body", "--body-file"},
        "deny-unsigned",
        'gh pr create --title "題" --body "本文"',
        "新しく作る PR の本文。署名が無ければ差し戻す (#3149)",
    ),
    ("pr", "edit"): (
        {"--body", "--body-file"},
        "deny-body",
        'gh pr edit 42 --body "本文"',
        "既存本文の書き換え (#2615)",
    ),
    ("pr", "merge"): (
        {"--body", "--body-file"},
        "pass",
        'gh pr merge 42 --squash --body "マージ本文"',
        "マージコミットの本文",
    ),
    ("pr", "revert"): (
        {"--body", "--body-file"},
        "deny-unsigned",
        'gh pr revert 42 --body "戻す理由"',
        "revert として作る PR の本文。create と同じ (#3149)",
    ),
    ("pr", "view"): (
        {"--comments"},
        "pass",
        "gh pr view 42 --comments",
        "読み取り",
    ),
}

# 導出が空振りしていないことを確かめる錨。gh のヘルプの書式が変わって解析が壊れたら、
# 「口が 1 つも無い」で緑になるのではなく、ここで赤くする
SURFACE_ANCHORS = (("issue", "comment"), ("issue", "close"), ("pr", "review"))

# 表を導いた gh の版。**手元ではこの版のときだけ完全一致を照合する** (#1360)。
# gh の版は人ごとに違い、違う版で赤くすると make ci-check を他の人が通せなくなる。
# 「gh が口を増やした日に赤くなる」(#708) は CI が担う。表を直したらここも上げる
SURFACES_GH_VERSION = "2.101.0"

GH = shutil.which("gh")
JQ = shutil.which("jq")

# --- gh のスタブ --------------------------------------------------------
#
# ラッパーは投稿の直前に宛先を読む (#1327)。検査でそこから外へ出ないよう、
# ラッパーを起動するときは必ず PATH の先頭にスタブを置く。

# 何もせず失敗するだけの gh。認証が無い / gh が古い環境を表す
# (「黙って続行する」側の経路。#1327 完了条件 4)
FAILING_GH = """#!/bin/bash
exit 1
"""

# 宛先の近況 (api graphql — #2660 から。以前は view) には固定の JSON を**実物の jq**で評価させ、
# comment は引数と本文を記録する。
# --jq の式はラッパーが書いたものがそのまま渡るので、式自体がここで検査される
# (スタブが答えを作ると、式が壊れても緑のままになってしまう)
#
# 宛先の近況は scripts/bot-hand.sh の recent_comments が、新しい順にページで遡って引く
# (#2660)。固定の JSON ({state, comments: [古い順]}) から、本物と同じく last: size・
# before: cursor の 1 ページを組んで返す (カーソルは添字の文字列)。引いたページは PAGE_LOG へ
RESPONDING_GH = """#!/bin/bash
if [ "$1" = api ]; then
  size= cursor=
  for arg in "$@"; do
    case "$arg" in
      size=*) size=${arg#size=} ;;
      cursor=*) cursor=${arg#cursor=} ;;
    esac
  done
  [ -z "${PAGE_LOG:-}" ] || echo "${cursor:-last}" >> "$PAGE_LOG"
  exec jq -c --argjson size "$size" --arg cursor "$cursor" '
    .state as $state | (.comments | length) as $n
    | (if $cursor == "" then $n else ($cursor | tonumber) end) as $end
    | ([$end - $size, 0] | max) as $start
    | {data: {repository: {issueOrPullRequest: {state: $state, comments: {
        totalCount: $n, pageInfo: {hasPreviousPage: ($start > 0), startCursor: ($start | tostring)},
        nodes: .comments[$start:$end]}}}}}' "$FIXTURE"
fi
printf '%s\\n' "$@" > "$LOG"
cat "${!#}" >> "$LOG"
"""


def destination_json(state="OPEN", comments=()):
    """宛先の state と全コメント (古い順)。ページは偽 gh が組む (RESPONDING_GH)。"""
    return json.dumps({"state": state, "comments": list(comments)})


def write_transcript(directory, models, subagents=()):
    """Claude Code のセッションの記録を模して置き、パスを返す (#3149)。

    assistant の行だけが message.model を持つ。ツールの結果に映った "model" の字面も 1 本
    混ぜる (字面で拾えば別のモデルを名乗る)。
    """
    path = Path(directory) / "projects" / "-repo" / "sess-1.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [json.dumps({"type": "user", "message": {"content": '{"model":"gpt-fake"}'}})]
    lines += [json.dumps({"type": "assistant", "message": {"model": m}}) for m in models]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    for i, sub in enumerate(subagents):
        agent = path.with_suffix("") / "subagents" / f"agent-{i}.jsonl"
        agent.parent.mkdir(parents=True, exist_ok=True)
        agent.write_text(
            "\n".join(json.dumps({"type": "assistant", "message": {"model": m}}) for m in sub) + "\n",
            encoding="utf-8",
        )
    return path


def stub_gh(testcase, script=FAILING_GH):
    """gh のスタブを 1 つ置いたディレクトリを作って返す (PATH の先頭に置く用)。"""
    tmp = tempfile.TemporaryDirectory()
    testcase.addCleanup(tmp.cleanup)
    directory = Path(tmp.name)
    gh = directory / "gh"
    gh.write_text(script, encoding="utf-8")
    gh.chmod(0o755)
    return directory


_SUBCOMMAND = re.compile(r"^  ([a-z][a-z-]*):\s", re.M)
_BODY_FLAG = re.compile(r"--(?:body-file|comments|comment|body)(?![\w-])")


def derive_body_bearing_surfaces():
    """gh の --help から「本文系フラグを持つ口」を導く。

    返すのは {(グループ, サブコマンド): {フラグ, …}}。認証もネットワークも要らない
    (--help しか読まない)。
    """

    def helptext(*args):
        proc = subprocess.run(
            ["gh", *args, "--help"], capture_output=True, text=True
        )
        return proc.stdout + proc.stderr

    derived = {}
    for group in ("issue", "pr"):
        for sub in _SUBCOMMAND.findall(helptext(group)):
            flags = set(_BODY_FLAG.findall(helptext(group, sub)))
            if flags:
                derived[(group, sub)] = flags
    return derived


def gh_version():
    """`gh --version` の 1 行目から版だけを取り出す (取れなければ空文字)。"""
    proc = subprocess.run(["gh", "--version"], capture_output=True, text=True)
    match = re.search(r"gh version (\S+)", proc.stdout)
    return match.group(1) if match else ""


def clean_env(path_prefix=None, **overrides):
    env = {k: v for k, v in os.environ.items() if k not in AGENT_ENV}
    if path_prefix is not None:
        env["PATH"] = f"{path_prefix}:{env['PATH']}"
    env.update(overrides)
    return env


class GuardTest(unittest.TestCase):
    """PreToolUse フック: どのコマンドを差し戻し、どれを素通しするか。"""

    def run_guard(self, command, cwd=None, payload_extra=None, **env):
        payload = json.dumps(
            {"tool_input": {"command": command}, **({"cwd": cwd} if cwd else {}),
             **(payload_extra or {})}
        )
        # 打つシェルから継ぐ GH_REPO は宛先に効く (#1729)。呼び出し元の値を漏らさない
        environment = {k: v for k, v in clean_env(**env).items() if k != "GH_REPO" or "GH_REPO" in env}
        proc = subprocess.run(
            ["/bin/bash", str(GUARD)],
            input=payload,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def assert_denied(self, command, cwd=None, wrapper="scripts/comment.sh", **env):
        out = self.run_guard(command, cwd=cwd, **env)
        self.assertTrue(out, f"差し戻されるはずが素通しした: {command}")
        decision = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")
        self.assertIn(wrapper, decision["permissionDecisionReason"])
        return decision["permissionDecisionReason"]

    def assert_passed(self, command, cwd=None, **env):
        self.assertEqual(
            self.run_guard(command, cwd=cwd, **env), "", f"素通しのはずが差し戻された: {command}"
        )

    def other_repo_dir(self):
        """別のリポジトリの作業ディレクトリを 1 つ用意する。"""
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name) / "theirs"
        root.mkdir()
        run = lambda *a: subprocess.run(["git", *a], cwd=root, check=True,
                                        capture_output=True)
        run("init", "-q")
        # 使い捨てのリポジトリでは署名を切る (#344)
        run("config", "commit.gpgsign", "false")
        run("remote", "add", "origin", "git@github.com:shinyaoguri/setup.git")
        return str(root)

    # --- 宛先がこのリポジトリでないもの (#611) --------------------------

    def test_other_repository_by_working_directory_is_passed(self):
        """別リポジトリのディレクトリから打ったコメントは、この規約の外。

        -R が無いだけで差し戻すと、投稿先が mokume 固定のラッパーへ誘導される —
        逃げ道がどこにも無い状態だった。
        """
        self.assert_passed(
            "gh issue com" + "ment 1 --body x", cwd=self.other_repo_dir()
        )

    def test_undecidable_directory_is_denied_with_the_escape_hatch(self):
        """宛先を決められないものは止めるが、逃げ道を示す。"""
        with tempfile.TemporaryDirectory() as plain:
            reason = self.assert_denied("gh issue com" + "ment 1 --body x", cwd=plain)
        self.assertIn("-R owner/repo", reason, "逃げ道が案内されていない")

    def test_bare_issue_comment_denied(self):
        self.assert_denied('gh issue comment 1 --body "x"')

    def test_bare_pr_comment_denied(self):
        self.assert_denied("gh pr comment 7 -F /tmp/body.md")

    def test_repo_option_before_subcommand_denied(self):
        # gh -R owner/repo issue comment ... のように前置オプションが挟まる形
        self.assert_denied("gh -R mokume-metal/mokume issue comment 1 --body x")

    def test_review_with_body_denied(self):
        self.assert_denied('gh pr review 3 --approve --body "見ました"')

    def test_review_without_body_passes(self):
        # 発言を伴わない Approve は署名の対象ではない
        self.assert_passed("gh pr review 3 --approve")

    # --- close / reopen に添える発言 (#123) -----------------------------

    def test_close_with_comment_denied(self):
        """閉じながらの発言も発言。#120 に未署名のコメントが残った形。"""
        self.assert_denied('gh pr close 120 -c "メンテナ名義だったので閉じる"')
        self.assert_denied('gh pr close 120 --comment "閉じる"')
        self.assert_denied("gh pr close 120 --comment=閉じる")
        self.assert_denied('gh issue close 42 -c "対応済み"')

    def test_reopen_with_comment_denied(self):
        self.assert_denied('gh issue reopen 42 --comment "やり直す"')
        self.assert_denied('gh pr reopen 120 -c "取り消す"')

    def test_close_with_comment_and_leading_option_denied(self):
        self.assert_denied('gh -R mokume-metal/mokume pr close 120 -c "理由"')

    def test_close_without_comment_passes(self):
        """状態を変えるだけなら発言が無い (--approve だけのレビューと同じ扱い)。"""
        self.assert_passed("gh pr close 120")
        self.assert_passed("gh pr close 120 --delete-branch")
        self.assert_passed('gh issue close 42 --reason "not planned"')
        self.assert_passed("gh issue reopen 42")

    def test_c_option_meaning_something_else_passes(self):
        """-c の意味は gh の中で衝突している。読み取りまで止めてはいけない。

        サブコマンドを絞らずオプションだけで判定すると、ここが全部赤になる。
        """
        self.assert_passed("gh pr view 121 -c")  # --comments (コメントを読む)
        self.assert_passed("gh issue view 42 -c")
        self.assert_passed("gh issue view 42 --comments")
        self.assert_passed("gh issue develop 42 -c")  # --checkout

    def test_merge_body_passes(self):
        """マージコミットの本文はスレッドへの発言ではない (境界)。"""
        self.assert_passed('gh pr merge 125 --auto --squash --body "マージ本文"')

    def test_close_reason_shows_the_two_step_procedure(self):
        """差し戻すだけでは直せない。ラッパーには close 機能が無いので手順を示す。"""
        out = self.run_guard('gh pr close 120 -c "理由"')
        reason = json.loads(out)["hookSpecificOutput"]["permissionDecisionReason"]
        self.assertIn("gh pr close <番号>", reason)

    # --- 他のリポジトリ宛て (#188) --------------------------------------

    def test_other_repo_passes(self):
        """他のリポジトリ宛てのコメントはこのリポジトリの規約の外。

        ラッパーの投稿先は mokume 固定なので、ここで差し戻すと逃げ道が無くなる。
        """
        self.assert_passed('gh issue comment 5 -R shinyaoguri/claude-plugins --body "x"')
        self.assert_passed("gh pr comment 7 --repo=other/repo -F /tmp/body.md")
        self.assert_passed('gh -R other/repo issue close 3 -c "対応済み"')
        self.assert_passed('gh pr review 3 -R other/repo --approve --body "見ました"')

    def test_this_repo_explicitly_denied(self):
        self.assert_denied('gh issue comment 1 -R mokume-metal/mokume --body "x"')

    def test_ambiguous_repo_denied(self):
        """owner を省いた --repo は自リポか判定できない。曖昧なら止める側に倒す。"""
        self.assert_denied('gh issue comment 1 --repo mokume --body "x"')

    def test_repo_mentioned_in_heredoc_body_denied(self):
        """本文の中の --repo は宛先ではない。データを宛先と取り違えない。"""
        self.assert_denied(
            "gh issue comment 1 -F - <<'EOF'\n"
            "他リポへ書くときは --repo other/repo を付ける。\n"
            "EOF"
        )

    # --- 以前は見逃していた形 (#128) ------------------------------------

    def test_command_substitution_denied(self):
        self.assert_denied('url=$(gh issue comment 1 --body "x")')

    def test_subshell_denied(self):
        self.assert_denied('(gh pr comment 7 --body "x")')

    def test_backticks_denied(self):
        self.assert_denied("url=`gh pr comment 7 --body x`")

    # --- 前置した gh (#1729) ---------------------------------------------
    #
    # #1727 の接続検証で、通常の形は差し戻すのに、環境変数やパスを前置した形を
    # 無出力で通していた。発言の 3 つの口すべてで見る

    PREFIXES = ("PATH=/tmp/bin:$PATH gh", "/tmp/bin/gh", "env GH_DEBUG=1 gh")

    def test_prefixed_gh_is_denied_on_every_surface(self):
        for gh in self.PREFIXES:
            with self.subTest(gh=gh):
                self.assert_denied(f'{gh} issue comment 1 --body "x"')
                self.assert_denied(f"{gh} pr comment 7 -F /tmp/body.md")
                self.assert_denied(f'{gh} pr review 3 --approve --body "見ました"')
                self.assert_denied(f'{gh} pr close 120 -c "閉じる"')
                self.assert_denied(f'{gh} issue reopen 42 --comment "やり直す"')

    def test_prefixed_gh_keeps_the_exceptions(self):
        """前置があっても、読み取り・本文なし・他 repo・--help は素通しのまま。"""
        for gh in self.PREFIXES:
            with self.subTest(gh=gh):
                self.assert_passed(f"{gh} issue view 42 -c")
                self.assert_passed(f"{gh} pr review 3 --approve")
                self.assert_passed(f"{gh} pr close 120")
                self.assert_passed(f'{gh} issue comment 5 -R other/repo --body "x"')
                self.assert_passed(f"{gh} issue comment --help")

    def test_gh_inside_loops_and_conditions_denied(self):
        """割った後の先頭が予約語になる形 (#1729 の反証)。"""
        self.assert_denied("for i in 1 2; do gh issue comment $i --body x; done")
        self.assert_denied("if true; then gh pr close 3 -c x; fi")
        self.assert_denied("{ gh pr comment 7 --body x; }")
        self.assert_denied("gh \\\n  issue comment 1 --body x")

    # --- 旗と例外は、その gh の呼び出しの中からだけ読む (#1729 の反証) ----
    #
    # 以前はコマンド全体への部分一致で、同じ行の別のコマンドの語に引きずられた

    def test_words_of_another_command_do_not_excuse_a_comment(self):
        self.assert_denied("cat scripts/comment.sh && gh issue comment 1 --body y")
        self.assert_denied(
            "bash scripts/comment.sh issue 1 --body x && PATH=/tmp/bin:$PATH gh issue comment 1 --body y"
        )
        self.assert_denied("ls --help && gh issue comment 1 --body x")
        self.assert_denied("git diff -R foo/bar; gh issue comment 1 --body x")

    def test_flags_of_another_command_do_not_make_a_comment(self):
        self.assert_passed("gh pr view 3 --comments; /tmp/bin/gh pr close 3 && echo -c x")
        self.assert_passed("PATH=/tmp/bin:$PATH gh pr review 3 --approve && echo --body")

    def test_mention_inside_a_quoted_message_passes(self):
        """引用の中の ; はコマンドの区切りではない。main から誤検知していた素の形も。"""
        self.assert_passed('git commit -m "note; gh issue comment 1"')
        self.assert_passed('git commit -m "note; X=1 gh issue comment 1"')
        self.assert_passed('git commit -m "note; /opt/homebrew/bin/gh issue comment 1"')

    def test_gh_repo_prefix_names_the_destination(self):
        """前置の GH_REPO= はその gh の宛先。両方向に読む (#1729 の反証)。"""
        self.assert_passed("GH_REPO=other/repo gh issue comment 1 --body x")
        self.assert_denied(
            "GH_REPO=mokume-metal/mokume gh issue comment 1 --body x", cwd=self.other_repo_dir()
        )

    # --- 2 回目の反証 (73d235f に対して) ---------------------------------

    def test_quoted_or_commented_heredoc_opener_does_not_hide_the_next_line(self):
        """引用や注釈の中の <<EOF を開きと読むと、後ろの行が判定から消えた (main から)。"""
        self.assert_denied('git commit -m "fix <<EOF parse"\ngh issue comment 1 -b x')
        self.assert_denied("echo '<<EOF'\ngh issue comment 1 -b x")
        self.assert_denied("# note <<EOF\ngh issue comment 1 -b x")

    def test_inherited_gh_repo_names_the_destination(self):
        self.assert_denied(
            "gh issue comment 1 -b x", cwd=self.other_repo_dir(), GH_REPO="mokume-metal/mokume"
        )
        self.assert_passed("gh issue comment 1 -b x", GH_REPO="other/repo")

    # --- 同じコマンドの中で文として変えた宛先 (#1823) --------------------

    # 発言の 4 口 (BODY_BEARING_SURFACES の deny)。形 × 口で回す
    PORTS = (
        "gh issue comment 1 --body x",
        "gh pr comment 1 --body x",
        "gh pr review 1 --body x",
        "gh issue close 1 --comment x",
        "gh pr reopen 1 --comment x",
    )

    # 他リポの cwd から、gh より前に宛先を mokume へ変えうる文・前置。{m} は mokume の
    # checkout。形を 1 つ足すなら行を 1 つ足す
    DESTINATION_FORMS = (
        "cd {m} && {gh}",
        "cd {m}; {gh}",
        "cd {m}\n{gh}",
        "pushd {m} && {gh}",
        "(cd {m} && {gh})",
        "export GH_REPO=mokume-metal/mokume && {gh}",
        "GH_REPO=mokume-metal/mokume; export GH_REPO; {gh}",
        "declare -x GH_REPO=mokume-metal/mokume; {gh}",
        "GIT_DIR={m}/.git {gh}",
        "export GIT_DIR={m}/.git && {gh}",
        # 反証 #1〜#3
        "builtin cd {m} && {gh}",
        "command cd {m} && {gh}",
        "builtin export GH_REPO=mokume-metal/mokume && {gh}",
        "GIT_COMMON_DIR={m}/.git {gh}",
        "printf -v GH_REPO %s mokume-metal/mokume && {gh}",
        "read -r GH_REPO <<< mokume-metal/mokume && {gh}",
        # 反証 2 回目の 2-1・2-3・補足の chdir
        "for GH_REPO in mokume-metal/mokume; do {gh}; done",
        "for i in 1 2; do {gh}; cd {m}; done",
        "chdir {m} && {gh}",
    )

    def test_repo_option_that_is_decided_at_run_time_denied(self):
        """反証 2-2 — -R の値が実行時に決まるなら、前置の GH_REPO="$X" と同じく止める側。"""
        for port in self.PORTS:
            with self.subTest(port=port):
                self.assert_denied(f'O=mokume-metal; R=mokume; {port} -R "$O/$R"')
        self.assert_passed('gh issue comment 1 --body x -R "other/repo"')

    def test_git_variables_that_do_not_move_the_destination_pass(self):
        """反証 2-5 — 宛先に効かない git の変数は、他リポ宛ての判定を変えない (main の判定)。"""
        there = self.other_repo_dir()
        self.assert_passed("GIT_PAGER=cat gh issue comment 1 --body x", cwd=there)
        self.assert_passed("export GIT_TERMINAL_PROMPT=0 && gh pr comment 1 --body x", cwd=there)

    # mokume の cwd で、継いだ他リポの GH_REPO を消す文 (#1836 の退行)
    UNSET_FORMS = ("unset GH_REPO && {gh}", "export -n GH_REPO && {gh}")

    def test_statement_that_changes_the_destination_denied_on_every_port(self):
        there = self.other_repo_dir()
        for form in self.DESTINATION_FORMS:
            for port in self.PORTS:
                command = form.format(m=REPO, gh=port)
                with self.subTest(command=command):
                    reason = self.assert_denied(command, cwd=there)
                    self.assertIn("-R owner/repo", reason, "逃げ道が案内されていない")
        for form in self.UNSET_FORMS:
            for port in self.PORTS:
                command = form.format(gh=port)
                with self.subTest(command=command):
                    self.assert_denied(command, GH_REPO="other/repo")

    def test_statement_that_changes_the_destination_keeps_the_escape_hatches(self):
        """-R の明示と、gh に効かない入れ子の中の cd は今までどおり通る (#1823 の D)。"""
        there = self.other_repo_dir()
        self.assert_passed(f"cd {REPO} && gh issue comment 1 -R other/repo --body x", cwd=there)
        self.assert_passed("export GH_REPO=other/repo && gh issue comment 1 --body x -R other/repo")
        self.assert_passed(f"x=$(cd {REPO} && pwd) && gh issue comment 1 --body x", cwd=there)
        # mokume の cwd から他リポへ変える文は、止める側の誤検知のまま (選択肢 2 の範囲)
        self.assert_denied("export GH_REPO=other/repo && gh issue comment 1 --body x")

    def test_coproc_and_function_bodies_denied(self):
        self.assert_denied("coproc gh issue comment 1 -b x")
        self.assert_denied("function f { gh issue comment 1 -b x; }")
        self.assert_denied("f() { gh issue comment 1 -b x; }")

    def test_substitution_inside_an_argument_says_so(self):
        """二重引用の中のバッククォートは実行されるので止めるが、文面はその直し方を示す。"""
        reason = self.assert_denied(
            'bash scripts/comment.sh issue 1 --body "see `gh issue comment` docs"'
        )
        self.assertIn("実行される", reason)
        self.assertIn("単一引用", reason)
        # 地の文の呼び出しには添えない
        self.assertNotIn("単一引用", self.assert_denied("gh issue comment 1 -b x"))
        # 単一引用なら実行されないので止めない
        self.assert_passed("bash scripts/comment.sh issue 1 --body 'see `gh issue comment` docs'")

    def test_prefixed_wrapper_passes(self):
        self.assert_passed("PATH=/tmp/bin:$PATH bash scripts/comment.sh issue 1 --body x")

    def test_prefixed_mention_in_heredoc_passes(self):
        self.assert_passed(
            "cat > body.md <<'EOF'\n"
            "PATH=/tmp/bin:$PATH gh issue comment 1 --body x\n"
            "/tmp/bin/gh issue comment 1 --body x\n"
            "EOF"
        )

    # --- 地の文で言及しただけなら止めない (#128) ------------------------

    def test_mention_in_commit_message_passes(self):
        self.assert_passed(
            "git commit -F - <<'EOF'\n"
            "guard は gh issue comment しか見ていなかった。\n"
            "EOF"
        )

    def test_mention_at_line_start_in_heredoc_passes(self):
        """本文の行頭に手順として書いた形。断片分割だけでは拾ってしまう。"""
        self.assert_passed(
            "cat > body.md <<'EOF'\n"
            "手順:\n"
            "\n"
            "  gh issue comment 1 --body x\n"
            "\n"
            "は使わない。\n"
            "EOF"
        )

    def test_mention_in_quoted_argument_passes(self):
        self.assert_passed("echo '投稿は gh issue comment ではなくラッパーで行う'")

    def test_words_are_not_bridged_across_a_fragment(self):
        """離れた語を繋げて拾わない。

        以前は gh と任意個の語をまたいで後方のサブコマンド名まで拾ったため、
        「gh issue comment と pr review の話」+ --body で誤検知した。
        """
        self.assert_passed("echo 'gh issue comment と pr review の話' --body x")

    def test_read_only_commands_pass(self):
        self.assert_passed("gh issue view 1")
        self.assert_passed("gh pr list")
        self.assert_passed("gh api repos/mokume-metal/mokume/issues/1")

    def test_help_passes(self):
        self.assert_passed("gh issue comment --help")

    def test_wrapper_passes(self):
        self.assert_passed("bash scripts/comment.sh issue 1 --body x")
        self.assert_passed("bash /abs/path/scripts/comment.sh pr 2 -F /tmp/x.md")

    def test_non_gh_command_passes(self):
        self.assert_passed("make ci-check")

    # --- 口の数え上げ (#708) --------------------------------------------

    @unittest.skipUnless(GH, "gh が PATH に無い")
    def test_body_bearing_surfaces_are_enumerated(self):
        """gh 自身が持つ口と、BODY_BEARING_SURFACES の数え上げが一致する。

        ガードの取りこぼしは「人が気付いたら足す」で支えていた。gh が口を増やした日に
        ここが赤くなり、分類を促す — 発言なら deny 側へ足し、本文なら理由を添えて
        素通し側へ足す。どちらにしても代表コマンドの扱いを 1 行書く。
        """
        derived = derive_body_bearing_surfaces()

        for anchor in SURFACE_ANCHORS:
            self.assertIn(
                anchor,
                derived,
                "gh --help の解析が壊れている (錨が導出できない)。"
                "_SUBCOMMAND / _BODY_FLAG を gh の書式に合わせ直す",
            )

        local = gh_version()
        if not os.environ.get("GITHUB_ACTIONS") and local != SURFACES_GH_VERSION:
            self.skipTest(
                f"手元の gh {local} は表を導いた版 {SURFACES_GH_VERSION} と違う。"
                "口の完全一致は CI が照合する"
            )

        appeared = sorted(set(derived) - set(BODY_BEARING_SURFACES))
        vanished = sorted(set(BODY_BEARING_SURFACES) - set(derived))
        self.assertEqual(
            ([], []),
            (appeared, vanished),
            f"gh の口が動いた (増: {appeared} / 減: {vanished})。"
            "BODY_BEARING_SURFACES を直し、増えた口はスレッドへの発言かで分類する。"
            f"直したら SURFACES_GH_VERSION を手元の gh の版 ({local}) へ上げる",
        )

        for surface, flags in sorted(derived.items()):
            with self.subTest(surface=" ".join(("gh", *surface))):
                self.assertEqual(BODY_BEARING_SURFACES[surface][0], flags)

    def test_every_enumerated_surface_is_handled_as_declared(self):
        """数え上げた口が、表の宣言どおりに差し戻される / 素通しする。

        表が扱いの一覧であることを、実際にガードへ流して確かめる。gh は要らない
        (代表コマンドは文字列で、ガードは文字列だけを読む)。
        """
        for surface, (_, expect, command, why) in sorted(
            BODY_BEARING_SURFACES.items()
        ):
            with self.subTest(surface=" ".join(("gh", *surface)), why=why):
                if expect == "deny":
                    self.assert_denied(command)
                elif expect == "deny-body":
                    self.assert_denied(command, wrapper="scripts/edit-body.sh")
                elif expect == "deny-unsigned":
                    self.assert_denied(command, wrapper=UNSIGNED)
                    # 同じコマンドに署名を足せば通る
                    self.assert_passed(command.replace("本文", f"本文 {SIGNATURE_LINE}")
                                       .replace("戻す理由", f"戻す理由 {SIGNATURE_LINE}"))
                else:
                    self.assert_passed(command)

    def test_review_comment_flag_alone_passes(self):
        """gh pr review の --comment はレビュー**種別**で、本文ではない (境界)。

        名前が同じなので close / reopen の --comment と同じに見えるが、こちらは
        本文を伴わなければ発言が無い (--approve だけのレビューと同じ扱い)。
        """
        self.assert_passed("gh pr review 42 --comment")

    # --- 本文の書き換え (#2615) ------------------------------------------
    #
    # #2610 では、別のエージェントが本文を改訂した 21 秒後に、古い写しを土台にした
    # gh issue edit --body-file がその改訂を消した。素の本文の書き換えはラッパーへ回す

    def assert_edit_denied(self, command, **kwargs):
        reason = self.assert_denied(command, wrapper="scripts/edit-body.sh", **kwargs)
        self.assertIn("--fetch", reason, "土台の取り方が案内されていない")
        self.assertNotIn("scripts/comment.sh", reason, "本文の書き換えをコメントと案内している")
        return reason

    def test_body_edit_is_sent_to_the_wrapper(self):
        """本文のオプションは 4 つの綴りすべてで、issue と pr の両方で止める。"""
        for group in ("issue", "pr"):
            for option in ("--body-file body.md", "-F body.md", '--body "本文"', "-b 本文",
                           "--body=本文", "--body-file=body.md"):
                with self.subTest(group=group, option=option):
                    self.assert_edit_denied(f"gh {group} edit 42 {option}")

    def test_body_edit_with_other_changes_is_still_sent_to_the_wrapper(self):
        self.assert_edit_denied('gh issue edit 42 --title "題" --add-label bug --body-file body.md')
        self.assert_edit_denied("gh -R mokume-metal/mokume issue edit 42 --body-file body.md")

    def test_edit_without_body_passes(self):
        """完了条件 3: タイトル・ラベル・担当などだけの edit は対象にしない。"""
        self.assert_passed('gh issue edit 42 --title "新しい題"')
        self.assert_passed('gh issue edit 42 --add-label "status: in progress"')
        self.assert_passed('gh issue edit 42 --remove-label "status: in progress" --add-assignee @me')
        self.assert_passed("gh issue edit 42 --type Bug")
        self.assert_passed("gh pr edit 42 --add-label no-visual-change --base main")

    def test_body_edit_keeps_the_exceptions(self):
        """他リポ宛て・--help・ラッパー経由・地の文での言及は素通しのまま。"""
        self.assert_passed("gh issue edit 5 -R shinyaoguri/claude-plugins --body-file body.md")
        self.assert_passed("gh issue edit --help")
        self.assert_passed("bash scripts/edit-body.sh issue 42 --fetch /tmp/42.md")
        self.assert_passed("bash scripts/edit-body.sh issue 42 --body-file /tmp/42.md")
        self.assert_passed("echo 'gh issue edit 42 --body-file は使わない'")
        self.assert_passed(f'gh issue create --title "題" --body "本文 {SIGNATURE_LINE}"')

    def test_prefixed_body_edit_is_denied(self):
        for gh in self.PREFIXES:
            with self.subTest(gh=gh):
                self.assert_edit_denied(f"{gh} issue edit 42 --body-file body.md")

    def test_comment_and_body_edit_together_name_both_wrappers(self):
        reason = self.assert_denied("gh issue comment 1 -b x && gh issue edit 1 --body-file body.md")
        self.assertIn("scripts/edit-body.sh", reason)


class CreateSignatureGuardTest(unittest.TestCase):
    """新しく作る本文の署名 (#3149): どの形を差し戻し、どの形を通すか。

    以前は Issue / PR の本文を「スレッドへの発言ではない」として素通しにしており、
    sub-issue の 11 件中 9 件・PR の本文 30 件すべてが無署名だった。
    """

    # ガードへの流し方は GuardTest と同じ (継ぐと GuardTest の検査が 2 度走る)
    run_guard = GuardTest.run_guard
    assert_denied = GuardTest.assert_denied
    assert_passed = GuardTest.assert_passed

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)

    def body_file(self, text):
        path = self.dir / "body.md"
        path.write_text(text, encoding="utf-8")
        return path

    def test_unsigned_body_file_is_denied_and_signed_passes(self):
        path = self.body_file("本文\n")
        for gh in ("gh issue create --title t", "gh pr create --title t", "gh pr revert 3"):
            with self.subTest(gh=gh):
                reason = self.assert_denied(f"{gh} --body-file {path}", wrapper=UNSIGNED)
                self.assertIn(SIGNATURE_KEY_IN_REASON, reason, "貼る 1 行が示されていない")
        self.body_file(f"本文\n\n---\n{SIGNATURE_LINE}\n")
        for gh in ("gh issue create --title t", "gh pr create --title t", "gh pr revert 3"):
            with self.subTest(gh=gh, signed=True):
                self.assert_passed(f"{gh} --body-file {path}")

    def test_relative_body_file_is_read_from_cwd(self):
        self.body_file(f"本文\n{SIGNATURE_LINE}\n")
        self.assert_passed("gh issue create -t t -F body.md", cwd=str(self.dir))
        self.body_file("本文\n")
        self.assert_denied("gh issue create -t t -F body.md", cwd=str(self.dir), wrapper=UNSIGNED)

    def test_heredoc_body_is_read_from_the_command(self):
        """`-F -` は本文を取り出せないが、ヒアドキュメントはコマンド文字列に載る。"""
        signed = f"gh pr create --title t --body-file - <<'EOF'\n本文\n---\n{SIGNATURE_LINE}\nEOF"
        self.assert_passed(signed)
        self.assert_denied("gh pr create --title t --body-file - <<'EOF'\n本文\nEOF", wrapper=UNSIGNED)

    def test_body_that_cannot_be_read_is_denied_without_a_signature(self):
        """本文を作るのに本文の旗が無い形も、署名の無い本文を作る。"""
        for command in (
            "gh pr create --fill",
            "gh pr create --title t --template bug.md",
            'gh issue create --title t --body "$(cat body.md)"',
            'url=$(gh issue create --title t --body "x") && echo "$url"',
        ):
            with self.subTest(command=command):
                self.assert_denied(command, wrapper=UNSIGNED)

    def test_signature_elsewhere_in_the_command_does_not_count(self):
        """本文を取り出せないとき、別のコマンドの語やコメントの署名では通さない (反証の #4)。"""
        for command in (
            "echo '🤖 Assisted by'; gh pr create --fill",
            "gh pr create --fill # 🤖 Assisted by",
            "gh pr create --fill && echo '<sub>🤖 Assisted by x</sub>'",
        ):
            with self.subTest(command=command):
                self.assert_denied(command, wrapper=UNSIGNED)

    def test_quoting_the_words_is_not_a_signature(self):
        """署名の話をするだけの本文 ("Assisted by" の引用) は署名ではない (反証の #6)。"""
        self.assert_denied('gh issue create --title t --body "Assisted by の綴りを直す"', wrapper=UNSIGNED)

    def test_signed_inline_body_passes(self):
        self.assert_passed(f'gh issue create --title t --body "本文\n---\n{SIGNATURE_LINE}"')
        # 他のエージェントの署名でも通る (検知キーは名乗りに依らない)
        self.assert_passed('gh issue create --title t --body "本文 <sub>🤖 Assisted by Grok CLI</sub>"')

    def test_exceptions_still_pass(self):
        self.assert_passed("gh issue create -R shinyaoguri/setup --title t --body x")
        self.assert_passed("gh pr create --help")
        self.assert_passed('gh pr merge 3 --squash --body "マージ本文"')
        self.assert_passed("echo 'gh issue create --body x は使わない'")

    def test_reason_names_the_models_of_this_session(self):
        """差し戻しの 1 行は、記録に残るモデル (サブエージェントの分も) を名乗る。"""
        transcript = write_transcript(
            self.dir, ["claude-opus-5-5"] * 3 + ["<synthetic>"], subagents=[["claude-haiku-5-5"]]
        )
        reason = self.assert_denied(
            "gh issue create --title t --body x",
            wrapper=UNSIGNED,
            payload_extra={"transcript_path": str(transcript)},
            CLAUDECODE="1",
        )
        self.assertIn(
            "Assisted by [Claude Code](https://claude.com/claude-code) (Claude Opus 5.5, Claude Haiku 5.5)",
            reason,
        )
        self.assertNotIn("synthetic", reason)
        self.assertNotIn("gpt-fake", reason, "ツールの結果に映った model を拾っている")

    def test_reason_uses_the_payload_model_for_other_agents(self):
        reason = self.assert_denied(
            "gh issue create --title t --body x",
            wrapper=UNSIGNED,
            payload_extra={"model": "gpt-6-astra"},
            CODEX_SANDBOX="seatbelt",
        )
        self.assertIn("Assisted by [OpenAI Codex](https://developers.openai.com/codex) (gpt-6-astra)", reason)

    def test_comment_and_unsigned_create_together_name_both(self):
        reason = self.assert_denied("gh issue comment 1 -b x && gh issue create -t t -b y")
        self.assertIn(UNSIGNED, reason)

class SignatureTest(unittest.TestCase):
    """ラッパー: 署名を誰の名前で、どう付けるか。"""

    def dry_run(self, body="本文", **env):
        # 宛先の近況 (#1327) はここの関心ではない。落ちる gh を噛ませて黙らせる
        proc = subprocess.run(
            ["/bin/bash", str(COMMENT), "issue", "42", "--body", body, "--dry-run"],
            capture_output=True,
            text=True,
            env=clean_env(path_prefix=stub_gh(self), **env),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout, proc.stderr

    def test_personal_info_in_body_is_announced_but_not_blocked(self):
        """#3075: メール・絶対パスは行番号だけ名乗る。止めず、中身は再掲しない。"""
        _, err = self.dry_run("連絡は so@example.com まで\n場所は /Users/so/x")
        self.assertIn("メールアドレス", err)
        self.assertIn("行 1", err)
        self.assertIn("畳めなかった絶対パス", err)
        self.assertNotIn("so@example.com", err)
        self.assertNotIn("/Users/so/x", err)

    def test_clean_body_is_not_announced(self):
        _, err = self.dry_run("ふつうの本文")
        self.assertNotIn("らしきもの", err)

    def test_claude_code_detected(self):
        out, _ = self.dry_run(CLAUDECODE="1")
        self.assertIn("Assisted by [Claude Code](https://claude.com/claude-code)", out)

    def test_claude_code_detected_via_ai_agent(self):
        out, _ = self.dry_run(AI_AGENT="claude-code_2-1-241_agent")
        self.assertIn("Assisted by [Claude Code]", out)

    def test_codex_detected(self):
        out, _ = self.dry_run(CODEX_SANDBOX="seatbelt")
        self.assertIn("Assisted by [OpenAI Codex]", out)
        self.assertNotIn("Claude Code", out)

    def test_explicit_name_wins(self):
        out, _ = self.dry_run(MOKUME_AGENT_NAME="Cursor", CLAUDECODE="1")
        self.assertIn("Assisted by Cursor", out)
        self.assertNotIn("Claude Code", out)

    def test_explicit_name_with_url(self):
        out, _ = self.dry_run(
            MOKUME_AGENT_NAME="Cursor", MOKUME_AGENT_URL="https://cursor.com"
        )
        self.assertIn("Assisted by [Cursor](https://cursor.com)", out)

    def test_unknown_agent_posts_with_generic_signature(self):
        # 検出できなくても投稿は止めない (止めるとラッパーが使われなくなる)
        out, err = self.dry_run()
        self.assertIn("Assisted by an AI agent", out)
        self.assertIn("MOKUME_AGENT_NAME", err)

    # --- モデルの名乗り・併記 (#3149) ----------------------------------------

    def test_claude_code_names_the_models_in_its_transcript(self):
        with tempfile.TemporaryDirectory() as d:
            write_transcript(
                d,
                ["claude-sonnet-5-5-20261001"] + ["claude-opus-5-5"] * 2,
                subagents=[["claude-haiku-5-5"], ["claude-opus-5-5"]],
            )
            out, _ = self.dry_run(CLAUDECODE="1", CLAUDE_CODE_SESSION_ID="sess-1", CLAUDE_CONFIG_DIR=d)
        self.assertIn(
            "Assisted by [Claude Code](https://claude.com/claude-code)"
            " (Claude Opus 5.5, Claude Sonnet 5.5, Claude Haiku 5.5)</sub>",
            out,
        )

    def test_the_latest_main_model_comes_first(self):
        """/model で切り替えたら、いま使っているモデルを先頭に名乗る (反証の #8)。"""
        with tempfile.TemporaryDirectory() as d:
            write_transcript(d, ["claude-haiku-5-5"] * 5 + ["claude-opus-5-5"])
            out, _ = self.dry_run(CLAUDECODE="1", CLAUDE_CODE_SESSION_ID="sess-1", CLAUDE_CONFIG_DIR=d)
        self.assertIn("(Claude Opus 5.5, Claude Haiku 5.5)</sub>", out)

    def test_missing_transcript_names_no_model(self):
        """記録が見つからなければモデルは書かない (推測で名乗らない)。"""
        with tempfile.TemporaryDirectory() as d:
            out, _ = self.dry_run(CLAUDECODE="1", CLAUDE_CODE_SESSION_ID="nope", CLAUDE_CONFIG_DIR=d)
        self.assertIn("Assisted by [Claude Code](https://claude.com/claude-code)</sub>", out)

    def test_unknown_model_id_is_kept_as_is(self):
        with tempfile.TemporaryDirectory() as d:
            write_transcript(d, ["claude-3-5-sonnet-20241022"])
            out, _ = self.dry_run(CLAUDECODE="1", CLAUDE_CODE_SESSION_ID="sess-1", CLAUDE_CONFIG_DIR=d)
        self.assertIn("(claude-3-5-sonnet-20241022)", out)

    def test_explicit_name_and_model(self):
        out, _ = self.dry_run(MOKUME_AGENT_NAME="Grok CLI", MOKUME_AGENT_MODEL="grok-5")
        self.assertIn("<sub>🤖 Assisted by Grok CLI (grok-5)</sub>", out)

    def test_unknown_ai_agent_names_its_tool(self):
        out, err = self.dry_run(AI_AGENT="grok-cli_1-0-0_agent")
        self.assertIn("Assisted by grok-cli</sub>", out)
        self.assertNotIn("判定できませんでした", err)

    def test_with_names_collaborators(self):
        proc = subprocess.run(
            ["/bin/bash", str(COMMENT), "issue", "42", "--body", "本文",
             "--with", "OpenAI Codex (gpt-6-astra)", "--with", "Grok CLI", "--dry-run"],
            capture_output=True,
            text=True,
            env=clean_env(path_prefix=stub_gh(self), CLAUDECODE="1"),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(
            "Assisted by [Claude Code](https://claude.com/claude-code)"
            " and OpenAI Codex (gpt-6-astra) and Grok CLI</sub>",
            proc.stdout,
        )

    def test_existing_signature_not_duplicated(self):
        body = "本文\n\n---\n<sub>🤖 Assisted by [Claude Code](https://claude.com/claude-code)</sub>"
        out, _ = self.dry_run(body=body, CLAUDECODE="1")
        self.assertEqual(out.count("Assisted by"), 1)

    def test_body_file_is_read(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "body.md"
            f.write_text("ファイルからの本文\n", encoding="utf-8")
            proc = subprocess.run(
                ["/bin/bash", str(COMMENT), "pr", "7", "--body-file", str(f), "--dry-run"],
                capture_output=True,
                text=True,
                env=clean_env(path_prefix=stub_gh(self), CLAUDECODE="1"),
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("ファイルからの本文", proc.stdout)
            self.assertIn("Assisted by [Claude Code]", proc.stdout)

    def test_missing_body_is_an_error(self):
        proc = subprocess.run(
            ["/bin/bash", str(COMMENT), "issue", "1", "--dry-run"],
            capture_output=True,
            text=True,
            env=clean_env(),
        )
        self.assertNotEqual(proc.returncode, 0)

    def test_bad_kind_is_an_error(self):
        proc = subprocess.run(
            ["/bin/bash", str(COMMENT), "discussion", "1", "--body", "x"],
            capture_output=True,
            text=True,
            env=clean_env(),
        )
        self.assertNotEqual(proc.returncode, 0)


class DocumentationTest(unittest.TestCase):
    """AGENTS.md と実装が食い違わないようにする。

    フックが強制できるのは Claude Code のセッションだけで、他のエージェントと人間には
    AGENTS.md しか届かない。だから両方に書く必要がある — ただし**同じことを二度書かない**。
    「何をすべきか」は AGENTS.md、「どう実現するか」(署名の文字列・検出の順序) は
    スクリプトにだけ置き、ここでその境界が保たれているかを見る。
    """

    def setUp(self):
        self.agents_md = (REPO / "AGENTS.md").read_text(encoding="utf-8")

    def test_agents_md_points_at_the_wrapper(self):
        # ラッパーを改名したらここで気付く (ドキュメントが古いパスを指し続けない)
        self.assertIn("scripts/comment.sh", self.agents_md)
        self.assertTrue(COMMENT.exists())
        self.assertIn("scripts/edit-body.sh", self.agents_md)
        self.assertTrue(EDIT_BODY.exists())

    def test_agents_md_does_not_restate_the_signature(self):
        # 署名の文字列を文書側にも書くと、変えたときに片方が古くなる。
        # 正本は scripts/comment.sh の signature() だけ
        self.assertNotIn("<sub>🤖", self.agents_md)

    def test_the_harm_behind_the_notice_is_traceable_from_the_header(self):
        """名乗りが何を塞いでいるかが、スクリプトの冒頭から辿れる (#1327 条件 5)。

        「この 1 行は何のために出ているのか」を知りたい人が最初に開くのは
        スクリプトである。実害の記述は Issue が正典なので、冒頭は番号で指す。
        """
        header = COMMENT.read_text(encoding="utf-8").split("set -euo pipefail")[0]
        self.assertIn("1327", header)


class GhInvocationTest(unittest.TestCase):
    """実際に gh へ渡す形 — 本文はファイル経由、リポジトリは明示する。

    投稿先の推定は事故のもとで、cwd の git リポジトリを文脈に取ると別のリポジトリの
    同じ番号へ飛ぶ。-R を必ず添えることをここで固定する。
    """

    def test_gh_receives_repo_and_body_file(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            log = d / "argv.txt"
            fixture = d / "view.json"
            fixture.write_text(destination_json(), encoding="utf-8")
            stub = d / "gh"
            stub.write_text(RESPONDING_GH, encoding="utf-8")
            stub.chmod(0o755)
            env = clean_env(
                path_prefix=d,
                CLAUDECODE="1",
                FIXTURE=str(fixture),
                LOG=str(log),
                GITHUB_REPOSITORY="mokume-metal/mokume",
            )
            proc = subprocess.run(
                ["/bin/bash", str(COMMENT), "issue", "42", "--body", "投稿本文"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            captured = log.read_text(encoding="utf-8")
            self.assertIn("issue", captured)
            self.assertIn("comment", captured)
            self.assertIn("42", captured)
            self.assertIn("mokume-metal/mokume", captured)
            self.assertIn("投稿本文", captured)
            self.assertIn("Assisted by [Claude Code]", captured)


@unittest.skipUnless(JQ, "jq が PATH に無い")
class DestinationNoticeTest(unittest.TestCase):
    """投稿の直前に宛先の近況を名乗る (#1327)。

    読んだ時刻と投稿する時刻の間が開くと、差し替わった判断の上に書いてしまう
    (#1291 では 1 時間 40 分が開き、12 分前に差し替わっていた判断を「そのまま効く」と
    書いたコメントが残った)。ここが見るのは 4 つ — 名乗ること・閉じている宛先は
    それも名乗ること・**止めないこと**・gh が使えないときに黙って続行することである。
    """

    def comment(self, minutes_ago, login="octocat", body="## 判断を差し替えた", kind="User"):
        at = datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)
        return {
            "createdAt": at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "author": {"__typename": kind, "login": login},
            "body": body,
        }

    def bot(self, minutes_ago):
        """github-actions の追記 (#2658)。GraphQL は Bot の login を [bot] なしで返す"""
        return self.comment(
            minutes_ago, login="github-actions", body="## 定期の検査が赤い", kind="Bot"
        )

    def run_comment(self, *args, state="OPEN", comments=None, gh=RESPONDING_GH, **env):
        directory = stub_gh(self, gh)
        fixture = directory / "view.json"
        fixture.write_text(destination_json(state, comments or []), encoding="utf-8")
        log = directory / "argv.txt"
        self.page_log = directory / "pages.txt"
        proc = subprocess.run(
            ["/bin/bash", str(COMMENT), *args],
            capture_output=True,
            text=True,
            env=clean_env(
                path_prefix=directory,
                CLAUDECODE="1",
                FIXTURE=str(fixture),
                LOG=str(log),
                PAGE_LOG=str(self.page_log),
                GITHUB_REPOSITORY="mokume-metal/mokume",
                **env,
            ),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc, log

    def pages_called(self):
        return self.page_log.read_text(encoding="utf-8").splitlines() if self.page_log.exists() else []

    def test_latest_comment_is_announced_and_posting_continues(self):
        """投稿者・相対時刻・見出しの冒頭が出て、投稿はそのまま走る (条件 1・3)。"""
        proc, log = self.run_comment(
            "issue",
            "42",
            "--body",
            "x",
            comments=[
                self.comment(100, body="## 当初の判断"),
                self.comment(12, login="maintainer", body="## 判断を差し替えた — 原因は相対パス"),
            ],
        )
        self.assertIn("宛先 issue #42", proc.stderr)
        self.assertIn("maintainer", proc.stderr)
        self.assertIn("12 分前", proc.stderr)
        self.assertIn("## 判断を差し替えた", proc.stderr)
        self.assertNotIn("当初の判断", proc.stderr, "最新ではなく古いコメントを名乗っている")
        # 止めない — gh comment まで到達している
        self.assertIn("comment", log.read_text(encoding="utf-8"))

    def test_bot_comments_do_not_bury_the_latest_human_comment(self):
        """#2660: 人が判断を差し替えた後に bot が追記しても、人の最新のコメントを名乗る。

        末尾のコメントを名乗ると、#1327 が塞いだ「読んだ後に判断が差し替わった」が、
        github-actions の追記 1 件で見えなくなる。後ろの追記は件数で添える。
        """
        proc, log = self.run_comment(
            "issue",
            "42",
            "--body",
            "x",
            comments=[
                self.comment(100, body="## 当初の判断"),
                self.comment(12, login="maintainer", body="## 判断を差し替えた — 原因は相対パス"),
                self.bot(5),
                self.bot(1),
            ],
        )
        self.assertIn(
            "最新コメント: maintainer・12 分前・「## 判断を差し替えた", proc.stderr,
            "bot の追記を最新コメントとして名乗っている",
        )
        self.assertIn("その後に bot の追記 2 件・最新「## 定期の検査が赤い」", proc.stderr)
        self.assertIn("comment", log.read_text(encoding="utf-8"))

    def test_bot_note_carries_the_reason_of_a_reopen(self):
        """parent-guard も github.token で reopen の理由を書く。件数だけでは理由が消える。"""
        reason = self.comment(
            2, login="github-actions", body="## 子が open のまま閉じられたので開き直した", kind="Bot"
        )
        proc, _ = self.run_comment(
            "issue", "42", "--body", "x", comments=[self.comment(30), reason]
        )
        self.assertIn("最新「## 子が open のまま閉じられたので開き直した」", proc.stderr)

    def test_other_bots_are_not_mistaken_for_the_appender(self):
        """GitHub App 経由で投稿するエージェントも Bot 型。除くのは追記の書き手だけ (#2660)。"""
        agent = self.comment(4, login="some-agent", body="## エージェントの判断", kind="Bot")
        proc, _ = self.run_comment(
            "issue", "42", "--body", "x", comments=[self.comment(30), agent, self.bot(1)]
        )
        self.assertIn("最新コメント: some-agent・4 分前・「## エージェントの判断」", proc.stderr)
        self.assertIn("その後に bot の追記 1 件", proc.stderr)

    def test_no_bot_note_when_the_human_comment_is_last(self):
        proc, _ = self.run_comment(
            "issue", "42", "--body", "x", comments=[self.bot(30), self.comment(3)]
        )
        self.assertIn("3 分前", proc.stderr)
        self.assertNotIn("bot の追記", proc.stderr)

    def test_only_bot_comments_in_the_window_say_so(self):
        proc, _ = self.run_comment(
            "issue", "42", "--body", "x", comments=[self.bot(30), self.bot(3)]
        )
        self.assertIn("人のコメントは無い (bot の追記 2 件・最新「## 定期の検査が赤い」)", proc.stderr)
        self.assertNotIn("最新コメント:", proc.stderr)
        self.assertNotIn("コメントはまだ無い", proc.stderr)

    def test_human_comment_pushed_out_of_the_window_is_still_named(self):
        """#2660: bot の追記で窓 (100 件) が溢れても、人の最新のコメントまで遡って名乗る。

        窓の中だけを見ると「人のコメントは無い」になり、#1327 の約束 (直前の人の判断を
        名乗る) が再び破れる
        """
        comments = [
            self.comment(300, login="maintainer", body="## 判断を差し替えた"),
            *[self.bot(299 - i) for i in range(130)],
        ]
        proc, _ = self.run_comment("issue", "42", "--body", "x", comments=comments)
        self.assertIn(
            "最新コメント: maintainer・5 時間前・「## 判断を差し替えた」 (その後に bot の追記 130 件",
            proc.stderr,
        )
        self.assertEqual(len(self.pages_called()), 2, "人の手が見つかるまで遡っていない")

    def test_paging_stops_at_the_limit_and_says_so(self):
        """遡るのには上限がある (plan-record と同じ部品)。打ち切ったらそう名乗る。"""
        comments = [self.comment(300), *[self.bot(299 - i) for i in range(250)]]
        proc, _ = self.run_comment(
            "issue", "42", "--body", "x", comments=comments, BOT_HAND_MAX_PAGES="2"
        )
        self.assertIn("人のコメントは新しい順の 200 件に無い (上限で遡りを打ち切った", proc.stderr)
        self.assertEqual(len(self.pages_called()), 2)

    def test_comment_by_a_deleted_user_counts_as_human(self):
        """作者の分からないコメントは bot の手と言わない (scripts/bot-hand.sh の向き)。"""
        deleted = self.comment(8, body="## 退会した人の判断")
        deleted["author"] = None
        proc, _ = self.run_comment(
            "issue", "42", "--body", "x", comments=[deleted, self.bot(2)]
        )
        self.assertIn("ghost・8 分前・「## 退会した人の判断」", proc.stderr)
        self.assertIn("その後に bot の追記 1 件", proc.stderr)

    def test_closed_destination_says_so(self):
        """条件 2。#1291 は投稿の 5 分後に closed になった。"""
        proc, _ = self.run_comment(
            "issue", "42", "--body", "x", state="CLOSED", comments=[self.comment(5)]
        )
        self.assertIn("(closed)", proc.stderr)

    def test_merged_pull_request_says_so(self):
        proc, _ = self.run_comment(
            "pr", "7", "--body", "x", state="MERGED", comments=[self.comment(5)]
        )
        self.assertIn("(merged)", proc.stderr)

    def test_open_destination_carries_no_state_mark(self):
        """開いている宛先に印は要らない (毎回出ると読み飛ばされる)。"""
        proc, _ = self.run_comment("issue", "42", "--body", "x", comments=[self.comment(5)])
        self.assertIn("宛先 issue #42 —", proc.stderr)

    def test_destination_without_comments(self):
        proc, _ = self.run_comment("issue", "42", "--body", "x")
        self.assertIn("コメントはまだ無い", proc.stderr)

    def test_relative_age_scales(self):
        for minutes, expected in ((0, "たった今"), (12, "12 分前"), (180, "3 時間前"), (2880, "2 日前")):
            with self.subTest(minutes=minutes):
                proc, _ = self.run_comment(
                    "issue", "42", "--body", "x", comments=[self.comment(minutes)]
                )
                self.assertIn(expected, proc.stderr)

    def test_marker_line_is_not_mistaken_for_the_heading(self):
        """この経路自身が付けるマーカー行を見出しと取り違えない。

        plan-record のプランは <!-- mokume-plan-record: … --> で始まるので、
        素朴に「最初の行」を取ると全部これになる。
        """
        proc, _ = self.run_comment(
            "issue",
            "42",
            "--body",
            "x",
            comments=[
                self.comment(3, body="<!-- mokume-plan-record: abc -->\n## 着手時のプラン\n\n本文")
            ],
        )
        self.assertIn("## 着手時のプラン", proc.stderr)
        self.assertNotIn("mokume-plan-record", proc.stderr)

    def test_long_heading_is_truncated(self):
        """1 行に収める。切り詰めは jq 側なので、マルチバイトを割らない。"""
        proc, _ = self.run_comment(
            "issue", "42", "--body", "x", comments=[self.comment(3, body="あ" * 120)]
        )
        self.assertIn("…", proc.stderr)
        self.assertNotIn("あ" * 60, proc.stderr)
        self.assertEqual(1, len([n for n in proc.stderr.splitlines() if n.startswith("宛先")]))

    def test_dry_run_announces_too(self):
        """条件 1: --dry-run でも同じものが出る。

        投稿の前に読み直させるのが目的なので、下見のほうにこそ要る。
        """
        proc, _ = self.run_comment(
            "issue", "42", "--body", "x", "--dry-run", comments=[self.comment(7, login="maintainer")]
        )
        self.assertIn("宛先 issue #42", proc.stderr)
        self.assertIn("7 分前", proc.stderr)
        self.assertIn("gh issue comment 42", proc.stdout)

    def test_unusable_gh_is_silent_and_posting_still_works(self):
        """条件 4: 署名という本務を、付加的な表示の失敗で落とさない。"""
        proc, _ = self.run_comment("issue", "42", "--body", "x", "--dry-run", gh=FAILING_GH)
        self.assertNotIn("宛先", proc.stderr)
        self.assertIn("Assisted by [Claude Code]", proc.stdout)


if __name__ == "__main__":
    unittest.main()
