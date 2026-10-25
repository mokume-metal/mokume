#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/release.py の検査。

守りたいのは 5 つ:
  1. 版の上げ幅が履歴どおりに決まる (1.0 未満では破壊的変更も minor)
  2. 中身の無い版を出さない (断片が 1 つも増えていなければ中断)
  3. 書いた断片がノートから黙って消えない (知らない分類も落とさない)
  4. 組めない形の断片は main に入る前に名指しで落ちる (#91)
  5. 書いた本文がまるごと 1 つの項目の中に描かれる (#446)
  6. 描画に触れた PR の絵が「この版の絵」に並び、それ以外は載らない (#2109)

git は一時リポジトリを本物で回す — 「前回のタグ以降に追加されたか」は履歴の話で、
そこを模造すると検査が確かめたい当のものを確かめなくなる。
"""

import contextlib
import importlib.util
import io
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
RELEASE = REPO / "scripts" / "release.py"

spec = importlib.util.spec_from_file_location("release", RELEASE)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class BumpTests(unittest.TestCase):
    """版の上げ幅。"""

    def test_breaking_before_one_zero_raises_minor(self):
        # 0.x は形が動くことを織り込んだ区間なので、破壊的変更でも major を上げない
        self.assertEqual(release.bump_for(["feat(core)!: 形を変える"], (0, 3, 2)), (0, 4, 0))
        self.assertEqual(
            release.bump_for(["fix: 直す", "BREAKING CHANGE: 形が変わる"], (0, 3, 2)),
            (0, 4, 0),
        )

    def test_feature_raises_minor(self):
        self.assertEqual(release.bump_for(["feat(draw): 円を足す"], (0, 3, 2)), (0, 4, 0))

    def test_anything_else_raises_patch(self):
        self.assertEqual(
            release.bump_for(["fix: 直す", "docs: 書く", "chore: 片付ける"], (0, 3, 2)),
            (0, 3, 3),
        )

    def test_after_one_zero_breaking_raises_major(self):
        self.assertEqual(release.bump_for(["feat!: 形を変える"], (1, 2, 3)), (2, 0, 0))
        self.assertEqual(release.bump_for(["feat: 足す"], (1, 2, 3)), (1, 3, 0))
        self.assertEqual(release.bump_for(["fix: 直す"], (1, 2, 3)), (1, 2, 4))

    def test_a_type_that_merely_starts_with_feat_is_not_a_feature(self):
        # "feature:" や "feats:" を feat と取り違えない
        self.assertEqual(release.bump_for(["feats: 何か"], (0, 1, 0)), (0, 1, 1))


class NotesTests(unittest.TestCase):
    """ノートの組み立て。"""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def fragment(self, name: str, body: str) -> Path:
        path = self.root / name
        # 検査が書く断片は本物と同じ形にする。ここは帰属の宣言ではないので、
        # REUSE の走査からは外す
        # REUSE-IgnoreStart
        path.write_text(
            "<!--\nSPDX-FileCopyrightText: 2026 mokume-metal\n"
            f"SPDX-License-Identifier: MIT\n-->\n\n{body}\n",
            encoding="utf-8",
        )
        # REUSE-IgnoreEnd
        return path

    def test_groups_by_category_in_a_fixed_order(self):
        notes = release.notes(
            [
                self.fragment("b.fix.md", "直した"),
                self.fragment("a.feature.md", "足した"),
                self.fragment("c.breaking.md", "変えた"),
            ]
        )
        self.assertLess(notes.index("破壊的変更"), notes.index("新機能"))
        self.assertLess(notes.index("新機能"), notes.index("修正"))

    def test_drops_the_license_header(self):
        notes = release.notes([self.fragment("a.feature.md", "足した")])
        self.assertNotIn("SPDX", notes)
        self.assertIn("足した", notes)
        self.assertNotIn("- 足した", notes)

    def test_keeps_entries_with_an_unknown_category(self):
        # 知らない分類を落とすと「書いたのにノートに出ない」が黙って起きる
        notes = release.notes([self.fragment("a.security.md", "塞いだ")])
        self.assertIn("塞いだ", notes)


class EntryTests(unittest.TestCase):
    """項目は箇条書きに入れず、畳みと段落を空行で区切って並べる (#3011)。"""

    def test_a_single_sentence_entry_is_a_paragraph(self):
        self.assertEqual(release.as_entry("足した。"), "足した。")

    def test_a_hard_wrapped_single_sentence_is_kept_as_written(self):
        self.assertEqual(release.as_entry("折り返した\n続き。"), "折り返した\n続き。")

    def test_a_multi_paragraph_entry_folds_without_a_list_or_indent(self):
        self.assertEqual(
            release.as_entry("1 段落目。\n\n2 段落目。"),
            "<details><summary>1 段落目。</summary>\n"
            "\n"
            "2 段落目。\n"
            "\n"
            "</details>",
        )

    def test_a_blank_line_carries_no_trailing_space(self):
        for line in release.as_entry("上。\n\n下。").split("\n"):
            self.assertEqual(line, line.rstrip())

    def test_entries_are_separated_by_a_blank_line(self):
        # 区切らないと、`</details>` の後の段落が HTML の塊に呑まれて Markdown として描かれない
        self.assertEqual(
            release.entries_of(["上。続き。", "下。"]),
            "<details><summary>上。</summary>\n\n続き。\n\n</details>\n\n下。",
        )

    def test_real_notes_carry_no_list_around_the_folds(self):
        # 本物の changelog.d で組み、畳みが箇条書きに入らず、どの `</details>` の後も空行か
        # 本文の終わりであること
        lines = release.notes(release.all_fragments()).split("\n")
        self.assertGreater(lines.count("</details>"), 0, "畳んだ項目が 1 つも無い")
        self.assertEqual([line for line in lines if line.startswith("- <details>")], [])
        unseparated = [
            following for line, following in zip(lines, lines[1:])
            if line == "</details>" and following.strip()
        ]
        self.assertEqual(unseparated, [], f"{len(unseparated)} 件の畳みの直後に空行が無い")


def folded_body(item: str) -> str:
    """畳んだ項目の、開いた中身。"""
    return item[item.index("</summary>") + len("</summary>"): item.index("</details>")].strip()


class InlineHtmlTests(unittest.TestCase):
    """要約を `<summary>` に置く HTML へ直す (#2871)。"""

    def test_bold_becomes_strong(self):
        self.assertEqual(release.inline_html("**直した。**"), "<strong>直した。</strong>")

    def test_code_is_escaped_and_not_read_as_markup(self):
        self.assertEqual(release.inline_html("`a**b**<c` と書く"), "<code>a**b**&lt;c</code> と書く")

    def test_a_link_becomes_an_anchor(self):
        self.assertEqual(
            release.inline_html("直した ([#1](https://example.com/1))。"),
            '直した (<a href="https://example.com/1">#1</a>)。',
        )

    def test_an_autolink_becomes_an_anchor(self):
        self.assertEqual(
            release.inline_html("<https://mokume.org/> の入口"),
            '<a href="https://mokume.org/">https://mokume.org/</a> の入口',
        )

    def test_bare_markup_characters_are_escaped(self):
        self.assertEqual(release.inline_html("a < b & c"), "a &lt; b &amp; c")

    def test_a_line_break_becomes_a_space(self):
        # `<summary>` の中に改行を残さない (空行になれば HTML の塊が切れる)
        self.assertEqual(release.inline_html("折り返した\n続き。"), "折り返した 続き。")


class SummaryTests(unittest.TestCase):
    """見せる要約は最初の文で、全文は畳む (#2766)。"""

    def test_the_summary_is_the_first_sentence(self):
        self.assertEqual(release.summary_of("足した。使い方はこう。"), "足した。")

    def test_the_summary_stays_in_the_first_paragraph(self):
        self.assertEqual(release.summary_of("文の終わりが無い\n\n次の段落。"), "文の終わりが無い")

    def test_an_english_sentence_ends_at_a_period_and_a_space(self):
        self.assertEqual(
            release.summary_of("Works like p5.js in v0.27.0 now. More follows."),
            "Works like p5.js in v0.27.0 now.",
        )

    def test_a_period_in_code_or_brackets_does_not_end_the_sentence(self):
        self.assertEqual(
            release.summary_of("`a。b` と書ける (p5.js と同じ。[#1](https://example.com/1))。続き。"),
            "`a。b` と書ける (p5.js と同じ。[#1](https://example.com/1))。",
        )

    def test_a_bold_sentence_keeps_its_closing_marks(self):
        self.assertEqual(
            release.summary_of("**直しました。** これまでは違った。"), "**直しました。**"
        )

    def test_a_single_sentence_entry_is_not_folded(self):
        self.assertNotIn("<details>", release.as_entry("足した。"))
        self.assertNotIn("<details>", release.as_entry("足した。\n"))

    def test_the_summary_and_the_folded_body_make_the_whole_entry(self):
        # 開いた中身は要約の後から始まり、要約と合わせて全文になる (#2871)
        entry = "変えた。\n\n移行:\n\n- `a` は `b` へ\n- `c` は消えた"
        item = release.as_entry(entry)
        self.assertTrue(item.startswith("<details><summary>変えた。</summary>\n\n移行:\n"))
        self.assertEqual(folded_body(item), "移行:\n\n- `a` は `b` へ\n- `c` は消えた")

    def test_a_summary_cut_mid_paragraph_opens_on_the_rest_of_it(self):
        item = release.as_entry("足した。使い方はこう。\n\n次の段落。")
        self.assertEqual(folded_body(item), "使い方はこう。\n\n次の段落。")

    def test_no_item_carries_a_separate_label_line(self):
        # 「詳しく」の札の行は出ない。要約そのものが開く札になる (#2871)
        item = release.as_entry("変えた。続き。")
        self.assertEqual(item.split("\n")[0], "<details><summary>変えた。</summary>")
        self.assertNotIn("詳しく", item)

    def test_real_summaries_carry_no_raw_markdown(self):
        # 本物の changelog.d で、`<summary>` に描かれない Markdown の記号が残らないこと
        rendered = release.notes(release.all_fragments())
        summaries = re.findall(r"^<details><summary>(.*?)</summary>$", rendered, flags=re.MULTILINE)
        self.assertGreater(len(summaries), 0, "畳んだ項目が 1 つも無い")
        raw = [s for s in summaries if re.search(r"\*\*|`|\]\(", re.sub(r"<code>.*?</code>", "", s))]
        self.assertEqual(raw, [], f"{len(raw)} 件の要約に Markdown の記号が残っている")

    def test_real_notes_show_far_less_than_they_fold(self):
        # 本物の changelog.d を材料に、畳まずに見える分が全体の半分を下回ること
        rendered = release.notes(release.all_fragments())
        shown = re.sub(r"<details>.*?</details>", "", rendered, flags=re.DOTALL)
        self.assertLess(len(shown), len(rendered) / 2)


class LintTests(unittest.TestCase):
    """断片の書式 (#91)。

    **壊れ方ごとに 1 件ずつ置いて赤くなることを見る。** 正しい断片だけの群で緑に
    なることも同じだけ大事で、偽陽性を出す検査は「赤いのが普通」にされて死ぬ。
    """

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def fragment(self, name: str, body: str = "足した。") -> Path:
        path = self.root / name
        # REUSE-IgnoreStart
        path.write_text(
            "<!--\nSPDX-FileCopyrightText: 2026 mokume-metal\n"
            f"SPDX-License-Identifier: MIT\n-->\n\n{body}",
            encoding="utf-8",
        )
        # REUSE-IgnoreEnd
        return path

    def problems(self, name: str, body: str = "足した。") -> list[str]:
        return release.problems_of(self.fragment(name, body))

    def test_a_well_formed_fragment_has_no_problems(self):
        for name in ("a.feature.md", "b.fix.md", "c.docs.md", "d.perf.md", "e.breaking.md"):
            with self.subTest(name=name):
                self.assertEqual(self.problems(name), [])

    def test_a_long_kebab_case_slug_is_fine(self):
        self.assertEqual(self.problems("seedable-random-and-noise.feature.md"), [])

    def test_an_absolute_link_is_fine(self):
        self.assertEqual(
            self.problems("a.feature.md", "[ADR-0001](https://example.com/adr) を見る。"),
            [],
        )

    def test_an_image_hosted_outside_is_fine(self):
        # 証跡の絵は外部ホスティングの URL で入る (リポジトリにコミットしない)
        self.assertEqual(
            self.problems("a.feature.md", "![絵](https://example.com/a.png)"), []
        )

    def test_an_image_with_a_relative_target_is_named(self):
        # 画像を特別扱いしない — 相対パスが壊れる理由はリンクと同じ
        problems = self.problems("a.feature.md", "![絵](shots/a.png)")
        self.assertEqual(len(problems), 1)
        self.assertIn("shots/a.png", problems[0])

    def test_a_misspelled_category_is_named(self):
        problems = self.problems("a.fixes.md")
        self.assertEqual(len(problems), 1)
        self.assertIn("fixes", problems[0])
        # 使える綴りは SECTIONS からその場で出す。README にも検査にも写しを作らない
        for known, _ in release.SECTIONS:
            self.assertIn(known, problems[0])

    def test_a_wrong_extension_is_named(self):
        self.assertEqual(len(self.problems("a.feature.markdown")), 1)

    def test_a_missing_category_is_named(self):
        # category_of は形の崩れた名前を既定の "feature" で黙って通す。
        # ここで落とさないと分類の取り違えが誰にも見えない
        self.assertEqual(release.category_of(self.fragment("a.md")), "feature")
        self.assertEqual(len(self.problems("a.md")), 1)

    def test_a_slug_that_is_not_kebab_case_is_named(self):
        for name in ("CamelCase.fix.md", "snake_case.fix.md", "-leading.fix.md"):
            with self.subTest(name=name):
                self.assertEqual(len(self.problems(name)), 1)

    def test_an_empty_body_is_named(self):
        # SPDX ヘッダだけの断片。ノートには中身の無い項目が出る
        self.assertEqual(len(self.problems("a.feature.md", "")), 1)

    def test_a_relative_link_is_named(self):
        problems = self.problems("a.feature.md", "[ADR](../docs/decisions/0001.md) を見る。")
        self.assertEqual(len(problems), 1)
        self.assertIn("../docs/decisions/0001.md", problems[0])

    def test_an_anchor_only_link_is_named(self):
        self.assertEqual(len(self.problems("a.feature.md", "[下](#形式) を見る。")), 1)

    def test_a_reference_style_link_is_named(self):
        # 定義がこのファイルに残るので、ノートに載った時点で必ず壊れる
        problems = self.problems("a.feature.md", "[ADR][adr] を見る。\n\n[adr]: https://example.com")
        self.assertEqual(len(problems), 1)
        self.assertIn("[ADR][adr]", problems[0])

    def test_it_reports_every_problem_of_one_fragment(self):
        # 1 件目で止めると、直すたびに走らせ直すことになる
        self.assertEqual(len(self.problems("Broken.md", "")), 2)

    def test_the_readme_is_not_a_fragment(self):
        (self.root / "README.md").write_text("案内\n", encoding="utf-8")
        self.fragment("a.feature.md")
        self.assertEqual(
            [f.name for f in release.all_fragments(self.root)], ["a.feature.md"]
        )


class HistoryTests(unittest.TestCase):
    """履歴から見た「今回ぶんの断片」。"""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "test")
        # 検査用の使い捨てリポジトリでは署名しない (手元の既定が署名を要求していても
        # 通るように。鍵の有無で結果が変わる検査にしない)
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        (self.root / "changelog.d").mkdir()
        self.original_repo = release.REPO
        release.REPO = self.root

    def tearDown(self):
        release.REPO = self.original_repo
        self.directory.cleanup()

    def git(self, *args: str):
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def commit(self, message: str):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def add_fragment(self, name: str):
        (self.root / "changelog.d" / name).write_text("足した\n", encoding="utf-8")

    def test_the_first_release_takes_every_fragment(self):
        self.add_fragment("a.feature.md")
        self.add_fragment("b.fix.md")
        self.commit("feat: 足す")
        self.assertEqual(len(release.added_fragments(None)), 2)

    def test_a_release_takes_only_what_was_added_since_the_last_tag(self):
        self.add_fragment("a.feature.md")
        self.commit("feat: 足す")
        self.git("tag", "v0.1.0")
        self.add_fragment("b.fix.md")
        self.commit("fix: 直す")

        fragments = release.added_fragments("v0.1.0")
        self.assertEqual([f.name for f in fragments], ["b.fix.md"])

    def test_it_refuses_to_cut_a_release_with_nothing_in_it(self):
        self.add_fragment("a.feature.md")
        self.commit("feat: 足す")
        self.git("tag", "v0.1.0")
        # 断片を増やさずにコミットだけ積む
        (self.root / "README.md").write_text("読み物\n", encoding="utf-8")
        self.commit("docs: 書く")

        self.assertEqual(release.command_next_version(), 2)

    def test_the_readme_of_the_fragment_directory_is_not_an_entry(self):
        (self.root / "changelog.d" / "README.md").write_text("案内\n", encoding="utf-8")
        self.commit("docs: 案内を置く")
        self.assertEqual(release.added_fragments(None), [])



class PicturesTests(unittest.TestCase):
    """この版の絵 (#2109)。

    PR の本文とラベルは gh から来るので差し替え、履歴と描画のパスの照合は本物で回す —
    「描画に触れたか」を模造すると、確かめたい当の照合を確かめなくなる。
    """

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        for args in (
            ("init", "-q", "-b", "main"),
            ("config", "user.email", "test@example.com"),
            ("config", "user.name", "test"),
            ("config", "commit.gpgsign", "false"),
            ("config", "tag.gpgsign", "false"),
        ):
            self.git(*args)
        self.write("README.md")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "chore: 始める")
        self.git("tag", "v0.1.0")
        self.original_repo = release.REPO
        release.REPO = self.root
        self.pulls: dict[int, dict] = {}

    def tearDown(self):
        release.REPO = self.original_repo
        self.directory.cleanup()

    def git(self, *args: str):
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def write(self, path: str):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(f"{path}\n")

    def merge(self, number: int, path: str, body: str, labels: tuple[str, ...] = ()):
        """squash で入った PR を 1 本積む。題の末尾に GitHub と同じ `(#N)` を付ける。"""
        self.pulls[number] = {
            "number": number,
            "title": f"fix: 直す {number}",
            "url": f"https://github.com/example/repo/pull/{number}",
            "body": body,
            "labels": [{"name": label} for label in labels],
        }
        self.write(path)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", f"fix: 直す {number} (#{number})")

    def section(self) -> str:
        return release.pictures("v0.1.0", fetch=self.pulls.get)

    def test_a_drawing_pull_shows_its_pictures_and_a_link(self):
        self.merge(10, "Sources/MokumeCore/Circle.swift",
                   "## 確認方法\n\n<img src=\"https://i.gyazo.com/a.png\" width=\"240\">\n"
                   "![after](https://i.gyazo.com/b.png)")
        section = self.section()
        self.assertTrue(section.startswith("## この版の絵"))
        self.assertIn("[#10 fix: 直す 10](https://github.com/example/repo/pull/10)", section)
        self.assertIn('<img src="https://i.gyazo.com/a.png" width="240">', section)
        self.assertIn("![after](https://i.gyazo.com/b.png)", section)

    def test_only_drawing_pulls_without_the_escape_label_are_listed(self):
        self.merge(10, "Sources/MokumeCore/Circle.swift", "![絵](https://i.gyazo.com/a.png)")
        self.merge(11, "docs/guide.md", "![図](https://i.gyazo.com/doc.png)")
        self.merge(12, "Sources/MokumeCore/Line.swift", "整えただけ", ("no-visual-change",))
        section = self.section()
        self.assertIn("#10", section)
        self.assertNotIn("#11", section)
        self.assertNotIn("doc.png", section)
        self.assertNotIn("#12", section)

    def test_no_section_without_a_drawing_pull(self):
        self.merge(11, "docs/guide.md", "![図](https://i.gyazo.com/doc.png)")
        self.merge(12, "Sources/MokumeCore/Line.swift", "整えただけ", ("no-visual-change",))
        self.assertEqual(self.section(), "")
        # 断片だけのノートは、節を足す前と 1 文字も変わらない
        fragment = self.root / "a.feature.md"
        fragment.write_text("足した\n", encoding="utf-8")
        self.assertEqual(release.notes([fragment], self.section()), "## 新機能\n\n足した\n")

    def test_the_section_follows_the_fragments(self):
        self.merge(10, "Sources/MokumeCore/Circle.swift", "![絵](https://i.gyazo.com/a.png)")
        fragment = self.root / "a.fix.md"
        fragment.write_text("直した\n", encoding="utf-8")
        notes = release.notes([fragment], self.section())
        self.assertLess(notes.index("## 修正"), notes.index("## この版の絵"))

    def test_the_release_notes_carry_the_section(self):
        # 組み立ての部品だけでなく、Release が実際に使う notes サブコマンドまで通す
        (self.root / "changelog.d").mkdir()
        (self.root / "changelog.d" / "a.fix.md").write_text("直した\n", encoding="utf-8")
        self.merge(10, "Sources/MokumeCore/Circle.swift", "![絵](https://i.gyazo.com/a.png)")
        original_fetch = release.fetch_pull
        release.fetch_pull = self.pulls.get
        output = io.StringIO()
        try:
            with contextlib.redirect_stdout(output):
                self.assertEqual(release.command_notes(), 0)
        finally:
            release.fetch_pull = original_fetch
        self.assertIn("## 修正", output.getvalue())
        self.assertIn("![絵](https://i.gyazo.com/a.png)", output.getvalue())

    def test_the_pictures_are_folded_under_a_count(self):
        self.merge(10, "Sources/MokumeCore/Circle.swift", "![絵](https://i.gyazo.com/a.png)")
        self.merge(11, "Sources/MokumeCore/Line.swift", "![線](https://i.gyazo.com/b.png)")
        section = self.section()
        visible, folded = section.split("<details><summary>絵を開く</summary>")
        self.assertIn("描画が変わった PR が 2 本ある。", visible)
        self.assertNotIn("gyazo", visible)
        self.assertIn("### [#10", folded)
        self.assertIn("![線](https://i.gyazo.com/b.png)", folded)
        self.assertTrue(folded.rstrip().endswith("</details>"))

    def test_an_unreadable_pull_is_named_not_dropped(self):
        self.merge(10, "Sources/MokumeCore/Circle.swift", "![絵](https://i.gyazo.com/a.png)")
        del self.pulls[10]
        section = self.section()
        self.assertIn("### #10", section)
        self.assertIn("読めなかった", section)

    def test_pulls_before_the_last_tag_are_not_listed(self):
        self.merge(10, "Sources/MokumeCore/Circle.swift", "![絵](https://i.gyazo.com/a.png)")
        self.git("tag", "v0.2.0")
        self.merge(11, "Sources/MokumeCore/Line.swift", "![線](https://i.gyazo.com/b.png)")
        section = release.pictures("v0.2.0", fetch=self.pulls.get)
        self.assertNotIn("#10", section)
        self.assertIn("#11", section)

    def test_references_read_back_every_form_the_section_wrote(self):
        # 書く側が通す記法は全部、読む側で戻る (#2268)。記法を足すときに片側だけ直ると、
        # 日次の死活検査は黙って 0 本になる。ノートは本物の notes() で組む
        self.merge(10, "Sources/MokumeCore/Circle.swift",
                   '<img src="https://i.gyazo.com/a.png" width="240">\n'
                   "![after](https://i.gyazo.com/b.png)\n"
                   "https://github.com/user-attachments/assets/0f1e\n"
                   "https://example.com/c.webp\n")
        self.merge(11, "Sources/MokumeCore/Line.swift",
                   '<video src="https://example.com/m.mp4" poster="https://i.gyazo.com/p.png"></video>')
        fragment = self.root / "a.fix.md"
        fragment.write_text("直した ![断片の外部画像](https://i.example.test/fragment.png)\n", encoding="utf-8")
        references = release.picture_references(release.notes([fragment], self.section()))
        self.assertEqual(
            [(r.url, r.pull) for r in references],
            [
                ("https://i.gyazo.com/a.png", 10),
                ("https://i.gyazo.com/b.png", 10),
                ("https://github.com/user-attachments/assets/0f1e", 10),
                ("https://example.com/c.webp", 10),
                ("https://example.com/m.mp4", 11),
                ("https://i.gyazo.com/p.png", 11),
            ],
        )

    def test_references_keep_the_pull_number_across_pulls_without_a_url(self):
        # 読めなかった PR・絵が見つからなかった PR は URL を持たない。次の PR の絵を
        # 手前の番号で名乗ると、直す側が違う PR 本文を開く
        self.merge(10, "Sources/MokumeCore/Circle.swift", "![絵](https://i.gyazo.com/a.png)")
        self.merge(11, "Sources/MokumeCore/Line.swift", "![線](https://i.gyazo.com/b.png)")
        self.merge(12, "Sources/MokumeCore/Rect.swift", "絵を貼っていない")
        self.merge(13, "Sources/MokumeCore/Dot.swift", "![点](https://i.gyazo.com/d.png)")
        del self.pulls[11]
        references = release.picture_references(release.notes([], self.section()))
        self.assertEqual(
            [(r.url, r.pull) for r in references],
            [("https://i.gyazo.com/a.png", 10), ("https://i.gyazo.com/d.png", 13)],
        )


class PicturesOfTests(unittest.TestCase):
    """本文から絵の参照を抜く。"""

    def test_takes_each_form_drawing_evidence_accepts(self):
        body = (
            "<img src=\"https://i.gyazo.com/a.png\" width=\"240\">\n"
            "![b](https://i.gyazo.com/b.png)\n"
            "https://github.com/user-attachments/assets/0f1e\n"
            "https://example.com/c.webp\n"
        )
        self.assertEqual(
            release.pictures_of(body),
            [
                '<img src="https://i.gyazo.com/a.png" width="240">',
                "![b](https://i.gyazo.com/b.png)",
                "https://github.com/user-attachments/assets/0f1e",
                "![](https://example.com/c.webp)",
            ],
        )

    def test_a_url_inside_a_tag_is_not_taken_twice(self):
        self.assertEqual(len(release.pictures_of('<img src="https://i.gyazo.com/a.png">')), 1)

    def test_the_same_picture_appears_once(self):
        body = "![x](https://i.gyazo.com/a.png)\n![x](https://i.gyazo.com/a.png)"
        self.assertEqual(len(release.pictures_of(body)), 1)

    def test_comments_and_code_blocks_are_not_pictures(self):
        body = "<!-- ![例](https://i.gyazo.com/t.png) -->\n```markdown\n![例](https://i.gyazo.com/c.png)\n```\n"
        self.assertEqual(release.pictures_of(body), [])

    def test_every_fence_form_hides_its_pictures(self):
        # ~~~・4 本以上・字下げ 1〜3 桁も ``` と同じ規則で読む (#2816 f)。
        # 行頭の ``` だけを見ていた頃は、これらの中の絵を「この版の絵」に載せていた
        sample = "![例](https://i.gyazo.com/c.png)"
        forms = {
            "tilde": f"~~~\n{sample}\n~~~\n",
            "4 本": f"````\n```\n{sample}\n```\n````\n",
            "字下げ 1 桁": f" ```\n{sample}\n ```\n",
            "字下げ 3 桁": f"   ~~~markdown\n{sample}\n   ~~~\n",
        }
        for name, body in forms.items():
            with self.subTest(name):
                self.assertEqual(release.pictures_of(body), [])

    def test_a_picture_after_a_closed_fence_is_taken(self):
        body = "~~~\n![例](https://i.gyazo.com/c.png)\n~~~\n\n![本物](https://i.gyazo.com/real.png)\n"
        self.assertEqual(release.pictures_of(body), ["![本物](https://i.gyazo.com/real.png)"])

    def test_a_four_column_indent_is_not_a_fence(self):
        # 4 桁の字下げは字下げコードブロックでフェンスではない。後ろの絵を隠さない
        body = "    ```\n\n![本物](https://i.gyazo.com/real.png)\n"
        self.assertEqual(release.pictures_of(body), ["![本物](https://i.gyazo.com/real.png)"])

    def test_a_fence_marker_inside_a_comment_does_not_hide_the_pictures_after_it(self):
        # コメントの中の ``` を開きと読むと、閉じないフェンスが後ろの絵まで隠す
        body = "<!--\n```\n-->\n![本物](https://i.gyazo.com/real.png)\n"
        self.assertEqual(release.pictures_of(body), ["![本物](https://i.gyazo.com/real.png)"])

    def test_a_comment_start_inside_a_fence_does_not_swallow_the_text_after_it(self):
        # フェンスの中の `<!--` は閉じない。コメントとして先に取り除くと、後ろの絵まで巻き込む
        body = "```html\n<!-- 見本\n```\n\n![本物](https://i.gyazo.com/real.png)\n"
        self.assertEqual(release.pictures_of(body), ["![本物](https://i.gyazo.com/real.png)"])


class PictureReferencesTests(unittest.TestCase):
    """ノートの本文から、載せた絵の URL を読む (#2268)。"""

    NOTES = (
        "## 修正\n\n- 直した ![外](https://i.example.test/fragment.png)\n\n"
        "## この版の絵\n\n"
        "### [#7 fix: 直す](https://github.com/example/repo/pull/7)\n\n"
        "![a](https://i.gyazo.com/a.png)\n\n"
        "### #8\n\n"
        "PR を読めなかった。\n\n"
        "## 別の節\n\n"
        "![節の外](https://i.example.test/after.png)\n"
    )

    def urls(self, notes):
        return [r.url for r in release.picture_references(notes)]

    def test_only_the_section_is_read(self):
        # 断片の本文の外部画像も、節の後ろの別の節の画像も、絵の記録ではない
        self.assertEqual(self.urls(self.NOTES), ["https://i.gyazo.com/a.png"])

    def test_notes_without_the_section_have_none(self):
        self.assertEqual(self.urls("## 修正\n\n- 直した\n"), [])
        self.assertEqual(self.urls(""), [])

    def test_the_line_is_the_one_in_the_notes(self):
        (reference,) = release.picture_references(self.NOTES)
        self.assertEqual(self.NOTES.splitlines()[reference.line - 1], "![a](https://i.gyazo.com/a.png)")

    def test_crlf_notes_are_read_too(self):
        # Release を Web で直すと改行が CRLF になりうる
        self.assertEqual(self.urls(self.NOTES.replace("\n", "\r\n")), ["https://i.gyazo.com/a.png"])

    def test_the_url_in_an_image_description_is_not_a_picture(self):
        notes = "## この版の絵\n\n### #1\n\n![https://i.example.test/alt.png](https://i.gyazo.com/real.png)\n"
        self.assertEqual(self.urls(notes), ["https://i.gyazo.com/real.png"])

    def test_a_relative_target_is_not_a_url_to_probe(self):
        notes = "## この版の絵\n\n### #1\n\n![](images/local.png)\n"
        self.assertEqual(self.urls(notes), [])


if __name__ == "__main__":
    unittest.main()
