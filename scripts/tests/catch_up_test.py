#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/catch-up.sh の検査 (#457)。

このスクリプトが守るのは 2 つ。

1. **打つ意味が無いときは走らない。** `make ci-check` は絵の検査を含むので数分
   かかる。描画に触れない PR や、順番でない PR で回してしまうと、その数分がまるごと
   無駄になる (順番でないうちは、先頭が入った時点でまた覆えなくなる)
2. **報告が付いたことを確かめてから queue へ戻す。** render-status は報告できなくても
   0 で終える設計なので、確かめずに戻すと弾かれた状態のまま入り直す

「待て (3)」と「壊れている (1)」を取り違えないことも併せて固定する — 取り違えると、
待つのが正解の場面で人が直しにかかる。

gh と make は PATH の先頭に置いた偽物へ差し替え、git は使い捨ての一時リポジトリ
(origin も手元の bare) を使うので、ネットワークも認証も要らない。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "catch-up.sh"

PATHS = "# 見出し\n\nSources/MokumeCore/\nSketches/\n"

FAKE_GH = """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "auth status") exit 0 ;;
esac
# 本人の認証かの判定 (App の installation token では通らない)
if [ "$1 $2" = "api user" ]; then
  [ -z "${NOT_A_USER:-}" ] || { echo "gh: 403" >&2; exit 1; }
  echo "someone"; exit 0
fi
if [[ "$*" == "repo view"* ]]; then
  printf '%s\\n' "mokume-metal/mokume"; exit 0
fi
if [[ "$*" == "pr view"* && "$*" == *"files"* ]]; then
  printf '%s\\n' ${PR_FILES:-}
  exit 0
fi
if [[ "$*" == "pr view"* ]]; then
  [ -z "${NO_PR:-}" ] || { echo "gh: no pull requests found" >&2; exit 1; }
  printf '%s\\n' "${PR_INFO:-7 OPEN false}"
  exit 0
fi
# 順番の判定が読む open な PR の一覧
if [[ "$*" == *"/pulls?"* ]]; then
  printf '%s\\n' ${OPEN_PRS:-}
  exit 0
fi
if [[ "$*" == *"/files"* ]]; then
  for entry in ${FILES_BY_PR:-}; do
    if [[ "$*" == *"/pulls/${entry%%=*}/files"* ]]; then
      printf '%s\\n' "${entry#*=}" | tr ',' '\\n'
      exit 0
    fi
  done
  exit 0
fi
if [[ "$*" == *"/statuses"* ]]; then
  printf '%s\\n' "${REPORTED:-success}"
  exit 0
fi
if [[ "$*" == "api graphql"* ]]; then
  printf '%s\\n' "isInMergeQueue=true position=1 state=AWAITING_CHECKS"
  exit 0
fi
if [[ "$*" == "pr merge"* ]]; then
  [ -z "${MERGE_FAILS:-}" ] || { echo "gh: 422" >&2; exit 1; }
  exit 0
fi
exit 0
"""

FAKE_MAKE = """#!/bin/bash
printf '%s\\n' "$*" >> "$MAKE_CALLS"
if [ "$1" = "ci-check" ] && [ -n "${CI_CHECK_FAILS:-}" ]; then
  echo "make: 検査が落ちた" >&2
  exit 2
fi
exit 0
"""

DRAWING = "Sources/MokumeCore/Canvas.swift"
NOT_DRAWING = "AGENTS.md"


class CatchUpTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name, body in (("gh", FAKE_GH), ("make", FAKE_MAKE)):
            path = bin_dir / name
            path.write_text(body)
            path.chmod(0o755)
        self.gh_calls = self.root / "gh-calls.txt"
        self.make_calls = self.root / "make-calls.txt"

        # origin を手元の bare リポジトリにする。取り込みと push を本物の git で通す
        self.origin = self.root / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(self.origin)], check=True)

        self.work = self.root / "work"
        self.work.mkdir()
        self._git("init", "-q", "-b", "main")
        self._git("config", "user.email", "t@example.invalid")
        self._git("config", "user.name", "t")
        # 使い捨てのリポジトリは手元の署名設定から独立させる (#344)
        self._git("config", "commit.gpgsign", "false")
        self._git("remote", "add", "origin", str(self.origin))
        (self.work / "paths.txt").write_text(PATHS)
        (self.work / "seed.txt").write_text("seed\n")
        self._git("add", "-A")
        self._git("commit", "-qm", "seed")
        self._git("push", "-q", "-u", "origin", "main")
        self._git("switch", "-qc", "work")
        (self.work / "mine.txt").write_text("mine\n")
        self._git("add", "-A")
        self._git("commit", "-qm", "mine")
        self._git("push", "-q", "-u", "origin", "work")

        self.env = dict(os.environ)
        self.env.update(
            PATH=f"{bin_dir}:{os.environ['PATH']}",
            GH_CALLS=str(self.gh_calls),
            MAKE_CALLS=str(self.make_calls),
            DRAWING_PATHS="paths.txt",
            PR_FILES=DRAWING,
            OPEN_PRS="7",
        )

    def _git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.work, capture_output=True, text=True,
            encoding="utf-8", check=True
        ).stdout

    def run_script(self, **env):
        self.env.update({k: str(v) for k, v in env.items()})
        return subprocess.run(
            ["bash", str(SCRIPT)],
            cwd=self.work, env=self.env, capture_output=True, text=True,
            encoding="utf-8",
        )

    def made(self):
        if not self.make_calls.exists():
            return []
        return self.make_calls.read_text().split()

    def merged_calls(self):
        if not self.gh_calls.exists():
            return []
        return [c for c in self.gh_calls.read_text().splitlines() if c.startswith("pr merge")]

    def advance_main(self, name="theirs.txt"):
        """main を 1 コミット進める (合流後の姿が動いた状況を作る)。"""
        other = self.root / "other"
        subprocess.run(["git", "clone", "-q", str(self.origin), str(other)], check=True)
        for key, value in (("user.email", "t@example.invalid"), ("user.name", "t"),
                           ("commit.gpgsign", "false")):
            subprocess.run(["git", "config", key, value], cwd=other, check=True)
        (other / name).write_text("theirs\n")
        subprocess.run(["git", "add", "-A"], cwd=other, check=True)
        subprocess.run(["git", "commit", "-qm", "theirs"], cwd=other, check=True)
        subprocess.run(["git", "push", "-q"], cwd=other, check=True)

    # --- 打つ意味が無い場面 (3) ------------------------------------------

    def test_描画に触れない_PR_では走らない(self):
        proc = self.run_script(PR_FILES=NOT_DRAWING)
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertIn("描画に触れない", proc.stdout)
        self.assertNotIn("ci-check", self.made())

    def test_先に描画_PR_が居るときは走らない(self):
        proc = self.run_script(OPEN_PRS="5 7", FILES_BY_PR=f"5={DRAWING}")
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertIn("#5", proc.stdout)
        self.assertNotIn("ci-check", self.made())

    def test_先に居るのが描画に触れない_PR_なら走る(self):
        proc = self.run_script(OPEN_PRS="5 7", FILES_BY_PR=f"5={NOT_DRAWING}")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("ci-check", self.made())

    def test_Draft_では走らない(self):
        proc = self.run_script(PR_INFO="7 OPEN true")
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertIn("Draft", proc.stdout)
        self.assertNotIn("ci-check", self.made())

    def test_閉じた_PR_では走らない(self):
        proc = self.run_script(PR_INFO="7 MERGED false")
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertNotIn("ci-check", self.made())

    # --- 止まる場面 (1) ---------------------------------------------------

    def test_PR_が無ければ止まる(self):
        proc = self.run_script(NO_PR="1")
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("PR が無い", proc.stderr)

    def test_作業ツリーが汚れていれば止まる(self):
        (self.work / "dirty.txt").write_text("dirty\n")
        proc = self.run_script()
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("汚れている", proc.stderr)
        self.assertNotIn("ci-check", self.made())

    def test_App_の_token_を掴んでいれば先に止まる(self):
        proc = self.run_script(NOT_A_USER="1")
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("installation token", proc.stderr)
        self.assertNotIn("ci-check", self.made())

    def test_検査が落ちれば_queue_へ戻さない(self):
        proc = self.run_script(CI_CHECK_FAILS="1")
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertEqual(self.merged_calls(), [])

    def test_取り込みで衝突すれば止まり中止しない(self):
        self.advance_main("mine.txt")  # 同じ名前・違う中身をぶつける
        proc = self.run_script()
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("衝突", proc.stderr)
        # 木を畳まない — 解くべき中身が index に残っていること (git merge --abort を
        # 打っていれば、未解決の段が消えてここが空になる)
        self.assertNotEqual(self._git("ls-files", "-u").strip(), "")
        self.assertEqual(self.merged_calls(), [])

    def test_報告が付いていなければ_queue_へ戻さない(self):
        proc = self.run_script(REPORTED="failure")
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("local-render", proc.stderr)
        self.assertEqual(self.merged_calls(), [])

    def test_報告が無ければ_queue_へ戻さない(self):
        proc = self.run_script(REPORTED="無い")
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertEqual(self.merged_calls(), [])

    # --- 通る場面 (0) -----------------------------------------------------

    def test_main_を取り込んで_queue_へ戻す(self):
        self.advance_main()
        proc = self.run_script()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        # 5 手が順に走ったこと
        self.assertIn("main を取り込む", proc.stdout)
        self.assertEqual(self.made(), ["ci-check", "render-status"])
        self.assertEqual(self.merged_calls(), ["pr merge 7 --auto --squash"])
        # 取り込みが実際に効いていること
        self.assertIn("theirs.txt", self._git("ls-files"))
        # push まで届いていること
        self.assertEqual(
            self._git("rev-parse", "HEAD").strip(),
            self._git("rev-parse", "origin/work").strip())

    def test_取り込み済みでも報告と再投入は行う(self):
        proc = self.run_script()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("取り込み済み", proc.stdout)
        self.assertEqual(self.made(), ["ci-check", "render-status"])
        self.assertEqual(self.merged_calls(), ["pr merge 7 --auto --squash"])

    def test_queue_に載ったことを_isInMergeQueue_で示す(self):
        proc = self.run_script()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("isInMergeQueue=true", proc.stdout)
        # autoMergeRequest が null でも正常だと伝えること (#457 で取り違えた)
        self.assertIn("autoMergeRequest", proc.stdout)


if __name__ == "__main__":
    unittest.main()
