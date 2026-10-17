#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/markdown-live.sh の `md_kind` の検査 (#2816)。

PR 本文・Issue 本文・ADR を行で読む検査が共通で使う「その行は生きているか」の読み方である。
**期待は GitHub の描画 API (POST /markdown) で確かめた結果に合わせてある** — 各ケースの
コメントが、描画で何が起きたかを書いている。CommonMark を読んだ見立てだけで書いたものは無い。

戻り値は 0 (生きた行)・1 (コードブロックの開き・中身・閉じ)・2 (HTML コメントのブロック)。
読み手ごとの検査 (review_gate_test など) は「その読み手がこの読み方を通すか」を見る。ここは
読み方そのものを見る。

mawk (Ubuntu の既定の awk。pr-gate は既定ブランチ版をこれで走らせる)・BSD awk (macOS)・gawk の
どれでも同じ結果になることを、手元に在る awk のすべてで確かめる。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import shutil
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LIB = REPO / "scripts" / "markdown-live.sh"

AWKS = [name for name in ("awk", "mawk", "gawk") if shutil.which(name)]


def kinds(text, awk="awk"):
    """text の各行の md_kind を並べて返す。"""
    script = f'. "$1" && {awk} "$MARKDOWN_LINES_AWK"\'{{ print md_kind($0) }}\''
    result = subprocess.run(
        ["/bin/bash", "-c", script, "markdown-live", str(LIB)],
        input=text, capture_output=True, text=True, check=True,
    )
    return [int(k) for k in result.stdout.split()]


def live_lines(text):
    script = '. "$1" && markdown_live_lines'
    result = subprocess.run(
        ["/bin/bash", "-c", script, "markdown-live", str(LIB)],
        input=text, capture_output=True, text=True, check=True,
    )
    return result.stdout.split("\n")[:-1]


