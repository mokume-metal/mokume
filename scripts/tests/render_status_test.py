#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/render-status.sh の検査 (#304)。

このスクリプトが守るのは 1 つ — **絵の検査が実際に走った commit にだけ
local-render を打つ**こと。打ってしまう側へ倒れると、打ち忘れた PR が緑で通る
状態に戻る (それが #304 の穴そのもの) ので、報告しない条件を 1 つずつ固定する。

`local` は「打つべきでないときに打たない」を、`proxy` は「描画に触れている PR に
代理で打ってしまわない」を主に見る。どちらも**失敗しない** (報告しない理由を述べて
0 で終える) ことを併せて固定する — 赤くする役目は GitHub 側の必須チェックの待ちが
担っており、ここで赤くすると make ci-check が報告のために落ちる。

gh は PATH の先頭に置いた偽物へ差し替え、git も使い捨ての一時リポジトリを作るので、
ネットワークも認証も要らない。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "render-status.sh"

LEDGER = "shapes 1111\ntransforms 2222\n"
PATHS = "# 見出し\n\nSources/MokumeCore/\nSketches/\n"

# 台帳の suite が通った実行の記録 (実際の出力の要点だけ)
LOG_PASSED = """◇ Test run started.
✔ Suite "代表シーンの台帳" passed after 1.234 seconds.
✔ Test run with 62 tests passed after 12.345 seconds.
"""
# GPU の無い機械の記録 — 台帳の suite はスキップされている
LOG_SKIPPED = """◇ Test run started.
➜ Suite "代表シーンの台帳" skipped: "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"
✔ Test run with 31 tests passed after 3.210 seconds.
"""

FAKE_GH = """#!/bin/bash
# 呼ばれた引数を記録する。auth status は通り、pulls/N/files は FILES を返す
printf '%s\\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "auth status") exit 0 ;;
esac
if [[ "$*" == *"/statuses/"* && -n "${GH_STATUS_FAILS:-}" ]]; then
  echo "gh: 422" >&2
  exit 1
fi
if [[ "$*" == *"/files"* ]]; then
  printf '%s\\n' $FILES
fi
exit 0
"""


class RenderStatusTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        self.calls = self.root / "gh-calls.txt"

        self.work = self.root / "work"
        (self.work / ".build").mkdir(parents=True)
        self._git("init", "-q", "-b", "main")
        self._git("config", "user.email", "t@example.invalid")
        self._git("config", "user.name", "t")
        self._git("remote", "add", "origin", "git@github.com:mokume-metal/mokume.git")
        # 追跡されていないファイルも「汚れ」に数える (追跡外の .swift は、ビルドには
        # 入るのに HEAD には無い)。だから土台のファイルは commit まで済ませておく
        (self.work / "seed.txt").write_text("seed\n")
        (self.work / "ledger.txt").write_text(LEDGER)
        (self.work / "paths.txt").write_text(PATHS)
        (self.work / ".gitignore").write_text(".build/\n")
        self._git("add", "-A")
        self._git("commit", "-qm", "seed")
        self.sha = self._git("rev-parse", "HEAD").strip()

        self.env = dict(os.environ)
        self.env.update(
            PATH=f"{bin_dir}:{os.environ['PATH']}",
            GH_CALLS=str(self.calls),
            FILES="",
            RENDER_TEST_LOG=".build/test-log.txt",
            RENDER_LEDGER="ledger.txt",
            DRAWING_PATHS="paths.txt",
        )

    def _git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.work, capture_output=True, text=True,
            encoding="utf-8", check=True
        ).stdout

    def run_script(self, mode, **env):
        self.env.update(env)
        proc = subprocess.run(
            ["bash", str(SCRIPT), mode],
            cwd=self.work,
            env=self.env,
            capture_output=True,
            text=True,
            # スクリプトは日本語で理由を述べる。ロケールに委ねると読めない環境がある
            encoding="utf-8",
        )
        self.assertEqual(proc.returncode, 0, f"0 で終えるべき: {proc.stderr}")
        return proc.stdout

    def posted(self):
        if not self.calls.exists():
            return []
        return [c for c in self.calls.read_text().splitlines() if "/statuses/" in c]

    def write_log(self, body):
        (self.work / ".build" / "test-log.txt").write_text(body)

    # --- local ---------------------------------------------------------

    def test_全部通った実行は報告する(self):
        self.write_log(LOG_PASSED)
        self.run_script("local")
        posted = self.posted()
        self.assertEqual(len(posted), 1)
        self.assertIn(f"repos/mokume-metal/mokume/statuses/{self.sha}", posted[0])
        self.assertIn("context=local-render", posted[0])
        self.assertIn("state=success", posted[0])

    def test_台帳のsuiteが通っていなければ報告しない(self):
        self.write_log(LOG_SKIPPED)
        out = self.run_script("local")
        self.assertEqual(self.posted(), [])
        self.assertIn("報告しない", out)

    def test_テストの記録が無ければ報告しない(self):
        out = self.run_script("local")
        self.assertEqual(self.posted(), [])
        self.assertIn("報告しない", out)

    def test_作業ツリーが汚れていれば報告しない(self):
        self.write_log(LOG_PASSED)
        (self.work / "seed.txt").write_text("触った\n")
        out = self.run_script("local")
        self.assertEqual(self.posted(), [])
        self.assertIn("報告しない", out)

    def test_報告に失敗しても検査は落ちない(self):
        """まだ push していない commit では status を打てない。それは作業の途中と
        いうだけなので、make ci-check をそこで赤くしない。"""
        self.write_log(LOG_PASSED)
        out = self.run_script("local", GH_STATUS_FAILS="1")
        self.assertIn("報告できなかった", out)
        self.assertIn("make render-status", out)

    # --- proxy ---------------------------------------------------------

    def test_描画に触れていないPRには代理で報告する(self):
        self.run_script(
            "proxy",
            GITHUB_REPOSITORY="mokume-metal/mokume",
            GITHUB_EVENT_NAME="pull_request",
            PR_NUMBER="5",
            PR_HEAD_SHA="deadbeef",
            FILES="docs/decisions/0001-founding-principles.md AGENTS.md",
        )
        posted = self.posted()
        self.assertEqual(len(posted), 1)
        self.assertIn("statuses/deadbeef", posted[0])

    def test_描画に触れているPRには代理で報告しない(self):
        out = self.run_script(
            "proxy",
            GITHUB_REPOSITORY="mokume-metal/mokume",
            GITHUB_EVENT_NAME="pull_request",
            PR_NUMBER="5",
            PR_HEAD_SHA="deadbeef",
            FILES="AGENTS.md Sources/MokumeCore/Drawing/Canvas.swift",
        )
        self.assertEqual(self.posted(), [])
        self.assertIn("手元の報告を待つ", out)

    def test_mergequeueには無条件に報告する(self):
        self.run_script(
            "proxy",
            GITHUB_REPOSITORY="mokume-metal/mokume",
            GITHUB_EVENT_NAME="merge_group",
            MERGE_GROUP_SHA="cafe1234",
        )
        posted = self.posted()
        self.assertEqual(len(posted), 1)
        self.assertIn("statuses/cafe1234", posted[0])


if __name__ == "__main__":
    unittest.main()
