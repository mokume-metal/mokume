#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/runner-job-started.sh — 専用機のジョブの始まりに作業ディレクトリを空にする (#878)。

守るのは 4 つ。

1. **作業ディレクトリの中身を、追跡外のもの (隠しファイル・ビルドの成果物) まで消す。**
   ディレクトリそのものは残す。まだ無ければ (初回のジョブ) 何もせずに緑
2. **runner の作業場所の形 (`_work/<名前>/<名前>`) でなければ、何も消さずに赤で終える。**
   GITHUB_WORKSPACE の渡し間違いで、ホームなどを消さないため
3. **消している最中に書き手がいても、期限内に止まれば打ち直して緑で終える** (#3616)。前の job の
   `swift build` が `.build` へ書き続けると、`rm -rf` は `Directory not empty` で落ちる。
   これまでは 1 回で落ち、PR と関係なく render が赤になって queue から外れていた
4. **期限を越えても空にならない・空にした後も書き手が残るなら、書き手を PID・ppid・経過・コマンドで
   名乗って赤にする。何も殺さない** (#3095 の `orphan-load` と同じ言い方)。値を変えずに
   待つ・握りつぶす緑は、前の job の成果物を持ち越す (ADR-0019 決定 7)

期限 (既定 60 秒) と打ち直しの間隔 (既定 2 秒) は JOB_STARTED_DEADLINE_SEC・JOB_STARTED_RETRY_SEC で縮める。
偽の rm・lsof・ps は PATH の先頭に置いた同名のスタブ (runner_preflight_test.py と同じ作法)。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "runner-job-started.sh"


# FAKE_RM_FAILS 回目までは「Directory not empty」で落ち (何も消さない)、以後は本物の rm に渡す。
# 負の数なら期限まで落ち続ける。呼ばれた回数は FAKE_RM_COUNT のファイルに数える
FAKE_RM = """#!/bin/sh
n=$(cat "$FAKE_RM_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$FAKE_RM_COUNT"
if [ "$FAKE_RM_FAILS" -lt 0 ] || [ "$n" -le "$FAKE_RM_FAILS" ]; then
  echo "rm: $FAKE_WORKSPACE/.build/out: Directory not empty" >&2
  exit 1
fi
exec /bin/rm "$@"
"""

# 作業場所の下を開いているプロセスの一覧 (`lsof -Fp +D <dir>` の形)。FAKE_WRITERS の pid を返す。空なら何も返さず 1
FAKE_LSOF = """#!/bin/sh
[ -n "$FAKE_WRITERS" ] || exit 1
for pid in $FAKE_WRITERS; do
  printf 'p%s\\nfcwd\\nn%s\\n' "$pid" "$FAKE_WORKSPACE"
done
"""

FAKE_PS = """#!/bin/sh
printf '%s\\n' "$FAKE_PS"
"""


class RunnerJobStartedTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def run_hook(self, workspace, **extra):
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_WORKSPACE" and not k.startswith("FAKE_")}
        if workspace is not None:
            env["GITHUB_WORKSPACE"] = str(workspace)
        env.update(extra)
        return subprocess.run(["/bin/bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60)

    def make_workspace(self):
        ws = self.root / "_work" / "mokume" / "mokume"
        (ws / ".build" / "out").mkdir(parents=True)
        (ws / ".build" / "out" / "leftover.o").write_text("x")
        (ws / "Sources").mkdir()
        return ws

    def run_with_stubs(self, ws, rm_fails, writers="", ps="", **extra):
        """偽の rm・lsof・ps を PATH の先頭に置いて走らせる。rm_fails は落ちる回数 (負なら落ち続ける)"""
        bin_dir = self.root / "bin"
        bin_dir.mkdir(exist_ok=True)
        for name, body in (("rm", FAKE_RM), ("lsof", FAKE_LSOF), ("ps", FAKE_PS)):
            path = bin_dir / name
            path.write_text(body, encoding="utf-8")
            path.chmod(0o755)
        count = self.root / "rm-count"
        count.unlink(missing_ok=True)
        self.rm_count = count
        return self.run_hook(
            ws,
            PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            FAKE_RM_COUNT=str(count),
            FAKE_RM_FAILS=str(rm_fails),
            FAKE_WRITERS=writers,
            FAKE_PS=ps,
            FAKE_WORKSPACE=str(ws),
            JOB_STARTED_DEADLINE_SEC="1",
            JOB_STARTED_RETRY_SEC="0.2",
            **extra,
        )

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

    def test_retries_when_a_writer_makes_the_first_rm_fail(self):
        # 1 回目の rm が「Directory not empty」で落ち、書き手が止まった 2 回目に空になる (#3616 の再現)
        ws = self.make_workspace()
        proc = self.run_with_stubs(ws, rm_fails=1)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(list(ws.iterdir()), [])
        self.assertIn("打ち直し 1 回", proc.stdout)

    def test_a_clean_first_try_does_not_mention_retries(self):
        ws = self.make_workspace()
        proc = self.run_with_stubs(ws, rm_fails=0)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(list(ws.iterdir()), [])
        self.assertNotIn("打ち直し", proc.stdout)

    def test_names_the_writer_and_goes_red_when_the_deadline_passes(self):
        # 期限まで空にならない。書き手を名乗って赤。作業場所の外は消さない。何も止めない
        ws = self.make_workspace()
        outside = self.root / "_work" / "mokume" / "keep.txt"
        outside.write_text("x")
        proc = self.run_with_stubs(
            ws,
            rm_fails=-1,
            writers="4242",
            ps="    1 01:12 /Library/Developer/swift-frontend -c foo.swift",
        )
        self.assertNotEqual(proc.returncode, 0)
        message = proc.stdout + proc.stderr
        self.assertIn("swift-frontend", message)
        self.assertIn("pid 4242", message)
        self.assertIn("ppid 1", message)
        self.assertIn("01:12", message)
        self.assertIn("何も止めていない", message)
        self.assertTrue(outside.exists())
        self.assertGreaterEqual(int(self.rm_count.read_text()), 2, "期限まで打ち直していない")

    def test_goes_red_and_says_so_when_no_writer_is_found(self):
        ws = self.make_workspace()
        proc = self.run_with_stubs(ws, rm_fails=-1)
        self.assertNotEqual(proc.returncode, 0)
        message = proc.stdout + proc.stderr
        self.assertIn("書き手は見つからなかった", message)
        self.assertIn("何も止めていない", message)
        self.assertTrue((ws / ".build").exists(), "消せなかったものを消えたように見せていない")

    @unittest.skipUnless(shutil.which("lsof"), "lsof が無い")
    def test_a_real_process_that_stops_in_time_lets_the_hook_go_green(self):
        # 本物の lsof で、作業場所に作業ディレクトリを置く本物のプロセスが期限内に終わる回
        ws = self.make_workspace()
        writer = subprocess.Popen(["sleep", "1.5"], cwd=ws)
        self.addCleanup(writer.wait)
        time.sleep(0.3)
        proc = self.run_hook(ws, JOB_STARTED_DEADLINE_SEC="20", JOB_STARTED_RETRY_SEC="0.2")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(list(ws.iterdir()), [])
        self.assertIn("打ち直し", proc.stdout)

    @unittest.skipUnless(shutil.which("lsof"), "lsof が無い")
    def test_a_real_process_that_stays_is_named_and_not_killed(self):
        # rm は成功して空になっても、作業場所に作業ディレクトリを置く書き手が残れば赤。殺さない
        ws = self.make_workspace()
        writer = subprocess.Popen(["sleep", "30"], cwd=ws)
        self.addCleanup(writer.wait)
        self.addCleanup(writer.terminate)
        time.sleep(0.3)
        proc = self.run_hook(ws, JOB_STARTED_DEADLINE_SEC="1", JOB_STARTED_RETRY_SEC="0.2")
        self.assertNotEqual(proc.returncode, 0)
        message = proc.stdout + proc.stderr
        self.assertIn(f"pid {writer.pid}", message)
        self.assertIn("sleep", message)
        self.assertIn("何も止めていない", message)
        self.assertIsNone(writer.poll(), "書き手を止めてはならない")


if __name__ == "__main__":
    unittest.main()