class MdKindTest(unittest.TestCase):
    def check(self, name, text, expected):
        for awk in AWKS:
            with self.subTest(case=name, awk=awk):
                self.assertEqual(kinds(text, awk), expected, text)

    # --- フェンス (#2768 から引き継いだ規則) -------------------------------

    def test_backtick_and_tilde_fences(self):
        self.check("backtick", "a\n```\n## x\n```\nb\n", [0, 1, 1, 1, 0])
        self.check("tilde", "a\n~~~\n## x\n~~~\nb\n", [0, 1, 1, 1, 0])

    def test_a_longer_fence_is_closed_only_by_an_equal_or_longer_one(self):
        self.check("longer", "````\n```\n## x\n```\n````\nb\n", [1, 1, 1, 1, 1, 0])

    def test_a_fence_of_the_other_kind_is_content(self):
        self.check("tilde in backtick", "```\n~~~\n## x\n~~~\n```\nb\n", [1, 1, 1, 1, 1, 0])
        self.check("backtick in tilde", "~~~\n```\n## x\n```\n~~~\nb\n", [1, 1, 1, 1, 1, 0])

    def test_a_closing_fence_with_text_after_it_does_not_close(self):
        self.check("info on close", "```\n```ruby\n## x\n```\nb\n", [1, 1, 1, 1, 0])

    def test_an_unclosed_fence_runs_to_the_end(self):
        self.check("unclosed", "a\n```\n## x\nb\n", [0, 1, 1, 1])

    def test_four_columns_is_not_a_fence_but_three_is(self):
        self.check("4 columns", "    ```\n## x\n", [0, 0])
        self.check("3 columns", "   ```\nx\n   ```\n## b\n", [1, 1, 1, 0])
        # 閉じの字下げも 3 桁まで。4 桁の ``` は閉じではなく中身
        self.check("4 columns close", "```\n    ```\nx\n", [1, 1, 1])
        # 1〜3 桁の字下げは ~~~ でも同じ (#2816 f)
        self.check("indented tilde", " ~~~\nx\n ~~~\n## b\n", [1, 1, 1, 0])

    def test_a_backtick_fence_whose_info_has_a_backtick_is_not_a_fence(self):
        self.check("inline code", "``` a`b\n## x\n", [0, 0])

    def test_crlf_lines(self):
        self.check("crlf", "```\r\nx\r\n```\r\n## b\r\n", [1, 1, 1, 0])

    # --- HTML コメント (#2816 a) --------------------------------------------
    # 描画 API: 行頭から始まるコメントは HTML ブロックで `-->` の行で終わる。中の ``` は
    # フェンスを開かず、後ろの `## B` は見出しとして描かれる

    def test_a_fence_marker_inside_a_block_comment_is_not_a_fence(self):
        self.check("comment", "## A\n<!--\n```\n-->\n## B\n", [0, 2, 2, 2, 0])

    def test_a_block_comment_on_one_line_ends_on_that_line(self):
        self.check("one line", "<!-- x -->\n```\nx\n```\n", [2, 1, 1, 1])

    def test_a_heading_inside_a_block_comment_is_not_a_heading(self):
        self.check("heading", "<!--\n## 反証\n-->\n## B\n", [2, 2, 2, 0])

    def test_an_unclosed_block_comment_hides_the_rest(self):
        # 描画 API: 後ろの `## B` まで見出しとして描かれない
        self.check("unclosed", "## A\n<!--\n```\n\n## B\n", [0, 2, 2, 2, 2])

    def test_a_comment_started_mid_line_does_not_protect_a_fence(self):
        # 描画 API: `text <!--` は保護されず、次の行頭の ``` がフェンスを開く
        # (`## B` はコードブロックの中に描かれた)
        self.check("mid-line", "text <!--\n```\n-->\n## B\n", [0, 1, 1, 1])

    def test_a_comment_start_inside_a_fence_is_content(self):
        self.check("in fence", "```\n<!--\n```\n## B\n", [1, 1, 1, 0])

    def test_an_indented_comment_of_three_columns_is_a_block(self):
        self.check("3 columns", "   <!--\n```\n-->\n## B\n", [2, 2, 2, 0])

    # --- リスト項目の中のフェンス (#2816 b) ---------------------------------
    # 描画 API: 項目の中のフェンスは、項目の内容の幅より浅い非空行で暗黙に閉じる

    def test_a_fence_in_a_list_item_closes_at_a_shallower_line_after_a_blank(self):
        self.check("blank", "- item\n  ```\n  code\n\n## B\n", [0, 1, 1, 1, 0])

    def test_a_fence_in_a_list_item_closes_at_a_shallower_line_without_a_blank(self):
        self.check("no blank", "- item\n  ```\n  code\n## B\n", [0, 1, 1, 0])

    def test_a_line_at_the_item_indent_is_still_inside_the_fence(self):
        # 描画 API: `  ## B` (項目の幅と同じ) はコードブロックの中。col 0 の text で閉じる
        self.check("same indent", "- item\n  ```\n  code\n\n  ## B\n\ntext\n", [0, 1, 1, 1, 1, 1, 0])

    def test_an_ordered_item_uses_its_own_content_width(self):
        self.check("ordered", "1. item\n   ```\n   code\n\n## B\n", [0, 1, 1, 1, 0])
        # 「1. 」の幅 (3) より浅い 2 桁の行で閉じる
        self.check("ordered shallow", "1. item\n   ```\n  code\n", [0, 1, 0])

    def test_a_one_column_line_closes_a_two_column_item(self):
        self.check("one column", "- item\n  ```\n code\n## B\n", [0, 1, 0, 0])

    def test_a_fence_on_the_marker_line_belongs_to_the_item(self):
        self.check("marker line", "- ```\n  code\n## B\n", [1, 1, 0])

    def test_a_fence_after_the_list_closed_is_not_the_items(self):
        # 描画 API: リストが閉じた後の字下げ 2 桁のフェンスは項目に属さず、浅い行では閉じない
        self.check("stale", "- item\n\npara\n\n  ```\ncode\n## B\n", [0, 0, 0, 0, 1, 1, 1])

    def test_a_nested_item_closes_with_its_own_width(self):
        # 描画 API: `  more` (外の項目の幅) は内の項目のフェンスを閉じ、外の項目の本文になる
        self.check("nested", "- a\n  - b\n    ```\n    x\n  more\n\n## B\n", [0, 0, 1, 1, 0, 0, 0])

    def test_a_lazy_continuation_line_keeps_the_item_open(self):
        # 描画 API: 項目の段落の続きの行 (字下げ 0 の text) は項目を閉じず、続く字下げ 2 桁の
        # フェンスは項目の中にあって、浅い `## B` で閉じる
        self.check("lazy", "- item\ntext\n  ```\n  code\n## B\n", [0, 0, 1, 1, 0])

    def test_a_blank_line_before_the_shallow_line_closes_the_item(self):
        # 描画 API: 空行を挟むと text は項目の外 (段落)。字下げ 2 桁のフェンスは最上位のもので、
        # 浅い `## B` では閉じない
        self.check("blank", "- item\n\ntext\n  ```\n  code\n## B\n", [0, 0, 0, 1, 1, 1])

    def test_a_column_zero_fence_after_a_list_is_top_level(self):
        self.check("top level", "- item\n```\ncode\n```\nx\n", [0, 1, 1, 1, 0])

    def test_a_properly_closed_fence_in_an_item_is_unchanged(self):
        self.check("closed", "- item\n  ```\n  code\n  ```\n## B\n", [0, 1, 1, 1, 0])

    def test_a_comment_in_a_list_item_protects_a_fence(self):
        # 描画 API: 項目の中のコメントも中の ``` をフェンスにしない
        self.check("comment in item", "- item\n  <!--\n  ```\n  -->\n## B\n", [0, 2, 2, 2, 0])


class MarkdownLiveLinesTest(unittest.TestCase):
    def test_fenced_lines_become_blank_and_the_line_count_is_kept(self):
        text = "## A\n```\nsecret\n```\ntail\n"
        self.assertEqual(live_lines(text), ["## A", "", "", "", "tail"])

    def test_comment_lines_are_kept(self):
        # コメントを取り除く側は別にある (review-gate の strip_html_comments)
        text = "<!--\nnote\n-->\ntail\n"
        self.assertEqual(live_lines(text), ["<!--", "note", "-->", "tail"])

    def test_a_body_without_a_trailing_newline_is_read(self):
        self.assertEqual(live_lines("a\n```\nx"), ["a", "", ""])


if __name__ == "__main__":
    unittest.main()
