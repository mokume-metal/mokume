#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/drawing-paths.sh の検査 (#497)。

一覧は 1 つで、**問いは 2 つある** — 「絵の証跡が要るか」(#306) と「手元の実行の
覆いが壊れるか」(#435)。いまは 2 つの答えが違う場所が無く、照合は用途を読まない。
答えを分けていた行の印 (`evidence-only`) は、最後の行から #1377 で外れ、読む口ごと
#1428 で畳んだ。

読み手ごとの検査 (render_status_test.py / drawing_evidence_test.py /
catch_up_test.py) が「どちらの問いで訊いているか」を固定するのに対し、ここは
**照合そのもの**を固定する。とくに固定したいのは倒れる向きで、どの用途で訊いても、
前置きの後ろに何が書かれていても、行は外れずに効く — 狭く倒すと、絵の退行が誰にも
見られずに main へ入る。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LIB = REPO / "scripts" / "drawing-paths.sh"

PATHS = """# 見出し

Sources/MokumeCore/
Sketches/
Tests/MokumeCoreTests/
"""


class DrawingPathsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.paths = Path(self.tmp.name) / "paths.txt"
        self.paths.write_text(PATHS)

    def files(self, purpose, *inputs):
        """drawing_files を通したあとに残るファイルの並び。"""
        script = f'. "{LIB}"\nprintf \'%s\\n\' "$@" | drawing_files {purpose}\n'
        proc = subprocess.run(
            ["/bin/bash", "-c", script, "bash", *inputs],
            capture_output=True, text=True, encoding="utf-8",
            env={"DRAWING_PATHS": str(self.paths), "PATH": "/usr/bin:/bin"},
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.split()

    def touches(self, purpose, *inputs):
        """touches_drawing の真偽。"""
        script = f'. "{LIB}"\nprintf \'%s\\n\' "$@" | touches_drawing {purpose}\n'
        proc = subprocess.run(
            ["/bin/bash", "-c", script, "bash", *inputs],
            capture_output=True, text=True, encoding="utf-8",
            env={"DRAWING_PATHS": str(self.paths), "PATH": "/usr/bin:/bin"},
        )
        return proc.returncode == 0

    # --- 行は前置きとして読む --------------------------------------------

    def test_一覧に載る場所は両方の用途に効く(self):
        f = ["Sources/MokumeCore/Canvas.swift"]
        self.assertEqual(self.files("evidence", *f), f)
        self.assertEqual(self.files("coverage", *f), f)

    def test_一覧に無い場所はどちらの用途でも外れる(self):
        f = ["AGENTS.md", "scripts/render-status.sh"]
        self.assertEqual(self.files("evidence", *f), [])
        self.assertEqual(self.files("coverage", *f), [])

    def test_行は先頭一致の前置きとして読む(self):
        self.assertEqual(
            self.files("evidence", "Sketches/Shapes/Circles.swift"),
            ["Sketches/Shapes/Circles.swift"],
        )

    def test_前置きの後ろに続く語は読まない(self):
        """行の先頭の語だけが前置きで、空白の後ろは読まない。畳んだ印 (`evidence-only`)
        や知らない語が書き残されていても、その行は外れずにどちらの問いにも効く —
        後ろの語で狭く倒れると、絵の退行が誰にも見られずに main へ入る (#1428)。"""
        self.paths.write_text("Sketches/  evidence-only\nTests/MokumeCoreTests/  なにか 別の語\n")
        f = ["Sketches/main.swift", "Tests/MokumeCoreTests/L.swift"]
        for purpose in ("evidence", "coverage"):
            with self.subTest(purpose=purpose):
                self.assertEqual(self.files(purpose, *f), f)
                self.assertTrue(self.touches(purpose, *f))

    # --- 用途は読まない --------------------------------------------------

    def test_どの用途で訊いても同じ答え(self):
        """いまは 2 つの問いの答えが違う場所が無い。用途を渡し忘れた読み手も、知らない
        用途を渡した読み手も、狭いほうへ黙って倒れてはいけない。"""
        f = ["Sketches/main.swift", "AGENTS.md", "Tests/MokumeCoreTests/L.swift"]
        want = ["Sketches/main.swift", "Tests/MokumeCoreTests/L.swift"]
        for purpose in ("evidence", "coverage", "いつかの新しい問い", ""):
            with self.subTest(purpose=purpose):
                self.assertEqual(self.files(purpose, *f), want)
                self.assertTrue(self.touches(purpose, *f))


if __name__ == "__main__":
    unittest.main()
