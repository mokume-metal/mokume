#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/api-surface.py の検査。

守りたいのは「規範に沿っていない公開シンボルを機械で見つけられる」こと (#243)。
検査そのものが壊れると、沿っていない API が黙って通る — そのときこちらが赤くなる。

シンボルグラフは手で組み立てる。実際にビルドすると、確かめたい壊れ方をこちらから
作れない (壊した API を持つソースが要ることになる)。実行は make hooks-test。
"""

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "api-surface.py"

_spec = importlib.util.spec_from_file_location("api_surface", SCRIPT)
api = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(api)


def symbol(
    name, owner=None, kind="swift.method", doc=None, precise=None, takes=None,
    parameters=None, location=None,
):
    """シンボルグラフ 1 件ぶん。必要な欄だけ持たせる。

    `takes` に `(綴り, precise id)` を渡すと、その型を引数に取る宣言になる。
    シンボルグラフでは型の参照が `preciseIdentifier` を持つ断片として出る。

    `parameters` は引数の型の綴りの並び。同名の宣言を見分ける鍵になる。
    `location` は `(パス, 宣言の行番号 0 起点)` で、`//` の読み取りが使う。
    """
    fragments = [{"spelling": f"func {name}"}]
    if takes:
        spelling, identifier = takes
        fragments.append(
            {"kind": "typeIdentifier", "spelling": spelling, "preciseIdentifier": identifier})
    entry = {
        "kind": {"identifier": kind},
        "identifier": {"precise": precise or f"s:{owner or ''}{name}"},
        "accessLevel": "public",
        "names": {"title": name},
        "pathComponents": ([owner] if owner else []) + [name],
        "declarationFragments": fragments,
    }
    if parameters:
        entry["functionSignature"] = {
            "parameters": [
                {"declarationFragments": [{"spelling": f"_ value: {spelling}"}]}
                for spelling in parameters
            ]
        }
    if location:
        path, line = location
        entry["location"] = {"uri": Path(path).as_uri(), "position": {"line": line}}
    if doc:
        entry["docComment"] = {"lines": [{"text": line} for line in doc.split("\n")]}
    return entry


def written(directory, source):
    """ソースを 1 本書いて `(パス, 最終行の行番号 0 起点)` を返す。

    `//` の読み取りは実際のソースを見るので、手組みのシンボルだけでは確かめられない。
    宣言は最終行に置く約束にして、呼ぶ側が行を数えなくて済むようにする。
    """
    path = Path(directory) / "Source.swift"
    path.write_text(source, encoding="utf-8")
    return str(path), len(source.rstrip("\n").split("\n")) - 1


class ApiSurfaceTests(unittest.TestCase):
    def test_オンオフの対になる綴りを見つける(self):
        problems = api.check_onoff([symbol("enableShadows()", owner="Sketch")])
        self.assertEqual(len(problems), 1)
        self.assertIn("決定 2", problems[0])

    def test_手本の綴りは通す(self):
        self.assertEqual(api.check_onoff([symbol("noFill()", owner="Sketch")]), [])

    def test_オンオフに見えるだけの名前は通す(self):
        # `clear` で始まっても、次が大文字でなければ別の語
        self.assertEqual(api.check_onoff([symbol("clearance()", owner="Sketch")]), [])

    def test_転送の引数ラベルの食い違いを見つける(self):
        symbols = [
            symbol("tint(_:)", owner="Sketch"),
            symbol("tint(color:)", owner="Canvas"),
        ]
        problems = api.check_forwarding(symbols, set())
        self.assertEqual(len(problems), 1)
        self.assertIn("決定 1", problems[0])

    def test_同じ名前と同じラベルなら通す(self):
        symbols = [symbol("tint(_:)", owner="Sketch"), symbol("tint(_:)", owner="Canvas")]
        self.assertEqual(api.check_forwarding(symbols, set()), [])

    def test_プロトコルの要件は転送の検査から外す(self):
        symbols = [
            symbol("draw()", owner="Sketch", precise="requirement"),
            symbol("draw(_:)", owner="Canvas"),
        ]
        self.assertEqual(api.check_forwarding(symbols, {"requirement"}), [])

    def test_同じ説明文が二層にあると見つける(self):
        symbols = [
            symbol("fill(_:)", owner="Sketch", doc="塗りの色。"),
            symbol("fill(_:)", owner="Canvas", doc="塗りの色。"),
        ]
        problems = api.check_doc_canon(symbols)
        self.assertEqual(len(problems), 1)
        self.assertIn("正本は 1 層", problems[0])

    def test_下の層の説明文が長いと見つける(self):
        symbols = [
            symbol("fill(_:)", owner="Sketch", doc="塗りの色。"),
            symbol("fill(_:)", owner="Canvas", doc="塗りの色。\n\nそして長い説明が続く。"),
        ]
        problems = api.check_doc_canon(symbols)
        self.assertEqual(len(problems), 1)
        self.assertIn("転送であることだけ", problems[0])

    def test_下の層が短ければ通す(self):
        symbols = [
            symbol("fill(_:)", owner="Sketch", doc="塗りの色。\n\n長い説明。"),
            symbol("fill(_:)", owner="Canvas", doc="転送。"),
        ]
        self.assertEqual(api.check_doc_canon(symbols), [])

    def test_下の層が二重斜線でも見つける(self):
        """`/` を 1 本削るだけで検査から消えられてはいけない (#315)。"""
        with tempfile.TemporaryDirectory() as directory:
            path, line = written(directory, "// 塗りの色。\npublic func fill(_ color: LinearRGBA) {}\n")
            symbols = [
                symbol("fill(_:)", owner="Sketch", doc="塗りの色。"),
                symbol("fill(_:)", owner="Canvas", location=(path, line)),
            ]
            problems = api.check_doc_canon(symbols)
            self.assertEqual(len(problems), 1)
            self.assertIn("正本は 1 層", problems[0])

    def test_三重斜線があればそちらを読む(self):
        """`///` の下に無関係な `//` が積まれていても、正本は `///` の側。"""
        with tempfile.TemporaryDirectory() as directory:
            path, line = written(
                directory,
                "// 溜めている列を閉じる。\n/// 転送。\npublic func fill(_ color: LinearRGBA) {}\n")
            twin = symbol("fill(_:)", owner="Canvas", doc="転送。", location=(path, line))
            # `///` の上にある `//` まで拾うと、覚え書きが説明文として二重に数えられる
            self.assertEqual(api.slash_doc(twin), "")
            self.assertEqual(api.doc(twin), "転送。")
            symbols = [symbol("fill(_:)", owner="Sketch", doc="塗りの色。\n\n長い説明。"), twin]
            self.assertEqual(api.check_doc_canon(symbols), [])

    def test_引数の型が違えば別の宣言として突き合わせる(self):
        """同名の宣言を 1 本に潰すと、どれと比べたかが行き当たりばったりになる (#315)。"""
        symbols = [
            symbol("background(_:)", owner="Sketch", doc="面全体を塗り直す。",
                   parameters=["LinearRGBA"], precise="a"),
            symbol("background(_:)", owner="Canvas", doc="面全体を塗り直す。",
                   parameters=["LinearRGBA"], precise="b"),
            symbol("background(_:)", owner="Canvas", parameters=["Surroundings"], precise="c"),
        ]
        problems = api.check_doc_canon(symbols)
        self.assertEqual(len(problems), 1)
        self.assertIn("background(_:)", problems[0])

    def test_署名に出てくる自前の型が一覧に無いと見つける(self):
        symbols = [symbol("shape(_:)", owner="Sketch", takes=("Mesh", "s:6Mokume4MeshV"))]
        problems = api.check_type_closure(symbols, {"s:6Mokume4MeshV"})
        self.assertEqual(len(problems), 1)
        self.assertIn("Mesh", problems[0])

    def test_署名に出てくる型が一覧にあれば通す(self):
        symbols = [
            symbol("shape(_:)", owner="Sketch", takes=("Mesh", "s:6Mokume4MeshV")),
            symbol("Mesh", kind="swift.struct", precise="s:6Mokume4MeshV"),
        ]
        self.assertEqual(api.check_type_closure(symbols, {"s:6Mokume4MeshV"}), [])

    def test_パッケージの外の型は対象外(self):
        # Float は一覧に載りようがない。載っているべき型を「自前のもの」に限る
        symbols = [symbol("circle(_:)", owner="Sketch", takes=("Float", "s:Sf"))]
        self.assertEqual(api.check_type_closure(symbols, {"s:6Mokume4MeshV"}), [])

    def test_同じ宣言が同じ型を何度も取っても一度だけ報告する(self):
        entry = symbol("line(_:_:)", owner="Sketch", takes=("Point", "s:6Mokume5PointV"))
        entry["declarationFragments"].append(
            {"kind": "typeIdentifier", "spelling": "Point",
             "preciseIdentifier": "s:6Mokume5PointV"})
        self.assertEqual(len(api.check_type_closure([entry], {"s:6Mokume5PointV"})), 1)

    def test_所有する識別子はグラフを横断して集まる(self):
        with tempfile.TemporaryDirectory() as directory:
            graphs = Path(directory)
            for name, precise in (("MokumeCore", "s:core"), ("MokumeDiagnostics", "s:diag")):
                (graphs / f"{name}.symbols.json").write_text(
                    json.dumps({"symbols": [symbol("Thing", kind="swift.struct", precise=precise)]}),
                    encoding="utf-8")
            self.assertEqual(api.load_owned_identifiers(graphs), {"s:core", "s:diag"})

    def test_署名に外部モジュールの型が出ると見つける(self):
        symbols = [symbol("load(_:)", owner="Sketch", takes=("URL", "s:10Foundation3URLV"))]
        problems = api.check_foreign_vocabulary(symbols, {"s:6Mokume4MeshV"})
        self.assertEqual(len(problems), 1)
        self.assertIn("Foundation", problems[0])
        self.assertIn("URL", problems[0])

    def test_署名に出てくる_ObjC_の型も見つける(self):
        symbols = [
            symbol("attach(_:)", owner="Sketch", takes=("NSApplication", "c:objc(cs)NSApplication"))
        ]
        problems = api.check_foreign_vocabulary(symbols, set())
        self.assertEqual(len(problems), 1)
        self.assertIn("NSApplication", problems[0])

    def test_例外表に載っているシンボルは通す(self):
        # 表に載る「シンボル → 理由」の組は実在するものを使う。表ごと消えたらこちらが赤くなる
        self.assertIn("RenderDevice.init(device:)", api.FOREIGN_ALLOWLIST)
        symbols = [
            symbol("init(device:)", owner="RenderDevice", takes=("MTLDevice", "c:objc(pl)MTLDevice"))
        ]
        self.assertEqual(api.check_foreign_vocabulary(symbols, set()), [])

    def test_例外の理由が空なら表として成立しない(self):
        for name, reason in api.FOREIGN_ALLOWLIST.items():
            with self.subTest(name):
                self.assertTrue(reason.strip(), f"{name} に理由が書かれていない")

    def test_標準ライブラリの型は面に出てよい(self):
        symbols = [
            symbol("circle(_:)", owner="Sketch", takes=("Float", "s:Sf")),
            symbol("name(_:)", owner="Sketch", takes=("String", "s:SS")),
            symbol("size(_:)", owner="Sketch", takes=("SIMD2", "s:s5SIMD2V")),
        ]
        self.assertEqual(api.check_foreign_vocabulary(symbols, set()), [])

    def test_自前の型は面に出てよい(self):
        # 自前の型が一覧から落ちていないかは check_type_closure が見る。こちらは境界だけ
        symbols = [symbol("shape(_:)", owner="Sketch", takes=("Mesh", "s:6Mokume4MeshV"))]
        self.assertEqual(api.check_foreign_vocabulary(symbols, {"s:6Mokume4MeshV"}), [])

    def test_USR_からモジュール名を取る(self):
        self.assertEqual(api.module_of("s:10Foundation3URLV"), "Foundation")
        self.assertEqual(api.module_of("s:6Mokume4MeshV"), "Mokume")
        self.assertEqual(api.module_of("c:objc(cs)NSApplication"), "(ObjC)")
        self.assertEqual(api.module_of("s:Sf"), "Swift")
        self.assertEqual(api.module_of("s:s5SIMD2V"), "Swift")

    def test_件数の直書きを見つける(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "README.md").write_text("公開 API は 128 個ある。\n", encoding="utf-8")
            problems = api.check_no_written_counts(root)
            self.assertEqual(len(problems), 1)
            self.assertIn("README.md:1", problems[0])

    def test_件数を書いていなければ通す(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "README.md").write_text("公開 API の一覧は版ごとに配る。\n", encoding="utf-8")
            self.assertEqual(api.check_no_written_counts(root), [])

    def test_一覧に件数が載る(self):
        text = api.render([symbol("Sketch", kind="swift.protocol")], "v1.2.3")
        self.assertIn("mokume v1.2.3", text)
        self.assertIn("公開シンボル 1 個", text)

    def test_要件と既定の実装は一覧で畳まれる(self):
        with tempfile.TemporaryDirectory() as directory:
            graphs = Path(directory)
            document = {
                "symbols": [
                    symbol("draw()", owner="Sketch", precise="a"),
                    symbol("draw()", owner="Sketch", precise="b"),
                ]
            }
            (graphs / "MokumeCore.symbols.json").write_text(
                json.dumps(document), encoding="utf-8")
            self.assertEqual(len(api.load_symbols(graphs, "MokumeCore")), 1)

    def test_引数の型が違うものは一覧で畳まれない(self):
        with tempfile.TemporaryDirectory() as directory:
            graphs = Path(directory)
            document = {
                "symbols": [
                    symbol("background(_:)", owner="Canvas",
                           parameters=["LinearRGBA"], precise="a"),
                    symbol("background(_:)", owner="Canvas",
                           parameters=["Surroundings"], precise="b"),
                ]
            }
            (graphs / "MokumeCore.symbols.json").write_text(
                json.dumps(document), encoding="utf-8")
            self.assertEqual(len(api.load_symbols(graphs, "MokumeCore")), 2)

    def test_シンボルグラフが無ければ落ちる(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                ["python3", str(SCRIPT), "check", "--graphs", directory],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("シンボルグラフが見つからない", result.stderr)


if __name__ == "__main__":
    unittest.main()
