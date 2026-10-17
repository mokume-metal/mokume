#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-runtime-math.py の検査 (#2751)。

守るのは「本体の超越関数の直の呼び出しを 1 つも見逃さない」と「呼び出しではないものを
赤くしない」の両方で、どちらも**呼び出しだけを正しく取れるか**に懸かっている。
読み違えると 2 通りに壊れる:

- コードを文字列やコメントと読む、メンバの呼び出しと取り違える — 見逃す側なので、
  塞ごうとしている再発 (#1736) がそのまま通る。**文字列補間の中はコード**である
- コメント・文字列・`RuntimeMath.sin`・メンバ・宣言を呼び出しと読む — 赤くなるので
  目には見えるが、正しいコードが止まる

形ごとに 1 件ずつ置く。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-runtime-math.py"

CANON = "MokumeCore/Math/RuntimeMath.swift"
CANON_TEXT = (
    "package nonisolated enum RuntimeMath {\n"
    "    @inline(never) package static func sin(_ x: Float) -> Float { Foundation.sin(x) }\n"
    "    @inline(never) package static func pow(_ x: Double, _ y: Double) -> Double { Foundation.pow(x, y) }\n"
    "    @inline(never) package static func atan2(_ y: Double, _ x: Double) -> Double { Foundation.atan2(y, x) }\n"
    "}\n")


class RuntimeMathTest(unittest.TestCase):
    def check(self, files, canon=CANON_TEXT):
        """Sources に見立てた一時ディレクトリへ正本とファイルを置いて検査を打つ。"""
        with tempfile.TemporaryDirectory() as root:
            tree = dict(files)
            if canon is not None:
                tree[CANON] = canon
            for name, text in tree.items():
                path = Path(root) / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
            result = subprocess.run(
                ["python3", str(SCRIPT), root], capture_output=True, text=True)
        return result.returncode, result.stdout + result.stderr

    def assertGreen(self, text, path="MokumeCore/Drawing/Shape.swift"):
        code, output = self.check({path: text})
        self.assertEqual(code, 0, output)

    def assertRedAt(self, text, line, path="MokumeCore/Drawing/Shape.swift"):
        code, output = self.check({path: text})
        self.assertEqual(code, 1, output)
        self.assertIn(f"{Path(path).name}:{line}:", output)
        return output

    # ------------------------------------------------------------ 直の呼び出しは赤

    def test_a_bare_call_is_red_with_the_replacement_and_the_reason(self):
        output = self.assertRedAt("let a = 1\nlet s = sin(angle)\n", 2)
        self.assertIn("`RuntimeMath.sin` を使う (#1736・ADR-0025 決定 7)", output)

    def test_every_wrapped_name_is_read_from_the_canon(self):
        for name in ("sin", "pow", "atan2"):
            with self.subTest(name=name):
                self.assertRedAt(f"let v = {name}(x, y)\n", 1)

    def test_a_name_the_canon_does_not_wrap_is_not_counted(self):
        """名前の一覧は RuntimeMath.swift が正本。包んでいない関数は数えない。"""
        self.assertGreen("let v = cos(x) + sqrt(y) + log2(z)\n")

    def test_a_new_wrapped_name_is_followed_without_editing_the_check(self):
        canon = CANON_TEXT.replace("}\n", "    package static func cos(_ x: Float) -> Float { Foundation.cos(x) }\n}\n")
        code, output = self.check({"MokumeCore/A.swift": "let v = cos(x)\n"}, canon=canon)
        self.assertEqual(code, 1, output)

    def test_a_call_with_a_space_before_the_parenthesis_is_red(self):
        self.assertRedAt("let s = sin (angle)\n", 1)

    def test_a_qualified_call_is_red(self):
        for qualifier in ("Foundation", "Darwin", "Glibc"):
            with self.subTest(qualifier=qualifier):
                self.assertRedAt(f"let s = {qualifier}.sin(angle)\n", 1)

    def test_a_call_inside_an_expression_and_an_argument_is_red(self):
        self.assertRedAt("let v = max(0, 1 - pow(x, 2))\n", 1)

    def test_the_line_number_follows_a_multiline_string_before_it(self):
        self.assertRedAt('let a = """\nline\nline\n"""\nlet s = sin(x)\n', 5)

    def test_a_call_in_string_interpolation_is_code(self):
        self.assertRedAt('let label = "angle: \\(sin(x))"\n', 1)

    def test_a_call_after_a_comment_on_the_same_line_is_red(self):
        self.assertRedAt("let s = /* 角度 */ sin(angle)\n", 1)

    def test_the_audio_target_is_checked_too(self):
        self.assertRedAt("let g = pow(10, db / 20)\n", 1, path="MokumeAudio/Level.swift")

    def test_every_hit_is_listed_with_its_count(self):
        _, output = self.check({"MokumeCore/A.swift": "let a = sin(x)\nlet b = pow(x, 2)\n"})
        self.assertIn("2 箇所", output)

    # ------------------------------------------------------------ 呼び出しではないものは緑

    def test_runtime_math_calls_are_the_goal(self):
        self.assertGreen("let s = RuntimeMath.sin(angle)\n")

    def test_member_calls_and_pi_are_not_counted(self):
        self.assertGreen("let r = x.squareRoot()\nlet h = Float.pi / 2\nlet a = angle.sin(0)\nlet p = v.pow(2)\n")

    def test_a_longer_name_is_not_a_call_of_a_shorter_one(self):
        self.assertGreen("let a = mysin(x)\nlet b = sin2(x)\nlet c = pow_(x)\n")

    def test_a_label_or_a_value_named_like_a_function_is_not_a_call(self):
        self.assertGreen("let a = f(sin: 1, pow: 2)\nlet sin = 3\nlet p = pow\n")

    def test_a_declaration_is_not_a_call(self):
        self.assertGreen("func sin(_ x: Float) -> Float { 0 }\nstatic func pow(_ x: Float) {}\n")

    def test_line_doc_and_block_comments_are_not_counted(self):
        self.assertGreen(
            "// let s = sin(x)\n"
            "/// 視野角は tan(fov/2) で求める\n"
            "/* pow(x, 2) /* atan2(y, x) */ sin(x) */\n"
            "let a = 1  // 行末の sin(x)\n")

    def test_a_string_is_not_counted(self):
        self.assertGreen(
            'let a = "pow(x, 2)"\n'
            'let b = "escaped \\" sin(x)"\n'
            'let c = #"raw sin(x) \\(sin(x))"#\n')

    def test_a_multiline_string_is_not_counted(self):
        self.assertGreen('let doc = """\n    sin(angle)\n    cos(angle) pow(x, 2)\n    """\n')

    def test_a_comment_marker_inside_a_string_does_not_hide_the_code_after_it(self):
        """文字列の中の `//` をコメントと読むと、後ろの本物の呼び出しを見逃す。"""
        self.assertRedAt('let url = "http://x"; let s = sin(x)\n', 1)

    # ------------------------------------------------------------ 範囲の外

    def test_other_targets_are_out_of_scope(self):
        code, output = self.check({
            "MokumeCore/Ok.swift": "let a = 1\n",
            "MokumeCamera/Frame.swift": "let s = sin(angle)\n",
            "MokumeCLI/Tool.swift": "let s = pow(x, 2)\n",
        })
        self.assertEqual(code, 0, output)

    def test_metal_sources_are_out_of_scope(self):
        code, output = self.check({
            "MokumeCore/Ok.swift": "let a = 1\n",
            "MokumeCore/Shaders/Fill.metal": "float s = sin(angle);\n",
        })
        self.assertEqual(code, 0, output)

    def test_the_canon_itself_is_excluded(self):
        code, output = self.check({"MokumeCore/Ok.swift": "let a = 1\n"})
        self.assertEqual(code, 0, output)
        self.assertIn("3 個の関数", output)

    # ------------------------------------------------------------ 見るものが無ければ赤

    def test_a_missing_canon_is_red(self):
        code, output = self.check({"MokumeCore/A.swift": "let a = 1\n"}, canon=None)
        self.assertEqual(code, 1, output)
        self.assertIn("正本を読めない", output)

    def test_a_canon_without_wrapped_functions_is_red(self):
        code, output = self.check(
            {"MokumeCore/A.swift": "let a = 1\n"},
            canon="// static func sin(_ x: Float) -> Float\nenum RuntimeMath {}\n")
        self.assertEqual(code, 1, output)
        self.assertIn("1 つも読めなかった", output)

    def test_a_tree_without_the_targets_is_red(self):
        code, output = self.check({"MokumeCamera/A.swift": "let a = 1\n"})
        self.assertEqual(code, 1, output)

    def test_the_real_tree_passes_the_check(self):
        """今の main に直の呼び出しは残っていない (#2751)。"""
        result = subprocess.run(
            ["python3", str(SCRIPT), str(REPO / "Sources")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
