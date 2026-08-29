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
# 呼ばれた引数を記録する。auth status は通り、API は環境変数の作り物を返す
printf '%s\\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "auth status") exit 0 ;;
esac
if [[ "$*" == *"/statuses/"* && -n "${GH_STATUS_FAILS:-}" ]]; then
  echo "gh: 422" >&2
  exit 1
fi
# 木の中身。--jq の結果 (blob の "path sha" の並び) を模す。truncated は
# スクリプトが読む合図をそのまま返す
if [[ "$*" == *"/git/trees/"* ]]; then
  [ -z "${TREE_FAILS:-}" ] || { echo "gh: 404" >&2; exit 1; }
  [ -z "${TREE_TRUNCATED:-}" ] || { echo '!truncated'; exit 0; }
  if [[ "$*" == *"/git/trees/${MERGE_GROUP_SHA:-__none__}"* ]]; then
    printf '%b\\n' "$TREE_MERGED"
  else
    printf '%b\\n' "$TREE_HEAD"
  fi
  exit 0
fi
if [[ "$*" == *"/files"* ]]; then
  printf '%s\\n' $FILES
  exit 0
fi
# PR そのもの (--jq .head.sha)
if [[ "$*" == *"/pulls/"* ]]; then
  printf '%s\\n' "${PR_HEAD_SHA:-headsha}"
  exit 0
fi
exit 0
"""

# 木の中身の作り物。描画に関わる 1 行が動くかどうかで覆いの判定が変わる
TREE_BASE = "Sources/MokumeCore/Canvas.swift aaa1\\nAGENTS.md bbb1"
TREE_DRAWING_MOVED = "Sources/MokumeCore/Canvas.swift aaa2\\nAGENTS.md bbb1"
TREE_OTHER_MOVED = "Sources/MokumeCore/Canvas.swift aaa1\\nAGENTS.md bbb2"


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

    # --- proxy / merge queue -------------------------------------------
    #
    # 手元の実行は**合流前の枝**でしか回らないので、queue の SHA には手元の報告が
    # 付きようがない。以前はそこを無条件の success で埋めていて、描画 PR が 2 本
    # 並走すると後から入ったほうが merge 後に main を赤くした (#432 / #435)。
    # ここで固定するのは「手元の報告が合流後の姿を覆っているか」の判定である。

    def queue(self, **env):
        base = dict(
            GITHUB_REPOSITORY="mokume-metal/mokume",
            GITHUB_EVENT_NAME="merge_group",
            MERGE_GROUP_SHA="cafe1234",
            MERGE_GROUP_HEAD_REF="gh-readonly-queue/main/pr-5-0123456789abcdef",
            PR_HEAD_SHA="beef5678",
            FILES="AGENTS.md Sources/MokumeCore/Canvas.swift",
            TREE_HEAD=TREE_BASE,
            TREE_MERGED=TREE_BASE,
            TREE_FAILS="",
            TREE_TRUNCATED="",
        )
        base.update(env)
        return self.run_script("proxy", **base)

    def test_覆えている描画PRは報告する(self):
        out = self.queue()
        posted = self.posted()
        self.assertEqual(len(posted), 1)
        self.assertIn("statuses/cafe1234", posted[0])
        self.assertIn("state=success", posted[0])
        # 何本を見た上で通したのかを名乗る (#441)
        self.assertIn("1 本の描画 PR", posted[0])
        self.assertIn("#5 は覆えている", out)

    def test_覆えていない描画PRには失敗を打つ(self):
        """#432 を止める行。main 側で描画のファイルが動いていれば、手元で回した木は
        合流後の姿を覆っていない — 待たせずに落として queue から外す。"""
        out = self.queue(TREE_MERGED=TREE_DRAWING_MOVED)
        posted = self.posted()
        self.assertEqual(len(posted), 1)
        self.assertIn("state=failure", posted[0])
        self.assertIn("覆っていない", out)

    def test_描画に触れないPRはmainが動いていても通す(self):
        """描画に触れない PR は main の絵の組み合わせを動かさない。BEHIND のまま
        merge できる従来の運用をここで壊さない。"""
        out = self.queue(
            FILES="AGENTS.md docs/decisions/0001-founding-principles.md",
            TREE_MERGED=TREE_DRAWING_MOVED,
        )
        posted = self.posted()
        self.assertEqual(len(posted), 1)
        self.assertIn("state=success", posted[0])
        # 読み飛ばすときも名乗る (#441)。黙って飛ばすと、通した回のログが
        # 「見た上で通した」のか「見る対象が無かった」のか読めない
        self.assertIn("#5 は描画に触れない", out)

    def test_見る対象が無かった回は覆っていると名乗らない(self):
        """#439 自身の merge がこれだった — 描画 PR は 1 本も無いのに、報告だけが
        「覆っている」と読める行を残した (#441)。"""
        self.queue(FILES="AGENTS.md")
        self.assertIn("描画に触れる PR は無い", self.posted()[0])

    def test_見る対象が無ければ合流後の木を引かない(self):
        """指紋は見る対象が現れて初めて要る。先に引くと、対象が無い回にも
        「木を読めなかった」という無関係な名乗りが出る経路が残る (#441)。"""
        self.queue(FILES="AGENTS.md")
        self.assertNotIn("/git/trees/", self.calls.read_text())

    def test_合流後の木は何本積まれても一度しか引かない(self):
        self.queue(MERGE_GROUP_HEAD_REF="gh-readonly-queue/main/pr-5-pr-6-0123456789ab")
        merged = [
            c
            for c in self.calls.read_text().splitlines()
            if "/git/trees/cafe1234" in c
        ]
        self.assertEqual(len(merged), 1, merged)

    def test_描画に関わらないファイルが動いただけなら覆えている(self):
        self.queue(TREE_MERGED=TREE_OTHER_MOVED)
        posted = self.posted()
        self.assertIn("state=success", posted[0])

    def test_木が読めなければ名乗って通す(self):
        out = self.queue(TREE_FAILS="1")
        self.assertIn("state=success", self.posted()[0])
        self.assertIn("覆いは見ていない", out)

    def test_木がtruncatedなら名乗って通す(self):
        out = self.queue(TREE_TRUNCATED="1")
        self.assertIn("state=success", self.posted()[0])
        self.assertIn("覆いは見ていない", out)

    def test_PR番号を読めなければ名乗って通す(self):
        out = self.queue(MERGE_GROUP_HEAD_REF="")
        self.assertIn("state=success", self.posted()[0])
        self.assertIn("覆いは見ていない", out)

    def test_積まれたPRをすべて見る(self):
        """queue はまとめて積む (max_entries_to_build: 5)。1 本でも覆えていなければ
        通さないので、枝の名前にある PR 番号は全件読む。"""
        self.queue(MERGE_GROUP_HEAD_REF="gh-readonly-queue/main/pr-5-pr-6-0123456789ab")
        calls = self.calls.read_text()
        self.assertIn("/pulls/5/files", calls)
        self.assertIn("/pulls/6/files", calls)


if __name__ == "__main__":
    unittest.main()
