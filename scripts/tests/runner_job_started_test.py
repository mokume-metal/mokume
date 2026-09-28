#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/runner-job-started.sh — 専用機のジョブの始まりに作業ディレクトリを空にする (#878)。

守るのは 2 つ。

1. **作業ディレクトリの中身を、追跡外のもの (隠しファイル・ビルドの成果物) まで消す。**
   ディレクトリそのものは残す。まだ無ければ (初回のジョブ) 何もせずに緑
2. **runner の作業場所の形 (`_work/<名前>/<名前>`) でなければ、何も消さずに赤で終える。**
   GITHUB_WORKSPACE の渡し間違いで、ホームなどを消さないため

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "runner-job-started.sh"


class RunnerJobStartedTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def run_hook(self, workspace):
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_WORKSPACE"}
        if workspace is not None:
            env["GITHUB_WORKSPACE"] = str(workspace)
        return subprocess.run(["/bin/bash", str(SCRIPT)], env=env, capture_output=True, text=True)

    def test_empties_the_workspace_but_keeps_it(self):
        ws = self.root / "_work" / "mokume" / "mokume"
        (ws / ".build" / "debug").mkdir(parents=True)
        (ws / ".build" / "debug" / "leftover.o").write_text("x")
        (ws / ".hidden").write_text("x")
        (ws / "Sources").mkdir()
        proc = self.run_hook(ws)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(ws.is_dir())
        self.assertEqual(list(ws.iterdir()), [])

    def test_a_workspace_not_yet_made_is_fine(self):
        proc = self.run_hook(self.root / "_work" / "mokume" / "mokume")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("まだ無い", proc.stdout)

    def test_refuses_a_path_outside_the_work_folder(self):
        home = self.root / "home"
        home.mkdir()
        (home / "keep.txt").write_text("x")
        proc = self.run_hook(home)
        self.assertNotEqual(proc.returncode, 0)
        self.assertTrue((home / "keep.txt").exists())

    def test_refuses_an_empty_workspace_variable(self):
        proc = self.run_hook(None)
        self.assertNotEqual(proc.returncode, 0)
        proc = self.run_hook("")
        self.assertNotEqual(proc.returncode, 0)


if __name__ == "__main__":
    unittest.main()
