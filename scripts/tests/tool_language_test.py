#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-tool-language.py の検査 (#1160)。

守るのは「コメントの外の日本語を 1 つも見逃さない」と「コメントの中を赤くしない」の
両方で、どちらも**字句の境界を正しく読めるか**に懸かっている。形ごとに 1 件ずつ置く:

- **`\"\"\"` の本文を数える** — 行単位の grep はここを取り逃し、18 通が `main` に残った (#1156)
- **文字列の中の `//` はコメントではない** — 読み違えると後ろの文字列を見逃す
- **エスケープした引用符・raw 文字列の `#`・補間の中の文字列・入れ子の `/* */`** — どれも
  読み違えると境界がずれ、後ろのコメントを赤くするか、後ろの文字列を見逃す
- **対象が 0 件なら赤い** — 見るものが無いまま緑にしない

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-tool-language.py"


class ToolLanguageTest(unittest.TestCase):
    def check(self, files):
        """ファイル名 → 中身を一時ディレクトリへ置いて検査を打つ。"""
        with tempfile.TemporaryDirectory() as root:
            for name, text in files.items():
                path = Path(root) / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
            result = subprocess.run(
                ["python3", str(SCRIPT), root], capture_output=True, text=True)
        return result.returncode, result.stdout + result.stderr

    def assertGreen(self, text):
        code, output = self.check({"Sketch.swift": text})
        self.assertEqual(code, 0, output)

    def assertRedAt(self, text, line):
        code, output = self.check({"Sketch.swift": text})
        self.assertEqual(code, 1, output)
        self.assertIn(f"Sketch.swift:{line}:", output)

    # ------------------------------------------------------------ コメントは読み物

    def test_line_and_doc_comments_are_allowed(self):
        self.assertGreen("// 日本語のコメント\n/// 説明文\nlet a = 1  // 行末の注\n")

    def test_nested_block_comment_is_allowed_to_its_end(self):
        self.assertGreen("/* 外側 /* 内側 */ まだ外側のコメント */ let a = 1\n")

    # ------------------------------------------------------------ 文字列は道具が話す言葉

    def test_single_line_string_is_named_with_its_line(self):
        self.assertRedAt('let a = 1\nlet b = "見つかりません"\n', 2)

    def test_multiline_string_body_is_counted(self):
        text = 'let a = """\n    Cannot find it.\n    探した場所:\n    """\n'
        self.assertRedAt(text, 3)

    def test_raw_string_is_counted(self):
        self.assertRedAt('let a = #"{"message":"読めない"}"#\n', 1)

    def test_raw_multiline_string_is_counted(self):
        self.assertRedAt('let a = #"""\n    "quoted" and 日本語\n    """#\n', 2)

    def test_string_inside_interpolation_is_counted(self):
        self.assertRedAt('let a = "\\(flag ? "在る" : "")"\n', 1)

    def test_identifier_outside_comments_is_counted(self):
        self.assertRedAt("let 名前 = 1\n", 1)

    # ------------------------------------------------------------ 境界を読み違えない

    def test_double_slash_inside_string_does_not_hide_the_rest(self):
        # 読み違えると `//` から行末までを塗り、その後ろの日本語を見逃す
        self.assertRedAt('let a = "see http://example.com の案内"\n', 1)

    def test_double_slash_in_a_string_inside_interpolation_does_not_hide_the_rest(self):
        # 補間を読まないと、中の文字列をコードと読んで `//` をコメントにしてしまう
        self.assertRedAt('let a = "\\(flag ? "http://x" : "") の案内"\n', 1)

    def test_escaped_quote_does_not_close_the_string(self):
        self.assertGreen('let quote = "\\""  // 日本語の注\n')

    def test_raw_string_closes_only_with_its_hashes(self):
        self.assertGreen('let a = #"a"b"#  // 日本語の注\n')

    def test_parentheses_inside_interpolation_are_counted(self):
        # 括弧を数えないと `f(x)` の閉じで補間を抜け、`"//"` をコードと読んでコメントにする
        self.assertRedAt('let a = "\\(f(x) + "//") の案内"\n', 1)

    def test_interpolation_with_strings_returns_to_the_outer_string(self):
        self.assertGreen('let a = "\\(flag ? "x" : "(y")"  // 日本語の注\n')

    def test_multiline_string_closes_before_a_trailing_comment(self):
        self.assertGreen('let a = """\n    english\n    """  // 日本語の注\n')

    # ------------------------------------------------------------ 対象

    def test_frame_rate_probe_is_excluded(self):
        code, output = self.check({
            "frame-rate-probe/main.swift": 'print("計測")\n',
            "mokume/Sketch.swift": 'let a = "english"\n',
        })
        self.assertEqual(code, 0, output)

    def test_no_swift_file_is_red(self):
        code, output = self.check({"README.md": "日本語\n"})
        self.assertEqual(code, 1, output)
        self.assertIn("Swift のファイルが 1 つも無い", output)


if __name__ == "__main__":
    unittest.main()
