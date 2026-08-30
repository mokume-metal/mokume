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
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "render-status.sh"

LEDGER = "shapes 1111\ntransforms 2222\n"
# `Sketches/` は印つきの行 — 絵の証跡は要るが、覆いの判定には数えない (#497)
PATHS = "# 見出し\n\nSources/MokumeCore/\nSketches/  evidence-only\n"

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
# open な PR の一覧 (--jq が draft を落とした後の番号の並び)。順番の判定が読む
if [[ "$*" == *"/pulls?"* ]]; then
  [ -z "${OPEN_PRS_FAILS:-}" ] || { echo "gh: 500" >&2; exit 1; }
  printf '%s\\n' ${OPEN_PRS:-}
  exit 0
fi
if [[ "$*" == *"/files"* ]]; then
  # 特定の PR だけ読めない状況を作る (判定の途中で見えなくなる回)
  if [ -n "${FILES_FAILS_FOR:-}" ] && [[ "$*" == *"/pulls/${FILES_FAILS_FOR}/files"* ]]; then
    echo "gh: 404" >&2
    exit 1
  fi
  # PR ごとに違う一覧を返す口。順番の判定は**自分以外の PR の中身**を見るので、
  # 「先に居るが描画には触れていない PR」を作れる必要がある (書式は 番号=a,b)
  for entry in ${FILES_BY_PR:-}; do
    if [[ "$*" == *"/pulls/${entry%%=*}/files"* ]]; then
      printf '%s\\n' "${entry#*=}" | tr ',' '\\n'
      exit 0
    fi
  done
  printf '%s\\n' $FILES
  exit 0
