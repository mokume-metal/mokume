#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/swift_typecheck.py の検査 (#820)。

同じ `swiftc -typecheck` の呼び方が 2 実装あり、**片方だけが macro の plugin 名を
動的に解いていた** — `check-param-declarations.sh` は `MokumeMacros-tool` と
`#MokumeMacros` を直書きしていた。

**macro の的を改名すると `examples` は追随し、`params` だけが落ちる。** しかも落ち方は
`external macro implementation … could not be found` で、改名が原因だとは読めない。

だから固定するのは 2 つ:

1. **名前を置き場から導くこと** — 別名の `*-tool` を置いても拾えること
2. **呼び方が 1 つであること** — `scripts/*.sh` と `scripts/*.py` に `swiftc -typecheck`
   の写しが無いこと (`swift_typecheck.py` と、そこを通す呼び出しだけ)

`swiftc` を実際に走らせる検査はここには置かない — 通しの型検査は `make examples` と
`make params` が受け持つ (どちらもパッケージの成果物が要る)。ここは呼び方の組み立てだけを
見るので、GPU もツールチェーンも要らない。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import importlib.util
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "scripts"
MODULE = SCRIPTS / "swift_typecheck.py"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


swift = _load("swift_typecheck", MODULE)


# インラインコードの span。**このリポジトリは散文の中でコードをバッククォートで囲む**
# ので、囲まれた言及は「呼び方を組んでいる」ことにならない (解説がまさにその綴りを
# 説明している場面がある)。潰してから探す — `bash_invocation_test.py` が AST で
# 自分自身のパターン文字列を避けているのと同じ問題への、shell も含められる答え
INLINE_CODE = re.compile(r"`[^`]*`")


def code_only(line: str) -> str:
    """散文を落として、コードとして書かれた部分だけを返す。

    **囲みの札 (```) を先に落とす。** 落とさないと札の 3 本がインラインコードの対を
    ずらし、同じ行の後ろにある囲みが解けなくなる (`check-examples.py:14` の
    「```swift の塊を… `swiftc -typecheck` に掛ける」がそれで拾われていた)。
    """
    stripped = line.lstrip()
    # shell のコメントと Python の行コメント
    if stripped.startswith("#"):
        return ""
    return INLINE_CODE.sub("", line.replace("```", ""))


def build_tree(directory, tool_name=None, extras=()):
    """`swift build` が作る置き場を模す。`<的>-tool` の名前を変えられる。"""
    build = Path(directory) / "debug"
    modules = build / "Modules"
    modules.mkdir(parents=True)
    if tool_name:
        tool = build / tool_name
        tool.write_text("")
        tool.chmod(0o755)
    for extra in extras:
        (build / extra).mkdir()
    return modules, (build / tool_name if tool_name else None)


class PluginFlagsTest(unittest.TestCase):
    def test_the_built_plugin_is_passed(self):
        with tempfile.TemporaryDirectory() as directory:
            modules, tool = build_tree(directory, "MokumeMacros-tool", extras=())
            (Path(directory) / "debug" / "notes.txt").write_text("")
            self.assertEqual(
                swift.plugin_flags(modules),
                ["-load-plugin-executable", f"{tool}#MokumeMacros"],
            )

    def test_a_renamed_target_is_followed(self):
        """**ここが #820 の主眼。** 名前を決め打ちしていると、改名で片方だけが落ちる。"""
        with tempfile.TemporaryDirectory() as directory:
            modules, tool = build_tree(directory, "MokumeSyntax-tool")
            self.assertEqual(
                swift.plugin_flags(modules),
                ["-load-plugin-executable", f"{tool}#MokumeSyntax"],
            )

    def test_a_directory_with_the_same_spelling_is_not_a_plugin(self):
        """実際の置き場には `Modules-tool` というディレクトリが並ぶ (実測)。
        渡すと swiftc がそこで落ちる。"""
        with tempfile.TemporaryDirectory() as directory:
            modules, _ = build_tree(directory, None, extras=("Modules-tool",))
            self.assertEqual(swift.plugin_flags(modules), [])

    def test_no_plugin_means_no_flags(self):
        with tempfile.TemporaryDirectory() as directory:
            modules, _ = build_tree(directory, None)
            self.assertEqual(swift.plugin_flags(modules), [])


class CommandTest(unittest.TestCase):
    def test_the_language_settings_are_carried(self):
        """**利用者のパッケージと同じ言語設定で見る。** 揃っていないと、利用者の手元では
        出ない食い違いを検査が拾ってしまう。"""
        with tempfile.TemporaryDirectory() as directory:
            modules, _ = build_tree(directory, None)
            argv = swift.command(Path("a.swift"), modules)
        self.assertEqual(argv[:2], ["swiftc", "-typecheck"])
        for flag in ("-swift-version", "6", "-default-isolation", "MainActor"):
            self.assertIn(flag, argv)
        self.assertIn("-I", argv)
        self.assertEqual(argv[-1], "a.swift")

    def test_the_usage_is_refused_with_the_conventional_code(self):
        proc = subprocess.run(
            [sys.executable, str(MODULE)], capture_output=True, text=True
        )
        # CLI の usage は 64 (sysexits の EX_USAGE) で揃えている
        self.assertEqual(proc.returncode, 64)
        self.assertIn("usage:", proc.stderr)


class OneWayOnlyTest(unittest.TestCase):
    """**呼び方が 1 つであることを構造で見る。**

    一覧は数え上げない — `scripts/` を glob するので、次に自前で組んだ人がここを
    直さなくても掛かる。
    """

    def sources(self):
        found = sorted(list(SCRIPTS.glob("*.sh")) + list(SCRIPTS.glob("*.py")))
        self.assertTrue(found, f"検査対象が 1 つも無い ({SCRIPTS})")
        return found

    def test_no_script_spells_the_invocation_itself(self):
        found = []
        for path in self.sources():
            if path.name == MODULE.name:
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if re.search(r"swiftc\s+-typecheck|-load-plugin-executable", code_only(line)):
                    found.append(f"  {path.name}:{number}: {line.strip()}")
        if found:
            self.fail(
                "自前で swiftc の呼び方を組んでいる箇所がある:\n"
                + "\n".join(found)
                + "\n\n直し方: swift_typecheck を通す (import か、口を叩く)。\n"
                "写しがあると、macro の的を改名したとき片方だけが落ちる (#820)。"
            )

    def test_no_script_hardcodes_the_macro_target(self):
        found = []
        for path in self.sources():
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if "MokumeMacros" in code_only(line):
                    found.append(f"  {path.name}:{number}: {line.strip()}")
        if found:
            self.fail(
                "macro の的の名前を直書きしている箇所がある:\n"
                + "\n".join(found)
                + "\n\n名前は置き場の `*-tool` から導く (Package.swift の写しを持たない)。"
            )

    def test_the_readers_go_through_it(self):
        for name in ("check-examples.py", "check-param-declarations.sh"):
            with self.subTest(reader=name):
                text = (SCRIPTS / name).read_text(encoding="utf-8")
                self.assertIn("swift_typecheck", text, f"{name} が共有の呼び方を通っていない")


if __name__ == "__main__":
    unittest.main()
