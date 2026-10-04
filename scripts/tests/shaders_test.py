#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-shaders.sh の、見るファイルの範囲の検査 (#2072)。

組み立ての順 (値の宣言 → Kinds → 前置き → 断片) は変えていない。固定するのは**見る範囲**
で、基準は「`git add -A` したときに CI の木になるもの」(追跡 + 未追跡 − 無視)。

- **無視された前置きを在ると数えない** — 手元にだけ在る `Common.metal` で断片を組み立てると
  手元では通り、前置きの無い CI の木では断片が単体で組み立てられて落ちる。手元でも落とす
- **無視されたシェーダは組み立てない** — CI の木に無いものの合否は CI に届かない
- **未追跡でも無視されていないものは見る** — `git add -A` で CI の木に入る

スクリプトは自分の隣 (`scripts/..`) を基準に動くので、一時ディレクトリの git
リポジトリに写して走らせる。metal コンパイラは代役に差し替える: 代役は、`needs_common`
を含む原文が `common_defined` も含むとき (= 共通部分つきで組み立てられたとき) だけ通し、
`broken` を含む原文を落とす。実物のコンパイラが要らないので、どの機械でも走る。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-shaders.sh"

# xcrun --find metal / xcrun metal -c <src> -o <out> の代役
XCRUN = """#!/bin/bash
if [ "$1" = "--find" ]; then echo /usr/bin/true; exit 0; fi
src="$3"
if grep -q broken "$src"; then echo "error: broken" >&2; exit 1; fi
if grep -q needs_common "$src" && ! grep -q common_defined "$src"; then
  echo "error: use of undeclared identifier" >&2; exit 1
fi
exit 0
"""

SHADERS = "Sources/Core/Drawing/Shaders"


class ShadersScopeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        subprocess.run(["git", "init", "-q", "."], cwd=self.root, check=True)
        # 使い捨てのリポジトリは手元の署名設定を継ぐ (#344)。ここは commit を
        # 打たないので効き目は無いが、抜けを人の記憶で守らないための規約に従う
        subprocess.run(
            ["git", "config", "commit.gpgsign", "false"], cwd=self.root, check=True
        )
        (self.root / "scripts").mkdir()
        shutil.copy(SCRIPT, self.root / "scripts" / "check-shaders.sh")
        self.bin = self.root / ".stub-bin"
        self.bin.mkdir()
        stub = self.bin / "xcrun"
        stub.write_text(XCRUN, encoding="utf-8")
        stub.chmod(0o755)
        self.ignore()

    def ignore(self, *patterns):
        lines = [".stub-bin/", *patterns]
        self.write(".gitignore", "\n".join(lines) + "\n")

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def run_check(self):
        env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}")
        return subprocess.run(
            ["/bin/bash", str(self.root / "scripts" / "check-shaders.sh")],
            cwd=self.root,
            capture_output=True,
            text=True,
            env=env,
        )

    def place_drawing(self):
        self.write(f"{SHADERS}/Common.metal", "// common_defined\n")
        self.write(f"{SHADERS}/Shapes.metal", "// needs_common\n")

    def test_fragment_with_common_passes(self):
        self.place_drawing()
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True)
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"ok: {SHADERS}/Shapes.metal (共通部分つき)", r.stdout)

    def test_ignored_common_does_not_count(self):
        # 手元にだけ在る前置きで組み立てると手元で通り、CI の木では単体で組まれて落ちる
        self.ignore(f"{SHADERS}/Common.metal")
        self.place_drawing()
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn(f"NG: {SHADERS}/Shapes.metal", r.stderr)

    def test_untracked_common_counts_before_git_add(self):
        self.place_drawing()
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("(共通部分つき)", r.stdout)

    def test_ignored_shader_is_not_compiled(self):
        # CI の木に無いシェーダの合否は CI に届かない
        self.ignore("Sources/Core/Scratch.metal")
        self.place_drawing()
        self.write("Sources/Core/Scratch.metal", "// broken\n")
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("Scratch.metal", r.stdout + r.stderr)

    def test_untracked_broken_shader_is_reported(self):
        self.place_drawing()
        self.write("Sources/Core/New.metal", "// broken\n")
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("NG: Sources/Core/New.metal", r.stderr)


if __name__ == "__main__":
    unittest.main()
