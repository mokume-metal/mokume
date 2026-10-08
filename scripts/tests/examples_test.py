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
# 綴りを共有しているかを見るために、撮る側も読む (#815)
shots = _load("example_shots", REPO / "scripts" / "example-shots.py")

# 落とす例には目印を置き、差し替えた swiftc がそれを見て error を吐く。
# 本物の型検査は make examples が受け持つ (こちらは仕組みの側だけを見る)
STUB = """\
#!/usr/bin/env python3
import pathlib, sys
# 渡された引数を残す。**旗が本当に型検査まで届いたか**は、ここを読まないと分からない
pathlib.Path(__file__).with_name("args.txt").write_text("\\n".join(sys.argv))
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

    def test_外へ出した_import_を撮る側と組める側が同じに先頭へ置く(self):
        """#2216。`import Foundation` を書いた例が make examples を通るのに、撮る側だけが
        その行を落として組めなかった — #667 と同じ形の食い違いが `import` で残っていた。
        **同じ例から、両者が同じ並びをファイルの先頭に置く**ことを見る。"""
        body = ["import Foundation", "", 'let u = URL(fileURLWithPath: "/tmp/x")', "circle(1, 2, 3)"]
        checked, _, _ = examples.build_source(
            [examples.Example(path=Path("Sources/A.swift"), line=1, body=body, context=[], skip=None)]
        )
        with tempfile.TemporaryDirectory() as tmp:
            snippet = Path(tmp) / "repro.swift"
            snippet.write_text("\n".join(body) + "\n", encoding="utf-8")
            package = Path(tmp) / "generated"
            shots.generate(Path(tmp), [shots.snippet_shot(snippet, 400, 300, 0, "a")], package)
            shot = (package / "Sources" / "example-shots" / "Shots.swift").read_text(encoding="utf-8")
        # 包んだ行は字下げされるので、行頭の `import` はファイルの先頭に置かれたものだけ
        heads = [
            [line for line in text.split("\n") if line.startswith("import ")] for text in (checked, shot)
        ]
        self.assertEqual(heads[0], ["import mokume", "import Foundation"])
        self.assertEqual(heads[1], heads[0], "撮る側と組める側で、先頭の import が食い違う")

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


# macro の plugin の解決と swiftc の呼び方の検査は
# scripts/tests/swift_typecheck_test.py へ移した (#820)。**呼び方は
# check-param-declarations.sh とも共有している**ので、片方のテストに置くと
# もう片方から見て他人の検査になる

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

    def test_macro_の_plugin_が型検査まで届く(self):
        """`plugin_flags` が正しくても、渡し忘れれば macro を使う例は落ちる。"""
        tool = self.root / ".build/debug/MokumeMacros-tool"
        tool.write_text("")
        tool.chmod(0o755)
        self.置く("Sources/A.swift", "/// ```swift\n/// circle(1, 2, 3)\n/// ```\n")
        self.打つ()
        passed = (self.root / "bin/args.txt").read_text()
        self.assertIn("-load-plugin-executable", passed)
        self.assertIn(f"{tool}#MokumeMacros", passed)

    def test_無視されていない未追跡のファイルも見る(self):
        """`git add` の前に打っても、add の後 (= CI が見る木) と同じ結果になる (#1998)。

        SwiftPM は `Sources/` の未追跡の `.swift` もそのまま組むので、見る範囲を
        ビルドに揃える。ここを追跡済みだけにすると、組めない例が手元では緑で
        push して初めて CI で赤になる。"""
        self.置く("Sources/A.swift", "public func a() {}\n")
        (self.root / "Sources/Untracked.swift").write_text("/// ```swift\n/// BROKEN()\n/// ```\n")
        before = self.打つ()
        self.assertEqual(before.returncode, 1, before.stdout)
        self.assertIn("ng Sources/Untracked.swift:1", before.stdout)
        # add の前後で同じ行が赤になる
        subprocess.run(["git", "-C", str(self.root), "add", "Sources/Untracked.swift"], check=True)
        after = self.打つ()
        self.assertEqual(after.returncode, 1, after.stdout)
        self.assertIn("ng Sources/Untracked.swift:1", after.stdout)

    def test_無視されたファイルは見ない(self):
        """生成物や手元の書き捨ては、他人の手元で結果が変わるので見ない (#566)。"""
        (self.root / ".gitignore").write_text("Sources/Scratch.swift\n")
        (self.root / "Sources/Scratch.swift").write_text("/// ```swift\n/// BROKEN()\n/// ```\n")
        self.置く("Sources/A.swift", "public func a() {}\n")
        result = self.打つ()
        self.assertEqual(result.returncode, 0, result.stdout)

    # 以下は「列挙に挙がったが、読めない・割れる」形。列挙を広げた (#1998) ので、
    # index にだけ残るパスと、名前の綴りの癖が、読む段で落ちる側に回る

    BROKEN_EXAMPLE = "/// ```swift\n/// BROKEN()\n/// ```\n"

    def test_消した追跡済みのパスで落ちず_残りは見る(self):
        """`git rm` していない削除は index に旧パスが残る。読もうとして落ちない。"""
        self.置く("Sources/Gone.swift", self.BROKEN_EXAMPLE)
        self.置く("Sources/A.swift", self.BROKEN_EXAMPLE)
        (self.root / "Sources/Gone.swift").unlink()
        result = self.打つ()
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("ng Sources/A.swift:1", result.stdout)
        self.assertNotIn("Gone.swift", result.stdout)

    def test_改名した追跡済みのパスは新しい名前だけを見る(self):
        self.置く("Sources/Old.swift", self.BROKEN_EXAMPLE)
        (self.root / "Sources/Old.swift").rename(self.root / "Sources/New.swift")
        result = self.打つ()
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("ng Sources/New.swift:1", result.stdout)
        self.assertNotIn("Old.swift", result.stdout)

    def test_壊れた_symlink_で落ちず_残りは見る(self):
        """エディタの退避リンク (`.#Foo.swift`) は、先が無いまま未追跡で残る。"""
        (self.root / "Sources/.#Foo.swift").symlink_to("nowhere.swift")
        self.置く("Sources/A.swift", self.BROKEN_EXAMPLE)
        result = self.打つ()
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("ng Sources/A.swift:1", result.stdout)

    def test_空白を含む名前のファイルも見る(self):
        self.置く("Sources/With Space.swift", self.BROKEN_EXAMPLE)
        result = self.打つ()
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("ng Sources/With Space.swift:1", result.stdout)

    def test_非_ASCII_の名前のファイルも見る(self):
        """`core.quotePath` の既定では、非 ASCII の名前は C 引用符つきで返る。
        その形のまま `.swift` かを見ると、黙って検査の外へ落ちる (緑のまま)。"""
        subprocess.run(
            ["git", "-C", str(self.root), "config", "core.quotePath", "true"], check=True
        )
        self.置く("Sources/日本語.swift", self.BROKEN_EXAMPLE)
        result = self.打つ()
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("ng Sources/日本語.swift:1", result.stdout)


class 綴りの共有(unittest.TestCase):
    """**組めることを見る側と撮る側が、同じ印を読むこと** (#667・#815)。

    #667 は「片方だけが `文脈` を読んだ」事故である。あのとき撮る側のコメントには
    「あちらが読むものをこちらも読む」と書かれていたが、**綴りは写しだった** —
    書いてあることと実物が食い違っていても、誰も赤くならなかった。

    ここで固定するのは「同じ物を読んでいる」という**同一性**だけで、印の意味は
    上の 集める が見る。同一性は `is` で見る (等しい正規表現ではなく、同じ物)。
    """

    def test_印は_1_本しかない(self):
        self.assertIs(examples.MARK, wrapping.MARK, "組めることを見る側が自前の印を持っている")
        self.assertIs(shots.MARK, wrapping.MARK, "撮る側が自前の印を持っている")

    def test_囲みは_2_綴りだけで_どちらも共有の置き場から来る(self):
        # `.md` も読む側は `///` を任意にし、説明文だけを読む側は必須にする。
        # **どちらも example_wrapping の中の綴りである**ことを見る
        self.assertIs(examples.FENCE_OPEN, wrapping.FENCE_OPEN)
        self.assertIs(examples.FENCE_CLOSE, wrapping.FENCE_CLOSE)
        self.assertIs(shots.FENCE_OPEN, wrapping.DOC_FENCE_OPEN)
        self.assertIs(shots.FENCE_CLOSE, wrapping.DOC_FENCE_CLOSE)

    def test_2_綴りの違いは_説明文の外を読むかだけ(self):
        """畳めない理由が本物であること。緩い側だけが素の Markdown を読む。"""
        fence = "`" * 3 + "swift"
        self.assertTrue(wrapping.FENCE_OPEN.match(fence))
        self.assertFalse(wrapping.DOC_FENCE_OPEN.match(fence), "説明文の外まで拾っている")
        self.assertTrue(wrapping.DOC_FENCE_OPEN.match(f"/// {fence}"))

    def test_文脈の印を両者が同じに読む(self):
        """同じ 1 行から、両者が同じ `文脈` の宣言を取り出す。"""
        line = "/// <!-- example: 文脈 let radius = 3.0 -->"
        for name, module in (("組めることを見る側", examples), ("撮る側", shots)):
            with self.subTest(reader=name):
                match = module.MARK.match(line)
                self.assertIsNotNone(match, f"{name} が印を読めていない")
                self.assertEqual(match["kind"], "文脈")
                self.assertEqual(match["rest"], "let radius = 3.0")

    def test_撮る側は組めない印を宣言として積まない(self):
        """印が 1 本になっても、`組めない` を `文脈` の代わりに積んではいけない。"""
        lines = [
            "/// <!-- example: 組めない 投げる呼び出し -->",
            "/// ```swift",
            "/// try thing()",
            "/// ```",
            "/// <!-- shot: 絵 -->",
        ]
        self.assertEqual(shots.context_above(lines, len(lines) - 1), [])


if __name__ == "__main__":
    unittest.main()
