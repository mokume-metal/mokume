#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-docs-links.py の検査 (#90)。

この検査が守るのは 2 つで、向きが逆なので両方を固定する。

- **指し先の無いリンクは赤い** — 参照先のファイルが無い、見出しが無い
- **書き方の例示では赤くならない** — コード塊の中のリンク、外部 URL

後者を落とすと直しようのない赤が出て、規範文書にコマンド例を書けなくなる。
このリポジトリの `.md` は 116 本中 83 本が changelog.d の断片で、残りは
コマンド例を大量に含む規範文書なので、偽陽性の害は本物の切れより大きい。

一時ディレクトリに小さな git リポジトリを組んで実行する (検査は
`git ls-files` で対象を集めるため、追跡下に置かないと何も見ない)。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-docs-links.py"


def _load():
    spec = importlib.util.spec_from_file_location("check_docs_links", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


checker = _load()


class DocsLinksTest(unittest.TestCase):
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

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def run_check(self):
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True)
        return subprocess.run(
            ["python3", str(SCRIPT)], cwd=self.root, capture_output=True, text=True
        )

    # --- 赤くなるべきもの ---

    def test_missing_file_is_reported_with_path_and_line(self):
        self.write("a.md", "# a\n\n[壊れた](nope.md)\n")
        r = self.run_check()
        self.assertEqual(r.returncode, 1)
        self.assertIn("a.md:3", r.stderr)
        self.assertIn("nope.md", r.stderr)

    def test_missing_anchor_lists_available_anchors(self):
        self.write("a.md", "# a\n\n[節へ](b.md#no-such)\n")
        self.write("b.md", "# b\n\n## 正典の在処\n")
        r = self.run_check()
        self.assertEqual(r.returncode, 1)
        self.assertIn("見出しが無い", r.stderr)
        # 踏んだ人が出力だけで書き直せること (この検査の要)
        self.assertIn("#正典の在処", r.stderr)

    def test_missing_anchor_in_same_file(self):
        self.write("a.md", "# ある見出し\n\n[自分の中](#無い見出し)\n")
        r = self.run_check()
        self.assertEqual(r.returncode, 1)
        self.assertIn("#ある見出し", r.stderr)

    def test_reference_style_link_is_checked_when_used(self):
        self.write("a.md", "# a\n\n[参照][ref] を使う。\n\n[ref]: nope.md\n")
        r = self.run_check()
        self.assertEqual(r.returncode, 1)
        self.assertIn("nope.md", r.stderr)

    def test_no_markdown_at_all_fails(self):
        # 緑のまま何も見ていない状態を作らない (check-file-modes.sh と同じ守り)
        self.write("README.txt", "not markdown")
        r = self.run_check()
        self.assertEqual(r.returncode, 1)
        self.assertIn("検査が成立していない", r.stderr)

    # --- 赤くなってはいけないもの ---

    def test_valid_links_pass(self):
        self.write(
            "a.md",
            "# 見出し 一つ目\n\n"
            "[隣](b.md)\n"
            "[節](b.md#節-一)\n"
            "[自分](#見出し-一つ目)\n"
            "[ディレクトリ](sub/)\n"
            "[スクリプト](s.sh)\n",
        )
        self.write("b.md", "# b\n\n## 節 一\n")
        self.write("sub/c.md", "# c\n")
        self.write("s.sh", "echo hi\n")
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("ok:", r.stdout)

    def test_links_inside_code_are_ignored(self):
        self.write(
            "a.md",
            "# a\n\n"
            "```markdown\n[フェンスの中](totally-missing.md)\n```\n\n"
            "インラインの `![](missing.md)` も拾わない。\n",
        )
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_external_urls_are_ignored(self):
        self.write(
            "a.md",
            "# a\n\n[外](https://example.invalid/nope)\n"
            "[メール](mailto:nobody@example.invalid)\n",
        )
        self.assertEqual(self.run_check().returncode, 0)

    def test_unused_reference_definition_is_ignored(self):
        # 定義だけあって誰も使っていないものを赤くしても直す動機が無い
        self.write("a.md", "# a\n\n本文。\n\n[unused]: nope.md\n")
        self.assertEqual(self.run_check().returncode, 0)

    def test_anchor_on_non_markdown_is_not_checked(self):
        self.write("a.md", "# a\n\n[行](s.sh#L10)\n")
        self.write("s.sh", "echo hi\n")
        self.assertEqual(self.run_check().returncode, 0)

    def test_root_relative_link_resolves_from_repository_root(self):
        self.write("sub/a.md", "# a\n\n[ルート起点](/b.md)\n")
        self.write("b.md", "# b\n")
        self.assertEqual(self.run_check().returncode, 0)

    def test_percent_encoded_path_is_decoded(self):
        self.write("a.md", "# a\n\n[空白入り](name%20with%20space.md)\n")
        self.write("name with space.md", "# n\n")
        self.assertEqual(self.run_check().returncode, 0)

    # --- 行番号 ---

    def test_line_number_survives_multiline_inline_code(self):
        # インラインコードを潰すときに改行まで空白へ変えると、以降の行番号が
        # 全部ずれる。潰した後も改行が残っていることを行番号で確かめる
        self.write(
            "a.md",
            "# a\n\n`複数行に\nまたがる` コード。\n\n[壊れた](nope.md)\n",
        )
        r = self.run_check()
        self.assertEqual(r.returncode, 1)
        self.assertIn("a.md:6", r.stderr)

    # --- アンカーの綴り ---

    def test_anchor_spelling_follows_github(self):
        anchors = checker.anchors_of(
            "# AGENTS.md\n"
            "## 正典の在処\n"
            "## Issue の分類\n"
            "## 置き場 — 情報の寿命で決める\n"
            "### 1. 正本を `.github/rulesets/*.json` に置く\n"
            "## **強調**を含む\n"
            "## [リンク](https://example.invalid) を含む\n"
            "## MY_VAR の話\n"
        )
        self.assertEqual(
            anchors,
            [
                "agentsmd",
                "正典の在処",
                "issue-の分類",
                "置き場--情報の寿命で決める",
                # インラインコードの中身はアンカーに残る (記号だけが落ちる)
                "1-正本を-githubrulesetsjson-に置く",
                "強調を含む",
                "リンク-を含む",
                # `_` は GitHub が残すので残す (緩い比較の側で吸収する)
                "my_var-の話",
            ],
        )

    def test_duplicate_headings_get_numeric_suffix(self):
        anchors = checker.anchors_of("## 節\n## 節\n## 節\n")
        self.assertEqual(anchors, ["節", "節-1", "節-2"])

    def test_headings_inside_code_fences_are_not_anchors(self):
        anchors = checker.anchors_of("# 本物\n\n```\n# 偽物\n```\n")
        self.assertEqual(anchors, ["本物"])

    def test_anchor_match_is_loose_about_punctuation(self):
        # GitHub の綴りの規則は公表仕様ではないので、約物の扱いのずれで
        # 「GitHub では動くリンク」を赤にしない。指し先の不在だけを見る
        self.write("a.md", "# a\n\n[節](b.md#節-一-つ目)\n[下線](b.md#myvar-の話)\n")
        self.write("b.md", "# b\n\n## 節 一 つ目\n\n## MY_VAR の話\n")
        self.assertEqual(self.run_check().returncode, 0)


if __name__ == "__main__":
    unittest.main()
