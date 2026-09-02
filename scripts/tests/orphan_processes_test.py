#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""孤児プロセスの一覧が、出所と持ち主の手掛かりを正しく引くことの検査 (#454)。

`ps` と `lsof` は PATH のスタブに差し替え、scratchpad は一時ディレクトリに組む。
worktree は使い捨ての git リポジトリを実際に作って生やす — slug の作り方
(`/` と `.` が `-` になる) をスタブで固定してしまうと、**検査だけが通って実機で
外れる**からである。

固定したい振る舞いは 4 つ:

1. 古い世代の scratchpad から起動されたものは「終わっている可能性が高い」に落ちる
2. 最近動いている世代のものは「生きている可能性が高い」に落ちる —
   **迷ったときに死んだ側へ倒さない**。落とす側の誤りだけが取り返しがつかない
3. このリポジトリに属さないものを黙って隠さない (`対象外` として出す)
4. **何も殺さない。** 本物のプロセスを一覧させ、走ったままであることを見る
"""

import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "orphan-processes.sh"

# ps の代わり。PS_LINES の中身をそのまま返す
FAKE_PS = """#!/bin/bash
printf '%s' "$PS_LINES"
"""

# lsof の代わり。LSOF_CWD があれば -Fn 形式で 1 件返す
FAKE_LSOF = """#!/bin/bash
[ -n "${LSOF_CWD:-}" ] || exit 1
printf 'p0\\nfcwd\\nn%s\\n' "$LSOF_CWD"
"""


def slug_of(path: Path) -> str:
    """scratchpad の置き場名。スクリプト側の tr '/.' '--' と同じ変換。"""
    return str(path).replace("/", "-").replace(".", "-")


class OrphanProcessesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        # git は実体のパスで worktree を報告する (macOS の /var は /private/var への
        # symlink)。slug は worktree のパスから作るので、ここで実体に寄せておかないと
        # 検査だけが「別プロジェクト」と判定してしまう
        self.root = Path(self.tmp.name).resolve()
        self.addCleanup(self.tmp.cleanup)

        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name, body in (("ps", FAKE_PS), ("lsof", FAKE_LSOF)):
            stub = bin_dir / name
            stub.write_text(body)
            stub.chmod(0o755)

        self.work = self.root / "work"
        self.work.mkdir()
        self._git("init", "-q", "-b", "main")
        self._git("config", "user.email", "t@example.invalid")
        self._git("config", "user.name", "t")
        # 使い捨てのリポジトリは手元の署名設定から独立させる (#344)
        self._git("config", "commit.gpgsign", "false")
        (self.work / "seed.txt").write_text("seed\n")
        self._git("add", "-A")
        self._git("commit", "-qm", "seed")

        self.tree = self.root / "trees" / "issue-1-abcdef"
        self._git("worktree", "add", "-q", "-b", "work", str(self.tree))

        self.scratch = self.root / "scratch"
        self.scratch.mkdir()

        self.env = dict(os.environ)
        self.env.update(
            PATH=f"{bin_dir}:{os.environ['PATH']}",
            MOKUME_SCRATCHPAD_ROOT=str(self.scratch),
            PS_LINES="",
        )
        self.env.pop("LSOF_CWD", None)

    def _git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.work, capture_output=True, text=True, check=True
        ).stdout

    def generation(self, tree: Path, session: str, minutes_ago: int) -> Path:
        """worktree に紐づく scratchpad の世代を、指定の古さで作る。

        中身は空にしておく — 最終活動は世代と直下の子の新しいほうで決まるので、
        古さを指定したいときは子を作らない。
        """
        directory = self.scratch / slug_of(tree) / session
        directory.mkdir(parents=True)
        stamp = time.time() - minutes_ago * 60
        os.utime(directory, (stamp, stamp))
        return directory

    def run_script(self, ps_lines, **env):
        environment = dict(self.env)
        environment["PS_LINES"] = ps_lines
        environment.update(env)
        return subprocess.run(
            ["/bin/bash", str(SCRIPT)],
            cwd=self.work,
            capture_output=True,
            text=True,
            env=environment,
        )

    # --- 出所と持ち主 ---------------------------------------------------------

    def test_old_generation_is_reported_as_probably_finished(self):
        binary = self.generation(self.tree, "20fce2f3-dead-beef", 180) / "sketch/.build/evidence"
        self.generation(self.tree, "58e33ea2-live-0001", 4)  # より新しい世代
        result = self.run_script(f"  4001     1    02:31:04 {binary}\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("4001", result.stdout)
        self.assertIn("issue-1-abcdef", result.stdout)
        self.assertIn("終わっている可能性が高い", result.stdout)

    def test_recent_generation_is_reported_as_probably_alive(self):
        binary = self.generation(self.tree, "58e33ea2-live-0001", 3) / "sketch/.build/evidence"
        result = self.run_script(f"  4002     1    00:33:00 {binary}\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("生きている可能性が高い", result.stdout)
        self.assertNotIn("終わっている可能性が高い", result.stdout)

    def test_activity_is_read_from_the_children_too(self):
        """世代のディレクトリ自身は古びていても、下が動いていれば生きている。

        実測での取り違え: 世代のディレクトリの mtime は直下に出入りがあったときしか
        動かず、書き込みは 1 つ下 (scratchpad/・tasks/) に集まる。世代だけを見ると、
        生きているセッションが 27 分前に見えていた。
        """
        generation = self.generation(self.tree, "58e33ea2-live-0001", 120)
        (generation / "scratchpad").mkdir()  # 作った直後なので今の時刻
        # 子を作ると親の mtime も動くので、親だけ古いまま据え直す (実機がこの形)
        stamp = time.time() - 120 * 60
        os.utime(generation, (stamp, stamp))
        binary = generation / "sketch/.build/evidence"
        result = self.run_script(f"  4010     1    02:00:00 {binary}\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("生きている可能性が高い", result.stdout)

    def test_stale_newest_generation_is_not_declared_dead(self):
        """最新の世代が古びているだけでは死を断定しない (静かに考えている場合がある)。"""
        binary = self.generation(self.tree, "90ec9b26-quiet-01", 240) / "sketch/.build/evidence"
        result = self.run_script(f"  4003     1    04:00:00 {binary}\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("判定できず", result.stdout)
        self.assertNotIn("終わっている可能性が高い", result.stdout)

    def test_worktree_build_falls_back_to_cwd_for_the_session(self):
        """worktree の .build から建てたものは、cwd から世代を引き直す。"""
        scratchpad = self.generation(self.tree, "58e33ea2-live-0001", 5)
        binary = self.tree / ".build/arm64-apple-macosx/debug/Split"
        result = self.run_script(
            f"  4004     1    00:46:00 {binary}\n", LSOF_CWD=str(scratchpad)
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("issue-1-abcdef", result.stdout)
        self.assertIn("58e33ea2", result.stdout)

    def test_worktree_build_without_cwd_still_names_the_worktree(self):
        binary = self.tree / ".build/arm64-apple-macosx/debug/Split"
        result = self.run_script(f"  4005     1    00:46:00 {binary}\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("issue-1-abcdef", result.stdout)
        self.assertIn("セッションは引けず", result.stdout)

    # --- 隠さない -------------------------------------------------------------

    def test_foreign_build_is_listed_not_hidden(self):
        """別プロジェクト由来も出す。実測で最長 (8 時間 44 分) はこちら側だった。"""
        result = self.run_script("  4006     1    08:44:12 /elsewhere/proj/.build/debug/probe\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("4006", result.stdout)
        self.assertIn("対象外", result.stdout)
        self.assertIn("/elsewhere/proj/.build/debug/probe", result.stdout)

    def test_foreign_scratchpad_is_named_as_out_of_scope(self):
        other = self.scratch / "-Users-someone-other-project" / "11111111-2222-3333"
        other.mkdir(parents=True)
        result = self.run_script(f"  4007     1    01:00:00 {other}/sketch/.build/probe\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("対象外", result.stdout)

    # --- 対象の絞り込み -------------------------------------------------------

    def test_processes_with_a_living_parent_are_skipped(self):
        binary = self.generation(self.tree, "58e33ea2-live-0001", 3) / "sketch/.build/evidence"
        result = self.run_script(f"  4008   900    00:33:00 {binary}\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("4008", result.stdout)
        self.assertIn("見つからなかった", result.stdout)

    def test_unrelated_daemons_are_skipped(self):
        result = self.run_script("  4009     1    30-00:00:00 /usr/libexec/somedaemon\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("4009", result.stdout)

    def test_nothing_found_exits_zero(self):
        result = self.run_script("")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("見つからなかった", result.stdout)

    # --- 殺さない -------------------------------------------------------------

    def test_the_listing_does_not_kill_anything(self):
        """本物のプロセスを一覧させ、走ったままであることを見る。

        `kill` は bash の組み込みなので PATH のスタブでは捕まらない。
        実物が生き残ることを直接見るのが、この不変条件の唯一まともな検査になる。
        """
        victim = subprocess.Popen(["sleep", "300"])
        self.addCleanup(victim.wait)
        self.addCleanup(victim.kill)

        binary = self.generation(self.tree, "20fce2f3-dead-beef", 300) / "s/.build/evidence"
        result = self.run_script(f"  {victim.pid}     1    05:00:00 {binary}\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(victim.pid), result.stdout)
        self.assertIn("何も殺さない", result.stdout)
        time.sleep(0.2)
        self.assertIsNone(victim.poll(), "一覧したプロセスが落とされている")


if __name__ == "__main__":
    unittest.main()
