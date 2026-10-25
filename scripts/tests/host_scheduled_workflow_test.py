#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`.github/workflows/host-scheduled.yml` の、ホストの macOS の定期の検査の形の検査 (#3220)。

ここで固定するのは:

  1. 起動は schedule と workflow_dispatch だけ — PR・push の契機を持たない (merge の前には
     重すぎる検査を置く場所で、PR の macOS の枠を奪わない)。cron は毎時 0 分を外す
  2. tsan は macos-26 (ADR-0009 の下限) で `make test-tsan` を走らせ、timeout-minutes を持つ
     (既定の 360 分で止まるとホストの macOS の枠を塞ぐ)。continue-on-error を持たない
     (赤が success に化けると起票が走らない)
  3. `issues: write` を持つのは起票の job (tsan-report) だけで、tsan が落ちた (`failure`) か
     切れた (`cancelled`) ときだけ走る。`if:` は always() を持つ — 無ければ暗黙の success() で、
     赤の回に skipped になる
  4. 起票の job は、artifact の名前と記録の綴りを tsan / Makefile と揃えて読む

ワークフローの読み手は render_workflow_test.py のものを使う。実行は make hooks-test。
"""

import re
import unittest
from pathlib import Path

import render_workflow_test as workflow

REPO = Path(__file__).resolve().parents[2]
HOST = REPO / ".github" / "workflows" / "host-scheduled.yml"
MAKEFILE = REPO / "Makefile"


class HostScheduledWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = HOST.read_text(encoding="utf-8")
        cls.top, cls.jobs = workflow.split(cls.text)

    def test_起動は定期と手動だけ(self):
        on = self.top["on"]
        events = set(re.findall(r"(?m)^  ([a-z_]+):", on))
        self.assertEqual(events, {"schedule", "workflow_dispatch"})
        crons = re.findall(r'cron: "(\S+) \S+ \S+ \S+ \S+"', on)
        self.assertTrue(crons)
        for minute in crons:
            self.assertNotEqual(minute, "0", "毎時 0 分は最も混む枠")

    def test_tsan_は下限_OS_で_make_test_tsan_を走らせ期限を持つ(self):
        tsan = self.jobs["tsan"]
        self.assertRegex(tsan, r"(?m)^    runs-on: macos-26\s*$")
        self.assertRegex(tsan, r"(?m)^    timeout-minutes: \d+\s*$")
        self.assertIn("make test-tsan", tsan)
        self.assertNotIn("continue-on-error", tsan)

    def test_issues_write_は起票のジョブだけが持つ(self):
        holders = {name for name, body in self.jobs.items() if re.search(r"issues:\s*write", body)}
        self.assertEqual(holders, {"tsan-report"})

    def test_起票は落ちたか切れた回だけ走る(self):
        report = self.jobs["tsan-report"]
        self.assertEqual(workflow.needs(report), {"tsan"})
        cond = workflow.condition(report)
        self.assertIn("always()", cond)
        self.assertIn("needs.tsan.result == 'failure'", cond)
        self.assertIn("needs.tsan.result == 'cancelled'", cond)
        self.assertNotIn("!=", cond)

    def test_起票は_tsan_が上げた記録の綴りで読む(self):
        tsan, report = self.jobs["tsan"], self.jobs["tsan-report"]
        self.assertIn("name: tsan-record", tsan)
        self.assertIn("name: tsan-record", report)
        makefile = MAKEFILE.read_text(encoding="utf-8")
        record = re.search(r"(?m)^TEST_RECORD_TSAN := (\S+)$", makefile).group(1)
        log = re.search(r"(?m)^TEST_LOG_TSAN := (\S+)$", makefile).group(1)
        self.assertIn(record, tsan)
        self.assertIn(log, tsan)
        self.assertIn(Path(record).name, report)
        self.assertIn(Path(log).name, report)
        self.assertIn("scripts/report-tsan.sh", report)


if __name__ == "__main__":
    unittest.main()
