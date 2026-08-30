#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-examples.py と scripts/example_wrapping.py の検査 (#479)。

固定するのは 3 つで、どれも破れ方が緑である。

- **段の見分けと `import` の追い出し** — ここを外すと、例そのものは正しいのに
  包み方の都合で落ちる。読む人は例を疑い、直しようのない赤を追うことになる
- **印は例外の側にしか付かない** — 印を忘れた例が黙って検査の外へ出ると、
  「見ていない」ことは誰にも見えない。理由の無い印も同じなので赤にする
- **落ちた行が元のファイルへ戻る** — 組み立てたファイルの行番号のまま出すと、
  どの説明文が壊れているのか誰にも分からない

実行は make hooks-test (CI もこれを呼ぶ)。**swiftc は差し替える**ので、ビルド済みの
成果物もツールチェーンも要らない。
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-examples.py"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


wrapping = _load("example_wrapping", REPO / "scripts" / "example_wrapping.py")
examples = _load("check_examples", SCRIPT)

# 落とす例には目印を置き、差し替えた swiftc がそれを見て error を吐く。
# 本物の型検査は make examples が受け持つ (こちらは仕組みの側だけを見る)
STUB = """\
#!/usr/bin/env python3
import pathlib, sys
source = pathlib.Path(sys.argv[-1])
bad = [
    number
    for number, line in enumerate(source.read_text().splitlines(), start=1)
    if "BROKEN" in line
]
for number in bad:
    print(f"{source}:{number}:5: error: cannot find 'BROKEN' in scope", file=sys.stderr)
sys.exit(1 if bad else 0)
"""


class 包み(unittest.TestCase):
    def test_型の宣言は名前空間に畳む(self):
        snippet = ["final class MySketch: Sketch {", "    func draw() {}", "}"]
        self.assertEqual(wrapping.level_of(snippet), wrapping.LEVEL_TYPE)
        self.assertEqual(wrapping.wrap("Ex", snippet)[0], "enum Ex {")

    def test_メンバの宣言はスケッチの中に置く(self):
        snippet = ["func setup() {", "    dust = nil", "}"]
        self.assertEqual(wrapping.level_of(snippet), wrapping.LEVEL_MEMBER)
        self.assertEqual(wrapping.wrap("Ex", snippet)[0], "final class Ex: Sketch {")
        self.assertNotIn("    func draw() {", wrapping.wrap("Ex", snippet))

    def test_それ以外は_draw_の本体として置く(self):
        snippet = ["circle(10, 10, 5)"]
        self.assertEqual(wrapping.level_of(snippet), wrapping.LEVEL_BODY)
        self.assertIn("    func draw() {", wrapping.wrap("Ex", snippet))

    def test_頭の注釈で段が変わらない(self):
        """`// waves.metal` のような前置きが型の宣言を隠さないこと。"""
        snippet = ["// waves.metal", "final class A: Sketch {", "}"]
        self.assertEqual(wrapping.level_of(snippet), wrapping.LEVEL_TYPE)

    def test_import_は外へ出す(self):
        """型の中へは入れられない。残すと `only valid at file scope` で落ち、
        **例そのものの誤りがその赤に埋もれる**。"""
        snippet = ["import mokume", "", "final class A: Sketch {", "}"]
        found, rest = wrapping.split_imports(snippet)
        self.assertEqual(found, ["import mokume"])
        self.assertNotIn("import mokume", wrapping.wrap("Ex", snippet))
        self.assertEqual(wrapping.level_of(snippet), wrapping.LEVEL_TYPE)

    def test_文脈は段に合わせた高さへ置く(self):
        body = wrapping.wrap("Ex", ["circle(1, 2, 3)"], context=["var dust: Particles!"])
        self.assertIn("    var dust: Particles!", body)
        self.assertLess(body.index("    var dust: Particles!"), body.index("    func draw() {"))


