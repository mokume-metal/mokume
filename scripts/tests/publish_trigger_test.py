#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-publish-trigger.py の検査 (#478)。

守るのは 3 つで、どれか 1 つでも抜けると検査は「何も見ていない緑」に倒れる。

- **入力の絞りがあれば赤い** — `paths` / `paths-ignore` は公開に使う入力の写しで、
  写しは必ず古くなる。古くなった症状は「ビルドは緑のまま公開だけが古い」
- **公開の経路が無ければ赤い** — 対象 0 件を「通った」で済ませない
- **鍵が `on` でも `true` でも読める** — YAML 1.1 は裸の `on` を真偽値として読むので、
  引用符の有無で検査が素通りしてはいけない
- **読めない YAML を自分で名乗る** — かつては `check=True` の traceback になり、ruby の
  診断は捨てられていた (#863)。読める形で止まっていたのは `github-yaml-lint` が的の並びで
  先に走るからで、この検査は順序に依存していた

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-publish-trigger.py"

SOUND = """\
name: Pages
on:
  push:
    branches: [main]
  workflow_dispatch:
jobs:
  publish:
    runs-on: macos-latest
    steps:
      - run: make reference OUT=_site
"""


class PublishTriggerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.workflows = Path(self.tmp.name) / "workflows"
        self.workflows.mkdir(parents=True)
        self.addCleanup(self.tmp.cleanup)

    def write(self, name, text):
        (self.workflows / name).write_text(text, encoding="utf-8")

    def run_check(self):
        return subprocess.run(
            ["python3", str(SCRIPT), "--workflows", str(self.workflows)],
            capture_output=True,
            text=True,
        )

    def test_絞りの無い公開のワークフローは通る(self):
        self.write("pages.yml", SOUND)
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pages.yml", result.stdout)

    def test_引用符付きの_on_でも読める(self):
        self.write("pages.yml", SOUND.replace("on:", '"on":'))
        self.assertEqual(self.run_check().returncode, 0)

    def test_paths_で絞ると赤い(self):
        self.write(
            "pages.yml",
            SOUND.replace("    branches: [main]\n", "    branches: [main]\n    paths: ['Sources/**']\n"),
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("paths", result.stderr)

    def test_他のイベントの_paths_ignore_も赤い(self):
        self.write(
            "pages.yml",
            SOUND.replace(
                "  workflow_dispatch:\n",
                "  pull_request:\n    paths-ignore: ['docs/**']\n",
            ),
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("paths-ignore", result.stderr)

    def test_main_への_push_で走らなければ赤い(self):
        self.write("pages.yml", SOUND.replace("branches: [main]", "branches: [release]"))
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("main", result.stderr)

    def test_push_の起動条件が無ければ赤い(self):
        self.write(
            "pages.yml",
            "name: Pages\non:\n  workflow_dispatch:\njobs:\n  publish:\n"
            "    runs-on: macos-latest\n    steps:\n      - run: make reference\n",
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("push", result.stderr)

    def test_公開の経路が無ければ赤い(self):
        # 面を組み立てる的を呼ぶワークフローが 1 本も無い状態。**0 件を緑にしない**
        self.write("ci.yml", "name: CI\non:\n  push:\n    branches: [main]\njobs: {}\n")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("make reference", result.stderr)

    def test_構文の壊れた_YAML_は_ruby_の診断つきで名乗る(self):
        """**traceback にしない。** 順序に依存せず、この検査自身が読めないと言う (#863)。"""
        self.write("pages.yml", SOUND + "  broken: [unclosed\n")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("YAML として読めない", result.stderr)
        self.assertIn("pages.yml", result.stderr)
        # ruby の診断 (何行目の何が壊れているか) を捨てていない
        self.assertIn("line", result.stderr.lower())
        # Python の traceback が出ていない
        self.assertNotIn("Traceback", result.stderr)
        self.assertNotIn("CalledProcessError", result.stderr)

    def test_空の_YAML_も名乗る(self):
        """空のファイルは null になる。対応表でないものを下へ流すと `on:` を探す側が落ちる。"""
        # 的を含む行だけを持つ「YAML としては妥当だが対応表ではない」ファイル
        self.write("pages.yml", "# make reference\n")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("最上位が対応表ではない", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_実物のワークフローが通る(self):
        # 検査の形だけでなく、このリポジトリの実際の配線が満たしていることを見る
        result = subprocess.run(
            ["python3", str(SCRIPT)], cwd=REPO, capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