fi
# commit に付いた status。--jq が抜いた後の description (local-render の最新の success)
if [[ "$*" == *"/commits/"*"/statuses"* ]]; then
  [ -z "${STATUSES_FAILS:-}" ] || { echo "gh: 404" >&2; exit 1; }
  printf '%s\n' "${COVERS_DESCRIPTION:-}"
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
TREE_BASE = "Sources/MokumeCore/Canvas.swift aaa1\\nSketches/main.swift ccc1\\nAGENTS.md bbb1"
TREE_DRAWING_MOVED = "Sources/MokumeCore/Canvas.swift aaa2\\nSketches/main.swift ccc1\\nAGENTS.md bbb1"
TREE_OTHER_MOVED = "Sources/MokumeCore/Canvas.swift aaa1\\nSketches/main.swift ccc1\\nAGENTS.md bbb2"
# 印つきの場所だけが動いた木。覆いの判定はここを見ない (#497)
TREE_SKETCH_MOVED = "Sources/MokumeCore/Canvas.swift aaa1\\nSketches/main.swift ccc2\\nAGENTS.md bbb1"


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
        # 使い捨てのリポジトリは手元の署名設定から独立させる (#344)
        self._git("config", "commit.gpgsign", "false")
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

    def posted_to(self, sha):
        return [c for c in self.posted() if f"/statuses/{sha}" in c]

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

    def test_報告は回した木の指紋を名乗る(self):
        """#612。merge queue はこの値と合流後の木を突き合わせる。名乗らなくなると
        判定が head の木へ落ちて、push を要求する形へ静かに戻る。"""
        self.write_log(LOG_PASSED)
        self.run_script("local")
        self.assertRegex(self.posted()[0], r"covers=[0-9a-f]{12}")

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
            OPEN_PRS="5",
            FILES="AGENTS.md Sources/MokumeCore/Drawing/Canvas.swift",
        )
        self.assertEqual(self.posted(), [])
        self.assertIn("手元の報告を待つ", out)

    def test_台帳の絵を動かさない場所だけの変更には代理で報告する(self):
        """`Sketches/` は絵の証跡は要るが、手元の実行の覆いは壊せない (#497)。
        覆いを壊さないなら手元の報告を待つ理由が無いので、代理で緑にする。"""
        out = self.run_script(
            "proxy",
            GITHUB_REPOSITORY="mokume-metal/mokume",
            GITHUB_EVENT_NAME="pull_request",
            PR_NUMBER="5",
            PR_HEAD_SHA="deadbeef",
            FILES="Sketches/Shapes/Circles.swift",
        )
        posted = self.posted()
        self.assertEqual(len(posted), 1)
        self.assertIn("state=success", posted[0])
        self.assertIn("覆いを壊さない", posted[0])
        self.assertNotIn("手元の報告を待つ", out)

    # --- proxy / 描画 PR の順番 -----------------------------------------
    #
    # #435 の判定は「手元で回した木が合流後の姿を覆っているか」を見る。裏を返すと
    # 「手元で打ってから merge されるまでに描画の変更が入らないこと」を要求して
    # おり、描画 PR が並走すると片方が入るたびにもう片方が弾かれた (#456 は 3 回)。
    # ここで固定するのは、その追いかけっこを止める番号順の順番である (#467)。

    def turn(self, **env):
        base = dict(
            GITHUB_REPOSITORY="mokume-metal/mokume",
            GITHUB_EVENT_NAME="pull_request",
            PR_NUMBER="9",
            PR_HEAD_SHA="deadbeef",
            OPEN_PRS="3 9",
            FILES="Sources/MokumeCore/Canvas.swift",
            FILES_BY_PR="",
            OPEN_PRS_FAILS="",
            FILES_FAILS_FOR="",
            COVERS_DESCRIPTION="",
            STATUSES_FAILS="",
        )
        base.update(env)
        return self.run_script("proxy", **base)

    def merged_fingerprint(self, **env):
        """合流後の木の指紋を、スクリプト自身の名乗りから読む。

        検査の側で指紋を組み立て直すと**判定の実体が 2 つ**になる (ADR-0001 原則 9)。
        覆えていない回の「合流後=…」をそのまま使えば、綴りが動いてもここは追随する。"""
        out = self.queue(TREE_HEAD=TREE_DRAWING_MOVED, **env)
        self.calls.unlink(missing_ok=True)  # 下ごしらえの分を数えない
        match = re.search(r"合流後=([0-9a-f]+)", out)
        self.assertIsNotNone(match, out)
        return match.group(1)

    def test_先に描画PRが居れば順番待ちで赤くする(self):
        out = self.turn()
        posted = self.posted_to("deadbeef")
        self.assertEqual(len(posted), 1)
        self.assertIn("failure", posted[0])
        self.assertIn("#3 の merge を待つ", posted[0])
        self.assertIn("先に #3 が居る", out)

    def test_先に居るのが描画に触れないPRなら先頭として扱う(self):
        out = self.turn(FILES_BY_PR="3=AGENTS.md,docs/decisions/0001-founding-principles.md")
        self.assertEqual(self.posted(), [])
        self.assertIn("この PR が描画の先頭", out)

    def test_順番待ちの相手は先に居る描画PRのうち最も若い番号(self):
        out = self.turn(
            OPEN_PRS="3 7 9",
            FILES_BY_PR="3=AGENTS.md 7=Sources/MokumeCore/Text.swift",
        )
        self.assertIn("#7 の merge を待つ", self.posted_to("deadbeef")[0])
        self.assertIn("先に #7 が居る", out)

    def test_先に居るのが台帳の絵を動かさないPRなら先頭として扱う(self):
        """#497 の実害そのもの — 完成した `Sketches/` の PR が、番号が若いだけの
        作業中の PR を待たされていた。覆いを壊さない PR は行列を作らない。"""
        out = self.turn(FILES_BY_PR="3=Sketches/main.swift")
        self.assertEqual(self.posted(), [])
        self.assertIn("この PR が描画の先頭", out)

    def test_台帳の絵を動かさないPRは順番待ちに並ばない(self):
        out = self.turn(FILES="Sketches/main.swift")
        posted = self.posted_to("deadbeef")
        self.assertEqual(len(posted), 1)
        self.assertIn("state=success", posted[0])
        self.assertNotIn("先に #3 が居る", out)

    def test_自分より後ろの描画PRは順番を塞がない(self):
        out = self.turn(PR_NUMBER="3", OPEN_PRS="3 9")
        self.assertEqual(self.posted(), [])
        self.assertIn("この PR が描画の先頭", out)

    def test_Draftの描画PRは順番の外(self):
        # 一覧は draft を落とした後の並びなので、自分が居なければ Draft である
        out = self.turn(OPEN_PRS="3")
        self.assertEqual(self.posted(), [])
        self.assertIn("順番の外", out)

    def test_open_PRの一覧を読めなければ名乗って通す(self):
        out = self.turn(OPEN_PRS_FAILS="1")
        self.assertEqual(self.posted(), [])
        self.assertIn("順番は見ていない", out)

    def test_先に居るPRの中身を読めなければ名乗って通す(self):
        out = self.turn(FILES_FAILS_FOR="3")
        self.assertEqual(self.posted(), [])
        self.assertIn("順番は見ていない", out)

    def test_描画に触れないPRは順番を見ない(self):
        # 順番待ちの failure は手元の実行でしか緑に戻せない。描画に触れない PR に
        # 打ってしまうと、打ち直す先の無い赤で止まる
        out = self.turn(
            FILES="AGENTS.md",
            OPEN_PRS="3 9",
            FILES_BY_PR="3=Sources/MokumeCore/Canvas.swift",
        )
        posted = self.posted_to("deadbeef")
        self.assertEqual(len(posted), 1)
        self.assertIn("覆いを壊さない", posted[0])
        self.assertNotIn("先に #3 が居る", out)

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
            FILES_FAILS_FOR="",
            COVERS_DESCRIPTION="",
            STATUSES_FAILS="",
        )
        base.update(env)
        return self.run_script("proxy", **base)

    def merged_fingerprint(self, **env):
        """合流後の木の指紋を、スクリプト自身の名乗りから読む。

        検査の側で指紋を組み立て直すと**判定の実体が 2 つ**になる (ADR-0001 原則 9)。
        覆えていない回の「合流後=…」をそのまま使えば、綴りが動いてもここは追随する。"""
        out = self.queue(TREE_HEAD=TREE_DRAWING_MOVED, **env)
        self.calls.unlink(missing_ok=True)  # 下ごしらえの分を数えない
        match = re.search(r"合流後=([0-9a-f]+)", out)
        self.assertIsNotNone(match, out)
        return match.group(1)

    def test_覆えている描画PRは報告する(self):
        out = self.queue()
        posted = self.posted()
        self.assertEqual(len(posted), 1)
        self.assertIn("statuses/cafe1234", posted[0])
        self.assertIn("state=success", posted[0])
        # 何本を見た上で通したのかを名乗る (#441)
        self.assertIn("1 本の描画 PR", posted[0])
        self.assertIn("#5 は覆えている", out)

    def test_手元が名乗る指紋で覆いを判定する(self):
        """#612。覆い直しのたびに push させると、ルールセットが承認を落とす。判定に
        要るのは「どの木を回したか」だけなので、それを報告そのものから読む。

        ここで固定するのは**head の木が合流後と違っていても、報告が合流後の木を
        名乗っていれば覆えている**こと — これが成り立つと push が要らなくなる。"""
        fingerprint = self.merged_fingerprint()
        out = self.queue(
            TREE_HEAD=TREE_DRAWING_MOVED,
            COVERS_DESCRIPTION=f"手元で全検査が通った skipped=0 ledger=abcd covers={fingerprint}",
        )
        posted = self.posted()
        self.assertEqual(len(posted), 1, posted)
        self.assertIn("state=success", posted[0])
        self.assertIn("手元の報告=", out)

    def test_名乗る指紋が合流後と違えば弾く(self):
        """報告が head の木より**強い**ことの裏側。head の木が合流後と同じでも、
        手元が別の木を回したと名乗っているなら覆えていない。"""
        out = self.queue(
            COVERS_DESCRIPTION="手元で全検査が通った skipped=0 ledger=abcd covers=000000000000",
        )
        self.assertEqual(len(self.posted()), 2, self.posted())
        self.assertIn("state=failure", self.posted_to("cafe1234")[0])
        self.assertIn("手元の報告=000000000000", out)

    def test_指紋を名乗らない報告はheadの木で判定する(self):
        """古い報告・手で打った status への逃がし。名乗りが無ければ今までどおり。"""
        out = self.queue(COVERS_DESCRIPTION="手元で全検査が通った skipped=0 ledger=abcd")
        self.assertIn("head の木=", out)
        self.assertIn("state=success", self.posted_to("cafe1234")[0])

    def test_statusを読めなくてもheadの木で判定できる(self):
        out = self.queue(STATUSES_FAILS="1")
        self.assertIn("head の木=", out)
        self.assertIn("state=success", self.posted_to("cafe1234")[0])

    def test_覆えていない描画PRには失敗を打つ(self):
        """#432 を止める行。main 側で描画のファイルが動いていれば、手元で回した木は
        合流後の姿を覆っていない — 待たせずに落として queue から外す。

        failure は **queue のコミットと PR の head の両方**に打つ (#462)。queue の
        コミットだけに打っていた頃は gh pr checks にもタイムラインにも現れず、
        弾かれたことに気付く経路が人間しか無かった。"""
        out = self.queue(TREE_MERGED=TREE_DRAWING_MOVED)
        self.assertEqual(len(self.posted()), 2, self.posted())
        queue_post = self.posted_to("cafe1234")
        self.assertEqual(len(queue_post), 1)
        self.assertIn("state=failure", queue_post[0])
        self.assertIn("#5", queue_post[0])
        self.assertIn("覆っていない", out)

    def test_覆えていないPRのheadが赤くなる(self):
        """gh pr checks が見るのは PR の head である。ここが赤くならないと、
        弾かれたことは PR 側のどこにも出ない (#462)。"""
        self.queue(TREE_MERGED=TREE_DRAWING_MOVED)
        head_post = self.posted_to("beef5678")
        self.assertEqual(len(head_post), 1, self.posted())
        self.assertIn("state=failure", head_post[0])
        # 理由と直し方を description が名乗る
        self.assertIn("merge queue で弾かれた", head_post[0])
        self.assertIn("make ci-check", head_post[0])

    def test_覆えているPRのheadには打たない(self):
        """CI が head へ打つのは failure だけである。success を打てるようにすると、
        手元の実行しか local-render を打たないという #304 の不変条件が崩れる。"""
        self.queue()
        self.assertEqual(self.posted_to("beef5678"), [])

    def test_覆えていないPRが複数あればすべてのheadが赤くなる(self):
        """queue はまとめて積む (max_entries_to_build: 5)。1 本目で切り上げると、
        2 本目以降の作者にとっては何も変わらない — 自分の PR は緑のまま弾かれる。"""
        out = self.queue(
            MERGE_GROUP_HEAD_REF="gh-readonly-queue/main/pr-5-pr-6-0123456789ab",
            TREE_MERGED=TREE_DRAWING_MOVED,
        )
        # head は偽 gh が 1 つしか返さないので、2 本ぶんの報告が同じ SHA へ 2 回打たれる
        self.assertEqual(len(self.posted_to("beef5678")), 2, self.posted())
        self.assertIn("#5 の手元の実行は", out)
        self.assertIn("#6 の手元の実行は", out)
        queue_post = self.posted_to("cafe1234")
        self.assertEqual(len(queue_post), 1)
        self.assertIn("state=failure", queue_post[0])
        # queue の報告は覆えていない PR を全部名乗る
        self.assertIn("#5", queue_post[0])
        self.assertIn("#6", queue_post[0])

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
        self.assertIn("#5 は台帳の絵を動かさない", out)

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

    def test_台帳の絵を動かさない場所が動いただけなら覆えている(self):
        """`Sketches/` は台帳が描く絵を 1 画素も動かせないので、そこが合流後に
        動いていても手元の実行は合流後の姿を覆っている (#497)。合流後の木の
        ビルド破れは merge queue の ci-check が見る。"""
        self.queue(TREE_MERGED=TREE_SKETCH_MOVED)
        posted = self.posted()
        self.assertEqual(len(posted), 1)
        self.assertIn("state=success", posted[0])

    def test_木が読めなければ名乗って通す(self):
        out = self.queue(TREE_FAILS="1")
        self.assertIn("state=success", self.posted()[0])
        self.assertIn("覆いは見ていない", out)

    def test_木がtruncatedなら名乗って通す(self):
        out = self.queue(TREE_TRUNCATED="1")
        self.assertIn("state=success", self.posted()[0])
        self.assertIn("覆いは見ていない", out)

    def test_覆えていない判定は後から読めなくなっても覆らない(self):
        """「読めなければ名乗って通す」は判定できなかったときの逃がしであって、
        判定できた failure を取り消す口ではない (#462)。"""
        out = self.queue(
            MERGE_GROUP_HEAD_REF="gh-readonly-queue/main/pr-5-pr-6-0123456789ab",
            TREE_MERGED=TREE_DRAWING_MOVED,
            FILES_FAILS_FOR="6",
        )
        queue_post = self.posted_to("cafe1234")
        self.assertEqual(len(queue_post), 1)
        self.assertIn("state=failure", queue_post[0])
        self.assertIn("#6 の変更ファイルを読めなかった", out)

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

    # --- target (報告先) -------------------------------------------------
    #
    # 覆い直しのたびに push すると、ルールセットの dismiss_stale_reviews_on_push が
    # 承認を落とす (#612)。**取り込みだけの木なら push 済み head へ報告する**ので
    # push が要らない。ここで固定するのは「どこまでを取り込みだけと見るか」である。

    def _upstream_scenario(self):
        """push 済みの head (origin/topic) と、その先へ進んだ origin/main を作る。

        **枝には自分の commit を持たせる。** 持たせないと取り込みが早送りになり、
        合流の commit が生まれないので、判定したい形にならない。"""
        self._git("checkout", "-qb", "topic")
        (self.work / "topic.txt").write_text("枝の変更\n")
        self._git("add", "-A")
        self._git("commit", "-qm", "枝の変更")
        pushed = self._git("rev-parse", "HEAD").strip()
        self._git("update-ref", "refs/remotes/origin/topic", pushed)
        self._git("branch", "--set-upstream-to=origin/topic", "topic")
        self._git("checkout", "-q", "main")
        (self.work / "other.txt").write_text("main が進んだ\n")
        self._git("add", "-A")
        self._git("commit", "-qm", "main が進む")
        self._git("update-ref", "refs/remotes/origin/main", self._git("rev-parse", "HEAD").strip())
        self._git("checkout", "-q", "topic")
        return pushed

    def test_取り込みだけの木はpush済みheadへ報告する(self):
        seed = self._upstream_scenario()
        self._git("merge", "--no-edit", "-q", "origin/main")
        self.assertEqual(self.run_script("target").strip(), seed)

    def test_普通のcommitが乗っていたらHEADへ報告する(self):
        """手元にしかない commit の木は誰も見られない。報告先を push 済み head へ
        寄せると、報告とその中身が食い違う。"""
        self._upstream_scenario()
        (self.work / "later.txt").write_text("push していない変更\n")
        self._git("add", "-A")
        self._git("commit", "-qm", "push していない変更")
        self._git("merge", "--no-edit", "-q", "origin/main")
        self.assertEqual(
            self.run_script("target").strip(), self._git("rev-parse", "HEAD").strip()
        )

    def test_衝突を解いた合流はHEADへ報告する(self):
        """解いた中身は remote に無いので、queue も同じ木を作れない。そこは push が
        要り、承認のやり直しも正しい。"""
        self._upstream_scenario()
        self._git("merge", "--no-commit", "--no-ff", "-q", "origin/main")
        (self.work / "other.txt").write_text("解いた結果\n")
        self._git("add", "-A")
        self._git("commit", "-qm", "解いて合流")
        self.assertEqual(
            self.run_script("target").strip(), self._git("rev-parse", "HEAD").strip()
        )

    def test_追跡先が無ければHEADへ報告する(self):
        self.assertEqual(
            self.run_script("target").strip(), self._git("rev-parse", "HEAD").strip()
        )


if __name__ == "__main__":
    unittest.main()
