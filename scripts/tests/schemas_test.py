#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-schemas.sh の、見るファイルの範囲の検査 (#2072)。

検査の中身 (例がスキーマどおりか・名前の対応) は変えていない。固定するのは**見る範囲**
で、基準は「`git add -A` したときに CI の木になるもの」(追跡 + 未追跡 − 無視)。

- **無視された例は数えない** — 手元に `Schemas/examples/<名>.json` が在っても無視されて
  いれば CI の木に無く、CI では「例が 1 つも無いスキーマ」で赤になる。手元でも赤にする
- **未追跡でも無視されていない例は数える** — `git add -A` で CI の木に入る

スクリプトは自分の隣 (`scripts/..`) を基準に動くので、一時ディレクトリの git
リポジトリに写して走らせる。例の検証 (`check-jsonschema`) と版の据え置きの検査
(`check-schema-versions.py`) は範囲の話ではないので、常に通す代役に差し替える。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-schemas.sh"

SCHEMA = '{"$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object"}\n'


class SchemasScopeTest(unittest.TestCase):
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
        shutil.copy(SCRIPT, self.root / "scripts" / "check-schemas.sh")
        self.write("scripts/check-schema-versions.py", "print('stub')\n")
        # 代役の check-jsonschema は常に通す
        self.bin = self.root / ".stub-bin"
        self.bin.mkdir()
        stub = self.bin / "check-jsonschema"
        stub.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        stub.chmod(0o755)
        self.write(".gitignore", ".stub-bin/\n")

    def write(self, name, text="{}\n"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def run_check(self):
        env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}")
        return subprocess.run(
            ["/bin/bash", str(self.root / "scripts" / "check-schemas.sh")],
            cwd=self.root,
            capture_output=True,
            text=True,
            env=env,
        )

    def test_schema_with_tracked_example_passes(self):
        self.write("Schemas/state.schema.json", SCHEMA)
        self.write("Schemas/examples/state.json")
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True)
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("ok: Schemas/examples/state.json", r.stdout)

    def test_ignored_example_does_not_count(self):
        # 手元に在っても CI の木には無い。CI では例の無いスキーマとして赤になる
        self.write(".gitignore", ".stub-bin/\nSchemas/examples/state.json\n")
        self.write("Schemas/state.schema.json", SCHEMA)
        self.write("Schemas/examples/state.json")
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("例が 1 つも無いスキーマ: Schemas/state.schema.json", r.stderr)

    def test_untracked_example_counts_before_git_add(self):
        self.write("Schemas/state.schema.json", SCHEMA)
        self.write("Schemas/examples/state-variant.json")
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_ignored_orphan_example_is_not_reported(self):
        # 無視された書き捨ては CI の木に入らないので、孤児として咎めない
        self.write(".gitignore", ".stub-bin/\nSchemas/examples/scratch.json\n")
        self.write("Schemas/state.schema.json", SCHEMA)
        self.write("Schemas/examples/state.json")
        self.write("Schemas/examples/scratch.json")
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_ignored_schema_is_not_checked(self):
        # 無視されたスキーマは CI の木に無いので、例を求めない
        self.write(".gitignore", ".stub-bin/\nSchemas/draft.schema.json\n")
        self.write("Schemas/state.schema.json", SCHEMA)
        self.write("Schemas/examples/state.json")
        self.write("Schemas/draft.schema.json", SCHEMA)
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == "__main__":
    unittest.main()
