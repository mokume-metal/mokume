#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/worktree-path-guard.sh の検査 (#499)。

守りたいのは 1 つ — **いまのセッションの worktree の外へは書けない**。破ると変更が
ブランチではなく別のツリーへ落ち、同名のファイルが両方にあるため差分を見るまで
気付けない。

判定はリポジトリの状態 (worktree が共有する .git) にしか依存しないので、実際に
git worktree を生やした使い捨てリポジトリを組み立てて走らせる。ネットワークも gh も
要らない。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "scripts" / "worktree-path-guard.sh"


class HookTestCase(unittest.TestCase):
    def setUp(self):
        self.workdir = tempfile.TemporaryDirectory()
        root = Path(self.workdir.name)
        self.addCleanup(self.workdir.cleanup)

        # メイン作業ツリー + そこから生やした worktree。実運用と同じく、worktree は
        # メインツリーの内側 .claude/worktrees/ に置く
        self.main = root / "repo"
        self.main.mkdir()
        self.git("init", "-q", "-b", "main", cwd=self.main)
        self.git("config", "user.email", "t@example.com", cwd=self.main)
        self.git("config", "user.name", "t", cwd=self.main)
        # 使い捨てのリポジトリでは署名を切る。手元のグローバル設定を継ぐと、
        # 署名鍵を持つエージェントが応えられない一瞬で 128 落ちする (#344)
        self.git("config", "commit.gpgsign", "false", cwd=self.main)
        (self.main / "app.swift").write_text("main\n")
        self.git("add", "-A", cwd=self.main)
        self.git("commit", "-qm", "init", cwd=self.main)

        self.linked = self.main / ".claude" / "worktrees" / "wt"
        self.git("worktree", "add", "-q", "-b", "feat", str(self.linked), cwd=self.main)

        # まったく別のリポジトリ (別プロジェクトの編集は止めない)
        self.other = root / "other"
        self.other.mkdir()
        self.git("init", "-q", cwd=self.other)
        (self.other / "app.swift").write_text("other\n")

    def git(self, *args, cwd):
        subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)

    def run_hook(self, cwd, tool="Edit", **tool_input):
        return subprocess.run(
            ["bash", str(GUARD)],
            input=json.dumps(
                {"tool_name": tool, "cwd": str(cwd), "tool_input": tool_input}
            ),
            capture_output=True,
            text=True,
            cwd=str(cwd),
            timeout=30,
        )

    def assert_allowed(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "", "素通しのはずが止めた")

    def assert_denied(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(result.stdout.strip(), "", "止めるはずが素通しした")
        payload = json.loads(result.stdout)
        decision = payload["hookSpecificOutput"]["permissionDecision"]
        self.assertEqual(decision, "deny", result.stdout)
        return payload["hookSpecificOutput"]["permissionDecisionReason"]

    # --- 素通しするもの ---------------------------------------------------

    def test_same_worktree_is_allowed(self):
        self.assert_allowed(
            self.run_hook(self.linked, file_path=str(self.linked / "app.swift"))
        )

    def test_new_file_in_same_worktree_is_allowed(self):
        self.assert_allowed(
            self.run_hook(self.linked, file_path=str(self.linked / "new" / "x.swift"))
        )

    def test_other_repository_is_allowed(self):
        # 別プロジェクトを触るのは正当な作業なので止めない
        self.assert_allowed(
            self.run_hook(self.linked, file_path=str(self.other / "app.swift"))
        )

    def test_outside_any_repository_is_allowed(self):
        # スクラッチパッドやセッションの記録はここの射程の外
        with tempfile.TemporaryDirectory() as plain:
            self.assert_allowed(
                self.run_hook(self.linked, file_path=str(Path(plain) / "note.md"))
            )

    def test_missing_file_path_is_allowed(self):
        self.assert_allowed(self.run_hook(self.linked, tool="Bash", command="ls"))

    def test_session_outside_repository_is_allowed(self):
        with tempfile.TemporaryDirectory() as plain:
            self.assert_allowed(
                self.run_hook(plain, file_path=str(self.main / "app.swift"))
            )

    # --- 止めるもの -------------------------------------------------------

    def test_main_worktree_from_linked_worktree_is_denied(self):
        # 実際に起きた事故そのもの: worktree セッションでメインツリーの絶対パスを掴む
        reason = self.assert_denied(
            self.run_hook(self.linked, file_path=str(self.main / "app.swift"))
        )
        self.assertIn(str(self.linked / "app.swift"), reason, "訂正後のパスが無い")

    def test_linked_worktree_from_main_is_denied(self):
        # 逆向き (並行して走っている別セッションの作業ツリーを踏む) も止める
        reason = self.assert_denied(
            self.run_hook(self.main, file_path=str(self.linked / "app.swift"))
        )
        self.assertIn(str(self.main / "app.swift"), reason)

    def test_nested_path_keeps_its_relative_position(self):
        nested = self.main / "Sources" / "Deep" / "File.swift"
        nested.parent.mkdir(parents=True)
        nested.write_text("x\n")
        reason = self.assert_denied(self.run_hook(self.linked, file_path=str(nested)))
        self.assertIn(str(self.linked / "Sources" / "Deep" / "File.swift"), reason)

    def test_new_file_in_other_worktree_is_denied(self):
        # 実在しないパスでも、親ディレクトリからどの worktree かは決まる
        reason = self.assert_denied(
            self.run_hook(self.linked, file_path=str(self.main / "brand-new.swift"))
        )
        self.assertIn(str(self.linked / "brand-new.swift"), reason)

    def test_notebook_edit_is_denied(self):
        self.assert_denied(
            self.run_hook(
                self.linked,
                tool="NotebookEdit",
                notebook_path=str(self.main / "n.ipynb"),
            )
        )

    def test_falls_back_to_process_cwd(self):
        # cwd をペイロードに載せない版のホストでも効く
        result = subprocess.run(
            ["bash", str(GUARD)],
            input=json.dumps(
                {
                    "tool_name": "Edit",
                    "tool_input": {"file_path": str(self.main / "app.swift")},
                }
            ),
            capture_output=True,
            text=True,
            cwd=str(self.linked),
            timeout=30,
        )
        self.assert_denied(result)


if __name__ == "__main__":
    unittest.main()
