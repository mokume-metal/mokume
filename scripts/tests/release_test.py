#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/release.py の検査。

守りたいのは 3 つ:
  1. 版の上げ幅が履歴どおりに決まる (1.0 未満では破壊的変更も minor)
  2. 中身の無い版を出さない (断片が 1 つも増えていなければ中断)
  3. 書いた断片がノートから黙って消えない (知らない分類も落とさない)

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
