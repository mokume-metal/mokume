#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/sub-issue.sh の検査 (#78)。

sub-issue.sh は「作成 + 親への紐づけ + 親の分類の継承」を 1 コマンドにする。
継承の対象は #78 で type: ラベルから Issue Type へ移した (ADR-0004 決定 5)。

固定するのは継承の三態 (継ぐ / 上書きする / 継ぐものが無い) と、使い捨て検証用の
--test の雛形。紐づけ (sub_issues API) は script の存在理由そのものなので併せて見る。

gh は PATH の先頭に置いた偽物へ差し替えるので、ネットワークも認証も要らない。
実行は make ci-check (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "sub-issue.sh"

# 偽 gh。sub-issue.sh が呼ぶのは 4 つ:
#   gh issue view <親> -R <repo> --json issueType --jq ... → 親の型
#   gh issue create ...                                    → 作成した URL
#   gh api repos/<repo>/issues/<番号> --jq .id             → 子の node id
#   gh api -X POST repos/<repo>/issues/<親>/sub_issues ... → 紐づけ
FAKE_GH = """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_GH_LOG"
case "$*" in
  *"issue view"*)   printf '%s' "$FAKE_PARENT_TYPE" ;;
  *"issue create"*) printf 'https://github.com/mokume-metal/mokume/issues/99\\n' ;;
  *"api -X POST"*)  printf '99\\n' ;;
  *"api "*)         printf '4242\\n' ;;
esac
exit 0
"""


class SubIssueTest(unittest.TestCase):
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

    def run_sub_issue(self, *args, parent_type=""):
        env = dict(os.environ)
        env["PATH"] = f"{self.bindir}:{env['PATH']}"
        env["FAKE_GH_LOG"] = str(self.log)
        env["FAKE_PARENT_TYPE"] = parent_type
        proc = subprocess.run(
            ["bash", str(SCRIPT), "74", *args],
            capture_output=True,
            text=True,
            env=env,
        )
        return proc, self.log.read_text(encoding="utf-8")

    def create_call(self, calls):
        for line in calls.splitlines():
            if line.startswith("issue create"):
                return line
        self.fail(f"issue create が呼ばれていない: {calls}")

    # --- 継承の三態 ---------------------------------------------------------

    def test_parent_type_is_inherited(self):
        proc, calls = self.run_sub_issue("ci: 直す", parent_type="Design")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("--type Design", self.create_call(calls))

    def test_explicit_type_wins_over_inheritance(self):
        proc, calls = self.run_sub_issue(
            "ci: 直す", "--type", "Task", parent_type="Design"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        create = self.create_call(calls)
        self.assertIn("--type Task", create)
        self.assertNotIn("Design", create)

    def test_no_type_is_passed_when_parent_has_none(self):
        proc, calls = self.run_sub_issue("ci: 直す")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("--type", self.create_call(calls))

    # --- 使い捨ての検証用 Issue ---------------------------------------------

    def test_test_flag_prefixes_the_title_and_marks_it_machine_verified(self):
        proc, calls = self.run_sub_issue("動作を確かめる", "--test")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        create = self.create_call(calls)
        self.assertIn("test: 動作を確かめる", create)
        self.assertIn("--label verify: machine", create)

    def test_test_flag_does_not_duplicate_an_existing_prefix(self):
        proc, calls = self.run_sub_issue("test: 動作を確かめる", "--test")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("test: test:", self.create_call(calls))

    # --- 紐づけ -------------------------------------------------------------

    def test_child_is_linked_to_the_parent(self):
        proc, calls = self.run_sub_issue("ci: 直す")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("api -X POST repos/mokume-metal/mokume/issues/74/sub_issues", calls)
        self.assertIn("sub_issue_id=4242", calls)


if __name__ == "__main__":
    unittest.main()
