#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/drawing-paths.sh の検査 (#497)。

一覧は 1 つで、問いも 1 つ — 「描画に触れているか」である。以前は「手元の実行の
覆いが壊れるか」(#435) の問いもあり、呼ぶ側が用途を渡していたが、覆いの機構ごと
#879 で畳んだ。答えを分けていた行の印 (`evidence-only`) は、#1428 で畳んだ。

読み手の検査 (drawing_evidence_test.py) が証跡の判定を固定するのに対し、ここは
**照合そのもの**を固定する。とくに固定したいのは倒れる向きで、前置きの後ろに何が
書かれていても、行は外れずに効く — 狭く倒すと、絵の退行が誰にも見られずに main へ
入る。

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

    def files(self, *inputs):
        """drawing_files を通したあとに残るファイルの並び。"""
        script = f'. "{LIB}"\nprintf \'%s\\n\' "$@" | drawing_files\n'
        proc = subprocess.run(
            ["/bin/bash", "-c", script, "bash", *inputs],
            capture_output=True, text=True, encoding="utf-8",
            env={"DRAWING_PATHS": str(self.paths), "PATH": "/usr/bin:/bin"},
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.split()

    def touches(self, *inputs):
        """touches_drawing の真偽。"""
        script = f'. "{LIB}"\nprintf \'%s\\n\' "$@" | touches_drawing\n'
        proc = subprocess.run(
            ["/bin/bash", "-c", script, "bash", *inputs],
            capture_output=True, text=True, encoding="utf-8",
            env={"DRAWING_PATHS": str(self.paths), "PATH": "/usr/bin:/bin"},
        )
        return proc.returncode == 0

    # --- 行は前置きとして読む --------------------------------------------

    def test_一覧に載る場所は残る(self):
        f = ["Sources/MokumeCore/Canvas.swift"]
        self.assertEqual(self.files(*f), f)
        self.assertTrue(self.touches(*f))

    def test_一覧に無い場所は外れる(self):
        f = ["AGENTS.md", "scripts/check-drawing-evidence.sh"]
        self.assertEqual(self.files(*f), [])
        self.assertFalse(self.touches(*f))

    def test_行は先頭一致の前置きとして読む(self):
        self.assertEqual(
            self.files("Sketches/Shapes/Circles.swift"),
            ["Sketches/Shapes/Circles.swift"],
        )

    def test_前置きの後ろに続く語は読まない(self):
        """行の先頭の語だけが前置きで、空白の後ろは読まない。畳んだ印 (`evidence-only`)
        や知らない語が書き残されていても、その行は外れずに効く —
        後ろの語で狭く倒れると、絵の退行が誰にも見られずに main へ入る (#1428)。"""
        self.paths.write_text("Sketches/  evidence-only\nTests/MokumeCoreTests/  なにか 別の語\n")
        f = ["Sketches/main.swift", "Tests/MokumeCoreTests/L.swift"]
        self.assertEqual(self.files(*f), f)
        self.assertTrue(self.touches(*f))


if __name__ == "__main__":
    unittest.main()
