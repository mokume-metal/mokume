#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-no-binaries.sh の、見るファイルの範囲の検査 (#2015)。

検査の中身 (どの拡張子を弾くか) は変えていない。固定するのは**見る範囲**で、基準は
「`git add -A` したときに CI の木になるもの」(追跡 + 未追跡 − 無視)。

- **`git add` 前の新しいファイルも見る** — 追跡済みだけを見ると、未追跡の `pic.png` が
  手元では緑で、`git add` して push した後の CI で初めて赤になる
- **無視されたものは見ない** — 生成物や手元の書き捨ては CI の木に入らない
- **index にだけ残る旧パスは見ない** — `git rm` していない削除・改名は、add -A の後の
  木に現れない
- **名前の綴りの癖で見落とさない** — 非 ASCII の名前は C 引用符つきで返り、末尾が `"` に
  なって拡張子の判定を黙って外れる (緑のままバイナリが入る)
- **件数と違反の一覧は同じ列挙から出す** — 別々に数えると、表示がずれる

一時ディレクトリに小さな git リポジトリを組んで実行する。実行は make hooks-test
(CI もこれを呼ぶ)。
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-no-binaries.sh"


class NoBinariesTest(unittest.TestCase):
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

    def write(self, name, text="x\n"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def add_all(self):
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True)

    def run_check(self, add=False):
        # 既定は `git add` の前の手元。`add=True` は `git add -A` の後 (= CI が見る木)
        if add:
            self.add_all()
        return subprocess.run(
            ["bash", str(SCRIPT)], cwd=self.root, capture_output=True, text=True
        )

    # --- 赤くなるべきもの ---

    def test_tracked_binary_is_reported(self):
        self.write("a.txt")
        self.write("pic.png", "not really a png")
        r = self.run_check(add=True)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("pic.png", r.stderr)

    def test_untracked_binary_is_reported_before_git_add(self):
        self.write("a.txt")
        self.write("assets/pic.png", "not really a png")
        before = self.run_check()
        self.assertEqual(before.returncode, 1, before.stdout)
        self.assertIn("assets/pic.png", before.stderr)
        # add の後も同じものが赤になる
        after = self.run_check(add=True)
        self.assertEqual(after.returncode, 1)
        self.assertIn("assets/pic.png", after.stderr)

    def test_name_with_space_is_reported(self):
        self.write("my pic.png", "not really a png")
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("my pic.png", r.stderr)

    def test_non_ascii_name_is_reported(self):
        # core.quotePath の既定では、非 ASCII の名前は C 引用符つきで返る。
        # 末尾が `"` になるので、そのまま拡張子を見ると黙って素通しになる
        subprocess.run(
            ["git", "config", "core.quotePath", "true"], cwd=self.root, check=True
        )
        self.write("画像.png", "not really a png")
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("画像.png", r.stderr)

    def test_broken_symlink_is_seen_by_name(self):
        # この検査は名前だけを見る (中身は読まない)。壊れたリンクも `git add -A` なら
        # そのまま CI の木に入るので、読めるかどうかで落とさない
        self.write("a.txt")
        (self.root / "pic.png").symlink_to("nowhere.png")
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("pic.png", r.stderr)

    # --- 赤くなってはいけないもの ---

    def test_ignored_binary_is_not_reported(self):
        # 生成物や手元の書き捨ては CI の木に入らない
        self.write(".gitignore", "build/\n")
        self.write("build/out.png", "not really a png")
        self.write("a.txt")
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("ok:", r.stdout)

    def test_removed_tracked_binary_is_not_reported(self):
        # `git rm` していない削除は index に旧パスが残る。add -A の後の木には無い
        self.write("a.txt")
        self.write("pic.png", "not really a png")
        self.add_all()
        (self.root / "pic.png").unlink()
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)

    # --- 件数 ---

    def test_count_matches_the_files_listed(self):
        # 数えるのも違反を探すのも同じ列挙から。無視されたもの・消した追跡済みは
        # 数えず、未追跡は数える (.gitignore 自身も未追跡の 1 ファイル)
        self.write(".gitignore", "*.log\n")
        self.write("a.txt")
        self.write("b.txt")
        self.write("scratch.log")
        self.write("gone.txt")
        self.add_all()
        (self.root / "gone.txt").unlink()
        self.write("c.txt")  # 未追跡
        self.write("d/e.txt")  # 未追跡
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)
        # .gitignore / a.txt / b.txt / c.txt / d/e.txt の 5 つ
        self.assertIn("5 ファイル検査", r.stdout)
        # add の後も同じ件数
        self.assertIn("5 ファイル検査", self.run_check(add=True).stdout)


if __name__ == "__main__":
    unittest.main()
