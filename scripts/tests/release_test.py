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

git は一時リポジトリを本物で回す — 「前回のタグ以降に追加されたか」は履歴の話で、
そこを模造すると検査が確かめたい当のものを確かめなくなる。
"""

import importlib.util
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
        self.assertIn("- 足した", notes)

    def test_keeps_entries_with_an_unknown_category(self):
        # 知らない分類を落とすと「書いたのにノートに出ない」が黙って起きる
        notes = release.notes([self.fragment("a.security.md", "塞いだ")])
        self.assertIn("塞いだ", notes)


def lines_outside_their_item(notes: str) -> list[str]:
    """箇条書きの外へ出てしまった行 (#446)。

    CommonMark / GFM は、リストの中で**空行のあとに列 0 から始まる行**が来たところで
    リストを終える。その行は書いた人の意図では項目の中身なので、外に出ていたら壊れて
    いる。見出しと、次の項目そのものは対象外。
    """
    escaped: list[str] = []
    in_list = False
    after_blank = False
    for line in notes.split("\n"):
        if line.startswith("## "):
            in_list = False
        elif line.startswith("- "):
            in_list = True
        elif line.strip() and in_list and after_blank and not line.startswith(" "):
            escaped.append(line)
        after_blank = not line.strip()
    return escaped


class ListItemTests(unittest.TestCase):
    """本文を 1 つの項目に収める (#446)。"""

    def test_a_single_paragraph_entry_is_untouched(self):
        # 直す前の出力と 1 文字も変わらないこと。v0.1.0 のノートは全件この形だった
        self.assertEqual(release.as_list_item("足した。"), "- 足した。")

    def test_a_multi_paragraph_entry_stays_in_its_item(self):
        self.assertEqual(
            release.as_list_item("1 段落目。\n\n2 段落目。"),
            "- 1 段落目。\n\n  2 段落目。",
        )

    def test_a_hard_wrapped_paragraph_stays_in_its_item(self):
        self.assertEqual(
            release.as_list_item("折り返した\n続き。"), "- 折り返した\n  続き。"
        )

    def test_a_blank_line_carries_no_trailing_space(self):
        for line in release.as_list_item("上。\n\n下。").split("\n"):
            self.assertEqual(line, line.rstrip())

    def test_the_detector_catches_the_shape_this_bug_produced(self):
        # 検出器そのものが効いていることを、壊れた形を直に渡して見る。
        # これが空を返すなら、下の本物の断片に対する検査も何も見ていない
        broken = "## 新機能\n\n- 1 段落目。\n\n2 段落目。\n- 次の項目。\n"
        self.assertEqual(lines_outside_their_item(broken), ["2 段落目。"])

    def test_the_detector_passes_a_well_formed_list(self):
        fixed = "## 新機能\n\n- 1 段落目。\n\n  2 段落目。\n- 次の項目。\n"
        self.assertEqual(lines_outside_their_item(fixed), [])

    def test_no_real_fragment_escapes_its_item(self):
        # 本物の changelog.d を材料にする。壊れ方は個々の断片ではなく、
        # 断片と組み方の組み合わせで出るため
        fragments = release.all_fragments()
        self.assertGreater(len(fragments), 0, "断片が 1 つも読めていない")
        escaped = lines_outside_their_item(release.notes(fragments))
        self.assertEqual(escaped, [], f"{len(escaped)} 行が項目の外へ出ている")


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


if __name__ == "__main__":
    unittest.main()
