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


class PlaceEncodingTest(unittest.TestCase):
    """書き直したグラフが、説明文の文字を逸脱しないこと (#2535)。

    絵文字のような BMP の外の文字を `\\ud83d\\udc4d` のサロゲート対にして渡すと、docc が
    何も言わずに落ちる。`json.dumps` の既定のままだと必ずそうなる。
    """

    def test_BMPの外の文字は逸脱せず素のUTF8で書く(self):
        import json
        import tempfile

        graph = {
            "module": {"name": "MokumeCore"},
            "symbols": [
                {
                    "identifier": {"precise": "s:test"},
                    "pathComponents": ["Sketch", "text"],
                    "docComment": {"lines": [{"text": "肌色の `👍🏽` と日本語"}]},
                }
            ],
            "relationships": [],
        }
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "MokumeCore.symbols.json"
            placed = Path(directory) / "placed.symbols.json"
            source.write_text(json.dumps(graph, ensure_ascii=False), encoding="utf-8")
            graphs.place(source, "mokume", INSIDE, set(), placed)
            written = placed.read_text(encoding="utf-8")
        self.assertNotIn("\\ud83d", written.lower())
        self.assertIn("👍🏽", written)
        # 読み直しても同じ文字列に戻る (逸脱が無くても中身は変わらない)
        self.assertEqual(
            json.loads(written)["symbols"][0]["docComment"]["lines"][0]["text"],
            "肌色の `👍🏽` と日本語",
        )


if __name__ == "__main__":
    unittest.main()
