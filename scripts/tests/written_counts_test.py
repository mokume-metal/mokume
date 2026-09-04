#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""文書に公開 API の件数を直書きしていないことを見る (#819 で移してきた)。

守っているのは [ADR-0001](../../docs/decisions/0001-founding-principles.md) 原則 8 —
**一覧をリポジトリへ置かない。** 置くと「それが古くないことを守る検査」が要るように
なり、以後すべての変更がその検査に引っかかる。数える必要があるものは
`scripts/api-surface.py` が要るときに組み立てて出す。

## なぜここへ移したか

判定は `root.rglob("*.md")` を読むだけで、**シンボルグラフを 1 バイトも使わない。**
それが `api-surface.py` の中にあったので、`make api` (= `api: build`) の依存でパッケージの
フル再ビルドの後ろに並んでいた — **ドキュメントだけ直した PR も再ビルドを待っていた。**

`make hooks-test` は `-p '*_test.py'` で discover するので、ここに置けば CI にも載り、
Makefile の的は増えない (`api` の仕事はむしろ減る)。判定が独立しているぶん、材料も
ここで完結する。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import re
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# 「公開 API は 128 個」のような書き方。**間に入る語は少しだけ許す** — 「公開されている
# シンボルは 128 本」のような言い換えを取りこぼさないため
COUNT_PATTERN = re.compile(r"公開\s*(?:されている)?\s*(?:シンボル|API)[^\n。]{0,16}?(\d+)\s*(?:個|本)")

# 読まない場所。生成物と外から持ち込んだ文書は対象外
SKIP_PARTS = {".build", ".git", "LICENSES"}


def written_counts(root: Path) -> list[str]:
    """件数を直書きしている箇所を「パス:行番号: 説明」で返す。"""
    problems = []
    for path in sorted(root.rglob("*.md")):
        if any(part in SKIP_PARTS for part in path.parts):
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if COUNT_PATTERN.search(line):
                problems.append(
                    f"{path.relative_to(root)}:{number}: 公開 API の件数が直書きされている。"
                    "数える必要があるものは scripts/api-surface.py から出す"
                )
    return problems


class PatternTest(unittest.TestCase):
    def test_a_written_count_is_found(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "README.md").write_text("公開 API は 128 個ある。\n", encoding="utf-8")
            problems = written_counts(root)
            self.assertEqual(len(problems), 1)
            self.assertIn("README.md:1", problems[0])
            # 直し方まで言う (検査の出力がそのまま手順になる)
            self.assertIn("api-surface.py", problems[0])

    def test_prose_without_a_count_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "README.md").write_text("公開 API の一覧は版ごとに配る。\n", encoding="utf-8")
            self.assertEqual(written_counts(root), [])

    def test_the_wording_variants_are_caught(self):
        """**言い換えを取りこぼさない。** 取りこぼすと、書いた人だけが得をする。"""
        for line in (
            "公開 API は 128 個",
            "公開シンボル 128 本",
            "公開されている API はいま 128 個",
        ):
            with self.subTest(line):
                self.assertIsNotNone(COUNT_PATTERN.search(line), line)

    def test_a_distant_number_is_not_a_count(self):
        """句点を跨いだ数字は別の話である (過検出で文章を縛らない)。"""
        self.assertIsNone(COUNT_PATTERN.search("公開 API の話。ところで 128 個の石がある"))

    def test_generated_places_are_not_read(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / ".build"
            build.mkdir()
            (build / "out.md").write_text("公開 API は 128 個ある。\n", encoding="utf-8")
            self.assertEqual(written_counts(root), [])


class RepositoryTest(unittest.TestCase):
    def test_this_repository_writes_no_counts(self):
        """**本番の判定。** 以前は `make api` (フル再ビルドの後ろ) がこれを見ていた。"""
        problems = written_counts(REPO)
        self.assertEqual(problems, [], "\n".join(problems))

    def test_the_check_left_the_symbol_graph_tool(self):
        """写しが残っていると、片方だけ直す事故が起きる。

        **報告は行だけに絞る。** ファイル全体を assertNotIn に渡すと、失敗したときに
        3 万字が出て何が起きたか読めない (site_source / guard-lib の検査で学んだ)。
        """
        path = REPO / "scripts" / "api-surface.py"
        found = [
            f"  {path.name}:{number}: {line.strip()}"
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1)
            if "check_no_written_counts" in line or "COUNT_PATTERN" in line
        ]
        if found:
            self.fail(
                "判定の写しがシンボルグラフの道具に残っている:\n"
                + "\n".join(found)
                + "\n\nこちら (written_counts_test.py) が正典 — あちらに置くと、"
                "ドキュメントだけ直した PR までフル再ビルドを待つ (#819)。"
            )


if __name__ == "__main__":
    unittest.main()
