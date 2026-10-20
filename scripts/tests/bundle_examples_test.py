#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/bundle-examples.py の検査 (#2436)。

固定するのは次の 4 つ。どれも破れ方が「一覧に出ない・開けない」で、利用者にしか見えない。

- **綴りが参照の面の見出しと同じ** — `Sketch` の口は名前だけ、それ以外の型の口は型の名前を
  前に付ける。ずれると、docc で見つけた名前で `--from` が引けない
- **同じ見出しに複数あれば番号を添える** — 番号は 1 から、ソースの並び
- **外すものを外す** — 型の段・組めない印・資材を読む例・宣言に結べない例。外さないと、開いても
  組めない・絵が出ない例が一覧に並ぶ
- **束の形** — 索引が 3 欄で、スケッチが `@main` と差し込み口を持ち、前の束と README の扱いが正しい

実行は make hooks-test。**swiftc は使わない** (組めることは MokumeCLITests が全部の例で見る)。
"""

import importlib.util
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


bundle = _load("bundle_examples", REPO / "scripts" / "bundle-examples.py")

SKETCH_SOURCE = """\
public extension Sketch {
    /// 三角形を塗る。**続き**は `ここ` のように書く。
    ///
    /// ```swift
    /// triangle(1, 2, 3, 4, 5, 6)
    /// ```
    func triangle(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {}

    /// 円を塗る。
    ///
    /// ```swift
    /// circle(1, 2, 3)
    /// ```
    ///
    /// ```swift
    /// circle(4, 5, 6)
    /// ```
    func circle(_ x: Float, _ y: Float, _ d: Float) {}

    /// 画像を読んで置く。
    ///
    /// ```swift
    /// image(try! loadImage("assets/grain.png"), 0, 0)
    /// ```
    func image(_ a: Int) {}

    /// 自作の型を使う。
    ///
    /// ```swift
    /// final class Mine: Sketch {
    ///     func draw() {}
    /// }
    /// ```
    func mine() {}

    /// 組めない例だけを持つ。
    ///
    /// <!-- example: 組めない 外のパッケージが持つ -->
    /// ```swift
    /// external()
    /// ```
    func external() {}

    /// 離れた説明文。
    ///
    /// ```swift
    /// detached()
    /// ```

    func detached() {}

    /// 文脈を持つ例。
    ///
    /// <!-- example: 文脈 var dust: Int = 0 -->
    /// ```swift
    /// dust += 1
    /// ```
    func withContext() {}
}

public struct Circle {
    /// 値の円を描く。
    ///
    /// ```swift
    /// Circle().draw()
    /// ```
    public func draw() {}
}
"""

CATALOG = """\
# ``mokume``

```swift
catalogueOnly()
```
"""


class 束(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        # 使い捨てのリポジトリは手元の署名設定を継ぐ (#344)。ここは commit しないが、
        # 条件はファイル側に持たせる決まりなので揃えておく
        subprocess.run(["git", "-C", str(self.root), "config", "commit.gpgsign", "false"], check=True)
        self.置く("Sources/MokumeCore/Sketch/Sketch+Demo.swift", SKETCH_SOURCE)
        self.置く("Documentation/mokume.docc/mokume.md", CATALOG)

    def tearDown(self):
        self.temporary.cleanup()

    def 置く(self, name: str, text: str):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(text), encoding="utf-8")
        subprocess.run(["git", "-C", str(self.root), "add", name], check=True)

    def 作る(self):
        return bundle.build(self.root)

    def 綴り(self):
        entries, _ = self.作る()
        return sorted(entry.spelling for entry in entries)

    # ---- 綴り

    def test_Sketch_の口は名前と引数のラベル_ほかの型の口は型の名前を前に付ける(self):
        spellings = self.綴り()
        self.assertIn("triangle(_:_:_:_:)", spellings)
        self.assertIn("Circle.draw()", spellings)
        # `Sketch` の語彙に型の名前は付かない
        self.assertFalse([s for s in spellings if s.startswith("Sketch.")])

    def test_同じ見出しに複数あれば_ソースの並びで番号を添える(self):
        spellings = self.綴り()
        self.assertIn("circle(_:_:_:)#1", spellings)
        self.assertIn("circle(_:_:_:)#2", spellings)
        self.assertNotIn("circle(_:_:_:)", spellings, "複数あるのに番号の無い綴りが残っている")
        # 1 本の口には番号を付けない
        self.assertNotIn("triangle(_:_:_:_:)#1", spellings)
        entries, _ = self.作る()
        first = next(entry for entry in entries if entry.spelling == "circle(_:_:_:)#1")
        second = next(entry for entry in entries if entry.spelling == "circle(_:_:_:)#2")
        self.assertIn("circle(1, 2, 3)", first.source)
        self.assertIn("circle(4, 5, 6)", second.source)

    def test_綴りは重ならない(self):
        spellings = self.綴り()
        self.assertEqual(len(spellings), len(set(spellings)))

    def test_説明は説明文の最初の1文で_記法の飾りを外す(self):
        entries, _ = self.作る()
        triangle = next(entry for entry in entries if entry.heading == "triangle(_:_:_:_:)")
        self.assertEqual(triangle.summary, "三角形を塗る。")
        # 1 文目が複数の飾りを持っても、素の文になる
        self.assertEqual(
            bundle.summary_of(
                ["/// **太い** `コード` と [リンク](https://example.com) と ``Sketch/fill(_:)`` を置く。続き。", "/// ```swift"],
                1,
            ),
            "太い コード と リンク と Sketch/fill(_:) を置く。",
        )

    # ---- 外すもの

    def test_外すもの(self):
        entries, left = self.作る()
        headings = {entry.heading for entry in entries}
        reasons = {item.reason.split(" (")[0] for item in left}
        # 資材を読む例・型の段・組めない印・宣言に結べない例・カタログの例
        self.assertNotIn("image(_:)", headings)
        self.assertNotIn("mine()", headings)
        self.assertNotIn("external()", headings)
        self.assertNotIn("detached()", headings)
        self.assertEqual(
            reasons,
            {"資材を読む", "型の段", "組めない印", "宣言に結べない", "カタログの例"},
        )

    def test_文脈の宣言は包みに入る(self):
        entries, _ = self.作る()
        source = next(entry for entry in entries if entry.heading == "withContext()").source
        self.assertIn("var dust: Int = 0", source)
        self.assertIn("dust += 1", source)

    # ---- スケッチ 1 本

    def test_スケッチは_main_と差し込み口を持ち_窓の大きさと題を宣言する(self):
        entries, _ = self.作る()
        source = next(entry for entry in entries if entry.heading == "triangle(_:_:_:_:)").source
        lines = source.split("\n")
        self.assertIn("@main", lines)
        self.assertEqual(lines[lines.index("@main") + 1], "final class {{TYPE}}: Sketch {")
        self.assertIn('    var settings = SketchSettings(width: 400, height: 300, title: "{{NAME}}")', lines)
        self.assertEqual(lines[1], "import mokume")
        self.assertTrue(source.endswith("}\n"))

    def test_差し込みの鍵と紛れる波括弧を持つ例は外す(self):
        self.置く(
            "Sources/MokumeCore/Sketch/Sketch+Braces.swift",
            """\
            public extension Sketch {
                /// 波括弧を重ねる。
                ///
                /// ```swift
                /// let table = [[1], [2]].map {{ $0 }}
                /// ```
                func braces() {}
            }
            """,
        )
        entries, left = self.作る()
        self.assertNotIn("braces()", {entry.heading for entry in entries})
        self.assertTrue(any("`{{`" in item.reason for item in left))

    # ---- 書く

    def test_束は索引とスケッチ_README_は残し_前の束は消す(self):
        entries, _ = self.作る()
        out = self.root / "out"
        out.mkdir()
        (out / "README.md").write_text("placeholder", encoding="utf-8")
        (out / "9999.swift.template").write_text("old", encoding="utf-8")
        (out / "stale-dir").mkdir()
        bundle.write(entries, out)

        self.assertEqual((out / "README.md").read_text(encoding="utf-8"), "placeholder")
        self.assertFalse((out / "9999.swift.template").exists(), "前の束が残っている")
        self.assertFalse((out / "stale-dir").exists())
        rows = [line.split("\t") for line in (out / "index.tsv").read_text(encoding="utf-8").splitlines()]
        self.assertEqual(len(rows), len(entries))
        for spelling, file, summary in rows:
            self.assertTrue(summary, f"{spelling} の説明が空")
            self.assertTrue((out / file).is_file(), f"{file} が無い")
            self.assertTrue(file.endswith(".swift.template"))
        # 並びは綴りの辞書順 (大小を区別しない)
        spellings = [row[0] for row in rows]
        self.assertEqual(spellings, sorted(spellings, key=str.lower))

    def test_索引は_tab_か改行を含む綴りと説明を断る(self):
        entry = bundle.Entry("a()", Path("Sources/A.swift"), 1, "説明\tに tab", "src", "a()")
        with self.assertRaises(SystemExit):
            bundle.index_text([entry])

    def test_1本も同梱できなければ落ちる(self):
        """読み方が壊れても緑で通る空回りを許さない。"""
        original = bundle.build
        bundle.build = lambda root: ([], [])
        argv = sys.argv
        sys.argv = ["bundle-examples.py", "--list"]
        try:
            with self.assertRaises(SystemExit) as stopped:
                bundle.main()
        finally:
            bundle.build = original
            sys.argv = argv
        self.assertIn("1 本も", str(stopped.exception))


class 本物の木(unittest.TestCase):
    """このリポジトリの説明文に対して。**作例が一覧から欠けると赤**。"""

    @classmethod
    def setUpClass(cls):
        cls.entries, cls.left = bundle.build(REPO)

    def test_完了条件の例_triangle_が1本に決まる(self):
        short = [e.spelling for e in self.entries if e.heading.split("(")[0] == "triangle"]
        self.assertEqual(short, ["triangle(_:_:_:_:_:_:)"])

    def test_複数ある口は番号つきで別々に並ぶ(self):
        spellings = {e.spelling for e in self.entries}
        for heading, count in (("circle(_:_:_:)", 2), ("rect(_:_:_:_:)", 2), ("arc(_:_:_:_:_:_:)", 4)):
            self.assertEqual(
                {s for s in spellings if s.startswith(heading + "#")},
                {f"{heading}#{n}" for n in range(1, count + 1)},
                heading,
            )

    def test_資材を読む例は1本も入らない(self):
        for entry in self.entries:
            self.assertNotRegex(entry.source, r'"(?:assets|data)/', entry.spelling)

    def test_全部の例が_main_と差し込み口を持つ(self):
        for entry in self.entries:
            lines = entry.source.split("\n")
            self.assertIn("@main", lines, entry.spelling)
            self.assertIn("final class {{TYPE}}: Sketch {", lines, entry.spelling)


if __name__ == "__main__":
    unittest.main()
