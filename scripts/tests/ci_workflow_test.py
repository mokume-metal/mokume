#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`.github/workflows/ci.yml` の test-release の起動の形の検査 (#2589)。

test-release は PR では走らせず、merge queue (merge_group) でだけ走らせる。GitHub ホストの
macOS の枠 (同時 5 本) を PR の ci-check に空けるためである。ここで固定するのは次の 2 つ:

  1. test-release は merge_group でだけ走る — PR に戻すと macOS の枠の待ちが戻る
     (2026-10-13 は PR の ci-check が走り出すまで約 1 時間)
  2. test-release は ci-gate の needs に残る — 外すと merge_group でも必須でなくなり、
     #1086 の「誰も見ていない release の赤」に戻る。ci-gate は skipped を通すので、PR では
     止まらない (failure と cancelled だけを赤にする)

ワークフローの読み手 (split / needs / condition) は render_workflow_test.py のものを使う
(写しを持たない)。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import unittest
from pathlib import Path

import render_workflow_test as workflow

REPO = Path(__file__).resolve().parents[2]
CI = REPO / ".github" / "workflows" / "ci.yml"


class CiWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _, cls.jobs = workflow.split(CI.read_text(encoding="utf-8"))

    def test_test_release_は_merge_group_でだけ走る(self):
        self.assertEqual(workflow.condition(self.jobs["test-release"]), "github.event_name == 'merge_group'")

    def test_test_release_は_ci_gate_の_needs_に残り_skipped_は通る(self):
        gate = self.jobs["ci-gate"]
        self.assertIn("test-release", workflow.needs(gate))
        # skipped を赤にすると、PR の ci-gate が毎回落ちる
        self.assertIn("(failure|cancelled)", gate)
        self.assertNotIn("skipped", gate.split("run: |", 1)[1])


if __name__ == "__main__":
    unittest.main()
