#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`.github/workflows/ci.yml` の必須の集約の形の検査 (#2589・#2662)。

release の検査 (`make test-release`) は ci.yml に置かない。merge queue の必須だった頃は
group ごとに約 12 分のホストの macOS を使い、queue の律速の 63% を占めた。いまは版を出す
前の `release.yml` の `release-check` が、版にする SHA そのものを検査する (形の固定は
release_workflow_test.py)。ここで固定するのは次の 2 つ:

  1. ci.yml に test-release が戻っていない — 戻すと、PR か merge_group で macOS の枠を
     また取り合う (2026-10-13 は PR の ci-check が走り出すまで約 1 時間待った)
  2. ci-gate は skipped を通す — 赤にするのは failure と cancelled だけで、PR では走らない
     ジョブ (merge_group だけの段・PR だけの段) が skipped で現れても止まらない

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

    def test_test_release_は_ci_yml_に無い(self):
        self.assertNotIn("test-release", self.jobs)
        self.assertNotIn("test-release", workflow.needs(self.jobs["ci-gate"]))
        for name, body in self.jobs.items():
            with self.subTest(job=name):
                self.assertNotIn("make test-release", body)

    def test_ci_gate_は_skipped_を通す(self):
        gate = self.jobs["ci-gate"]
        # skipped を赤にすると、PR の ci-gate が毎回落ちる
        self.assertIn("(failure|cancelled)", gate)
        self.assertNotIn("skipped", gate.split("run: |", 1)[1])


if __name__ == "__main__":
    unittest.main()
