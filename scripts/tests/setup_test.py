#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`make setup` が python3 の版を確かめることを見る (#2030)。

`scripts/` の Python は 3.10 以上を前提に書かれている (`release.py` の `match`、
`run-hooks-tests.py` と `check-agents-md-size.py` の評価時の `int | None`)。macOS 同梱の
python3 は 3.9 で、以前の `setup` は python3 が**在るか**しか見なかったので、3.9 が PATH の
先にある環境では `ok` を出した後に `make changelog-lint` / `make hooks-test` /
`make agents-md-size` が構文と評価の誤りで落ちていた。

本物の Makefile の `setup` を、版だけを偽った python3 を PATH の先頭に置いて走らせる。
偽の python3 は本物へ処理を渡し、渡す前に `sys.version_info` だけを差し替える — 版の
判定の式そのものは本物の Python が評価する。

**見るのは版の行だけである。** 3.10 のときに `setup` 全体が緑になることは求めない —
後に続く gh / reuse / check-jsonschema の有無は機械ごとに違う。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MAKE = shutil.which("make")

# 版を偽る python3。`-c` のコードは、版を差し替えた後に本物の Python が評価する
FAKE_PYTHON = """#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "Python {major}.{minor}.6"
  exit 0
fi
if [ "$1" = "-c" ]; then
  FAKE_CODE="$2" exec "{real}" -c 'import os, sys; sys.version_info = ({major}, {minor}, 6, "final", 0); exec(os.environ["FAKE_CODE"])'
fi
exec "{real}" "$@"
"""

TOO_OLD = "より古い"


class SetupPythonVersionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()

    def fake_python(self, major, minor):
        path = self.bin / "python3"
        path.write_text(
            FAKE_PYTHON.format(major=major, minor=minor, real=sys.executable),
            encoding="utf-8",
        )
        path.chmod(0o755)

    def run_setup(self, path):
        return subprocess.run(
            [MAKE, "-s", "--no-print-directory", "setup"],
            cwd=REPO,
            env={**os.environ, "PATH": path},
            capture_output=True,
            text=True,
        )

    def test_python_older_than_3_10_stops_setup(self):
        self.fake_python(3, 9)
        proc = self.run_setup(f"{self.bin}:{os.environ['PATH']}")
        output = proc.stdout + proc.stderr
        self.assertNotEqual(proc.returncode, 0, output)
        self.assertIn(TOO_OLD, output)
        # 見つけた版と入れ方を名乗る (赤の読み手は次の一手を探す)
        self.assertIn("Python 3.9.6", output)
        self.assertIn("brew install python", output)
        self.assertNotIn("ok: 必要なツールは揃っている", output)

    def test_python_3_10_passes_the_version_line(self):
        self.fake_python(3, 10)
        proc = self.run_setup(f"{self.bin}:{os.environ['PATH']}")
        self.assertNotIn(TOO_OLD, proc.stdout + proc.stderr)

    def test_missing_python_points_at_a_new_enough_one(self):
        """同梱の 3.9 を入れる xcode-select は勧めない。"""
        proc = self.run_setup(str(self.bin))  # 空のディレクトリだけ
        output = proc.stdout + proc.stderr
        self.assertNotEqual(proc.returncode, 0, output)
        self.assertIn("python3 が見つからない", output)
        self.assertIn("brew install python", output)
        self.assertNotIn("xcode-select", output)


if __name__ == "__main__":
    unittest.main()
