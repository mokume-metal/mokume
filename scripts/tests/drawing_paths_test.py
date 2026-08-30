#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/drawing-paths.sh の検査 (#497)。

一覧は 1 つだが、**問いは 2 つある** — 「絵の証跡が要るか」(#306) と「手元の実行の
覆いが壊れるか」(#435)。`Sketches/` はその 2 つで答えが違う場所で、行の印
(`evidence-only`) がその違いを持つ。

読み手ごとの検査 (render_status_test.py / drawing_evidence_test.py /
catch_up_test.py) が「どちらの問いで訊いているか」を固定するのに対し、ここは
**照合そのもの**を固定する。とくに固定したいのは倒れる向きで、印も用途も読めない
ときは広い側 (両方の問いに効く) へ倒れる — 狭く倒すと、絵の退行が誰にも見られずに
main へ入る。

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
Sketches/  evidence-only
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
            ["bash", "-c", script, "bash", *inputs],
            capture_output=True, text=True, encoding="utf-8",
            env={"DRAWING_PATHS": str(self.paths), "PATH": "/usr/bin:/bin"},
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.split()

    def touches(self, purpose, *inputs):
        """touches_drawing の真偽。"""
        script = f'. "{LIB}"\nprintf \'%s\\n\' "$@" | touches_drawing {purpose}\n'
        proc = subprocess.run(
            ["bash", "-c", script, "bash", *inputs],
            capture_output=True, text=True, encoding="utf-8",
            env={"DRAWING_PATHS": str(self.paths), "PATH": "/usr/bin:/bin"},
        )
        return proc.returncode == 0

    # --- 印の無い行は、どちらの問いにも効く ------------------------------

    def test_印の無い行は両方の用途に効く(self):
        f = ["Sources/MokumeCore/Canvas.swift"]
        self.assertEqual(self.files("evidence", *f), f)
        self.assertEqual(self.files("coverage", *f), f)

    def test_一覧に無い場所はどちらの用途でも外れる(self):
        f = ["AGENTS.md", "scripts/render-status.sh"]
        self.assertEqual(self.files("evidence", *f), [])
        self.assertEqual(self.files("coverage", *f), [])

    def test_行は先頭一致の前置きとして読む(self):
        # 印を足しても、前置きの読み方は変わらない
        self.assertEqual(
            self.files("evidence", "Sketches/Shapes/Circles.swift"),
            ["Sketches/Shapes/Circles.swift"],
        )

    # --- evidence-only の行 ---------------------------------------------

    def test_evidence_onlyの行は証跡の問いには効く(self):
        f = ["Sketches/main.swift"]
        self.assertEqual(self.files("evidence", *f), f)
        self.assertTrue(self.touches("evidence", *f))

    def test_evidence_onlyの行は覆いの問いから外れる(self):
        """#497 の本体。参照スケッチは台帳が描く絵を動かせないので、手元の実行の
        覆いにも、描画 PR の順番待ちにも数えない。"""
        f = ["Sketches/main.swift"]
        self.assertEqual(self.files("coverage", *f), [])
        self.assertFalse(self.touches("coverage", *f))

    def test_印の付いた行と付かない行が混ざっても覆いは残る(self):
        self.assertEqual(
            self.files("coverage", "Sketches/main.swift", "Tests/MokumeCoreTests/L.swift"),
            ["Tests/MokumeCoreTests/L.swift"],
        )

    # --- 読めないものは広い側へ倒れる ------------------------------------

    def test_用途を渡さなければ広い側へ倒れる(self):
        """新しい読み手が用途を渡し忘れたら、狭いほうへ黙って倒れてはいけない。"""
        script = f'. "{LIB}"\nprintf \'%s\\n\' Sketches/main.swift | drawing_files\n'
        proc = subprocess.run(
            ["bash", "-c", script],
            capture_output=True, text=True, encoding="utf-8",
            env={"DRAWING_PATHS": str(self.paths), "PATH": "/usr/bin:/bin"},
        )
        self.assertEqual(proc.stdout.split(), ["Sketches/main.swift"])

    def test_知らない用途は広い側へ倒れる(self):
        self.assertEqual(
            self.files("いつかの新しい問い", "Sketches/main.swift"),
            ["Sketches/main.swift"],
        )

    def test_知らない印は無視して広い側へ倒れる(self):
        # evidence-only の綴り違いは「印が無い」と同じ扱い = 両方の問いに効く
        self.paths.write_text("Sketches/  evidence-onlyy\n")
        self.assertEqual(
            self.files("coverage", "Sketches/main.swift"), ["Sketches/main.swift"]
        )


if __name__ == "__main__":
    unittest.main()
