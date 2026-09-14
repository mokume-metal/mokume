#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-agents-md-size.py の検査 (#737)。

固定したいのは 3 つ:

- **ラチェットは等号でしか通さない** — 記録値より長くても短くても赤
- **数え方がロケールに依らない** — `LC_ALL=C` でも日本語をバイトではなく文字で数える
  (#737 の起票はここを踏んで単位を取り違えた)
- **節はコードフェンスの中の `## ` で割れない**

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-agents-md-size.py"


def _load():
    spec = importlib.util.spec_from_file_location("check_agents_md_size", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


size = _load()

DOC = "# AGENTS.md\n\n冒頭。\n\n## 進め方\n\n規律。\n\n## 描画\n\n```bash\n## これは見出しではない\n```\n"


class RatchetTest(unittest.TestCase):
    def test_equal_is_green(self):
        self.assertEqual(size.check(DOC, len(DOC)), [])

    def test_longer_than_highwater_is_red_with_offload_targets(self):
        problems = size.check(DOC + "足した。\n", len(DOC))
        self.assertEqual(len(problems), 1)
        self.assertIn("5 字超えている", problems[0])
        self.assertIn("経緯と実測は Issue / PR", problems[0])

    def test_shorter_than_highwater_is_also_red(self):
        shorter = DOC.replace("規律。\n\n", "")
        problems = size.check(shorter, len(DOC))
        self.assertEqual(len(problems), 1)
        self.assertIn(f"記録値を {len(shorter)} へ下げてください", problems[0])
        self.assertIn("縮めた分は戻せない", problems[0])


class SectionTest(unittest.TestCase):
    def test_heading_inside_fence_does_not_split(self):
        titles = [t for t, _ in size.sections(DOC)]
        self.assertEqual(titles, ["(冒頭)", "進め方", "描画"])

    def test_subsection_counts_toward_parent(self):
        doc = "## 親\n\n### 子\n\n本文\n"
        self.assertEqual(size.sections(doc), [("(冒頭)", 0), ("親", len(doc))])

    def test_sections_add_up_to_whole(self):
        parts = size.sections(DOC)
        # 節の間の改行 1 つは節に数えない
        self.assertEqual(sum(n for _, n in parts) + len(parts) - 1, len(DOC))

    def test_section_over_limit_is_named(self):
        doc = "## 短い\n\nあ\n\n## 長い節\n\n" + "い" * 50 + "\n"
        problems = size.check(doc, len(doc), limit=40)
        self.assertEqual(len(problems), 1)
        self.assertIn("節「長い節」", problems[0])

    def test_section_at_limit_is_green(self):
        doc = "## 節\n\n" + "う" * 10
        limit = size.sections(doc)[1][1]
        self.assertEqual(size.check(doc, len(doc), limit=limit), [])


class CommandTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.agents = Path(self.tmp.name) / "AGENTS.md"
        self.highwater = Path(self.tmp.name) / "highwater.txt"
        self.agents.write_text(DOC, encoding="utf-8")

    def run_check(self, env_extra=None):
        env = {**os.environ, **(env_extra or {})}
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--agents", str(self.agents), "--highwater", str(self.highwater)],
            capture_output=True, text=True, encoding="utf-8", env=env,
        )

    def test_counts_characters_not_bytes_under_c_locale(self):
        # 日本語を含むので、バイトで数えれば記録値と食い違って赤くなる
        self.assertNotEqual(len(DOC), len(DOC.encode("utf-8")))
        self.highwater.write_text(f"{len(DOC)}\n", encoding="utf-8")
        result = self.run_check({"LC_ALL": "C", "LC_CTYPE": "C", "LANG": "C"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"{len(DOC)} 字", result.stdout)

    def test_red_prints_sections(self):
        self.highwater.write_text(f"{len(DOC) + 1}\n", encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("下げてください", result.stderr)
        self.assertIn("進め方", result.stderr)

    def test_highwater_must_be_a_single_number(self):
        self.highwater.write_text("約 20000\n", encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("字数 1 つだけを持つ", result.stderr)

    def test_highwater_skips_comment_lines(self):
        self.highwater.write_text(f"# 見出しのコメント\n#\n# 説明 123\n{len(DOC)}\n", encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_highwater_with_two_values_is_red(self):
        self.highwater.write_text(f"{len(DOC)}\n{len(DOC)}\n", encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()
