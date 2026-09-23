#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/comment.sh と scripts/agent-comment-guard.sh の検査 (#18)。

守りたいのは 3 つ:
  1. 素の gh でコメントしようとしたら差し戻される (付け忘れの経路を塞ぐ)
  2. ラッパー経由なら、どの AI が書いたかの署名が自動で付く
  3. 投稿の直前に、宛先の近況が 1 行で名乗られる (#1327)

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
]


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
# **境界は「スレッドへの発言か」の 1 本。** Issue / PR の本文・マージコミットの本文は
# 発言ではないので素通しする (署名の作法はスレッドに並ぶコメントを対象にしている)。
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
        "pass",
        'gh issue create --title "題" --body "本文"',
        "Issue の本文。スレッドへの発言ではない",
    ),
    ("issue", "edit"): (
        {"--body", "--body-file"},
        "pass",
        "gh issue edit 42 --body-file body.md",
        "既存本文の書き換え。新しい発言は増えない",
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
        "pass",
        'gh pr create --title "題" --body "本文"',
        "PR の本文。スレッドへの発言ではない",
    ),
    ("pr", "edit"): (
        {"--body", "--body-file"},
        "pass",
        'gh pr edit 42 --body "本文"',
        "既存本文の書き換え",
    ),
    ("pr", "merge"): (
        {"--body", "--body-file"},
        "pass",
        'gh pr merge 42 --squash --body "マージ本文"',
        "マージコミットの本文",
    ),
    ("pr", "revert"): (
        {"--body", "--body-file"},
        "pass",
        'gh pr revert 42 --body "戻す理由"',
        "revert として作る PR の本文",
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

# view には固定の JSON を**実物の jq**で評価させ、comment は引数と本文を記録する。
# --jq の式はラッパーが書いたものがそのまま渡るので、式自体がここで検査される
# (スタブが答えを作ると、式が壊れても緑のままになってしまう)
RESPONDING_GH = """#!/bin/bash
if [ "$2" = view ]; then
  expr=""
  while [ $# -gt 0 ]; do
    if [ "$1" = --jq ]; then expr="$2"; shift 2; else shift; fi
  done
  exec jq -r "$expr" "$FIXTURE"
fi
printf '%s\\n' "$@" > "$LOG"
cat "${!#}" >> "$LOG"
"""


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

    def run_guard(self, command, cwd=None):
        payload = json.dumps(
            {"tool_input": {"command": command}, **({"cwd": cwd} if cwd else {})}
        )
        proc = subprocess.run(
            ["/bin/bash", str(GUARD)],
            input=payload,
            capture_output=True,
            text=True,
            env=clean_env(),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def assert_denied(self, command, cwd=None):
        out = self.run_guard(command, cwd=cwd)
        self.assertTrue(out, f"差し戻されるはずが素通しした: {command}")
        decision = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")
        self.assertIn("scripts/comment.sh", decision["permissionDecisionReason"])
        return decision["permissionDecisionReason"]

    def assert_passed(self, command, cwd=None):
        self.assertEqual(
            self.run_guard(command, cwd=cwd), "", f"素通しのはずが差し戻された: {command}"
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
        pr-identity-guard.sh が同じ判定で素通ししているのと揃える。
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
                else:
                    self.assert_passed(command)

    def test_review_comment_flag_alone_passes(self):
        """gh pr review の --comment はレビュー**種別**で、本文ではない (境界)。

        名前が同じなので close / reopen の --comment と同じに見えるが、こちらは
        本文を伴わなければ発言が無い (--approve だけのレビューと同じ扱い)。
        """
        self.assert_passed("gh pr review 42 --comment")


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
            fixture.write_text('{"state":"OPEN","comments":[]}', encoding="utf-8")
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

    def comment(self, minutes_ago, login="octocat", body="## 判断を差し替えた"):
        at = datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)
        return {
            "createdAt": at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "author": {"login": login},
            "body": body,
        }

    def run_comment(self, *args, state="OPEN", comments=None, gh=RESPONDING_GH):
        directory = stub_gh(self, gh)
        fixture = directory / "view.json"
        fixture.write_text(
            json.dumps({"state": state, "comments": comments or []}), encoding="utf-8"
        )
        log = directory / "argv.txt"
        proc = subprocess.run(
            ["/bin/bash", str(COMMENT), *args],
            capture_output=True,
            text=True,
            env=clean_env(
                path_prefix=directory,
                CLAUDECODE="1",
                FIXTURE=str(fixture),
                LOG=str(log),
                GITHUB_REPOSITORY="mokume-metal/mokume",
            ),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc, log

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
