#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/run-hooks-tests.py の検査 (#1714)。

この駆動役が守るのは 2 つ。

1. **落ちたものを落ちたと言う。** 1 ファイルでも落ちれば 1 で終わり、どのファイルかを
   名乗る。検査が 1 件も無いファイルを「0 件で通った」と数えると、並列にしたことで検査が
   黙って減る (import で死んだファイルは unittest が 1 件の失敗として 1 で終わる)
2. **件数を足し合わせる。** 最後の `Ran N tests` は各ファイルの件数の合計で、直列のときと
   比べられる数でなければならない (#1714 の完了条件 2)

並列に走ることは、互いの印を待ち合う 2 ファイルで確かめる。同時に走らなければ先に
起きた側が期限切れで落ちる。検査用のファイルは一時ディレクトリに作って --dir で渡すので、
本物の検査は走らせない。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "run-hooks-tests.py"

PASSING = """
import unittest

class T(unittest.TestCase):
{methods}
"""

# 自分の印を置いてから相手の印を待つ。相手が同時に走っていなければ期限で落ちる
RENDEZVOUS = """
import os, time, unittest
from pathlib import Path

class T(unittest.TestCase):
    def test_meet(self):
        here = Path(os.environ["RENDEZVOUS_DIR"])
        (here / "{me}").touch()
        deadline = time.monotonic() + float(os.environ["RENDEZVOUS_WAIT"])
        while not (here / "{other}").exists():
            self.assertLess(time.monotonic(), deadline, "相手が同時に走っていない")
            time.sleep(0.02)
"""


def passing(count):
    methods = "\n".join(f"    def test_{i}(self):\n        pass\n" for i in range(count))
    return PASSING.format(methods=methods)


class RunHooksTestsTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.tests = self.root / "tests"
        self.tests.mkdir()
        self.meet = self.root / "meet"
        self.meet.mkdir()

    def write(self, name, source):
        (self.tests / name).write_text(textwrap.dedent(source))

    def run_driver(self, jobs=None, wait="10"):
        env = dict(os.environ, RENDEZVOUS_DIR=str(self.meet), RENDEZVOUS_WAIT=wait)
        env.pop("HOOKS_TEST_JOBS", None)
        if jobs is not None:
            env["HOOKS_TEST_JOBS"] = jobs
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--dir", str(self.tests)],
            capture_output=True, text=True, env=env, timeout=60,
        )

    def test_counts_from_every_file_are_added_up(self):
        self.write("a_test.py", passing(2))
        self.write("b_test.py", passing(3))
        result = self.run_driver()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Ran 5 tests in ", result.stdout)
        self.assertIn("ok    a_test  2 件", result.stdout)
        self.assertIn("ok    b_test  3 件", result.stdout)
        self.assertTrue(result.stdout.rstrip().endswith("OK"), result.stdout)

    def test_a_failing_file_fails_the_run_and_is_named(self):
        self.write("a_test.py", passing(2))
        self.write("bad_test.py", """
            import unittest

            class T(unittest.TestCase):
                def test_ok(self):
                    pass

                def test_broken(self):
                    self.assertEqual(1, 2, "わざと落とす")
        """)
        result = self.run_driver()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL  bad_test  終了コード 1・2 件", result.stdout)
        self.assertIn("わざと落とす", result.stdout)
        self.assertIn("FAILED (1 ファイル: bad_test)", result.stdout)
        # 落ちたファイルの件数も合計に入る (直列の unittest と同じ数え方)
        self.assertIn("Ran 4 tests in ", result.stdout)

    def test_a_file_that_dies_on_import_is_a_failure(self):
        # unittest は import の失敗を 1 件の失敗 (_FailedTest) として数えて 1 で終わる
        self.write("a_test.py", passing(1))
        self.write("dead_test.py", "import no_such_module_for_hooks_test\n")
        result = self.run_driver()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL  dead_test", result.stdout)
        self.assertIn("no_such_module_for_hooks_test", result.stdout)
        self.assertIn("FAILED (1 ファイル: dead_test)", result.stdout)

    def test_a_file_without_tests_is_a_failure(self):
        self.write("a_test.py", passing(1))
        self.write("empty_test.py", "import unittest\n")
        result = self.run_driver()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL  empty_test  検査が 1 件も無い", result.stdout)

    def test_files_run_at_the_same_time(self):
        self.write("left_test.py", RENDEZVOUS.format(me="left", other="right"))
        self.write("right_test.py", RENDEZVOUS.format(me="right", other="left"))
        result = self.run_driver(jobs="2")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Ran 2 tests in ", result.stdout)

    def test_one_job_runs_the_files_one_after_another(self):
        self.write("left_test.py", RENDEZVOUS.format(me="left", other="right"))
        self.write("right_test.py", RENDEZVOUS.format(me="right", other="left"))
        result = self.run_driver(jobs="1", wait="1")
        # 先に走った側は相手を待ちきれずに落ち、後の側は先の印を見て通る
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAILED (1 ファイル: ", result.stdout)
        self.assertIn("同時に 1", result.stdout)

    def test_jobs_must_be_a_positive_integer(self):
        self.write("a_test.py", passing(1))
        for bad in ("0", "-1", "many"):
            with self.subTest(bad=bad):
                result = self.run_driver(jobs=bad)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("HOOKS_TEST_JOBS は正の整数", result.stderr)

    def test_an_empty_directory_is_a_failure(self):
        result = self.run_driver()
        self.assertEqual(result.returncode, 1)
        self.assertIn("検査のファイルが 1 つも無い", result.stderr)


if __name__ == "__main__":
    unittest.main()