class 集める(unittest.TestCase):
    def 拾う(self, text: str):
        return examples.examples_in(textwrap.dedent(text), Path("Sources/A.swift"))

    def test_説明文の中の囲みを拾う(self):
        found, problems = self.拾う(
            """\
            /// ```swift
            /// circle(1, 2, 3)
            /// ```
            public func circle() {}
            """
        )
        self.assertEqual(problems, [])
        self.assertEqual([e.body for e in found], [["circle(1, 2, 3)"]])
        self.assertEqual(found[0].line, 1)

    def test_字下げを保つ(self):
        found, _ = self.拾う(
            """\
            /// ```swift
            /// func draw() {
            ///     circle(1, 2, 3)
            /// }
            /// ```
            """
        )
        self.assertEqual(found[0].body, ["func draw() {", "    circle(1, 2, 3)", "}"])

    def test_文脈の印が例に付く(self):
        found, problems = self.拾う(
            """\
            /// <!-- example: 文脈 var dust: Particles! -->
            /// <!-- example: 文脈 var heat: Numbers! -->
            /// ```swift
            /// particles(dust)
            /// ```
            """
        )
        self.assertEqual(problems, [])
        self.assertEqual(found[0].context, ["var dust: Particles!", "var heat: Numbers!"])
        self.assertIsNone(found[0].skip)

    def test_組めないの印が理由ごと付く(self):
        found, problems = self.拾う(
            """\
            /// <!-- example: 組めない 外のパッケージが持つ -->
            /// ```swift
            /// VideoSender()
            /// ```
            """
        )
        self.assertEqual(problems, [])
        self.assertEqual(found[0].skip, "外のパッケージが持つ")

    def test_理由の無い組めないは赤(self):
        """見ていないことを黙って増やせる印は、あってはならない。"""
        _, problems = self.拾う(
            """\
            /// <!-- example: 組めない -->
            /// ```swift
            /// VideoSender()
            /// ```
            """
        )
        self.assertEqual(len(problems), 1)
        self.assertIn("理由", problems[0])

    def test_宣言の無い文脈は赤(self):
        _, problems = self.拾う(
            """\
            /// <!-- example: 文脈 -->
            /// ```swift
            /// circle(1, 2, 3)
            /// ```
            """
        )
        self.assertEqual(len(problems), 1)
        self.assertIn("宣言", problems[0])

    def test_綴りを外した印は赤(self):
        """黙って素通しにすると「書いたのに効かない」になる。"""
        _, problems = self.拾う(
            """\
            /// <!-- example: 見ない 理由 -->
            /// ```swift
            /// circle(1, 2, 3)
            /// ```
            """
        )
        self.assertEqual(len(problems), 1)
        self.assertIn("綴り", problems[0])

    def test_行き先の無い印は赤(self):
        _, problems = self.拾う(
            """\
            /// <!-- example: 文脈 var dust: Particles! -->
            /// ふつうの説明の行
            /// ```swift
            /// circle(1, 2, 3)
            /// ```
            """
        )
        self.assertEqual(len(problems), 1)
        self.assertIn("行き先", problems[0])

    def test_カタログの素の囲みも拾う(self):
        found, _ = examples.examples_in(
            "```swift\nimport mokume\n\nfinal class A: Sketch {}\n```\n",
            Path("Documentation/mokume.docc/MokumeCore.md"),
        )
        self.assertEqual(found[0].body, ["import mokume", "", "final class A: Sketch {}"])


class 通しで(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        # 使い捨てのリポジトリは手元の署名設定を継ぐ (#344)。ここは commit しないが、
        # 条件はファイル側に持たせる決まりなので揃えておく
        subprocess.run(
            ["git", "-C", str(self.root), "config", "commit.gpgsign", "false"], check=True
        )
        (self.root / "Sources").mkdir()
        (self.root / ".build/debug/Modules").mkdir(parents=True)
        (self.root / ".build/debug/Modules/mokume.swiftmodule").write_text("")
        bin_directory = self.root / "bin"
        bin_directory.mkdir()
        stub = bin_directory / "swiftc"
        stub.write_text(STUB)
        stub.chmod(0o755)
        self.environment = dict(os.environ, PATH=f"{bin_directory}:{os.environ['PATH']}")

    def tearDown(self):
        self.temporary.cleanup()

    def 置く(self, name: str, text: str):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(text))
        subprocess.run(["git", "-C", str(self.root), "add", name], check=True)

    def 打つ(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT)],
            cwd=self.root,
            env=self.environment,
            capture_output=True,
            text=True,
        )

    def test_落ちた行が元のファイルへ戻る(self):
        self.置く(
            "Sources/A.swift",
            """\
            /// ```swift
            /// circle(1, 2, 3)
            /// ```
            public func a() {}

            /// ```swift
            /// BROKEN()
            /// ```
            public func b() {}
            """,
        )
        result = self.打つ()
        self.assertEqual(result.returncode, 1, result.stdout)
        # 6 行目が 2 つ目の囲み。組み立てたファイルの行番号ではなく、こちらが出る
        self.assertIn("ng Sources/A.swift:6", result.stdout)
        self.assertNotIn("Sources/A.swift:1", result.stdout)

    def test_文脈を付ければ通る(self):
        self.置く(
            "Sources/A.swift",
            """\
            /// <!-- example: 文脈 let BROKEN = 1 -->
            /// ```swift
            /// print(1)
            /// ```
            public func a() {}
            """,
        )
        # 文脈は包みの中へ入るので、目印は組み立てた本文に現れる = 差し替えた
        # swiftc が拾う。**印が効いていることを、効いた結果で見る**
        self.assertEqual(self.打つ().returncode, 1)
        self.置く(
            "Sources/A.swift",
            """\
            /// ```swift
            /// print(1)
            /// ```
            public func a() {}
            """,
        )
        result = self.打つ()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("ok:", result.stdout)

    def test_組めないは組み立てから外れる(self):
        self.置く(
            "Sources/A.swift",
            """\
            /// <!-- example: 組めない 外のパッケージが持つ -->
            /// ```swift
            /// BROKEN()
            /// ```
            public func a() {}
            """,
        )
        result = self.打つ()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("組めないと宣言 1", result.stdout)
        self.assertIn("外のパッケージが持つ", result.stdout)

    def test_見ていない範囲を毎回名乗る(self):
        self.置く("Sources/A.swift", "public func a() {}\n")
        result = self.打つ()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("見ていない範囲:", result.stdout)

    def test_成果物が無ければ理由を言って止まる(self):
        self.置く("Sources/A.swift", "public func a() {}\n")
        (self.root / ".build/debug/Modules/mokume.swiftmodule").unlink()
        result = self.打つ()
        self.assertEqual(result.returncode, 1)
        self.assertIn("swift build", result.stdout)

    def test_追跡されていないファイルは見ない(self):
        """他人の手元で結果が変わらないように、git が挙げたものだけを見る。"""
        (self.root / "Sources/Untracked.swift").write_text("/// ```swift\n/// BROKEN()\n/// ```\n")
        self.置く("Sources/A.swift", "public func a() {}\n")
        self.assertEqual(self.打つ().returncode, 0)


if __name__ == "__main__":
    unittest.main()
