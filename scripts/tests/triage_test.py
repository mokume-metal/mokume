#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/triage.sh の検査 (#78)。

triage は起票直後に一度だけ走り、二つの下書きをする:
  1. 完了条件がまだ無い Issue に status: needs-triage を付ける
  2. タイトルの Conventional Commits prefix から Issue Type を推定する

固定したいのは「機械が埋めない」二つの境界 (ADR-0004 決定 5):
  - prefix が読めなければ型を付けない (無分類のまま人が決める)
  - 既に型があれば上書きしない (テンプレート・sub-issue.sh の明示指定が優先)

この workflow は issues イベントで走るため既定ブランチのものしか実行されず、
ブランチ上では実地確認できない。だからロジックを YAML から出してここで検査する。

gh は PATH の先頭に置いた偽物へ差し替えるので、ネットワークも認証も要らない。
実行は make ci-check (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "triage.sh"

# 偽 gh。呼ばれた引数を残し、問い合わせには環境変数の値を返す。
#   gh issue view <n> -R <repo> --json labels    --jq ... → FAKE_LABELS
#   gh issue view <n> -R <repo> --json issueType --jq ... → FAKE_TYPE
#   gh issue edit <n> -R <repo> --add-label / --type      → 記録するだけ
# --jq は本物が畳んだ後の文字列をそのまま返す (整形は検査の対象ではない)
FAKE_GH = """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_GH_LOG"
case "$*" in
  *"--json labels"*)    printf '%s' "$FAKE_LABELS" ;;
  *"--json issueType"*) printf '%s' "$FAKE_TYPE" ;;
  *"issue edit"*)
    case "$*" in
      *--type*) [ "${FAKE_TYPE_EDIT_FAILS:-0}" = "1" ] && exit 1 ;;
    esac
    ;;
esac
exit 0
"""


class TriageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bindir = Path(self.tmp.name) / "bin"
        self.bindir.mkdir()
        stub = self.bindir / "gh"
        stub.write_text(FAKE_GH, encoding="utf-8")
        stub.chmod(0o755)
        self.log = Path(self.tmp.name) / "gh.log"
        self.log.touch()

    def run_triage(self, title, labels="", current_type="", type_edit_fails=False):
        env = dict(os.environ)
        env["PATH"] = f"{self.bindir}:{env['PATH']}"
        env["FAKE_GH_LOG"] = str(self.log)
        env["FAKE_LABELS"] = labels
        env["FAKE_TYPE"] = current_type
        env["FAKE_TYPE_EDIT_FAILS"] = "1" if type_edit_fails else "0"
        proc = subprocess.run(
            ["bash", str(SCRIPT), "42", title],
            capture_output=True,
            text=True,
            env=env,
        )
        return proc, self.log.read_text(encoding="utf-8")

    # --- 1. needs-triage ----------------------------------------------------

    def test_needs_triage_is_added_when_completion_is_undecided(self):
        proc, calls = self.run_triage("chore: 何かする")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("--add-label status: needs-triage", calls)

    def test_needs_triage_is_skipped_when_verify_is_already_set(self):
        proc, calls = self.run_triage("chore: 何かする", labels="verify: machine")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("--add-label", calls)

    # --- 2. prefix からの型の推定 -------------------------------------------

    def test_prefix_decides_the_type(self):
        for title, expected in [
            ("fix: 落ちる", "Bug"),
            ("fix(core): 落ちる", "Bug"),
            ("feat: 足す", "Feature"),
            ("docs: 直す", "Docs"),
            ("design: 決める", "Design"),
            ("chore: 整える", "Task"),
            ("ci: 直す", "Task"),
            ("test: 確かめる", "Task"),
            ("refactor: 整理する", "Task"),
        ]:
            with self.subTest(title=title):
                self.setUp()
                proc, calls = self.run_triage(title)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertIn(f"--type {expected}", calls)

    # --- 3. 機械が埋めない境界 ----------------------------------------------

    def test_title_without_prefix_gets_no_type(self):
        proc, calls = self.run_triage("reuse が SPDX を見落とすことがある")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("--type", calls)
        self.assertIn("推定できなかった", proc.stdout)

    def test_existing_type_is_not_overwritten(self):
        # sub-issue.sh が親から継いだ Design を、タイトルの ci: が上書きしない
        proc, calls = self.run_triage("ci: 直す", current_type="Design")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("--type", calls)
        self.assertIn("上書きしない", proc.stdout)

    # --- 4. 型が無いときは黙らない ------------------------------------------

    def test_missing_type_in_org_is_reported(self):
        proc, _ = self.run_triage("design: 決める", type_edit_fails=True)
        self.assertNotEqual(proc.returncode, 0, "握り潰してしまった")
        self.assertIn("付けられなかった", proc.stderr)
        self.assertIn("次にすること", proc.stderr)


if __name__ == "__main__":
    unittest.main()
