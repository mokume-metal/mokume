#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`scripts/gpu-slot.py` — GPU の検査を、機械全体で共有する枠を取ってから走らせる包みの検査 (#1898)。

守るのは 4 つ。
- 枠の数より多くは同時に走らない
- 持ち主が殺されれば、枠が返る
- 待つ側が期限を持つ
- 子の終了コードをそのまま返す

Swift も GPU も要らない。子には、合図のファイルを待つだけの小さな Python を走らせる。
置き場は検査ごとの一時ディレクトリで、本物の枠 (`~/Library/Caches/mokume/gpu-slots`) には触らない。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "gpu-slot.py"

# 子: 始まったら started を作り、release が現れるまで待って、与えた終了コードで抜ける
CHILD = (
    "import sys, time, pathlib\n"
    "started, release, code = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])\n"
    "started.touch()\n"
    "while not release.exists():\n"
    "    time.sleep(0.02)\n"
    "sys.exit(code)\n"
)


def _wait_for(predicate, seconds=10.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


class GpuSlotTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.slots = self.root / "slots"
        self.running = []

    def tearDown(self):
        # 先に合図を置いて子を終わらせる。包みを SIGKILL すると子が取り残され、パイプを握った
        # まま残る (持ち主を殺す検査はわざとそうするので、ここで終わらせる)
        for name in {path.stem for path in self.root.glob("*.started")}:
            (self.root / f"{name}.release").touch()
        for process in self.running:
            if process.poll() is None:
                process.terminate()  # 包みは SIGTERM を子へ渡す
        for process in self.running:
            process.communicate(timeout=10)
        self.temporary.cleanup()

    def _environment(self, slots="2", wait="30", extra=None):
        environment = dict(os.environ)
        environment.update(
            {
                "MOKUME_GPU_SLOT_DIR": str(self.slots),
                "MOKUME_GPU_SLOTS": slots,
                "MOKUME_GPU_SLOT_WAIT": wait,
                "MOKUME_GPU_SLOT_POLL": "0.02",
                "MOKUME_GPU_SLOT_REPORT": "0.1",
            }
        )
        environment.update(extra or {})
        return environment

    def _start(self, name, code=0, **options):
        """包みを通して子を走らせる。子が始まった印と、子を終わらせる合図のファイルを返す。"""
        started = self.root / f"{name}.started"
        release = self.root / f"{name}.release"
        process = subprocess.Popen(
            [sys.executable, str(SCRIPT), "--", sys.executable, "-c", CHILD, str(started), str(release), str(code)],
            env=self._environment(**options),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.running.append(process)
        return process, started, release

    def test_no_more_than_the_slot_count_run_at_once(self):
        first, first_started, first_release = self._start("first")
        second, second_started, _ = self._start("second")
        self.assertTrue(_wait_for(first_started.exists), "1 本目が走らない")
        self.assertTrue(_wait_for(second_started.exists), "2 本目が走らない")
        third, third_started, _ = self._start("third")
        time.sleep(0.5)
        self.assertFalse(third_started.exists(), "枠 2 なのに 3 本目が走った")
        first_release.touch()
        self.assertEqual(first.wait(timeout=10), 0)
        self.assertTrue(_wait_for(third_started.exists), "枠が空いても 3 本目が走らない")

    def test_waiting_side_names_the_holders(self):
        holder, holder_started, _ = self._start("holder", slots="1")
        self.assertTrue(_wait_for(holder_started.exists))
        waiter, _, _ = self._start("waiter", slots="1", wait="0.5")
        _, error = waiter.communicate(timeout=10)
        self.assertIn("空くのを待っている", error)
        self.assertIn(f"pid {holder.pid}", error)

    def test_a_killed_holder_gives_its_slot_back(self):
        holder, holder_started, holder_release = self._start("holder", slots="1")
        self.assertTrue(_wait_for(holder_started.exists))
        waiter, waiter_started, _ = self._start("waiter", slots="1")
        time.sleep(0.3)
        self.assertFalse(waiter_started.exists(), "枠 1 なのに 2 本目が走った")
        holder.send_signal(signal.SIGKILL)
        holder.wait(timeout=10)
        self.assertTrue(_wait_for(waiter_started.exists), "持ち主が殺されても枠が返らない")
        holder_release.touch()  # 取り残された子を終わらせる

    def test_the_waiting_side_gives_up_at_its_deadline(self):
        holder, holder_started, _ = self._start("holder", slots="1")
        self.assertTrue(_wait_for(holder_started.exists))
        waiter, waiter_started, _ = self._start("waiter", slots="1", wait="0.3")
        _, error = waiter.communicate(timeout=10)
        self.assertEqual(waiter.returncode, 75)
        self.assertFalse(waiter_started.exists(), "期限で抜けたのに子を走らせた")
        self.assertIn("空かなかった", error)
        self.assertIn(f"pid {holder.pid}", error)

    def test_the_child_exit_code_is_returned(self):
        for code in (0, 1, 3):
            with self.subTest(code=code):
                process, started, release = self._start(f"code{code}", code=code)
                self.assertTrue(_wait_for(started.exists))
                release.touch()
                self.assertEqual(process.wait(timeout=10), code)

    def test_a_bad_slot_count_is_refused(self):
        for value in ("0", "-1", "x", "1.5"):
            with self.subTest(value=value):
                process, started, _ = self._start(f"bad{value}", slots=value)
                _, error = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 2)
                self.assertIn("MOKUME_GPU_SLOTS", error)
                self.assertFalse(started.exists())

    def test_an_unusable_slot_directory_runs_without_a_slot_and_says_so(self):
        blocker = self.root / "blocker"
        blocker.write_text("")  # ファイルの下にディレクトリは作れない
        process, started, release = self._start(
            "unslotted", extra={"MOKUME_GPU_SLOT_DIR": str(blocker / "slots")}
        )
        self.assertTrue(_wait_for(started.exists), "置き場を使えないと子が走らない")
        release.touch()
        _, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0)
        self.assertIn("枠を取らずに走らせる", error)

    def test_usage_without_a_command(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT)], env=self._environment(), capture_output=True, text=True, timeout=10
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("使い方", result.stderr)


