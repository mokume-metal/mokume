#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/ci-check.sh の検査 (#1182)。

このスクリプトが守るのは 2 つ。

1. **並びの意味を崩さない。** 段は並びどおりに 1 つずつ走り、落ちた段で止まってその
   終了コードで抜ける。止まらずに進むと、落ちた検査があっても最後の render-status が
   「手元で走った」と報告してしまう
2. **いまどこに居てあとどれくらいかを名乗る。** 段の名乗り・継続中の行・前回の所要・
   止まった段の名乗り

make は MAKE で渡す偽物に差し替え、段の所要は偽物の sleep で作るので、Swift も
ネットワークも要らない。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci-check.sh"

# 最後の引数が段名。slow / slow2 は間隔 1 秒の継続中の行が 2 回出る長さ、bad は落ちる段
FAKE_MAKE = """#!/bin/bash
printf '%s\\n' "$*" >> "$MAKE_CALLS"
case "${@: -1}" in
  slow|slow2) sleep 2.5 ;;
  bad) exit 7 ;;
esac
exit 0
"""


class CiCheckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.make = self.root / "make"
        self.make.write_text(FAKE_MAKE)
        self.make.chmod(0o755)
        self.calls = self.root / "make-calls.txt"

    def env(self, heartbeat):
        env = dict(os.environ)
        env.update(
            MAKE=str(self.make),
            MAKE_CALLS=str(self.calls),
            CI_CHECK_HEARTBEAT=heartbeat,
        )
        return env

    def run_steps(self, *steps, heartbeat="30"):
        env = self.env(heartbeat)
        # 出力は管ではなくファイルで受ける。継続中の行が止まらない壊れ方をしたとき、
        # 管だと読み手が EOF を待って固まり、赤ではなく無言になる (管の検査は下に 1 本だけ置く)
        with tempfile.TemporaryFile("w+") as out, tempfile.TemporaryFile("w+") as err:
            code = subprocess.call(
                ["bash", str(SCRIPT), *steps],
                cwd=self.root, env=env, stdout=out, stderr=err, timeout=30,
            )
            out.seek(0)
            err.seek(0)
            return subprocess.CompletedProcess(steps, code, out.read(), err.read())

    def made(self):
        if not self.calls.exists():
            return []
        return self.calls.read_text().splitlines()

    def test_runs_steps_in_order_and_skips_rebuild_after_build(self):
        result = self.run_steps("build", "examples", "render-status")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            self.made(),
            [
                "--no-print-directory build",
                "--no-print-directory -o build examples",
                "--no-print-directory -o build render-status",
            ],
        )

    def test_does_not_skip_build_when_build_is_not_in_the_steps(self):
        # build を含まない並びで -o build を渡すと、組まずに走ってしまう
        result = self.run_steps("examples")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.made(), ["--no-print-directory examples"])

    def test_names_each_step_with_its_position(self):
        result = self.run_steps("build", "examples")
        self.assertIn("[1/2] build", result.stdout)
        self.assertIn("[2/2] examples", result.stdout)
        self.assertIn("✔ ci-check 2 段通過", result.stdout)

    def test_stops_at_the_failing_step_and_keeps_its_exit_code(self):
        result = self.run_steps("build", "bad", "render-status")
        self.assertEqual(result.returncode, 7)
        # 後段 (render-status) を走らせない — 走れば落ちた実行を「通った」と報告する
        self.assertEqual(
            self.made(),
            ["--no-print-directory build", "--no-print-directory -o build bad"],
        )
        self.assertIn("✘ ci-check は [2/3] bad で止まった (終了コード 7", result.stdout)
        self.assertNotIn("✔", result.stdout)

    def test_reports_that_a_long_step_is_still_running(self):
        result = self.run_steps("slow", "examples", heartbeat="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lines = result.stdout.splitlines()
        running = [line for line in lines if "slow 継続中" in line]
        self.assertGreaterEqual(len(running), 2, result.stdout)
        # 継続中の行は段が終われば止まる — 次の段の名乗りより後には出ない
        after = lines[next(i for i, line in enumerate(lines) if "[2/2] examples" in line):]
        self.assertFalse([line for line in after if "継続中" in line], result.stdout)

    def test_heartbeat_of_a_finished_step_does_not_leak_into_the_next(self):
        result = self.run_steps("slow", "slow2", heartbeat="1")
        lines = result.stdout.splitlines()
        after = lines[next(i for i, line in enumerate(lines) if "[2/2] slow2" in line):]
        self.assertTrue([line for line in after if "slow2 継続中" in line], result.stdout)
        self.assertFalse([line for line in after if "slow 継続中" in line], result.stdout)

    def test_does_not_hold_the_output_pipe_after_finishing(self):
        # 継続中の行の sleep は kill された後も残りの間隔だけ生き延びる。出力を握らせると、
        # make ci-check を管で受ける読み手 (CI のログ・tee) が間隔ぶん EOF を待たされる
        proc = subprocess.Popen(
            ["bash", str(SCRIPT), "build", "examples"],
            cwd=self.root, env=self.env("30"),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            proc.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            self.fail("終わった後も出力の管が閉じない (背面の行が握っている)")

    def test_short_step_is_not_reported_as_still_running(self):
        result = self.run_steps("build", heartbeat="1")
        self.assertNotIn("継続中", result.stdout)

    def test_second_run_names_the_previous_durations(self):
        first = self.run_steps("build", "examples")
        self.assertNotIn("前回", first.stdout)
        second = self.run_steps("build", "examples")
        self.assertIn("前回この段", second.stdout)
        self.assertIn("前回全体", second.stdout)

    def test_failed_run_still_records_the_steps_that_passed(self):
        self.run_steps("build", "bad")
        again = self.run_steps("build", "bad")
        build_line = next(line for line in again.stdout.splitlines() if "build" in line)
        self.assertIn("前回この段", build_line)
        # 記録に無い段がある並びでは、欠けた和を「前回全体」として名乗らない
        self.assertNotIn("前回全体", again.stdout)

    def test_requires_at_least_one_step(self):
        result = self.run_steps()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.made(), [])


if __name__ == "__main__":
    unittest.main()
