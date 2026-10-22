#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-attach-result.py の検査 (#2794)。

守るのは「作る口が、道具を通さない `attach` を書き足したら見逃さない」と「道具の形や、ほかの型の
同名の口を赤くしない」の両方で、どちらも**スケッチへ足す呼び出しだけを正しく取れるか**に懸かっている。
読み違えると 2 通りに壊れる:

- 素の呼び出しを、改行を挟んだ受け手・引数で受け回したスケッチ・呼ばない参照・入れ子の `calledAs:` と
  取り違える — 見逃す側なので、塞ごうとしている再発 (#2297・#2295 が #2740 の約束を写した形) が通る。
  **文字列補間の中はコード**である
- 道具の形 (`calledAs:` をトップレベルの引数に持つ)・宣言・別の型の `engine.attach(node)`・正規表現リテラルを
  素の呼び出しと読む — 赤くなるので目には見えるが、正しいコードが止まる

反証役が試した書き方 (#2794) を、形ごとに 1 件ずつ置く。実行は make hooks-test (CI もこれを呼ぶ)。
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
    "    package func attachedOnSurface<F, P>(\n"
    "        _ f: F.Type, calledAs call: String, making make: () throws(F) -> P\n"
    "    ) throws(F) -> P {}\n"
    "    private func attachAfterCheck<P>(_ part: P) -> P { _ = attach(part); return part }\n"
    "    package func attach(_ inlet: any Inlet, calledAs call: String, returning value: String) -> Bool {\n"
    "        runtime.attach(inlet)\n"
    "    }\n"
    "}\n")
NET = "MokumeNetwork/Sketch+Net.swift"
# 許している別の型の文脈 (check-attach-result.py の EXEMPT_TYPES)。木に無いと許可が空振りで落ちる
FLOW = "MokumeAudio/SoundFlow.swift"
FLOW_TEXT = "final class SoundFlow {\n    func join() {\n        engine.attach(node)\n    }\n}\n"
MICROPHONE = "MokumeAudio/MicrophoneSource.swift"
MICROPHONE_TEXT = "final class MicrophoneSource {\n}\n"
DATAGRAM = "MokumeNetwork/Datagram.swift"
DATAGRAM_TEXT = "final class DatagramSender {\n    func open() {\n        attach(opened)\n    }\n}\n"


class AttachResultTest(unittest.TestCase):
    def check(self, files, toolbox=TOOLBOX_TEXT):
        """Sources に見立てた一時ディレクトリへ道具の置き場・許している文脈とファイルを置いて検査を打つ。"""
        tree = {FLOW: FLOW_TEXT, MICROPHONE: MICROPHONE_TEXT, DATAGRAM: DATAGRAM_TEXT}
        if toolbox is not None:
            tree[TOOLBOX] = toolbox
        tree.update(files)
        with tempfile.TemporaryDirectory() as root:
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
        self.assertIn("attachedOnSurface(_:calledAs:making:)", output)
        self.assertIn("attach(_:calledAs:returning:)", output)
        self.assertIn("#2794", output)
        self.assertIn("Sketch+Seams.swift", output)

    def test_every_module_is_checked(self):
        """見る置き場の名前の一覧を持たない。将来の MokumeMIDI・MokumeGame も、本体の MokumeCore・mokume も同じ。"""
        for package in ("MokumeAudio", "MokumeCamera", "MokumeNetwork", "MokumeGamepad",
                        "MokumeCore/Sketch", "mokume", "MokumeMIDI", "MokumeGame", "MokumeSyphon"):
            with self.subTest(package=package):
                self.assertRedAt("attach(x)\n", 1, path=f"{package}/Sketch+A.swift")

    def test_a_call_on_the_sketch_is_red(self):
        for receiver in ("self", "sketch", "owner", "self.sketch"):
            with self.subTest(receiver=receiver):
                self.assertRedAt(f"{receiver}.attach(pad)\n", 1)

    def test_a_call_on_a_sketch_passed_as_an_argument_is_red(self):
        """ゲームパッドと合成は、スケッチを引数で受け回している (名前の一覧では取れない)。"""
        for receiver in ("host", "part", "target", "any_name_at_all"):
            with self.subTest(receiver=receiver):
                self.assertRedAt(f"{receiver}.attach(pad)\n", 1)

    def test_a_line_break_or_a_tab_before_the_dot_is_red(self):
        self.assertRedAt("sketch\n    .attach(pad)\n", 2)
        self.assertRedAt("sketch\t.attach(pad)\n", 1)
        self.assertRedAt("sketch.\n    attach(pad)\n", 2)

    def test_a_receiver_that_is_not_a_plain_name_is_red(self):
        for receiver in ("sketch?", "sketches[0]", "makeSketch()", "sketch!", "(a ?? b)"):
            with self.subTest(receiver=receiver):
                self.assertRedAt(f"{receiver}.attach(pad)\n", 1)

    def test_a_call_with_spaces_and_a_line_break_is_red(self):
        self.assertRedAt("attach (\n    server\n)\n", 1)
        self.assertRedAt("attach\n(server)\n", 1)

    def test_a_call_in_an_expression_is_red(self):
        self.assertRedAt("if !attach(pad) { return }\n", 1)
        self.assertRedAt("_ = attach(pad)\n", 1)

    def test_a_backticked_name_is_red(self):
        self.assertRedAt("`attach`(x)\n", 1)
        self.assertRedAt("sketch.`attach`(x)\n", 1)

    def test_a_reference_that_is_not_called_is_red(self):
        for text in ("inlets.forEach(attach)\n", "let add = attach\n", "let add = self.attach\n",
                     "let add = sketch.attach\n", "let add: (any Inlet) -> Bool = attach(_:)\n",
                     "run(#selector(attach))\n", "add = `attach`\n"):
            with self.subTest(text=text):
                output = self.assertRedAt(text, 1)
                self.assertIn("呼ばずに参照", output)

    def test_the_label_only_in_a_nested_call_is_not_the_tool(self):
        """`calledAs:` は、トップレベルの引数のラベルでなければ道具の形ではない。"""
        self.assertRedAt("attach(f(calledAs: c))\n", 1)
        self.assertRedAt("attach(g(x, calledAs: c), y)\n", 1)
        self.assertRedAt("attach([calledAs: c])\n", 1)

    def test_the_label_in_a_comment_or_a_string_is_not_the_tool(self):
        self.assertRedAt('attach(x, "calledAs: c")\n', 1)
        self.assertRedAt("attach(x /* calledAs: c */)\n", 1)
        self.assertRedAt("attach(x) // calledAs: c\n", 1)

    def test_the_line_number_follows_a_multiline_string_before_it(self):
        self.assertRedAt('let s = """\nattach(x)\n"""\nattach(y)\n', 4)

    def test_a_call_in_string_interpolation_is_code(self):
        self.assertRedAt('let s = "\\(attach(x))"\n', 1)

    def test_a_call_after_a_comment_on_the_same_line_is_red(self):
        self.assertRedAt("/* 足す */ attach(x)\n", 1)

    def test_a_division_before_a_call_is_not_a_regex_literal(self):
        self.assertRedAt("let r = a / b / c\nattach(x)\n", 2)
        self.assertRedAt("let r = (a) / (b) + attach(x) / 2\n", 1)

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
        self.assertGreen('if host\n    .attach(pad, calledAs: call, returning: "pads") { return }\n')

    def test_a_longer_name_is_not_a_call_of_attach(self):
        self.assertGreen("reattach(x)\nattachRecorded(x)\nattached(x)\nattachedAfterSurface(x)\n"
                         "attachedOnSurface(F.self, calledAs: c) { x }\n")

    def test_a_declaration_is_not_a_call(self):
        self.assertGreen("func attach(_ opened: NWConnection) {}\n")
        self.assertGreen("enum OutsideCall {\n    case attach\n}\n")

    def test_an_implicit_member_is_not_a_call(self):
        self.assertGreen("OutsideRun.log.warn(.attach)\nswitch c {\ncase .attach:\n    break\n}\n")

    def test_a_label_named_attach_is_not_a_call(self):
        self.assertGreen("run(attach: true)\nlet d = [attach: 1]\n")

    def test_a_macro_attribute_is_not_a_call(self):
        self.assertGreen("@attached(accessor, names: named(get))\nmacro Param()\n")

    def test_line_doc_and_block_comments_are_not_counted(self):
        self.assertGreen("// attach(x)\n/// ``SketchPart/attach(_:)-(Inlet)``\n/* attach(x) */\n")

    def test_a_string_is_not_counted(self):
        self.assertGreen('let s = "attach(x)"\nlet t = """\nattach(y)\n"""\n')

    def test_a_regex_literal_is_not_counted(self):
        self.assertGreen("let r = /attach(x)/\nlet s = #/attach(x)/#\nlet t = try Regex(#\"attach(x)\"#)\n")
        self.assertGreen("run(/attach(x)/)\nlet a = [/attach(x)/, /attach(y)/]\n")

    def test_a_call_with_another_first_label_is_another_types(self):
        """スケッチの `attach` の第 1 引数はラベルが無い。`to:` で呼べるのは別の型の口 (AppKit の画面など)。"""
        self.assertGreen("view.attach(to: host)\nscreenLink.attach(to: NSScreen.main, following: window)\n")

    # ------------------------------------------------------------ 別の型の口は文脈で許す

    def test_another_types_attach_is_allowed_in_its_type(self):
        """`AVAudioEngine` の `attach(_:)`。受け手の綴りを読まないので、どんな形の受け手でも同じ。"""
        for receiver in ("engine", "self.engine", "engine?", "engines[0]", "makeEngine()", "audioEngine\n    "):
            with self.subTest(receiver=receiver):
                self.assertGreen(
                    f"final class SoundFlow {{\n    func join() {{\n        {receiver}.attach(node)\n    }}\n}}\n",
                    path=FLOW)

    def test_another_types_attach_outside_its_type_is_red(self):
        self.assertRedAt("final class Other {\n    func join() {\n        engine.attach(node)\n    }\n}\n", 3)
        self.assertRedAt("final class SoundFlow {\n}\nfinal class Other {\n    func f() { engine.attach(n) }\n}\n",
                         4, path=FLOW)

    def test_a_rename_of_the_argument_does_not_turn_the_allowed_call_red(self):
        """許すのは (ファイル, 型) で、引数の綴りではない。名前を変えても、同じ形の型を足しても赤くならない。"""
        self.assertGreen(
            "final class DatagramSender {\n    func open() {\n        attach(renamed)\n"
            "        attach(another(opened))\n    }\n}\n", path=DATAGRAM)

    def test_the_same_file_is_not_allowed_outside_the_type(self):
        self.assertRedAt(
            DATAGRAM_TEXT + "final class Other {\n    func f() { attach(opened) }\n}\n", 7, path=DATAGRAM)

    def test_a_stale_permission_is_red(self):
        """許している型が消えた・名前が変わったのに許可が残ると、別の所を黙って許す。"""
        code, output = self.check({FLOW: "final class Renamed {\n}\n"})
        self.assertEqual(code, 1, output)
        self.assertIn("空振り", output)
        self.assertIn("SoundFlow", output)

    def test_a_stale_function_permission_is_red(self):
        code, output = self.check({}, toolbox=TOOLBOX_TEXT.replace("attachAfterCheck", "renamed"))
        self.assertEqual(code, 1, output)
        self.assertIn("空振り", output)
        self.assertIn("attachAfterCheck", output)

    # ------------------------------------------------------------ 道具の中

    def test_the_toolbox_is_checked_like_any_file(self):
        """道具の置き場にも、許した関数の外の素の呼び出しは赤。"""
        code, output = self.check({TOOLBOX: TOOLBOX_TEXT + "func sneaky() { _ = attach(part) }\n"})
        self.assertEqual(code, 1, output)
        self.assertIn("Sketch+Seams.swift:11:", output)

    def test_a_helper_renamed_from_the_tool_is_red(self):
        """名前を変えただけで確かめずに足して捨てる道具を、別の所に作っても赤。"""
        self.assertRedAt(
            "extension Sketch {\n    func attachedLater<P>(_ part: P) -> P {\n        _ = attach(part)\n"
            "        return part\n    }\n}\n", 3)

    # ------------------------------------------------------------ 投げる口

    def test_the_throwless_tool_in_a_throwing_mouth_is_red(self):
        output = self.assertRedAt(
            "extension Sketch {\n    public func createX() throws(NetworkFailure) -> X {\n"
            "        let x = X()\n        attach(x, calledAs: #function, returning: \"a port\")\n        return x\n"
            "    }\n}\n", 4)
        self.assertIn("投げる口", output)
        self.assertIn("attached(_:calledAs:making:)", output)

    def test_a_throwing_mouth_with_a_plain_throws_is_red(self):
        self.assertRedAt(
            "func make() throws -> X {\n    attach(x, calledAs: c, returning: v)\n    return x\n}\n", 2)

    def test_a_throwing_initialiser_is_red(self):
        self.assertRedAt(
            "final class A {\n    init() throws {\n        attach(x, calledAs: c, returning: v)\n    }\n}\n", 3)

    def test_the_tool_in_a_mouth_that_does_not_throw_is_the_goal(self):
        self.assertGreen(
            "extension Sketch {\n    public func createX() -> X {\n"
            "        let x = X()\n        attach(x, calledAs: #function, returning: \"a port\")\n        return x\n"
            "    }\n}\n")

    def test_a_non_throwing_mouth_after_a_throwing_one_is_not_confused(self):
        self.assertGreen(
            "func a() throws -> X { return X() }\n"
            "func b() -> X {\n    attach(x, calledAs: c, returning: v)\n    return x\n}\n")

    # ------------------------------------------------------------ 緑に倒れない

    def test_a_missing_toolbox_is_red(self):
        code, output = self.check({NET: "let a = 1\n"}, toolbox=None)
        self.assertEqual(code, 1, output)
        self.assertIn("案内する道具が無い", output)

    def test_a_toolbox_without_the_tool_is_red(self):
        code, output = self.check({NET: "let a = 1\n"}, toolbox="extension SketchPart {}\n")
        self.assertEqual(code, 1, output)
        self.assertIn("案内する道具が無い", output)

    def test_a_toolbox_with_only_a_similar_name_is_red(self):
        """`func attachedAfterSurface` は `attached` の宣言ではない (名前の部分一致で満たさない)。"""
        for text in (
                TOOLBOX_TEXT.replace("func attached<", "func attachedAfterSurface<"),
                TOOLBOX_TEXT.replace("func attachedOnSurface<", "func attachedOnSurfaceLater<"),
        ):
            with self.subTest(text=text):
                code, output = self.check({NET: "let a = 1\n"}, toolbox=text)
                self.assertEqual(code, 1, output)
                self.assertIn("案内する道具が無い", output)

    def test_a_toolbox_with_the_tool_only_in_a_comment_is_red(self):
        code, output = self.check({}, toolbox=(
            "// package func attached<F, P>(_ f: F.Type, calledAs call: String, making make: () -> P)\n"
            "/// package func attachedOnSurface<F, P>(_ f: F.Type, calledAs c: String, making m: () -> P)\n"
            "extension SketchPart {\n    func attach(_ x: Int) {}\n    func attachAfterCheck() {}\n}\n"))
        self.assertEqual(code, 1, output)
        self.assertIn("案内する道具が無い", output)

    def test_a_toolbox_with_the_wrong_shape_is_red(self):
        """名前が合っても、`calledAs`・`making` の形が崩れていれば道具ではない。"""
        code, output = self.check({}, toolbox=TOOLBOX_TEXT.replace("calledAs call: String, making", "making"))
        self.assertEqual(code, 1, output)

    def test_a_tree_without_any_swift_is_red(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / TOOLBOX
            path.parent.mkdir(parents=True)
            path.write_text("", encoding="utf-8")
            result = subprocess.run(["python3", str(SCRIPT), root], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_the_real_tree_passes_the_check(self):
        """今の木に道具を通さない attach は残っていない (#2794)。"""
        result = subprocess.run(
            ["python3", str(SCRIPT), str(REPO / "Sources")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
