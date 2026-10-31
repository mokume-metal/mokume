#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-shaders.sh の、見るファイルの範囲の検査 (#2072)。

組み立ての順 (値の宣言 → Kinds → 前置き → 断片) は変えていない。固定するのは**見る範囲**
で、基準は「`git add -A` したときに CI の木になるもの」(追跡 + 未追跡 − 無視)。

加えて、**区切りごとの名乗り** (#2457) を固定する。実行時の `ShaderSource.assemble` と同じく、
区切りの頭に `#line 1 "<名前>"` を差し、区切りの後に改行を 1 つ足す。差さないと、同梱した
断片の誤りが、つないだ一時のファイルの行で出る。

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

# xcrun metal --version / xcrun metal -c <src> -o <out> の代役
XCRUN = """#!/bin/bash
if [ "$2" = "--version" ]; then echo "Apple metal version 0"; exit 0; fi
src="$3"
# 組み立てた原文を残す (名乗りの検査が読む)
if [ -n "${CHECK_SHADERS_KEEP:-}" ]; then cp "$src" "$CHECK_SHADERS_KEEP/"; fi
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

    def run_check(self, keep=None):
        env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}")
        if keep is not None:
            env["CHECK_SHADERS_KEEP"] = str(keep)
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

    def test_every_part_names_itself_with_line(self):
        # 区切りの頭で、木の中のパス (値の宣言は実行時と同じ mokume/Values) と 1 行目を名乗る。
        # 区切りの後の改行は、最後の行に改行の無いファイルでも次の名乗りを行頭に置く
        self.write(f"{SHADERS}/Kinds.metal", "// kinds\n")
        self.write(f"{SHADERS}/Common.metal", "// common_defined\n")
        self.write(f"{SHADERS}/Shapes.metal", "// needs_common")
        self.write("Sources/Core/Solo.metal", "// solo\n")
        keep = self.root / ".kept"
        keep.mkdir()
        r = self.run_check(keep=keep)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            (keep / "Shapes.metal").read_text(encoding="utf-8"),
            '#line 1 "mokume/Values"\n'
            "struct Values {\n    float4 mokume_unused;\n};\n\n"
            f'#line 1 "{SHADERS}/Kinds.metal"\n// kinds\n\n'
            f'#line 1 "{SHADERS}/Common.metal"\n// common_defined\n\n'
            f'#line 1 "{SHADERS}/Shapes.metal"\n// needs_common\n',
        )
        self.assertEqual(
            (keep / "Solo.metal").read_text(encoding="utf-8"),
            '#line 1 "Sources/Core/Solo.metal"\n// solo\n\n',
        )

    def test_noise_goes_between_kinds_and_prelude(self):
        # 揺らぎの本体 (Noise.metal) は 3 本の前置きすべてに入り、Kinds.metal の後・前置きの前に並ぶ。
        # 実行時の ShaderLibraries.prelude と順がずれると、実行時にだけ組めない断片が検査を通る (#3569)
        self.write(f"{SHADERS}/Kinds.metal", "// kinds\n")
        self.write(f"{SHADERS}/Noise.metal", "// noise\n")
        self.write(f"{SHADERS}/Common.metal", "// common_defined\n")
        self.write(f"{SHADERS}/Shapes.metal", "// needs_common\n")
        self.write(f"{SHADERS}/Effect.metal", "// effect_prelude\n")
        self.write(f"{SHADERS}/Effects/Builtin.metal", "// builtin\n")
        keep = self.root / ".kept"
        keep.mkdir()
        r = self.run_check(keep=keep)
        self.assertEqual(r.returncode, 0, r.stderr)
        for name, prelude in (("Shapes.metal", "Common"), ("Builtin.metal", "Effect")):
            text = (keep / name).read_text(encoding="utf-8")
            order = [
                text.index(f'#line 1 "{SHADERS}/Kinds.metal"'),
                text.index(f'#line 1 "{SHADERS}/Noise.metal"'),
                text.index(f'#line 1 "{SHADERS}/{prelude}.metal"'),
            ]
            self.assertEqual(order, sorted(order), name)
        # 前置きそのものは単体で確かめない (Noise.metal も同じ)
        self.assertNotIn("Noise.metal (", r.stdout)

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

    def test_a_stub_without_the_component_names_how_to_install(self):
        # Xcode 26 のスタブは在処を答えたまま、起こすとコンポーネントが無いと言って落ちうる。
        # 断片ごとの生のエラーではなく、入れ方を 1 度だけ言って止まる
        (self.bin / "xcrun").write_text(
            "#!/bin/bash\n"
            'if [ "$1" = "--find" ]; then echo /usr/bin/metal; exit 0; fi\n'
            'echo "error: cannot execute tool \'metal\' due to missing Metal Toolchain" >&2\n'
            "exit 1\n",
            encoding="utf-8",
        )
        self.place_drawing()
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("xcodebuild -downloadComponent MetalToolchain", r.stderr)
        self.assertNotIn("NG:", r.stderr)



if __name__ == "__main__":
    unittest.main()
