#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/reference-graphs.py の検査。

守りたいのは「面の内側どうしの拡張が、1 つの面に溶けて出る」こと (#1977)。docc は
ファイル名の `A@B` を「モジュール B への拡張」と読むので、B を面の名前へ名乗り直した
ままそれを渡すと、`Sketch` に足した口のページが作られず、リンクだけが切れる。
実行は make hooks-test。
"""

import importlib.util
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "reference-graphs.py"

_spec = importlib.util.spec_from_file_location("reference_graphs", SCRIPT)
graphs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(graphs)

INSIDE = {"MokumeCore", "MokumeCamera"}


class PlacedNameTest(unittest.TestCase):
    def test_面の内側への拡張は_at_を外して置く(self):
        self.assertEqual(
            graphs.placed_name("MokumeCamera@MokumeCore.symbols.json", INSIDE),
            "MokumeCamera-MokumeCore.symbols.json",
        )

    def test_面の外への拡張はそのまま置く(self):
        # Swift の型への拡張は、docc が Swift への拡張として出すのが正しい
        self.assertEqual(
            graphs.placed_name("MokumeCore@Swift.symbols.json", INSIDE),
            "MokumeCore@Swift.symbols.json",
        )

    def test_本体のグラフはそのまま置く(self):
        self.assertEqual(
            graphs.placed_name("MokumeCamera.symbols.json", INSIDE), "MokumeCamera.symbols.json"
        )


if __name__ == "__main__":
    unittest.main()
