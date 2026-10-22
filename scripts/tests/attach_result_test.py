#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-attach-result.py の検査 (#2794)。

守るのは「作る口が、道具を通さない素の `attach(x)` を書き足したら見逃さない」と「道具の形や、
ほかの型の同名の口を赤くしない」の両方で、どちらも**スケッチへ足す呼び出しだけを正しく取れるか**に
懸かっている。読み違えると 2 通りに壊れる:

- 素の呼び出しを、コメントや文字列、ほかの型の口と取り違える — 見逃す側なので、塞ごうとしている
  再発 (#2297・#2295 が #2740 の約束を写した形) がそのまま通る。**文字列補間の中はコード**である
- 道具の形 (`calledAs:`)・宣言・`engine.attach(node)` を素の呼び出しと読む — 赤くなるので目には見えるが、
  正しいコードが止まる

形ごとに 1 件ずつ置く。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-attach-result.py"

TOOLBOX = "MokumeCore/Sketch/Sketch+Seams.swift"
TOOLBOX_TEXT = (
    "extension SketchPart {\n"
    "    package func attached<F, P>(_ f: F.Type, calledAs call: String, making make: () -> P) throws(F) -> P {}\n"
    "}\n")
NET = "MokumeNetwork/Sketch+Net.swift"


class AttachResultTest(unittest.TestCase):
    def check(self, files, toolbox=TOOLBOX_TEXT):
        """Sources に見立てた一時ディレクトリへ道具の置き場とファイルを置いて検査を打つ。"""
        with tempfile.TemporaryDirectory() as root:
            tree = dict(files)
            if toolbox is not None:
                tree[TOOLBOX] = toolbox
            for name, text in tree.items():
                path = Path(root) / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
            result = subprocess.run(
                ["python3", str(SCRIPT), root], capture_output=True, text=True)
        return result.returncode, result.stdout + result.stderr

    def assertGreen(self, text, path=NET):
        code, output = self.check({path: text})
        self.assertEqual(code, 0, output)

    def assertRedAt(self, text, line, path=NET):
        code, output = self.check({path: text})
        self.assertEqual(code, 1, output)
        self.assertIn(f"{Path(path).name}:{line}:", output)
        return output

    # ------------------------------------------------------------ 素の呼び出しは赤

    def test_a_bare_attach_is_red_with_the_tools_and_the_reason(self):
        output = self.assertRedAt("let a = 1\nattach(server)\n", 2)
        self.assertIn("attached(_:calledAs:making:)", output)
        self.assertIn("attachedAfterSurface(_:)", output)
        self.assertIn("attach(_:calledAs:returning:)", output)
        self.assertIn("#2794", output)
        self.assertIn("Sketch+Seams.swift", output)

    def test_every_target_package_is_checked(self):
        for package in ("MokumeAudio", "MokumeCamera", "MokumeNetwork", "MokumeGamepad"):
            with self.subTest(package=package):
                self.assertRedAt("attach(x)\n", 1, path=f"{package}/Sketch+A.swift")

    def test_a_call_on_the_sketch_is_red(self):
        for receiver in ("self", "sketch", "owner", "self.sketch"):
            with self.subTest(receiver=receiver):
                self.assertRedAt(f"{receiver}.attach(pad)\n", 1)

    def test_a_call_with_spaces_and_a_line_break_is_red(self):
        self.assertRedAt("attach (\n    server\n)\n", 1)

    def test_a_call_in_an_expression_is_red(self):
        self.assertRedAt("if !attach(pad) { return }\n", 1)

    def test_the_line_number_follows_a_multiline_string_before_it(self):
        self.assertRedAt('let s = """\nattach(x)\n"""\nattach(y)\n', 4)

    def test_a_call_in_string_interpolation_is_code(self):
        self.assertRedAt('let s = "\\(attach(x))"\n', 1)

    def test_a_call_after_a_comment_on_the_same_line_is_red(self):
        self.assertRedAt("/* 足す */ attach(x)\n", 1)

    def test_every_hit_is_listed(self):
        code, output = self.check({NET: "attach(a)\nattach(b)\nattach(c)\n"})
        self.assertEqual(code, 1, output)
        self.assertIn("3 箇所", output)
        for line in (1, 2, 3):
            self.assertIn(f"Sketch+Net.swift:{line}:", output)

    # ------------------------------------------------------------ 道具の形・別物は緑

    def test_the_three_argument_tool_is_the_goal(self):
        self.assertGreen('attach(server, calledAs: #function, returning: "a port")\n')

    def test_the_tool_with_the_label_on_a_later_line_is_the_goal(self):
        self.assertGreen('attach(\n    server,\n    calledAs: #function,\n    returning: "a port")\n')

    def test_the_sketch_receiver_with_the_tool_is_the_goal(self):
        self.assertGreen('if sketch.attach(pad, calledAs: call, returning: "pads") { return }\n')

    def test_another_types_attach_is_not_counted(self):
        """`AVAudioEngine` の `attach(_:)` はスケッチへ足す口ではない。"""
        self.assertGreen("engine.attach(node)\nself.engine.attach(sink)\naudioEngine.attach(x)\n")

    def test_a_longer_name_is_not_a_call_of_attach(self):
        self.assertGreen("reattach(x)\nattachRecorded(x)\nattached(x)\nattachedAfterSurface(x)\n")

    def test_a_declaration_is_not_a_call(self):
        self.assertGreen("func attach(_ opened: NWConnection) {}\n")

    def test_line_doc_and_block_comments_are_not_counted(self):
        self.assertGreen("// attach(x)\n/// ``SketchPart/attach(_:)-(Inlet)``\n/* attach(x) */\n")

    def test_a_string_is_not_counted(self):
        self.assertGreen('let s = "attach(x)"\nlet t = """\nattach(y)\n"""\n')

    def test_the_label_form_attach_to_is_not_a_sketch_attach(self):
        """ほかの型の `attach(to:)` は、スケッチの `attach(_:)` ではない (受け手がスケッチでない)。"""
        self.assertGreen("view.attach(to: host)\n")

    # ------------------------------------------------------------ 許す 1 つ

    def test_the_connection_attach_in_datagram_is_allowed(self):
        """`NWConnection` を繋ぐ同じ綴りの別物 (`Datagram.swift`)。"""
        self.assertGreen("attach(opened)\n", path="MokumeNetwork/Datagram.swift")

    def test_another_argument_in_datagram_is_still_red(self):
        """許すのは (ファイル, 引数の綴り) の対で、ファイルごとではない。"""
        self.assertRedAt("attach(opened)\nattach(server)\n", 2, path="MokumeNetwork/Datagram.swift")

    def test_the_same_argument_in_another_file_is_still_red(self):
        self.assertRedAt("attach(opened)\n", 1)

    # ------------------------------------------------------------ 範囲

    def test_core_is_out_of_scope(self):
        """`MokumeCore` は道具の置き場で、公開の `attach` の実装がある。"""
        code, output = self.check({
            NET: "let a = 1\n",
            "MokumeCore/Sketch/Sketch+Other.swift": "attach(inlet)\n"})
        self.assertEqual(code, 0, output)

    def test_other_targets_are_out_of_scope(self):
        code, output = self.check({
            NET: "let a = 1\n",
            "MokumeSyphon/A.swift": "attach(x)\n"})
        self.assertEqual(code, 0, output)

    # ------------------------------------------------------------ 緑に倒れない

    def test_a_missing_toolbox_is_red(self):
        code, output = self.check({NET: "let a = 1\n"}, toolbox=None)
        self.assertEqual(code, 1, output)
        self.assertIn("案内する道具が無い", output)

    def test_a_toolbox_without_the_tool_is_red(self):
        code, output = self.check({NET: "let a = 1\n"}, toolbox="extension SketchPart {}\n")
        self.assertEqual(code, 1, output)
        self.assertIn("案内する道具が無い", output)

    def test_a_tree_without_the_targets_is_red(self):
        code, output = self.check({"MokumeCore/A.swift": "let a = 1\n"})
        self.assertEqual(code, 1, output)
        self.assertIn("1 つも無い", output)

    def test_the_real_tree_passes_the_check(self):
        """今の main に道具を通さない素の attach は残っていない (#2794)。"""
        result = subprocess.run(
            ["python3", str(SCRIPT), str(REPO / "Sources")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
