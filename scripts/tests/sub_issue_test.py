#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/sub-issue.sh の検査 (#78)。

sub-issue.sh は「作成 + 親への紐づけ + 親の分類の継承」を 1 コマンドにする。
継承の対象は #78 で type: ラベルから Issue Type へ移した (ADR-0004 決定 5)。

固定するのは継承の三態 (継ぐ / 上書きする / 継ぐものが無い) と、使い捨て検証用の
--test の雛形。紐づけ (sub_issues API) は script の存在理由そのものなので併せて見る。
既に在る Issue を繋ぐ --attach (#1661) は、作らないこと・型を継がないこと・既に親の居る
Issue を付け替えないことを見る。

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
  # 紐づけを断らせる (#1661)。綴りは既に親を持つ子を繋ごうとしたときの GitHub の応答
  *"api -X POST"*)
    if [ -n "${FAKE_LINK_ERROR:-}" ]; then
      # 本物の gh api と同じく、本文 (errors を含む) は stdout・要約は stderr (#2075)
      printf '%s\\n' "${FAKE_LINK_BODY:-}"
      printf '%s\\n' "$FAKE_LINK_ERROR" >&2; exit 1
    fi
    printf '99\\n' ;;
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

    def run_sub_issue(self, *args, parent_type="", link_error="", link_body=""):
        env = dict(os.environ)
        env["PATH"] = f"{self.bindir}:{env['PATH']}"
        env["FAKE_GH_LOG"] = str(self.log)
        env["FAKE_PARENT_TYPE"] = parent_type
        env["FAKE_LINK_ERROR"] = link_error
        env["FAKE_LINK_BODY"] = link_body
        proc = subprocess.run(
            ["/bin/bash", str(SCRIPT), "74", *args],
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
        self.assertIn("--label verify: triaged", create)

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

    # --- 既に在る Issue を繋ぐ (#1661) ---------------------------------------
    # 同じ根の群を束ねる相手は、たいてい既に起票されている (ADR-0040 決定 2)

    def test_attach_links_an_existing_issue_without_creating_one(self):
        proc, calls = self.run_sub_issue("--attach", "55", parent_type="Design")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("api repos/mokume-metal/mokume/issues/55 --jq .id", calls)
        self.assertIn("api -X POST repos/mokume-metal/mokume/issues/74/sub_issues", calls)
        self.assertIn("sub_issue_id=4242", calls)
        self.assertNotIn("issue create", calls, "--attach なのに新しく作っている")
        # 型は起票したときに決まっている。親の型を読みに行くこと自体が要らない
        self.assertNotIn("issue view", calls, "--attach で親の型を継ごうとしている")
        self.assertIn("#55 を #74 の下に繋いだ", proc.stdout)

    def test_attach_does_not_reparent_an_issue_that_has_another_parent(self):
        proc, calls = self.run_sub_issue(
            "--attach",
            "55",
            link_error="gh: Validation Failed (HTTP 422)",
            link_body='{"message":"Validation Failed","errors":["Sub issue may only have one parent"]}',
        )
        self.assertNotEqual(proc.returncode, 0, "断られたのに成功を返している")
        self.assertIn("繋げなかった", proc.stderr)
        self.assertIn("付け替えはしない", proc.stderr)
        self.assertIn("only have one parent", proc.stderr, "GitHub の理由を隠している")
        self.assertNotIn("replace_parent", calls, "黙って付け替えようとしている")
        self.assertNotIn("繋いだ", proc.stdout)

    def test_attach_without_a_number_is_a_usage_error(self):
        for args in (("--attach",), ("--attach", "abc"), ("--attach", "55", "--type", "Bug")):
            with self.subTest(args=args):
                proc, calls = self.run_sub_issue(*args)
                self.assertEqual(proc.returncode, 64, proc.stderr)
                self.assertIn("--attach <番号>", proc.stderr)
                self.assertNotIn("api ", calls, "使い方の誤りなのに GitHub を叩いている")


if __name__ == "__main__":
    unittest.main()