class ParallelizationWidthTest(unittest.TestCase):
    """子の swift test へ、Swift Testing の並列の幅が届くこと (#1999)。"""

    VARIABLE = "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)

    def _child_sees(self, extra):
        environment = {key: value for key, value in os.environ.items() if key != self.VARIABLE}
        environment.update({"MOKUME_GPU_SLOT_DIR": self.temporary.name, "MOKUME_GPU_SLOT_POLL": "0.02"})
        environment.update(extra)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--", sys.executable, "-c",
             f"import os; print(os.environ.get({self.VARIABLE!r}, 'unset'))"],
            env=environment,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_the_child_runs_with_width_1_by_default(self):
        # 幅 4 以上では、MTL4CommandQueue の解放の直後の仕事が落ちる (#2007)
        self.assertEqual(self._child_sees({}), "1")

    def test_a_width_given_by_the_caller_is_kept(self):
        # 既定 (1) と区別できる値で見る
        self.assertEqual(self._child_sees({self.VARIABLE: "4"}), "4")

    def test_an_empty_width_is_treated_as_unset(self):
        self.assertEqual(self._child_sees({self.VARIABLE: ""}), "1")


class MakefileWiringTest(unittest.TestCase):
    """test と test-release の段が、swift test を枠の包みの内で走らせていること。"""

    def test_swift_test_runs_inside_the_slot(self):
        makefile = (REPO / "Makefile").read_text()
        for target in ("test:", "test-release:"):
            with self.subTest(target=target):
                body = makefile.split(f"\n{target}", 1)[1].split("\n\n", 1)[0]
                runs = [line for line in body.splitlines() if "swift test" in line]
                self.assertTrue(runs, f"{target} に swift test が無い")
                for line in runs:
                    self.assertIn("scripts/gpu-slot.py -- swift test", line)

    def test_the_build_stays_outside_the_slot(self):
        makefile = (REPO / "Makefile").read_text()
        body = makefile.split("\ntest:", 1)[1].split("\n\n", 1)[0]
        builds = [line for line in body.splitlines() if "swift build" in line]
        self.assertTrue(builds)
        for line in builds:
            self.assertNotIn("gpu-slot.py", line)


if __name__ == "__main__":
    unittest.main()
