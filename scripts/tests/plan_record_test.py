#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/plan-record.sh の検査 (#35)。

守りたいのは 4 つ (Issue #35 の完了条件):
  1. プラン承認 (ExitPlanMode) の直後に、投稿の指示が出る
  2. 未投稿のままセッションを終えようとすると差し戻される
  3. 投稿本文から絶対パスとホームが畳まれ、秘密らしき文字列があれば投稿が止まる
  4. 1〜3 がリポジトリ側だけで完結している (個人環境のフックに依存しない)

フックの契約 (stdin の JSON → 記録ファイル + stderr の指示 + 終了コード) を
サブプロセス経由で検証する。投稿先の解決と投稿済み判定は gh に依存するので、
PATH の先頭に偽の gh を置いて振る舞いを環境変数で決める。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "plan-record.sh"

# 着手時の再チェック (ADR-0031 決定 4)。capture はプランに「対象 Issue の番号」と
# 「完了条件の現況」の両方を要求するので、主題でないテストにはこれを自動で足す
RECHECK = "\n\n#12 の完了条件 1 は、着手時点でもまだ有効。\n"
COMMENT = REPO / "scripts" / "comment.sh"
SETTINGS = REPO / ".claude" / "settings.json"

# 引数から用件だけを見分ける最小の gh。番号を返す問い合わせと、コメント本文を返す
# 問い合わせの二つしか使われない。前者は state による絞り込みまで見るので、末尾の
# -q に来る jq クエリを本物と同じように適用する
FAKE_GH = """#!/bin/sh
kind=$1
query=.
prev=
for arg in "$@"; do
  [ "$prev" = "-q" ] && query=$arg
  prev=$arg
done
case "$*" in
  # 二重着手の跡見 (#642) は comments を JSON のまま引く (url が要る)。呼び手は後段で
  # jq を掛けるので、ここで絞り込まない。既存の *comments* 分岐 (本文だけを返す近道) と
  # 区別するため、この変数が置かれているときだけ先に応える
  *comments*)
    if [ -n "${FAKE_GH_ISSUE_STATE:-}" ] && [ "$kind" = issue ]; then
      printf '%s' "$FAKE_GH_ISSUE_STATE" | jq -r "$query"
      exit 0
    fi
    ;;
esac
case "$*" in
  # コメントは種別ごとに出し分けられるようにする。#631 の筋 (プランは Issue にあり
  # PR には無い) は、両方が同じものを返す偽 gh では表現できない。
  # ${VAR-...} はコロン無し — 空文字を渡せば「そちらには無い」を明示できる
  *comments*)
    case "$kind" in
      pr)    printf '%s\\n' "${FAKE_GH_PR_COMMENTS-${FAKE_GH_COMMENTS:-}}" ;;
      issue) printf '%s\\n' "${FAKE_GH_ISSUE_COMMENTS-${FAKE_GH_COMMENTS:-}}" ;;
      *)     printf '%s\\n' "${FAKE_GH_COMMENTS:-}" ;;
    esac
    exit 0 ;;
esac
json=
case "$kind" in
  # FAKE_GH_PR は「open な PR がその番号」の近道。state を変えたいときは
  # FAKE_GH_PR_JSON へ {"number":n,"state":"MERGED"} のように直接置く
  pr)
    json=${FAKE_GH_PR_JSON:-}
    [ -n "$json" ] || [ -z "${FAKE_GH_PR:-}" ] || json='{"number":'$FAKE_GH_PR',"state":"OPEN"}'
    ;;
  issue)
    # 実在しない番号を表現する (#646 — 候補は実在確認を通ったものだけが並ぶ)。
    # 引数は issue view <番号> ... なので番号は $3
    case " ${FAKE_GH_MISSING:-} " in *" $3 "*) exit 1 ;; esac
    json=${FAKE_GH_ISSUE_JSON:-}
    [ -n "$json" ] || [ -z "${FAKE_GH_ISSUE:-}" ] || json='{"number":'$FAKE_GH_ISSUE'}'
    ;;
esac
[ -n "$json" ] || exit 1
printf '%s' "$json" | jq -r "$query"
"""

def issue_state(in_progress=False, plans=()):
    """#642 の跡見が引く JSON を組む。plans は (記録 ID, URL) の並び。

    in_progress は「ラベルが在っても名乗らない」ことを見るために残してある
    (跡見はラベルを読まない — 付け主を判定できないため)。
    """
    return json.dumps(
        {
            "labels": [{"name": "status: in progress"}] if in_progress else [],
            "comments": [
                {"body": f"<!-- mokume-plan-record: {rid} -->\n計画。", "url": url}
                for rid, url in plans
            ],
        }
    )


MERGED_PR = '{"number":108,"state":"MERGED"}'
CLOSED_PR = '{"number":108,"state":"CLOSED"}'

# エージェント検出・フック制御に関わる環境変数。呼び出し元 (このテストを走らせている
# エージェントのセッション) の env が漏れると、検出できたのか漏れたのか区別できない
LEAKY_ENV = [
    "MOKUME_PLAN_RECORD",
    "MOKUME_PLAN_RECORD_DEBUG",
    "MOKUME_AGENT_NAME",
    "MOKUME_AGENT_URL",
    "CLAUDECODE",
    "CLAUDE_CODE_ENTRYPOINT",
    "AI_AGENT",
    "CODEX_SANDBOX",
    "CODEX_SANDBOX_NETWORK_DISABLED",
    "CODEX_HOME",
    "GITHUB_REPOSITORY",
]


class PlanRecordTestCase(unittest.TestCase):
    def setUp(self):
        self.workdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.workdir.cleanup)
        root = Path(self.workdir.name)

        self.repo = root / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "feat/plan-123")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        # 使い捨てのリポジトリは手元の署名設定から独立させる (#344)
        self.git("config", "commit.gpgsign", "false")
        (self.repo / "README.md").write_text("hi\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "init")

        bindir = root / "bin"
        bindir.mkdir()
        gh = bindir / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        self.bindir = bindir

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True)

    def env(self, **overrides):
        env = {k: v for k, v in os.environ.items() if k not in LEAKY_ENV}
        env["PATH"] = f"{self.bindir}:{env['PATH']}"
        env.update(overrides)
        return env

    def run_hook(self, mode, payload=None, stdin="", **env):
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), mode],
            input=json.dumps(payload) if payload is not None else stdin,
            capture_output=True,
            text=True,
            cwd=str(self.repo),
            env=self.env(**env),
            timeout=30,
        )

    def capture(self, plan, recheck=True, **env):
        """capture を叩く。

        recheck が真なら、完了条件の再チェック (ADR-0031 決定 4) をプランの末尾へ
        自動で足す — 実際のプランには必ず書かれるものなので、ここが主題でないテストに
        毎回書かせない。検査そのものを見るテストだけ recheck=False を渡す。
        """
        if recheck:
            plan = plan + RECHECK
        return self.run_hook(
            "capture",
            {
                "tool_name": "ExitPlanMode",
                "cwd": str(self.repo),
                "session_id": "abcd1234-ef56-7890",
                "tool_input": {"plan": plan},
            },
            **env,
        )

    def capture_payload(self, **overrides):
        """tool_input / tool_response を差し替えて capture を叩く。

        プラン本文の置き場は Claude Code のバージョンで動くので、素の payload を
        組めるようにしておく (self.capture は旧来の tool_input.plan 形式の近道)。
        """
        env = {k: v for k, v in overrides.items() if k.isupper()}
        payload = {
            "tool_name": "ExitPlanMode",
            "cwd": str(self.repo),
            "session_id": "abcd1234-ef56-7890",
            **{k: v for k, v in overrides.items() if not k.isupper()},
        }
        return self.run_hook("capture", payload, **env)

    def guard(self, **env):
        return self.run_hook("guard", {"cwd": str(self.repo)}, **env)

    def records(self):
        return sorted((self.repo / ".git" / "mokume-plan-records").glob("*.md"))

    def metas(self):
        return sorted((self.repo / ".git" / "mokume-plan-records").glob("*.meta"))

    def marker(self):
        return f"<!-- mokume-plan-record: {self.record_id()} -->"

    def record_id(self):
        text = self.records()[0].read_text(encoding="utf-8")
        return text.split("mokume-plan-record: ")[1].split(" ")[0]

    def assert_not_targeted(self, number, stderr):
        """その番号が「投稿先」として現れていないことだけを見る。

        stderr には記録ファイルのパスが載り、その名前には Unix timestamp が入る
        (plan-record.sh の id="${session%%-*}-$(date +%s)")。番号を stderr 全体から
        探すと timestamp を拾って偶発的に落ちるので、検査の網を投稿先の形に絞る
        (投稿先は必ず scripts/comment.sh <kind> <番号> の形で出る。#113)。
        """
        for kind in ("issue", "pr"):
            self.assertNotIn(f"scripts/comment.sh {kind} {number}", stderr)

    # --- サニタイズ (完了条件 3) ---------------------------------------------

    def test_sanitize_collapses_repo_and_home_paths(self):
        body = (
            "触るのは /Users/so/Repos/mokume/.claude/worktrees/wt/scripts/comment.sh。\n"
            "他の人の /home/alice/notes.md も引用した。\n"
        )
        out = subprocess.run(
            ["/bin/bash", str(SCRIPT), "sanitize",
             "/Users/so/Repos/mokume/.claude/worktrees/wt"],
            input=body, capture_output=True, text=True, check=True,
        ).stdout
        self.assertIn("触るのは scripts/comment.sh", out)
        self.assertIn("~/notes.md", out)
        self.assertNotIn("/Users/so", out)
        self.assertNotIn("alice", out)

    def test_sanitize_survives_regex_metacharacters_in_path(self):
        # worktree のディレクトリ名に括弧やドットが入っても sed が壊れないこと
        root = "/Users/so/Repos/mokume (old)/.claude/wt+1"
        out = subprocess.run(
            ["/bin/bash", str(SCRIPT), "sanitize", root],
            input=f"{root}/scripts/comment.sh を直す\n",
            capture_output=True, text=True,
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("scripts/comment.sh を直す", out.stdout)

    # --- 検査 (完了条件 3) ---------------------------------------------------

    def test_scan_flags_secrets_and_leaves_prose_alone(self):
        body = (
            "export GITHUB_TOKEN=ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789\n"
            "token は環境変数で渡す (値は書かない)\n"
            "参照は $API_KEY と <your-token> のまま\n"
        )
        out = subprocess.run(
            ["/bin/bash", str(SCRIPT), "scan"],
            input=body, capture_output=True, text=True, check=True,
        ).stdout
        self.assertIn("BLOCK", out)
        self.assertIn("行 1", out)
        # 2〜3 行目は説明文と伏せ字なので、秘密情報として拾ってはいけない
        self.assertNotIn("行 2", out)
        self.assertNotIn("行 3", out)

    def test_scan_warns_without_blocking(self):
        body = "連絡は alice@example.com。参照は op://Vault/item/credential\n"
        out = subprocess.run(
            ["/bin/bash", str(SCRIPT), "scan"],
            input=body, capture_output=True, text=True, check=True,
        ).stdout
        self.assertIn("WARN", out)
        self.assertNotIn("BLOCK", out)

    def test_scan_ignores_github_noreply(self):
        out = subprocess.run(
            ["/bin/bash", str(SCRIPT), "scan"],
            input="Assisted-by: Claude <noreply@anthropic.com>\n",
            capture_output=True, text=True, check=True,
        ).stdout
        self.assertEqual(out.strip(), "")

    # --- capture (完了条件 1) -------------------------------------------------

    def test_capture_writes_sanitized_record_and_instructs(self):
        result = self.capture(
            f"## 方針\n\n{self.repo}/README.md を直す。却下案: 全面書き換え。\n",
            FAKE_GH_PR="42",
        )
        self.assertEqual(result.returncode, 2, result.stderr)

        files = self.records()
        self.assertEqual(len(files), 1)
        body = files[0].read_text(encoding="utf-8")
        self.assertIn("却下案: 全面書き換え", body)
        self.assertIn("README.md を直す", body)
        self.assertNotIn(str(self.repo), body)  # 絶対パスは畳まれている
        self.assertIn("<!-- mokume-plan-record: ", body)  # 投稿済み判定の目印

        self.assertIn("scripts/comment.sh pr 42", result.stderr)

    def test_capture_instructs_through_the_wrapper_not_bare_gh(self):
        # 素の gh は agent-comment-guard.sh が差し戻す (#18)。指示がそこへ誘導したら、
        # 言われたとおりに打ったエージェントが弾かれて手が止まる
        result = self.capture("計画。\n", FAKE_GH_PR="42")
        self.assertIn("bash scripts/comment.sh", result.stderr)
        self.assertNotIn("gh pr comment", result.stderr)
        self.assertNotIn("gh issue comment", result.stderr)

    def test_record_carries_no_signature_of_its_own(self):
        # 署名は投稿時に実行環境から判定して付く (#18)。ここで焼き込むと、
        # 記録を作った環境と投稿した環境が違うときに嘘の名前が残る
        self.capture("計画。\n", FAKE_GH_PR="42")
        self.assertNotIn("Assisted by", self.records()[0].read_text(encoding="utf-8"))

    def test_record_flows_through_the_wrapper_intact(self):
        # #18 と #35 の継ぎ目。記録をラッパーに通したとき、目印が生き残り、
        # 署名がちょうど 1 つ付くこと
        self.capture("計画。\n", FAKE_GH_PR="42")
        record = self.records()[0]
        proc = subprocess.run(
            ["/bin/bash", str(COMMENT), "pr", "42", "--body-file", str(record), "--dry-run"],
            capture_output=True, text=True, env=self.env(CLAUDECODE="1"),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("<!-- mokume-plan-record: ", proc.stdout)
        self.assertEqual(proc.stdout.count("Assisted by"), 1)
        self.assertIn("Assisted by [Claude Code]", proc.stdout)

    def test_capture_falls_back_to_issue_named_by_the_plan(self):
        result = self.capture("Closes #77 のための計画。\n", FAKE_GH_ISSUE="77")
        self.assertIn("scripts/comment.sh issue 77", result.stderr)

    def test_capture_refuses_when_the_plan_carries_a_secret(self):
        result = self.capture(
            "手順:\n1. export GITHUB_TOKEN=ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789\n",
            FAKE_GH_PR="42",
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.records(), [])  # 秘密を .git の中に置き去りにしない
        self.assertIn("秘密情報", result.stderr)
        # 検出した値そのものを再掲しない (hook の出力も記録に残るため)
        self.assertNotIn("ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ", result.stderr)

    # --- 着手時の再チェック (ADR-0031 決定 4) ---------------------------------

    def test_capture_refuses_a_plan_without_a_recheck(self):
        """トリアージ済みのラベルは、付いた時点の判断しか表さない (#618)。

        直近 100 Issue のうち 11 件で着手時に完了条件が動いている。#457 は起票時の
        3 条件が着手前に既に満たされており (別の PR が解消していた)、#448 は載せ替える
        対象が 4 つではなく 2 つだった。再チェックは実務では既に行われているのに、
        促すものが何も無かった。
        """
        result = self.capture("## 方針\n\n#12 を直す。\n", recheck=False, FAKE_GH_PR="42")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.records(), [])  # 記録は作らない — 書き直させる
        self.assertIn("完了条件の現況", result.stderr)

    def test_capture_refuses_a_plan_without_an_issue_number(self):
        # どの Issue の完了条件を見たのかが分からないと、突き合わせたことにならない
        result = self.capture(
            "## 方針\n\n完了条件はまだ有効。\n", recheck=False, FAKE_GH_PR="42"
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.records(), [])
        self.assertIn("対象 Issue の番号", result.stderr)

    def test_capture_accepts_the_other_verdicts(self):
        """現況は 3 通りある。「まだ有効」以外も通ること。

        語彙を狭く取ると、正しく再チェックしたプランまで差し戻され、
        MOKUME_PLAN_RECORD=0 で外す癖がついて機構ごと形骸化する
        (check-drawing-evidence.sh が絵の参照を広く取っているのと同じ理由)。
        """
        for plan in (
            "#12 の条件 2 は既に満たされている (PR #34 が解消済み)。\n",
            "#12 の条件 3 は現実に合わないので、Issue 本文を先に更新した。\n",
            "#12 の完了条件を現行コードと突き合わせた。差し替えは要らない。\n",
        ):
            with self.subTest(plan=plan):
                for f in self.records():
                    f.unlink()
                result = self.capture(plan, recheck=False, FAKE_GH_PR="42")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(len(self.records()), 1, result.stderr)

    def test_capture_still_records_when_no_target_exists_yet(self):
        result = self.capture("PR も Issue もまだ無い状態の計画。\n")
        self.assertEqual(len(self.records()), 1)
        self.assertIn("まだありません", result.stderr)

    def test_capture_reports_warnings_for_human_judgement(self):
        result = self.capture("連絡先 alice@example.com を使う。\n", FAKE_GH_PR="42")
        self.assertIn("メールアドレス", result.stderr)
        self.assertEqual(len(self.records()), 1)  # 警告では止めない

    def test_capture_outside_git_is_silent(self):
        outside = Path(self.workdir.name) / "plain"
        outside.mkdir()
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT), "capture"],
            input=json.dumps(
                {"cwd": str(outside), "session_id": "x", "tool_input": {"plan": "計画"}}
            ),
            capture_output=True, text=True, cwd=str(outside), env=self.env(), timeout=30,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")

    # --- プラン本文の取り出し (置き場は Claude Code のバージョンで動く) --------

    def test_capture_reads_the_plan_from_the_tool_response(self):
        # 現行の ExitPlanMode はモデルが引数を取らず、本文は tool_response に返る。
        # tool_input だけを見ていると、ここで無言のまま記録が作られない
        result = self.capture_payload(
            tool_input={"_targetMode": "auto"},
            tool_response={"plan": "## 方針\n\n却下案: 全面書き換え。#12 の完了条件はまだ有効。\n", "isAgent": False},
            FAKE_GH_PR="42",
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(len(self.records()), 1)
        self.assertIn("却下案: 全面書き換え", self.records()[0].read_text(encoding="utf-8"))

    def test_capture_reads_the_plan_from_the_file_it_was_written_to(self):
        plan_file = Path(self.workdir.name) / "plan.md"
        plan_file.write_text(
            "## 方針\n\nファイル越しに渡されたプラン。#12 の完了条件はまだ有効。\n",
            encoding="utf-8",
        )
        result = self.capture_payload(
            tool_input={"_targetMode": "auto"},
            tool_response={"filePath": str(plan_file)},
            FAKE_GH_PR="42",
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(
            "ファイル越しに渡されたプラン", self.records()[0].read_text(encoding="utf-8")
        )

    def test_capture_speaks_up_when_the_plan_cannot_be_found(self):
        # ExitPlanMode が通った以上プランは必ずある。取り出せないなら異常なので、
        # 黙って諦めると guard も黙り、仕組みごと無言で無効化される
        result = self.capture_payload(
            tool_input={"_targetMode": "auto"}, tool_response={}, FAKE_GH_PR="42"
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.records(), [])
        self.assertIn("取り出せませんでした", result.stderr)
        # 次に直す人のために、受け取ったキーだけを見せる (値は出さない)
        self.assertIn("_targetMode", result.stderr)

    # --- 何もせず終わった理由の可視化 -----------------------------------------

    def test_debug_explains_why_nothing_happened(self):
        outside = Path(self.workdir.name) / "plain"
        outside.mkdir()
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT), "capture"],
            input=json.dumps(
                {"cwd": str(outside), "session_id": "x", "tool_input": {"plan": "計画"}}
            ),
            capture_output=True, text=True, cwd=str(outside),
            env=self.env(MOKUME_PLAN_RECORD_DEBUG="1"), timeout=30,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("plan-record:", result.stderr)
        self.assertIn("git リポジトリの外", result.stderr)

    def test_debug_is_off_by_default(self):
        # 通常運転では黙っていること
        result = self.capture_payload(
            tool_input={"plan": "計画。\n"}, MOKUME_PLAN_RECORD="0"
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")

    def test_debug_explains_being_disabled(self):
        result = self.capture_payload(
            tool_input={"plan": "計画。\n"},
            MOKUME_PLAN_RECORD="0", MOKUME_PLAN_RECORD_DEBUG="1",
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("無効化されている", result.stderr)

    # --- 投稿先の解決 -------------------------------------------------------

    def test_capture_posts_to_a_merged_pull_request(self):
        # マージすると PR は MERGED になる。ここで見失うと、規約どおり PR へ
        # 投稿を済ませたセッションほど閉じた Issue へ催促される
        result = self.capture(
            "Closes #77 のための計画。\n", FAKE_GH_PR_JSON=MERGED_PR, FAKE_GH_ISSUE="77"
        )
        self.assertIn("scripts/comment.sh pr 108", result.stderr)
        self.assertNotIn("issue 77", result.stderr)

    def test_capture_skips_an_abandoned_pull_request(self):
        # 放棄された PR (CLOSED) は器として死んでいるので、名乗った Issue へ回す
        result = self.capture(
            "Closes #77 のための計画。\n", FAKE_GH_PR_JSON=CLOSED_PR, FAKE_GH_ISSUE="77"
        )
        self.assertIn("scripts/comment.sh issue 77", result.stderr)

    def test_capture_ignores_a_hex_suffix_in_the_branch_name(self):
        # claude/<説明>-<6 桁 hex>。936 は無関係な Issue として実在しうるので、
        # 実在確認を通り抜けてプランが撃ち込まれる
        self.git("checkout", "-q", "-b", "claude/batch-issue-cleanup-c936e5")
        result = self.capture("名乗りの無い計画。\n", FAKE_GH_ISSUE="936")
        self.assertIn("まだありません", result.stderr)
        self.assert_not_targeted("936", result.stderr)

    def test_capture_ignores_an_all_digit_hex_suffix(self):
        # hex が全数字だと「区切りに接した数字だけ」の網は通ってしまうので、
        # ここを守っているのは末尾 hex を落とす sed だけになる (#113)
        self.git("checkout", "-q", "-b", "claude/batch-issue-cleanup-123456")
        result = self.capture("名乗りの無い計画。\n", FAKE_GH_ISSUE="123456")
        self.assertIn("まだありません", result.stderr)
        self.assert_not_targeted("123456", result.stderr)

    def test_capture_ignores_digits_glued_to_letters_in_the_branch_name(self):
        # worktree の自動生成名。0127 は英字に挟まれたハッシュの断片
        self.git("checkout", "-q", "-b", "worktree-bridge-cse_0127aTN6krq7fqrr56rh6gbc")
        result = self.capture("名乗りの無い計画。\n", FAKE_GH_ISSUE="127")
        self.assertIn("まだありません", result.stderr)
        self.assert_not_targeted("127", result.stderr)

    def test_capture_still_reads_a_delimited_number_from_the_branch_name(self):
        # 区切りに接した数字は従来どおり拾う (推定の親切さを落とさない)
        for branch in ("issues-123", "fix/123-foo", "claude/fix-123-c936e5"):
            with self.subTest(branch=branch):
                self.git("checkout", "-q", "-b", branch)
                result = self.capture("名乗りの無い計画。\n", FAKE_GH_ISSUE="123")
                self.assertIn("scripts/comment.sh issue 123", result.stderr)

    # --- guard (完了条件 2) ---------------------------------------------------

    def test_guard_blocks_stop_while_the_plan_is_unposted(self):
        self.capture("計画。\n", FAKE_GH_PR="42")
        result = self.guard(FAKE_GH_PR="42")
        self.assertEqual(result.returncode, 2)
        self.assertIn("scripts/comment.sh pr 42", result.stderr)

    def test_guard_clears_the_record_once_it_is_posted(self):
        self.capture("計画。\n", FAKE_GH_PR="42")
        result = self.guard(
            FAKE_GH_PR="42",
            FAKE_GH_COMMENTS=f"<!-- mokume-plan-record: {self.record_id()} -->",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.records(), [])

    def test_guard_is_not_fooled_by_another_records_marker(self):
        # 投稿済み判定は GitHub 側に問い合わせる。別の記録の目印で黙ってはいけない
        self.capture("計画。\n", FAKE_GH_PR="42")
        result = self.guard(
            FAKE_GH_PR="42",
            FAKE_GH_COMMENTS="<!-- mokume-plan-record: someone-else-1700000000 -->",
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(len(self.records()), 1)

    def test_guard_clears_a_record_posted_to_a_merged_pull_request(self):
        self.capture("計画。\n", FAKE_GH_PR_JSON=MERGED_PR)
        result = self.guard(
            FAKE_GH_PR_JSON=MERGED_PR,
            FAKE_GH_COMMENTS=f"<!-- mokume-plan-record: {self.record_id()} -->",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.records(), [])

    def test_guard_is_quiet_when_there_is_nowhere_to_post(self):
        self.capture("PR がまだ無い計画。\n")
        result = self.guard()  # PR も Issue も解決できない
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.records()), 1)  # 記録は残す (急かさないだけ)

    def test_guard_ignores_records_from_another_branch(self):
        self.capture("別ブランチで立てた計画。\n", FAKE_GH_PR="42")
        self.git("checkout", "-q", "-b", "other")
        result = self.guard(FAKE_GH_PR="42")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_guard_gives_up_after_repeated_nags(self):
        self.capture("計画。\n", FAKE_GH_PR="42")
        for _ in range(3):
            self.assertEqual(self.guard(FAKE_GH_PR="42").returncode, 2)
        # 4 回目は諦めて人間の判断へ返す (無限に終われないセッションを作らない)
        self.assertEqual(self.guard(FAKE_GH_PR="42").returncode, 0)
        self.assertEqual(self.records(), [])

    def test_guard_shows_how_to_escape_a_wrong_target(self):
        # 投稿先の推定が外れたとき、差し戻しを読むだけで抜けられる必要がある
        self.capture("計画。\n", FAKE_GH_PR="42")
        result = self.guard(FAKE_GH_PR="42")
        self.assertEqual(result.returncode, 2)
        self.assertIn("投稿先が違う", result.stderr)

    def test_guard_can_be_disabled(self):
        self.capture("計画。\n", FAKE_GH_PR="42")
        result = self.guard(FAKE_GH_PR="42", MOKUME_PLAN_RECORD="0")
        self.assertEqual(result.returncode, 0)

    # --- capture が指示した先も見る (#631) -----------------------------------
    # AGENTS.md 「進め方」は 4 (プランを Issue へ) → 6 (PR) の順を求めるので、guard の
    # 時点では resolve_target の答えが Issue から PR へ移っている。引き直した先だけを
    # 見ていた頃は、規約どおりに進めたセッションが毎回差し戻されていた。

    # --- 見出しの番号も候補にする (#655) -------------------------------------
    # recheck_missing は本文のどこかに #N が在れば通すが、plan_targets は名乗りの綴りを
    # 要求していた。`対象 Issue: #655` のように書くと片方だけを満たし、番号は本文に在るのに
    # 投稿先が確定しなかった。投稿済みプラン 112 件で測ると、番号はプランのタイトルに書くのが
    # 慣行 (90 件・当たり 98.9%) だったので、そこを見る。

    def test_capture_reads_the_number_from_the_heading(self):
        """見出しの番号で確定する (名乗りが無くてもブランチ名に頼らない)。"""
        result = self.capture("# #646 見出しに番号がある\n\n本文。\n", FAKE_GH_ISSUE="1")
        self.assertNotIn("確定できません", result.stderr)
        self.assertIn("scripts/comment.sh issue 646", result.stderr)

    def test_capture_treats_heading_and_claim_of_the_same_number_as_one(self):
        """見出しと名乗りが同じ番号なら候補は 1 件 (同じ先を 2 度並べない)。"""
        result = self.capture(
            "# #646 見出しと名乗りが揃っている\n\nCloses #646\n", FAKE_GH_ISSUE="1"
        )
        self.assertNotIn("確定できません", result.stderr)
        self.assertIn("scripts/comment.sh issue 646", result.stderr)

    def test_capture_lists_both_when_heading_and_claim_disagree(self):
        """食い違うときは並べる — 見出しを最優先で 1 つに決めると誤爆する (実測で 1 件)。"""
        result = self.capture(
            "# #646 見出しと名乗りが違う\n\nCloses #631\n", FAKE_GH_ISSUE="1"
        )
        self.assertIn("投稿先を確定できません", result.stderr)
        self.assertIn("scripts/comment.sh issue 646", result.stderr)
        self.assertIn("scripts/comment.sh issue 631", result.stderr)

    def test_capture_puts_the_heading_first(self):
        """見出しが先頭の候補になる (催促や跡見が見る「先頭」がそちらであること)。"""
        self.capture("# #646 見出しが先\n\nCloses #631\n", FAKE_GH_ISSUE="1")
        meta = self.metas()[0].read_text(encoding="utf-8")
        targets = [l for l in meta.splitlines() if l.startswith("target=")]
        self.assertEqual(targets, ["target=issue 646", "target=issue 631"])

    def test_capture_ignores_headings_without_a_hash_number(self):
        """`#N` の形でない見出しを拾わない。

        **数字を含む見出しは普通にある** (`### 1. 決めたこと` / `## 3 つの案`)。そこを
        番号と読むと、候補が本文の節番号で埋まって毎回「確定できません」に落ちる。
        """
        result = self.capture(
            "# 番号の無いタイトル\n\n## 3 つの案\n\n### 1. 決めたこと\n\nCloses #646\n",
            FAKE_GH_ISSUE="1",
        )
        self.assertNotIn("確定できません", result.stderr)
        self.assertIn("scripts/comment.sh issue 646", result.stderr)
        # 節番号が候補に混ざっていないこと
        self.assertNotIn("issue 3", result.stderr)
        self.assertNotIn("issue 1 ", result.stderr)

    def test_capture_falls_back_to_the_branch_without_heading_or_claim(self):
        """見出しも名乗りも無ければ従来どおりブランチ名 (実測で 6 件)。"""
        result = self.capture("番号をどこにも書かない計画。\n", FAKE_GH_ISSUE="1")
        # setUp のブランチは feat/plan-123
        self.assertIn("scripts/comment.sh issue 123", result.stderr)

    def test_recheck_message_tells_how_to_write_the_number(self):
        """差し戻し文が、投稿先も確定する書き方を案内する。

        案内が無いと「この検査は通ったのに投稿先が確定しない」綴りを書き手が当てる
        ことになる (#655 で実際に 2 段踏んだ)。
        """
        result = self.capture("番号も現況も書かない計画。\n", recheck=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("# #N 短い説明", result.stderr)

    # --- 名乗りが 2 つ以上あれば確定しない (#646) ----------------------------
    # プランは設計を説明する文書なので番号の例示が自然に出る。本来の対象が 2 番目以降に
    # 現れると、最初の 1 件だけを採る規則では無関係な Issue を指した。投稿済みプラン
    # 112 件で測ると誤爆は 2 件で、どちらも「本来の対象が 2 番目以降」だった。

    AMBIGUOUS = "説明として `Closes #631` を引きつつ、対象は別。\n\nCloses #646\n"

    def test_capture_does_not_pick_when_two_numbers_are_claimed(self):
        result = self.capture(self.AMBIGUOUS, FAKE_GH_ISSUE="1")
        self.assertIn("投稿先を確定できません", result.stderr)
        self.assertIn("名乗る番号が 2 件", result.stderr)
        # **両方**が候補として出る (どちらかを機械が選ばない)
        self.assertIn("scripts/comment.sh issue 631", result.stderr)
        self.assertIn("scripts/comment.sh issue 646", result.stderr)

    def test_capture_records_every_candidate(self):
        """確定しなかった候補は記録に残る — guard が取りこぼさないため。"""
        self.capture(self.AMBIGUOUS, FAKE_GH_ISSUE="1")
        meta = self.metas()[0].read_text(encoding="utf-8")
        self.assertIn("target=issue 631", meta)
        self.assertIn("target=issue 646", meta)

    def test_capture_still_picks_a_single_claim(self):
        """名乗りが 1 種類なら従来どおり確定する (112 件のうち 75 件がこれ)。"""
        result = self.capture("対象は 1 つだけ。\n\nCloses #646\n", FAKE_GH_ISSUE="1")
        self.assertNotIn("確定できません", result.stderr)
        self.assertIn("scripts/comment.sh issue 646", result.stderr)

    def test_capture_prefers_the_pull_request_over_many_claims(self):
        """open PR があれば、名乗りが何件あっても PR 1 つに確定する。"""
        result = self.capture(self.AMBIGUOUS, FAKE_GH_PR="42", FAKE_GH_ISSUE="1")
        self.assertNotIn("確定できません", result.stderr)
        self.assertIn("scripts/comment.sh pr 42", result.stderr)

    def test_capture_drops_candidates_that_do_not_exist(self):
        """実在しない番号は候補に並べない (ハッシュの断片を拾うことがある)。"""
        result = self.capture(self.AMBIGUOUS, FAKE_GH_ISSUE="1", FAKE_GH_MISSING="631")
        self.assertNotIn("確定できません", result.stderr)  # 実在するのは 1 件だけ
        self.assertNotIn("issue 631", result.stderr)
        self.assertIn("scripts/comment.sh issue 646", result.stderr)

    def test_guard_nags_with_every_candidate(self):
        """確定しなかったプランも取りこぼさない — 催促のときも候補を並べる。"""
        self.capture(self.AMBIGUOUS, FAKE_GH_ISSUE="1")
        result = self.guard(FAKE_GH_ISSUE="1", FAKE_GH_ISSUE_COMMENTS="")
        self.assertEqual(result.returncode, 2)
        self.assertIn("scripts/comment.sh issue 631", result.stderr)
        self.assertIn("scripts/comment.sh issue 646", result.stderr)

    def test_guard_clears_a_record_posted_to_one_of_the_candidates(self):
        """候補のどれかに載っていれば黙る (全部に投稿させない)。"""
        self.capture(self.AMBIGUOUS, FAKE_GH_ISSUE="1")
        result = self.guard(
            FAKE_GH_ISSUE="1", FAKE_GH_ISSUE_COMMENTS=self.marker()
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.records(), [])

    # --- 二重着手の跡を名乗る (#642) -----------------------------------------
    # 止めないことが要点。実例では、重複を知った側は知った時点で自分から畳んだので、
    # 要ったのは知らせることだった。自分で解けない差し戻しは押し通す口を要求する。

    def test_capture_does_not_treat_the_in_progress_label_as_a_mark(self):
        """ラベルは跡に数えない。

        ラベルを付けるのは着手するセッション自身なので、規約どおり動くと capture の
        時点で必ず自分が付けたものが在る。しかも付け主は判定できない (エージェントは
        同じ認証で操作するので actor が同じ)。毎回出る注意は意味を失う。
        """
        result = self.capture(
            "計画。\n",
            FAKE_GH_ISSUE="123",
            FAKE_GH_ISSUE_STATE=issue_state(in_progress=True),
        )
        self.assertNotIn("二重着手", result.stderr)
        self.assertIn("scripts/comment.sh issue 123", result.stderr)

    def test_capture_names_another_sessions_plan_with_its_url(self):
        """別のセッションが載せたプランを、読みに行ける形で名乗る。"""
        result = self.capture(
            "計画。\n",
            FAKE_GH_ISSUE="123",
            FAKE_GH_ISSUE_STATE=issue_state(
                plans=[("other5678-1700000000", "https://example.invalid/c/1")]
            ),
        )
        self.assertIn("別のセッションのプランが 1 件載っている", result.stderr)
        self.assertIn("https://example.invalid/c/1", result.stderr)

    def test_capture_does_not_point_at_its_own_session(self):
        """自分のセッションが載せたプランは跡に数えない。

        同じセッションで 2 度プランを取ると自分の目印が既に載っている。そこで
        「二重着手かもしれません」と言うと、注意が毎回出て意味を失う。
        """
        result = self.capture(
            "計画。\n",
            FAKE_GH_ISSUE="123",
            # capture が使うセッション ID は abcd1234-ef56-7890 なので接頭辞は abcd1234
            FAKE_GH_ISSUE_STATE=issue_state(
                plans=[("abcd1234-1700000000", "https://example.invalid/c/1")]
            ),
        )
        self.assertNotIn("二重着手", result.stderr)

    def test_capture_is_quiet_without_any_marks(self):
        result = self.capture(
            "計画。\n", FAKE_GH_ISSUE="123", FAKE_GH_ISSUE_STATE=issue_state()
        )
        self.assertNotIn("二重着手", result.stderr)

    def test_capture_still_instructs_posting_while_naming_marks(self):
        """名乗っても着手は止めない — 終了コードも投稿の指示も変わらない。"""
        result = self.capture(
            "計画。\n",
            FAKE_GH_ISSUE="123",
            FAKE_GH_ISSUE_STATE=issue_state(
                plans=[("other5678-1700000000", "https://example.invalid/c/1")]
            ),
        )
        self.assertEqual(result.returncode, 2)  # capture は常に 2 (指示を出すため)
        self.assertIn("scripts/comment.sh issue 123", result.stderr)
        self.assertIn("着手を止めません", result.stderr)
        self.assertEqual(len(self.records()), 1)  # 記録も普通に作られる

    def test_capture_does_not_look_when_the_target_is_a_pull_request(self):
        """投稿先が PR なら見ない (既に自分が着手していて、跡を問う場面ではない)。"""
        result = self.capture(
            "計画。\n",
            FAKE_GH_PR="42",
            FAKE_GH_ISSUE_STATE=issue_state(
                plans=[("other5678-1700000000", "https://example.invalid/c/1")]
            ),
        )
        self.assertNotIn("二重着手", result.stderr)

    def test_capture_is_quiet_when_github_cannot_be_read(self):
        """跡を引けないときは黙る (材料が無いことは書いた人の落ち度ではない)。"""
        result = self.capture("計画。\n", FAKE_GH_ISSUE="123")  # STATE を渡さない = exit 1
        self.assertNotIn("二重着手", result.stderr)
        self.assertIn("scripts/comment.sh issue 123", result.stderr)

    def test_capture_records_the_target_it_pointed_at(self):
        """指示した先が記録に残ること。ここが空だと guard は引き直しだけに頼る。"""
        self.capture("計画。\n", FAKE_GH_ISSUE="123")
        self.assertIn("target=issue 123", self.metas()[0].read_text(encoding="utf-8"))

    def test_guard_accepts_a_plan_posted_before_the_pull_request_existed(self):
        """#631 の回帰 — Issue へ載せてから PR を立てたセッションを差し戻さない。"""
        self.capture("計画。\n", FAKE_GH_ISSUE="123")  # PR はまだ無い
        result = self.guard(
            FAKE_GH_PR="42",  # ここで PR ができ、解決の先頭が PR へ移る
            FAKE_GH_ISSUE="123",
            FAKE_GH_ISSUE_COMMENTS=self.marker(),
            FAKE_GH_PR_COMMENTS="",  # PR 側には無い — プランは Issue にある
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.records(), [])

    def test_guard_blocks_when_the_plan_is_on_neither(self):
        """本当に未投稿なら、投稿先が動いていても従来どおり差し戻す。"""
        self.capture("計画。\n", FAKE_GH_ISSUE="123")
        result = self.guard(
            FAKE_GH_PR="42",
            FAKE_GH_ISSUE="123",
            FAKE_GH_ISSUE_COMMENTS="",
            FAKE_GH_PR_COMMENTS="",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("scripts/comment.sh pr 42", result.stderr)
        self.assertEqual(len(self.records()), 1)

    def test_guard_still_requires_the_pull_request_for_a_later_plan(self):
        """PR ができた後に取ったプランは PR 側を要求する。

        「Issue にも PR にも無いこと」で判定すると、ここが黙ってしまい
        AGENTS.md 「進め方」4 の「PR を出した後なら PR 側へ」が効かなくなる。
        """
        self.capture("計画。\n", FAKE_GH_PR="42", FAKE_GH_ISSUE="123")
        result = self.guard(
            FAKE_GH_PR="42",
            FAKE_GH_ISSUE="123",
            FAKE_GH_ISSUE_COMMENTS=self.marker(),  # Issue に載せても足りない
            FAKE_GH_PR_COMMENTS="",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("scripts/comment.sh pr 42", result.stderr)

    def test_guard_keeps_the_captured_target_across_nags(self):
        """催促で記録を書き直しても、指示した先が消えないこと。

        1 回目の差し戻しで target 行を落とすと、2 回目からこの仕組みが効かない。
        """
        self.capture("計画。\n", FAKE_GH_ISSUE="123")
        marker = self.marker()
        first = self.guard(
            FAKE_GH_PR="42",
            FAKE_GH_ISSUE="123",
            FAKE_GH_ISSUE_COMMENTS="",
            FAKE_GH_PR_COMMENTS="",
        )
        self.assertEqual(first.returncode, 2)
        second = self.guard(
            FAKE_GH_PR="42",
            FAKE_GH_ISSUE="123",
            FAKE_GH_ISSUE_COMMENTS=marker,
            FAKE_GH_PR_COMMENTS="",
        )
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.records(), [])

    def test_guard_falls_back_to_the_current_target_without_a_captured_one(self):
        """target 行を持たない記録 (この仕組みが入る前のもの) は従来どおり。"""
        self.capture("計画。\n", FAKE_GH_ISSUE="123")
        meta = self.metas()[0]
        kept = [
            line
            for line in meta.read_text(encoding="utf-8").splitlines()
            if not line.startswith("target=")
        ]
        meta.write_text("\n".join(kept) + "\n", encoding="utf-8")
        result = self.guard(
            FAKE_GH_PR="42",
            FAKE_GH_PR_COMMENTS=self.marker(),  # 引き直した先に載っていれば黙る
            FAKE_GH_ISSUE_COMMENTS="",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.records(), [])


class SelfContainedTest(unittest.TestCase):
    """エージェント支援がリポジトリ側だけで完結していること (ADR-0017)。

    個人環境のフックが無い開発環境 (他の人・CI・別のエージェント) でも同じ担保が
    効く必要がある。実体もその配線も、この検査でリポジトリ内に閉じていることを見る。
    """

    def setUp(self):
        self.settings = json.loads(SETTINGS.read_text(encoding="utf-8"))
        self.hooks = self.settings.get("hooks", {})

    def commands_for(self, event, matcher=None):
        out = []
        for entry in self.hooks.get(event, []):
            if matcher is not None and entry.get("matcher") != matcher:
                continue
            out += [h.get("command", "") for h in entry.get("hooks", [])]
        return out

    def test_capture_is_wired_to_exit_plan_mode(self):
        commands = self.commands_for("PostToolUse", "ExitPlanMode")
        self.assertTrue(
            any("plan-record.sh" in c and "capture" in c for c in commands),
            f"ExitPlanMode に capture が配線されていない: {commands}",
        )

    def test_guard_is_wired_to_stop(self):
        commands = self.commands_for("Stop")
        self.assertTrue(
            any("plan-record.sh" in c and "guard" in c for c in commands),
            f"Stop に guard が配線されていない: {commands}",
        )

    def test_hooks_run_the_repository_copy(self):
        # $CLAUDE_PROJECT_DIR 経由 = リポジトリ同梱の実体。~ 起点だと
        # 個人環境のファイルに依存し、他の環境で黙って効かなくなる
        for command in self.commands_for("PostToolUse", "ExitPlanMode") + self.commands_for("Stop"):
            if "plan-record.sh" in command:
                self.assertIn("$CLAUDE_PROJECT_DIR", command)

    def test_settings_do_not_reach_into_the_personal_environment(self):
        self.assertNotIn("~/.claude", SETTINGS.read_text(encoding="utf-8"))

    def test_script_does_not_reach_into_the_personal_environment(self):
        self.assertNotIn("~/.claude", SCRIPT.read_text(encoding="utf-8"))

    def test_personal_plugins_are_not_declared(self):
        # ADR-0017 決定 2。宣言すると、入れている人にだけ効く支援がリポジトリの
        # 前提になり、規約が環境によって変わる (#176)。個人が自分の ~/.claude に
        # 何を入れるかは自由で、ここで見るのはリポジトリが要求する側だけ
        for key in ("extraKnownMarketplaces", "enabledPlugins"):
            self.assertNotIn(key, self.settings)

    def test_personal_hook_is_silenced_while_working_here(self):
        # 論点 1: 個人環境にも同種のフックがある。両方動くと二重に指示が出て、
        # 二重に差し戻される。リポ側が担保するので個人側は黙らせる
        self.assertEqual(self.settings.get("env", {}).get("CLAUDE_PLAN_RECORD"), "0")

    def test_ci_watch_hook_is_silenced_while_working_here(self):
        # 重要パスの PR は承認が付くまでマージボックスで止まる (ADR-0002 決定 3 /
        # ADR-0031 決定 1)。個人環境の CI 見届けフックはその設計を知らないので、直す
        # 対象が無いまま「直せ」と鳴り続ける (#159 / #194)。CI の見届けはリポ側の
        # ci-gate と merge queue が担うので、個人側は黙らせる
        self.assertEqual(self.settings.get("env", {}).get("RS_CI_WATCH"), "0")



class StdinDeadlineTest(PlanRecordTestCase):
    """stdin を待って無言に固まらない (#636)。

    **固まるのは EOF が来ない stdin である。** 空を渡した場合 (< /dev/null) は
    即座に EOF が来るので昔から返っていた — 手で打つと端末やパイプが開いたままで、
    そこで永遠に待っていた。実際に 40 分放置された。
    """

    def test_capture_gives_up_on_a_stdin_that_never_closes(self):
        proc = subprocess.Popen(
            ["/bin/bash", str(SCRIPT), "capture"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=str(self.repo),
            env=self.env(),
        )
        # **書かず・閉じない。** communicate() は stdin を閉じてしまうので使えない
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
            self.fail("期限が効いていない — stdin を閉じるまで終わらない")
        stderr = proc.stderr.read()
        # プロセスは終わっているので閉じてよい (先に閉じると EOF が届いて検査の意味が消える)
        proc.stdin.close()
        proc.stdout.close()
        proc.stderr.close()
        self.assertEqual(proc.returncode, 64)
        self.assertIn("stdin", stderr)

    def test_capture_names_the_requirement(self):
        result = self.run_hook("capture", stdin="")
        self.assertEqual(result.returncode, 64)
        self.assertIn("stdin", result.stderr)

    def test_guard_names_the_requirement(self):
        result = self.run_hook("guard", stdin="")
        self.assertEqual(result.returncode, 64)
        self.assertIn("stdin", result.stderr)

    def test_scan_stays_out_of_the_way(self):
        # パイプの途中で使われるので、空でも止めない
        result = self.run_hook("scan", stdin="")
        self.assertEqual(result.returncode, 0)
        self.assertIn("stdin", result.stderr)

    def test_sanitize_stays_out_of_the_way(self):
        result = self.run_hook("sanitize", stdin="")
        self.assertEqual(result.returncode, 0)
        self.assertIn("stdin", result.stderr)

    def test_usage_names_the_stdin_requirement(self):
        result = self.run_hook("no-such-mode", stdin="")
        self.assertIn("stdin", result.stderr)

if __name__ == "__main__":
    unittest.main(verbosity=2)
