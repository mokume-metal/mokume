#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`make gpu-ran` — 描画の検査が実際に走ったかを test の記録から確かめる的の検査 (#878)。

専用機の描画ジョブ (.github/workflows/render.yml) は test の後にこの的を走らせる。描画の
検査は GPU が見えなければ飛ぶ作りなので、専用機の GPU が見えなくなっても test は緑で
終わる。この的は、そのとき**赤で止める**ことを守る。

守るのは 1 つ — **台帳の検査が走って通った記録だけを緑にする。** 全部飛ばされた・記録に
無い・落ちている・記録を読めない、はどれも赤にする。一部が飛んだだけ (基準の版でない
OS の字形の行など) は緑のままにする。

本物の Makefile の的を、偽の記録を指して走らせる。Swift も GPU も要らない。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LEDGER = "MokumeCoreTests.SceneLedgerTests"


def _case(classname, name, child=""):
    if not child:
        return f'    <testcase classname="{classname}" name="{name}" time="0.1" />\n'
    return (
        f'    <testcase classname="{classname}" name="{name}" time="0.1">\n'
        f"      {child}\n    </testcase>\n"
    )


def _record(*cases):
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n'
        '  <testsuite name="TestResults" tests="%d">\n%s  </testsuite>\n</testsuites>\n'
        % (len(cases), "".join(cases))
    )


SKIPPED = '<skipped message="この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする" />'
OTHER = _case("MokumeCoreTests.CanvasTests", "draws()")


class GpuRanTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.record = Path(self.tmp.name) / "record.xml"

    def run_target(self, content=None):
        if content is not None:
            self.record.write_text(content, encoding="utf-8")
        return subprocess.run(
            ["make", "-s", "--no-print-directory", "gpu-ran", f"TEST_RECORD={self.record}"],
            cwd=REPO,
            capture_output=True,
            text=True,
        )

    def test_the_ledger_ran_and_passed(self):
        proc = self.run_target(_record(OTHER, _case(LEDGER, "sceneMatchesLedger(_:)")))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("描画の検査が走った", proc.stdout)

    def test_a_partly_skipped_ledger_still_passes(self):
        # 基準の版でない OS の機械では、字形の行だけが飛ぶ。残りが走っていれば緑
        proc = self.run_target(
            _record(
                _case(LEDGER, "sceneMatchesLedger(_:)"),
                _case(LEDGER, "glyphSceneMatchesLedger(_:)", SKIPPED),
            )
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_an_all_skipped_ledger_is_red(self):
        # GPU が見えない機械の姿。test 自体は緑で終わるので、ここで止めなければ通ってしまう
        proc = self.run_target(
            _record(
                OTHER,
                _case(LEDGER, "sceneMatchesLedger(_:)", SKIPPED),
                _case(LEDGER, "sketchMatchesLedger(_:)", SKIPPED),
            )
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("GPU", proc.stdout)

    def test_a_missing_ledger_is_red(self):
        proc = self.run_target(_record(OTHER))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("記録に無い", proc.stdout)

    def test_a_failed_ledger_is_red(self):
        proc = self.run_target(_record(_case(LEDGER, "sceneMatchesLedger(_:)", '<failure message="指紋が違う" />')))
        self.assertNotEqual(proc.returncode, 0)

    def test_a_missing_record_is_red(self):
        proc = self.run_target()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("読めない", proc.stdout)


if __name__ == "__main__":
    unittest.main()
