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
  5. exit test (`#expect(processExitsWith:)`) を持つ検査は、どれも Makefile の TSAN_SKIP に
     載る — TSan の下では子が中身を走らせずに止まり、`.failure` を期待する検査は偽って緑に
     なる (#3220 の実測)。足した exit test を TSAN_SKIP に載せ忘れると、ここが赤になる

ワークフローの読み手は render_workflow_test.py のものを使う。実行は make hooks-test。
"""

import re
import unittest
from pathlib import Path

import render_workflow_test as workflow

REPO = Path(__file__).resolve().parents[2]
HOST = REPO / ".github" / "workflows" / "host-scheduled.yml"
MAKEFILE = REPO / "Makefile"
TESTS = REPO / "Tests"


def tsan_skip(makefile):
    """Makefile の TSAN_SKIP の並び (行継ぎを畳む)。"""
    m = re.search(r"(?ms)^TSAN_SKIP := (.*?)(?<!\\)\n", makefile)
    return m.group(1).replace("\\\n", " ").split()


def exit_tests(root):
    """exit test を持つ (Suite の型名, 関数名) の集合。関数は宣言の後で最初に出たものに帰す。"""
    found = set()
    for path in root.rglob("*.swift"):
        suite = function = None
        for line in path.read_text(encoding="utf-8").splitlines():
            m = re.match(r"^(?:final class|struct|class) (\w+)", line)
            if m:
                suite = m.group(1)
            m = re.search(r"\bfunc (\w+)\(", line)
            if m:
                function = m.group(1)
            if "processExitsWith" in line and suite and function:
                found.add((suite, function))
    return found


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


    def test_exit_test_は_TSan_の下から外す(self):
        skip = tsan_skip(MAKEFILE.read_text(encoding="utf-8"))
        found = exit_tests(TESTS)
        self.assertTrue(found, "Tests/ に exit test が 1 つも見つからない — 読み方が壊れている")
        missing = sorted(
            f"{suite}/{function}"
            for suite, function in found
            if f"{suite}/{function}" not in skip and f"{suite}/" not in skip
        )
        self.assertEqual(missing, [], "Makefile の TSAN_SKIP に足す (理由は TSAN_SKIP の上)")

    def test_TSAN_SKIP_の読み方(self):
        text = "TSAN_SKIP := A/ \\\n\tB/c \\\n\tD/e\n\nNEXT := x\n"
        self.assertEqual(tsan_skip(text), ["A/", "B/c", "D/e"])


if __name__ == "__main__":
    unittest.main()
