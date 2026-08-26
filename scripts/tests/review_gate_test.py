#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/review-gate.sh の検査 (#44)。

このゲートが守るのは mokume 固有の三点だけ:
  1. PR が Issue に紐づいている (例外は no-issue ラベル)
  2. 対象 Issue に verify: ラベルがある (完了条件が固まっている)
  3. verify: human なら人間の Approve がある

重要パスの承認要求は CODEOWNERS が担うので、ここでは見ない。`review: approved`
ラベルの fallback は identity 分離 (ADR-0003) で廃止した。**外したことが戻らない**
ことを 8 番目と 9 番目のケースで固定する。

gh は PATH の先頭に置いた偽物へ差し替えるので、ネットワークも認証も要らない。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "review-gate.sh"

# 偽 gh。review-gate が呼ぶのは 2 つだけ:
#   gh pr view <n> -R <repo> --json body,labels,latestReviews
#   gh issue view <n> -R <repo> --json labels --jq <query>
# 応答は環境変数で決める。--jq が付くときは本物と同じようにクエリを適用する
FAKE_GH = """#!/bin/sh
kind=$2
query=
prev=
for arg in "$@"; do
  [ "$prev" = "--jq" ] && query=$arg
  prev=$arg
done
case "$1 $2" in
  "pr view") json=$FAKE_PR_JSON ;;
  "issue view") json=$FAKE_ISSUE_JSON ;;
  *) exit 1 ;;
esac
if [ -n "$query" ]; then
  printf '%s' "$json" | jq -r "$query"
else
  printf '%s' "$json"
fi
"""


def pr_json(body="Closes #12", labels=(), reviews=()):
    return json.dumps(
        {
            "body": body,
            "labels": [{"name": n} for n in labels],
            "latestReviews": [{"state": s} for s in reviews],
        }
    )


def issue_json(*labels):
    return json.dumps({"labels": [{"name": n} for n in labels]})


class ReviewGateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bindir = Path(self.tmp.name) / "bin"
        self.bindir.mkdir()
        stub = self.bindir / "gh"
        stub.write_text(FAKE_GH, encoding="utf-8")
        stub.chmod(0o755)

    def run_gate(self, pr, issue=None):
        env = dict(os.environ)
        env["PATH"] = f"{self.bindir}:{env['PATH']}"
        env["FAKE_PR_JSON"] = pr
        env["FAKE_ISSUE_JSON"] = issue if issue is not None else issue_json()
        return subprocess.run(
            ["bash", str(SCRIPT), "12"], capture_output=True, text=True, env=env
        )

    def assert_blocked(self, proc, message):
        self.assertNotEqual(proc.returncode, 0, f"通ってしまった: {proc.stdout}")
        self.assertIn(message, proc.stderr)
        self.assertIn("次にすること", proc.stderr)

    # --- 1. Issue への紐づけ ------------------------------------------------

    def test_pr_without_issue_is_blocked(self):
        proc = self.run_gate(pr_json(body="Issue に触れていない本文"))
        self.assert_blocked(proc, "Issue に紐づいていない")

    def test_no_issue_label_is_an_accepted_exception(self):
        proc = self.run_gate(pr_json(body="紐づけなし", labels=["no-issue"]))
        self.assertEqual(proc.returncode, 0, proc.stderr)

    # --- 2. verify ラベル ---------------------------------------------------

    def test_issue_without_verify_label_is_blocked(self):
        proc = self.run_gate(pr_json(), issue_json("status: needs-triage"))
        self.assert_blocked(proc, "verify: ラベルが無い")

    def test_verify_machine_passes_unattended(self):
        proc = self.run_gate(pr_json(), issue_json("verify: machine"))
        self.assertEqual(proc.returncode, 0, proc.stderr)

    # --- 3. verify: human は人間の承認を待つ --------------------------------

    def test_verify_human_without_review_is_blocked(self):
        proc = self.run_gate(pr_json(), issue_json("verify: human"))
        self.assert_blocked(proc, "メンテナの承認が必要")

    def test_verify_human_with_approval_passes(self):
        proc = self.run_gate(
            pr_json(reviews=["APPROVED"]), issue_json("verify: human")
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_changes_requested_blocks_even_with_an_approval(self):
        proc = self.run_gate(
            pr_json(reviews=["APPROVED", "CHANGES_REQUESTED"]),
            issue_json("verify: machine"),
        )
        self.assert_blocked(proc, "変更要求")

    # --- 廃止したものが戻らないことの固定 -----------------------------------

    def test_review_approved_label_no_longer_substitutes_for_a_review(self):
        # identity 分離 (ADR-0003) までの暫定 fallback。ラベルはエージェント自身も
        # 付けられるので、承認の代わりにはならない
        proc = self.run_gate(
            pr_json(labels=["review: approved"]), issue_json("verify: human")
        )
        self.assert_blocked(proc, "メンテナの承認が必要")

    def test_important_paths_are_left_to_codeowners(self):
        # 重要パスに触れていても、対象 Issue が verify: machine ならここは通す。
        # 承認を要求するのは CODEOWNERS 側 (native の Review required)
        proc = self.run_gate(pr_json(), issue_json("verify: machine"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("重要パス", proc.stdout + proc.stderr)


if __name__ == "__main__":
    unittest.main()
