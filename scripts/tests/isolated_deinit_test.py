#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-isolated-deinit.py の検査 (#1083)。

守るのは「隔離を明示していない `isolated deinit` を 1 つも見逃さない」で、それは
**囲む型を正しく取れるか**に懸かっている。読み違えると 2 通りに壊れる:

- 囲みを取り違えて**外側の `@MainActor` を内側の型のものと読む** — 見逃す側なので、
  塞ごうとしている再発 (#761 → #1021) がそのまま通る
- コメントの中の綴りを宣言と読む — 赤くなるので目には見えるが、正しいコードが止まる

形ごとに 1 件ずつ置く。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-isolated-deinit.py"


class IsolatedDeinitTest(unittest.TestCase):
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
        return output

    # ------------------------------------------------------------ 隔離を明示していれば緑

    def test_attribute_on_the_declaration_line(self):
        self.assertGreen(
            "@MainActor final class Page {\n"
            "    isolated deinit { retire() }\n"
            "}\n")

    def test_attribute_on_its_own_line(self):
        self.assertGreen(
            "@MainActor\nfinal class Page {\n"
            "    isolated deinit {\n        retire()\n    }\n"
            "}\n")

    def test_several_attributes_above_the_declaration(self):
        self.assertGreen(
            "@available(macOS 26, *)\n@MainActor\nprivate final class Page {\n"
            "    isolated deinit { retire() }\n"
            "}\n")

    def test_actor_needs_no_attribute(self):
        self.assertGreen(
            "actor Page {\n"
            "    isolated deinit { retire() }\n"
            "}\n")

    def test_a_custom_global_actor_counts(self):
        self.assertGreen(
            "@RenderActor final class Page {\n"
            "    isolated deinit { retire() }\n"
            "}\n")

    # ------------------------------------------------------------ 明示が無ければ赤

    def test_a_bare_class_is_named_with_its_type(self):
        output = self.assertRedAt(
            "final class Page {\n"
            "    isolated deinit { retire() }\n"
            "}\n", 2)
        self.assertIn("class Page", output)

    def test_the_red_points_at_the_canonical_reason(self):
        _, output = self.check({"Sketch.swift": "final class Page {\n    isolated deinit {}\n}\n"})
        self.assertIn("@MainActor", output)
        self.assertIn("Sources/MokumeCore/Rendering/RenderDevice.swift", output)

    def test_an_inner_type_does_not_inherit_the_outer_attribute(self):
        """外側の `@MainActor` は内側の型を隔離しない — 見逃すと再発がそのまま通る。"""
        self.assertRedAt(
            "@MainActor final class Stage {\n"
            "    final class Relay {\n"
            "        isolated deinit { retire() }\n"
            "    }\n"
            "}\n", 3)

    def test_an_inner_type_with_its_own_attribute_is_green(self):
        self.assertGreen(
            "final class Stage {\n"
            "    @MainActor private final class Relay {\n"
            "        isolated deinit { retire() }\n"
            "    }\n"
            "}\n")

    def test_the_nearest_enclosing_declaration_wins(self):
        """浅い宣言が後から現れても、囲みは deinit より浅い最初のものである。"""
        self.assertGreen(
            "@MainActor final class Page {\n"
            "    struct Slot { let index: Int }\n"
            "    isolated deinit { retire() }\n"
            "}\n")

    def test_an_unreadable_enclosure_is_red(self):
        self.assertRedAt("isolated deinit { retire() }\n", 1)

    # ------------------------------------------------------------ コメントは宣言ではない

    def test_the_spelling_inside_a_comment_is_not_a_declaration(self):
        self.assertGreen(
            "// `isolated deinit` を持つ型は隔離を明示する。理由は RenderDevice の冒頭が持つ\n"
            "/// 例:\n"
            "///     isolated deinit { retire() }\n"
            "final class Page {\n"
            "    let index = 0\n"
            "}\n")

    # ------------------------------------------------------------ 見るものが無ければ赤

    def test_a_tree_without_swift_is_red(self):
        code, output = self.check({"README.md": "# 読み物\n"})
        self.assertEqual(code, 1, output)
        self.assertIn("1 つも無い", output)

    def test_a_tree_without_isolated_deinit_is_green(self):
        code, output = self.check({"Sketch.swift": "final class Page {\n    deinit {}\n}\n"})
        self.assertEqual(code, 0, output)
        self.assertIn("0 箇所", output)


if __name__ == "__main__":
    unittest.main()
