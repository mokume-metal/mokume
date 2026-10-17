#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-github-yaml.sh を `/bin/bash` で起こす検査 (#2612)。

この段は CI では ubuntu の ci-static で走る。手元とエージェントは macOS の `/bin/bash` (3.2) と
BSD の道具で走らせるので、そこで動くことはこの検査 (macOS に残る hooks-test) が持つ (#702)。

YAML の構文の判定そのものは ruby が持つので、代役の `ruby` を PATH の先に置く。代役は
中身に `BROKEN` を含むファイルだけを不正と名乗る。見るのは周りのシェル — `.github/` の下の
`.yml` と `.yaml` を名指しせずに全部拾うこと (#87)、1 つでも不正なら 1 で抜けること、
対象が無いときに黙らず名乗ること。

一時ディレクトリに小さな git リポジトリを組んで実行する。実行は make hooks-test。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-github-yaml.sh"

# ruby -ryaml -e '...' -- <file> の代役。最後の引数を読み、BROKEN を含めば構文の誤りを名乗る
FAKE_RUBY = """#!/bin/sh
for f in "$@"; do last="$f"; done
if grep -q BROKEN "$last"; then
  echo "(fake) did not find expected key while parsing a block mapping" >&2
  exit 1
fi
exit 0
"""


class GithubYamlTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "repo"
        self.root.mkdir()
        subprocess.run(["git", "init", "-q", "."], cwd=self.root, check=True)
        subprocess.run(["git", "config", "commit.gpgsign", "false"], cwd=self.root, check=True)
        bin_dir = Path(self.tmp.name) / "bin"
        bin_dir.mkdir()
        ruby = bin_dir / "ruby"
        ruby.write_text(FAKE_RUBY)
        ruby.chmod(0o755)
        self.env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"}

    def put(self, name: str, text: str = "a: 1\n"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def run_check(self):
        return subprocess.run(
            ["/bin/bash", str(SCRIPT)], cwd=self.root, env=self.env,
            capture_output=True, text=True, timeout=60,
        )

    def test_正しい_YAML_だけなら緑で全部を名乗る(self):
        self.put(".github/workflows/ci.yml")
        self.put(".github/dependabot.yaml")
        self.put(".github/ISSUE_TEMPLATE/bug.yml")
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)
        for name in (".github/workflows/ci.yml", ".github/dependabot.yaml", ".github/ISSUE_TEMPLATE/bug.yml"):
            self.assertIn(f"ok: {name}", r.stdout)

    def test_1_つでも不正なら赤で名指しし残りも見る(self):
        self.put(".github/a.yml")
        self.put(".github/b.yml", "BROKEN\n")
        self.put(".github/c.yml")
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("NG: .github/b.yml", r.stderr)
        self.assertIn("ok: .github/a.yml", r.stdout)
        self.assertIn("ok: .github/c.yml", r.stdout)

    def test_YAML_でないファイルは見ない(self):
        self.put(".github/notes.md", "BROKEN\n")
        self.put(".github/a.yml")
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("notes.md", r.stdout + r.stderr)

    def test_対象が無ければ黙らずに名乗る(self):
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("検査対象の YAML が .github/ に無い", r.stdout)

    def test_根から見る(self):
        # 下のディレクトリから打っても、リポジトリの根の .github を見る
        self.put(".github/b.yml", "BROKEN\n")
        (self.root / "sub").mkdir()
        r = subprocess.run(
            ["/bin/bash", str(SCRIPT)], cwd=self.root / "sub", env=self.env,
            capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("NG: .github/b.yml", r.stderr)


if __name__ == "__main__":
    unittest.main()
