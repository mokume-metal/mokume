#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-file-modes.sh の検査 (#272・#2072)。

基準は「`git add -A` したときに CI の木になるもの」で、向きが逆の 2 つを固定する。

- **CI の木に 100755 が載るなら赤い** — index に 100755 で載っているもの (追跡済み)
  と、作業ツリーで `chmod +x` されていて `git add -A` で 100755 として載るもの
  (未追跡の新しいファイルがその典型)。後者を見ないと手元で緑・push 後の CI で赤になる
- **CI の木に届かないものでは赤くならない** — 無視されたファイル、symlink、
  `core.fileMode = false` のクローンでの作業ツリーの実行ビット (`git add` が index に
  載せない)

一時ディレクトリに小さな git リポジトリを組んで実行する。実行は make hooks-test
(CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-file-modes.sh"


class FileModesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        subprocess.run(["git", "init", "-q", "."], cwd=self.root, check=True)
        # 使い捨てのリポジトリは手元の署名設定を継ぐ (#344)。ここは commit を
        # 打たないので効き目は無いが、抜けを人の記憶で守らないための規約に従う
        self.git("config", "commit.gpgsign", "false")
        # 手元の global 設定に依らず、既定 (実行ビットを index に載せる) から始める
        self.git("config", "core.fileMode", "true")

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True)

    def write(self, name, text="echo hi\n", executable=False):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        path.chmod(0o755 if executable else 0o644)
        return path

    def track_base(self):
        # 追跡ファイルが 0 件だと「検査が成立していない」で落ちるので、土台を 1 つ載せる
        self.write("README.txt", "base\n")
        self.git("add", "-A")

    def run_check(self, add=False):
        # 既定は `git add` の前の手元。`add=True` は `git add -A` の後 (= CI が見る木)
        if add:
            self.git("add", "-A")
        return subprocess.run(
            ["/bin/bash", str(SCRIPT)], cwd=self.root, capture_output=True, text=True
        )

    # --- 赤くなるべきもの ---

    def test_tracked_executable_in_index_is_reported(self):
        self.write("a.sh", executable=True)
        r = self.run_check(add=True)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("a.sh", r.stderr)
        self.assertIn("git update-index --chmod=-x a.sh", r.stderr)

    def test_untracked_executable_is_reported_before_git_add(self):
        # Issue #2072 の例: chmod +x してまだ git add していない新しいスクリプト
        self.track_base()
        self.write("scripts/new-check.sh", executable=True)
        before = self.run_check()
        self.assertEqual(before.returncode, 1, before.stdout)
        self.assertIn("scripts/new-check.sh", before.stderr)
        self.assertIn("chmod -x scripts/new-check.sh", before.stderr)
        # add の後 (= CI の木) も同じものが赤になる
        after = self.run_check(add=True)
        self.assertEqual(after.returncode, 1, after.stdout)
        self.assertIn("scripts/new-check.sh", after.stderr)

    def test_tracked_file_made_executable_but_not_added_is_reported(self):
        # index は 100644 のまま、作業ツリーで chmod +x した。add -A で 100755 になる
        self.track_base()
        (self.root / "README.txt").chmod(0o755)
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("chmod -x README.txt", r.stderr)

    def test_index_mode_is_still_checked_when_file_mode_is_false(self):
        # 追跡済みの判定 (index のモード) は core.fileMode に依らない
        self.write("a.sh")
        self.git("add", "-A")
        self.git("update-index", "--chmod=+x", "a.sh")
        self.git("config", "core.fileMode", "false")
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("git update-index --chmod=-x a.sh", r.stderr)

    def test_name_with_space_is_reported_with_pasteable_command(self):
        self.track_base()
        self.write("my script.sh", executable=True)
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("my script.sh", r.stderr)
        # 外し方の行はそのまま貼れる (空白で 2 語に割れない)
        self.assertIn("chmod -x 'my script.sh'", r.stderr)

    def test_hint_command_actually_removes_the_bit(self):
        # 外し方の行を貼って打てば緑に戻る (引用符・空白・非 ASCII を含む名前でも)
        self.track_base()
        self.write("it's mine.sh", executable=True)
        self.write("日本語.sh", executable=True)
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        hint = next(
            line.strip()
            for line in r.stderr.splitlines()
            if line.strip().startswith("chmod -x")
        )
        subprocess.run(["/bin/bash", "-c", hint], cwd=self.root, check=True)
        self.assertEqual(self.run_check().returncode, 0)

    def test_non_ascii_name_is_reported(self):
        # core.quotePath の既定では、非 ASCII の名前は C 引用符つきで返る。
        # その形のまま -x を見ると、実在するファイルを見失って緑になる
        self.git("config", "core.quotePath", "true")
        self.track_base()
        self.write("日本語.sh", executable=True)
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("日本語.sh", r.stderr)

    def test_index_hint_for_non_ascii_name_actually_removes_the_bit(self):
        # index 側の外し方も、非 ASCII の名前を C 引用符つきのまま貼らせない
        self.git("config", "core.quotePath", "true")
        self.git("config", "core.fileMode", "false")
        self.write("日本語.sh")
        self.git("add", "-A")
        self.git("update-index", "--chmod=+x", "日本語.sh")
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        hint = next(
            line.strip()
            for line in r.stderr.splitlines()
            if line.strip().startswith("git update-index")
        )
        subprocess.run(["/bin/bash", "-c", hint], cwd=self.root, check=True)
        self.assertEqual(self.run_check().returncode, 0)

    def test_no_tracked_files_fails(self):
        # 緑のまま何も見ていない状態を作らない
        self.write("a.sh")
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("検査が成立していない", r.stderr)

    # --- 赤くなってはいけないもの ---

    def test_clean_tree_passes(self):
        self.track_base()
        self.write("new.sh")
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("ok:", r.stdout)

    def test_ignored_executable_is_not_reported(self):
        # 生成物や手元の書き捨ては CI の木に入らない
        self.write(".gitignore", "build/\n")
        self.track_base()
        self.write("build/tool", executable=True)
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_untracked_executable_is_not_reported_when_file_mode_is_false(self):
        # その設定の下では git add が実行ビットを index に載せない (100644 で載る)
        self.track_base()
        self.git("config", "core.fileMode", "false")
        self.write("new.sh", executable=True)
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("core.fileMode=false", r.stdout)
        # 前提の確認: 実際に add しても index には 100644 で載る
        self.git("add", "-A")
        staged = subprocess.run(
            ["git", "ls-files", "-s", "new.sh"],
            cwd=self.root,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        self.assertTrue(staged.startswith("100644"), staged)

    def test_symlink_to_executable_is_not_reported(self):
        # symlink は 120000 で載り、実行ビットの話ではない (-x は先を見てしまう)
        self.write(".gitignore", "bin/\n")
        self.track_base()
        self.write("bin/tool", executable=True)
        os.symlink("bin/tool", self.root / "tool")
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_removed_tracked_file_is_skipped(self):
        # `git rm` していない削除は index に旧パスが残る。add -A の後の木には無い
        self.track_base()
        self.write("gone.sh")
        self.git("add", "-A")
        (self.root / "gone.sh").unlink()
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == "__main__":
    unittest.main()
