#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/stall-watch.sh と scripts/stall-act.sh の検査 (#961)。

固定したいのは十六。

1. **集約のジョブ (ci-gate) は上流より後に打つ** (#1883)。先に打つと ci-gate だけが前の結論を
   読んで同じ赤を返し、その run が走っている間は上流の打ち直しが拒まれる。除外したジョブ
   (render-pr・pr-gate) には打たない
2. **同じ run の他の失敗ジョブには打つ。** 除外を守るために全部を飛ばしてしまうと、
   古い失敗 check が判定を固定したまま (#259 / #513) 誰も直さなくなる
3. **凍結されたペイロードの可変欄を読むジョブが、除外リストに載っている。** いまは
   1 本も無い (ci.yml の pr-title は #2669 で消えた) が、同じ形のジョブが増えたときに人が
   気付く経路が無い (#801 と同じ形)。タイトルの赤は pr-gate のタイトルの step で読む
4. **BLOCKED で予約が外れた PR は、重要パスに触れていても名乗る。** 承認のゲートは
   ADR-0044 で外れた (#2108) ので、承認待ちと読んで黙ると予約が外れたまま誰も直さない
5. **判定は何も打たない。** 手元で様子を見るために打っただけで auto-merge が掛かると、
   判定と対処を分けた意味が消える
6. **Draft と fork からの PR は見ない。** 作業中の PR を Draft にしておくのが opt-out で、
   fork の PR に予約を掛けるかは引き取るメンテナが決める (#1361)
7. **猶予の中の名乗りでは赤くしない。** 走るたびに通知が飛ぶと「毎回出る注意は意味を
   失う」(#642) を踏む
8. **専用機の runner が止まったことを、順番待ちと分けて名乗る** (#1774)。必須の render が
   走らないと、描画に触れない PR も含めて queue 全体が止まる。1 台なので、他の run を
   走らせている間の queued は正常な順番待ちで、名乗ると毎回の注意になる (#642)。runner が
   RENDER_TURN_SLOTS (N) 本のときは、専用機の job が N 本そろって走っている間だけ順番待ちで、
   N 本未満なら空いた runner が拾わない queued を名乗る (#3320)。N は門番と同じ値を読み、
   未設定なら 1 (従来どおり)
9. **予約が外れた PR があっても、当番は予約を掛けない** (#2614)。当番の GITHUB_TOKEN では
   掛けられず (`enablePullRequestAutoMerge` が FORBIDDEN)、掛け直しは一度も成功しないまま、
   毎回 stall-act を exit 1 にして他の赤を埋もれさせていた。**代わりに、外れた出来事
   (queue から弾かれた・人の操作でなく外された) から猶予を超えたら赤で人に返す。**
   一度も予約を掛けていない PR と、人が外した予約は「外れた」と名乗らない
10. **gh が失敗した理由 (stderr) を捨てない** (#2614)。捨てると、失敗が何十回続いても
   理由がどこにも残らない。rerun の拒否のうち、打つ対象がその回に居ないだけのもの (同じ
   run が走り直している・古い attempt のジョブ) は赤にしない
11. **当番の job が持つ書き込み権限と、スクリプトが打つ書き込みが対応している** (#2614)。
   偽 gh は権限を見ないので、権限の外の操作を打ち続けても単体の検査は緑のままだった。
   全 workflow の分と合わせて workflow_permissions_test.py が見る (#2675)
12. **作法のジョブを含む古い ci.yml の run (#2669 の前) は丸ごと打たない。** 打つと古いイベントを
   再生し (#699)、その run の ci-gate は needs の赤で赤く走り直して最新になる。ラベルだけで
   直されて新しい ci-gate が付かない PR は legacy-gate と名乗って人へ返す (#2669 の反証 1・2)
13. **段を走らせていない run (本文の編集) の緑の ci-gate は、直った証拠に数えない。** 数えると
   本当に赤いコードの検査を当番のたびに打ち直す。打たずに masked-red と名乗る (#2669 の反証 4)
14. **必須が揃っているのに、必須が読む最新の check suite の pr-gate が cancelled で BLOCKED の PR を、
   猶予の後に名乗る** (#2716)。#2712 は必須が揃った後も queue に入らず、どの分類にも当たらなかった。
   打ち直す run の番号を出し、当番は打たない。新旧は suite の id で読み、cancelled が古い suite の
   ほう (#2710)・最新の suite の赤 (PR を読んだ結論)・必須が揃っていない BLOCKED (待ち・赤・欠け) は
   名乗らない。古い suite の結論は問わず、stale-checks と同じ PR でも名乗る (#2716 の反証 1・2・6)
15. **段を走らせていない run の赤い ci-gate は、同じ SHA の検査の最新がどちらも緑なら、打たずに
   移行期の行 (edited-gate) で名乗る** (#2717・#2718)。検査を打ち直して緑にしても、run の id の大きい
   その赤が必須を塞ぎ続ける。#2718 で当番の打ち直し (reread) を外したので、黙ると誰も気付かない。
   名乗りの行に打ち直す run の番号を出す。検査の最新が赤・走っている途中・片方が無いなら名乗らない
   (読み直しても緑にならない)。検査の最新は ci-gate.sh と同じく作成順で最新の run (suite) の、その
   中の最後の attempt で読み、作法のジョブを含む古い run の赤は legacy-gate に残す。legacy-gate の
   対処は push だけを言う (本文の編集では新しい ci-gate が付かない)

16. **人の手が閾値 (既定 3 日) 以上無い着手印を、Issue の番号で名乗って赤くする** (#3366)。判定は
   scripts/ready-queue.sh の dropped と 1 つで、ここは `DROPPED_MINUTES=<閾値> bash ready-queue.sh`
   を打って dropped の行だけを取る (式の写しは無い)。busy の行は名乗らない。ready-queue.sh の終了
   コード 1 (ready が 0 件) は読めている。2 と、件数の行が無い 1 (途中で落ちた回) は unreadable。
   当番の job は issues: read だけを持ち、Issue に書き込む権限は持たない。判定そのものの例
   (手元の Mac と当番の GNU の date で同じに出る・閾値の境目) は ready_queue_test.py が固定する

gh は PATH の先頭に置いた偽物へ差し替える。偽物は **--jq を実際に適用する**ので、
検査は判定そのものを踏む (応答を素通しにすると、絞り込みの誤りが素通りする)。
実行は make ci-check (CI もこれを呼ぶ)。
"""

import json
import os
import re
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WATCH = REPO / "scripts" / "stall-watch.sh"
ACT = REPO / "scripts" / "stall-act.sh"
WORKFLOWS = REPO / ".github" / "workflows"
# PR の head に check を付けるワークフロー。stall-act はその head の失敗ジョブを打つ
PR_WORKFLOWS = ("ci.yml", "pr-gate.yml", "render.yml")

# --jq の値を取り出して本物の jq を当てる。応答は $PR_DIR の中の JSON から読む
FAKE_GH = """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALLS"

filter=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then filter=$a; fi
  prev=$a
done

emit() { # $1=JSON ファイル
  [ -f "$1" ] || { printf '%s' ""; return 0; }
  if [ -n "$filter" ]; then jq -r "$filter" < "$1"; else cat "$1"; fi
}

if [ "$1 $2" = "pr list" ]; then emit "$PR_DIR/list.json"; exit 0; fi

if [ "$1 $2" = "pr view" ]; then
  [ -z "${VIEW_FAILS:-}" ] || { echo "gh: HTTP 502: Bad Gateway (pr view)" >&2; exit 1; }
  emit "$PR_DIR/$3.json"; exit 0
fi

if [ "$1 $2" = "pr merge" ]; then
  [ -z "${MERGE_FAILS:-}" ] || { echo "gh: cannot enable auto-merge" >&2; exit 1; }
  exit 0
fi

if [ "$1 $2" = "api graphql" ]; then
  num=""
  prev=""
  for a in "$@"; do
    case "$prev $a" in "-F number="*) num=${a#number=} ;; esac
    prev=$a
  done
  case "$*" in
    # 予約と queue の出来事 (#2614)。既定は出来事なし
    *timelineItems*)
      [ -z "${TIMELINE_FAILS:-}" ] || { echo "gh: HTTP 502: Bad Gateway (timeline)" >&2; exit 1; }
      f="$PR_DIR/$num.timeline.json"
      [ -f "$f" ] || f="$PR_DIR/timeline.none.json"
      emit "$f"; exit 0 ;;
    *isInMergeQueue*)
      [ -z "${QUEUE_FAILS:-}" ] || { echo "gh: HTTP 502: Bad Gateway (isInMergeQueue)" >&2; exit 1; } ;;
    # 順番の判定が読む merge queue の並び (#1266)。既定は空
    *"mergeQueue{"*) printf '%s\\n' ${QUEUED_PRS:-}; exit 0 ;;
  esac
  printf '%s\\n' "${IN_QUEUE:-false}"; exit 0
fi

# **URL は $2 から取る。** "$*" には --jq の値 (複数行) まで混ざるので、
# そこから切り出すと 2 行目以降が素通りして経路名が壊れる
url=${2:-}

case "$url" in
  # PR gate の run の一覧 (stale-gate が check suite の作成順を読む・#2716)。既定は空の並び
  */actions/workflows/pr-gate.yml/runs\\?*)
    [ -z "${GATERUNS_FAIL:-}" ] || { echo "gh: HTTP 504: Gateway Timeout (pr-gate runs)" >&2; exit 1; }
    sha=${url#*head_sha=}; sha=${sha%%&*}
    f="$PR_DIR/${sha#sha-}.gateruns.json"
    [ -f "$f" ] || f="$PR_DIR/render-runs.none.json"
    emit "$f"; exit 0 ;;
  # 専用機の render の run (#1774)。status の値ごとに応答を分ける。既定は空の並び
  */actions/workflows/render.yml/runs\\?*)
    [ -z "${RUNS_FAIL:-}" ] || { echo "gh: 502" >&2; exit 1; }
    st=${url#*status=}; st=${st%%&*}
    f="$PR_DIR/render-runs.$st.json"
    [ -f "$f" ] || f="$PR_DIR/render-runs.none.json"
    emit "$f"; exit 0 ;;
  # run の job (#2062)。既定は空の並び
  */actions/runs/*/jobs\\?*)
    [ -z "${JOBS_FAIL:-}" ] || { echo "gh: 502" >&2; exit 1; }
    id=${url%/jobs*}; id=${id##*/}
    f="$PR_DIR/render-jobs.$id.json"
    [ -f "$f" ] || { echo '{"jobs":[]}' > "$PR_DIR/render-jobs.none.json"; f="$PR_DIR/render-jobs.none.json"; }
    emit "$f"; exit 0 ;;
  # ジョブの rerun (POST)。本物の gh api は失敗の文面を「gh: <message> (HTTP <code>)」で出す
  */actions/jobs/*/rerun)
    [ -z "${RERUN_FAILS:-}" ] || { echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; }
    [ -z "${RERUN_RUNNING:-}" ] || { echo "gh: The workflow run containing this job is already running (HTTP 403)" >&2; exit 1; }
    [ -z "${RERUN_OLD_ATTEMPT:-}" ] || { echo "gh: Only jobs from the current attempt can be re-run (HTTP 403)" >&2; exit 1; }
    exit 0 ;;
  # ジョブの中身 (step の結論)。bad-title が赤い pr-gate のタイトルの step を読む (#2669)。
  # 既定は空 (step が見つからない)
  */actions/jobs/*)
    [ -z "${JOB_FAILS:-}" ] || { echo "gh: HTTP 502: Bad Gateway (job)" >&2; exit 1; }
    emit "$PR_DIR/job.${url##*/}.json"; exit 0 ;;
  # stall-watch の stale-gate は check_name と filter を問い合わせの文字列で渡す (#2716)
  */check-runs|*/check-runs\\?*)
    [ -z "${CHECKRUNS_FAIL:-}" ] || { echo "gh: HTTP 504: Gateway Timeout (check-runs)" >&2; exit 1; }
    sha=${url%%\\?*}; sha=${sha%/check-runs}; sha=${sha##*/}
    emit "$PR_DIR/${sha#sha-}.checkruns.json"; exit 0 ;;
  */files)
    n=${url%/files}; n=${n##*/}
    emit "$PR_DIR/$n.files.json"; exit 0 ;;
esac

echo "偽 gh が知らない呼び出し: $*" >&2
exit 1
"""


def ago(minutes):
    """いま から minutes 分前の ISO8601。"""
    return (datetime.now(timezone.utc) - timedelta(minutes=minutes)).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def removed(reason, minutes):
    """queue から外れた出来事 (#2614)。reason は GitHub の値 (failed_checks・manual・merged など)。"""
    return {"__typename": "RemovedFromMergeQueueEvent", "createdAt": ago(minutes), "reason": reason}


def disabled(code, minutes):
    """auto-merge が外された出来事 (#2614)。人が外すと reasonCode は manually_disabled になる。"""
    return {"__typename": "AutoMergeDisabledEvent", "createdAt": ago(minutes), "reasonCode": code}


def enabled(minutes):
    return {"__typename": "AutoMergeEnabledEvent", "createdAt": ago(minutes)}


def check(name, result, at=None, run=None, job=1):
    """run を渡すと detailsUrl に Actions の run id と job id を載せる (新旧の基準・#2568)。"""
    item = {"name": name, "conclusion": result, "completedAt": at or ago(30)}
    if run is not None:
        item["detailsUrl"] = f"https://github.com/o/r/actions/runs/{run}/job/{job}"
    return item


TITLE_STEP = "pr-title (Conventional Commits)"


def gate_job(title, review="success", drawing="success"):
    """pr-gate の job の応答 (step の結論)。bad-title はタイトルの step の結論を読む。"""
    return {
        "steps": [
            {"name": "Set up job", "conclusion": "success"},
            {"name": TITLE_STEP, "conclusion": title},
            {"name": "review-gate", "conclusion": review},
            {"name": "drawing-evidence", "conclusion": drawing},
        ]
    }


class StallWatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)

        bin_dir = root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH, encoding="utf-8")
        gh.chmod(0o755)

        self.pr_dir = root / "pr"
        self.pr_dir.mkdir()
        # **run が無いときも応答は返す** (空の並び)。本物の gh もそう返すので、判定側の
        # `// ""` と length を素通りさせない
        self.write_runs("none")
        self.write_timeline("none", [])
        self.calls = root / "gh-calls.txt"
        self.calls.write_text("", encoding="utf-8")
        self.bin_dir = bin_dir

        # 着手印の判定 (ready-queue.sh) は差し替える。判定そのものは ready_queue_test.py が固定する。
        # 既定は dropped が 0 件で、ready も 0 件 (終了コード 1・件数の行つき)
        self.queue_dir = root / "queue"
        self.queue_dir.mkdir()
        self.write_ready_queue([])


    def write(self, name, payload):
        (self.pr_dir / name).write_text(json.dumps(payload), encoding="utf-8")

    def write_ready_queue(self, lines, *, rc=1, summary=True):
        """差し替える ready-queue.sh。lines を標準出力へ出し、rc で終わる。

        渡された DROPPED_MINUTES は seen-minutes へ控える。summary=False は件数の行を出さない
        (途中で落ちた回の形)。"""
        (self.queue_dir / "out.txt").write_text("".join(f"{l}\n" for l in lines), encoding="utf-8")
        script = self.queue_dir / "ready-queue.sh"
        script.write_text(
            "#!/bin/bash\n"
            f'printf "%s" "${{DROPPED_MINUTES-unset}}" > "{self.queue_dir}/seen-minutes"\n'
            f'cat "{self.queue_dir}/out.txt"\n'
            + ('echo "ready 0 / stock 0 / dropped 0 / busy 0 / decide 0" >&2\n' if summary else 'echo "boom" >&2\n')
            + f"exit {rc}\n",
            encoding="utf-8",
        )
        script.chmod(0o755)

    def write_timeline(self, key, events):
        """PR の予約と queue の出来事を、GraphQL の応答の形で置く (古い順)。"""
        self.write(
            f"{key}.timeline.json",
            {"data": {"repository": {"pullRequest": {"timelineItems": {"nodes": list(events)}}}}},
        )

    def write_runs(self, status, *created, job_status=None, gate="completed"):
        """render.yml の run のうち、status のものを created の時刻で並べる。

        run ごとに、専用機の job 1 本 (status は job_status・既定は run と同じ) と、GitHub
        ホストの門番の job 1 本 (status は gate) を置く。
        """
        runs = []
        for at in created:
            self.next_run_id = getattr(self, "next_run_id", 100) + 1
            run_id = self.next_run_id
            runs.append({"id": run_id, "status": status, "created_at": at})
            jobs = [
                {"name": "render-turn", "status": gate, "created_at": at, "labels": ["ubuntu-latest"]},
                {
                    "name": "render",
                    "status": job_status or status,
                    "created_at": at,
                    "labels": ["self-hosted", "mokume-render"],
                },
            ]
            self.write(f"render-jobs.{run_id}.json", {"total_count": len(jobs), "jobs": jobs})
        self.write(f"render-runs.{status}.json", {"total_count": len(runs), "workflow_runs": runs})

    def add_pr(
        self,
        number,
        *,
        draft=False,
        cross=False,
        auto=True,
        state="CLEAN",
        checks=(),
        updated=None,
        files=(),
        events=None,
    ):
        listing = []
        path = self.pr_dir / "list.json"
        if path.exists():
            listing = json.loads(path.read_text(encoding="utf-8"))
        listing.append({"number": number, "isDraft": draft, "isCrossRepository": cross})
        self.write("list.json", listing)

        self.write(
            f"{number}.json",
            {
                "isDraft": draft,
                "autoMergeRequest": {"enabledAt": ago(60)} if auto else None,
                "mergeStateStatus": state,
                "statusCheckRollup": list(checks),
                "updatedAt": updated or ago(30),
                "headRefOid": f"sha-{number}",
            },
        )
        self.write(f"{number}.files.json", [{"filename": f} for f in files])
        if events is not None:
            self.write_timeline(number, events)

    def env(self, **extra):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}:{env['PATH']}"
        env["GH_CALLS"] = str(self.calls)
        env["PR_DIR"] = str(self.pr_dir)
        env["READY_QUEUE"] = str(self.queue_dir / "ready-queue.sh")
        # 手元で打ったときの既定を再現する (Actions の変数が残っていると分岐が変わる)
        for key in ("GITHUB_RUN_ID", "GITHUB_SERVER_URL", "GITHUB_EVENT_NAME", "GH_TOKEN", "RENDER_TURN_SLOTS"):
            env.pop(key, None)
        env.update({k: str(v) for k, v in extra.items()})
        return env

    def watch(self, **extra):
        proc = subprocess.run(
            ["/bin/bash", str(WATCH)],
            capture_output=True,
            text=True,
            env=self.env(**extra),
        )
        return proc

    def act(self, lines, **extra):
        log = Path(self.tmp.name) / "stall.log"
        log.write_text("".join(f"{line}\n" for line in lines), encoding="utf-8")
        return subprocess.run(
            ["/bin/bash", str(ACT), str(log)],
            capture_output=True,
            text=True,
            env=self.env(**extra),
        )

    def gh_log(self):
        return self.calls.read_text(encoding="utf-8")

    def classify(self, number, proc):
        for line in proc.stdout.splitlines():
            parts = line.split(maxsplit=3)
            if parts and parts[0] == str(number):
                return parts[1], parts[2]
        return None, None

    # --- 判定 ---------------------------------------------------------------

    def test_Draft_の_PR_は見ない(self):
        self.add_pr(1, draft=True, auto=False, state="BLOCKED")
        proc = self.watch()
        self.assertEqual(proc.stdout.strip(), "", proc.stdout)

    def test_fork_の_PR_は見ない(self):
        """予約が無く緑の fork PR でも、当番は掛け直さない (#1361)。"""
        self.add_pr(9, cross=True, auto=False, state="CLEAN", checks=[check("ci-gate", "SUCCESS")])
        proc = self.watch()
        self.assertEqual(proc.stdout.strip(), "", proc.stdout)

    def test_auto_merge_が外れた_PR_は名乗るに分類される(self):
        """当番は掛け直さず、人に返す (#2614)。"""
        self.add_pr(
            2,
            auto=False,
            state="CLEAN",
            checks=[check("ci-gate", "SUCCESS")],
            events=[enabled(90), removed("failed_checks", 10)],
        )
        kind, action = self.classify(2, self.watch())
        self.assertEqual((kind, action), ("auto-merge-dropped", "name"))

    def test_一度も予約を掛けていない_PR_は外れたと名乗らない(self):
        """後からコミットを足す PR は予約を掛けずに置く (AGENTS.md)。外れた出来事が無いものを
        外れたと名乗ると、置いてあるだけの PR が猶予の後に当番を赤くする (#2614)。"""
        self.add_pr(30, auto=False, state="BLOCKED", checks=[check("ci-gate", "SUCCESS")], events=[])
        proc = self.watch(STALL_MINUTES=1)
        self.assertEqual(self.classify(30, proc), (None, None), proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_人が外した予約は外れたと名乗らない(self):
        """人が外した (disable-auto・queue から手で出した) のは意図で、当番が返す先も人である。"""
        for number, events in (
            (31, [enabled(120), disabled("manually_disabled", 100)]),
            (32, [enabled(120), removed("manual", 100)]),
        ):
            self.add_pr(number, auto=False, state="BLOCKED", checks=[check("ci-gate", "SUCCESS")], events=events)
        proc = self.watch(STALL_MINUTES=1)
        self.assertEqual(self.classify(31, proc), (None, None), proc.stdout)
        self.assertEqual(self.classify(32, proc), (None, None), proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_人の操作でなく外された予約は名乗る(self):
        """reasonCode が manually_disabled 以外 (知らない値も含む) は外れたと読む。"""
        self.add_pr(33, auto=False, state="BLOCKED", events=[enabled(120), disabled("unknown_reason", 20)])
        self.assertEqual(self.classify(33, self.watch()), ("auto-merge-dropped", "name"))

    def test_外れた後に予約を掛け直した出来事が新しければ名乗らない(self):
        """見るのは最新の出来事だけ。弾かれた後に掛け直され、queue に入る前の隙間は外れていない。"""
        self.add_pr(34, auto=False, state="BLOCKED", events=[removed("failed_checks", 60), enabled(1)])
        self.assertEqual(self.classify(34, self.watch()), (None, None))

    def test_弾かれてから猶予を超えたら赤くする(self):
        """#961 の約束: 機械が打てないものは、猶予を過ぎたら赤で人に返す。経過は弾かれた時刻から測る。"""
        self.add_pr(35, auto=False, state="BLOCKED", events=[enabled(200), removed("checks_timed_out", 120)])
        proc = self.watch(STALL_MINUTES=60)
        line = next(l.split(maxsplit=4) for l in proc.stdout.splitlines() if l.startswith("35 "))
        self.assertEqual(line[1:3], ["auto-merge-dropped", "name"], proc.stdout)
        self.assertGreaterEqual(int(line[3]), 119, proc.stdout)
        self.assertIn("checks_timed_out", line[4], proc.stdout)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)

    def test_予約の出来事を読めなければ読めなかったと名乗る(self):
        self.add_pr(36, auto=False, state="BLOCKED", events=[removed("failed_checks", 120)])
        proc = self.watch(TIMELINE_FAILS=1)
        self.assertEqual(self.classify(36, proc), ("unreadable", "name"), proc.stdout)
        self.assertIn("HTTP 502: Bad Gateway (timeline)", proc.stderr)

    def test_queue_に居るかを読めなければ読めなかったと名乗る(self):
        """読めずに空が返ったとき、居ないと読んで外れた・古い check に落とさない (#1303)。"""
        self.add_pr(37, auto=False, state="BLOCKED", events=[removed("failed_checks", 120)])
        self.add_pr(
            38,
            auto=False,
            state="BLOCKED",
            checks=[check("ci-gate", "FAILURE", ago(90)), check("ci-gate", "SUCCESS", ago(10))],
        )
        proc = self.watch(QUEUE_FAILS=1)
        self.assertEqual(self.classify(37, proc), ("unreadable", "name"), proc.stdout)
        self.assertEqual(self.classify(38, proc), ("unreadable", "name"), proc.stdout)
        self.assertIn("HTTP 502: Bad Gateway (isInMergeQueue)", proc.stderr)

    def test_重要パスに触れる_PR_も予約が外れていれば名乗る(self):
        """承認のゲートは ADR-0044 で外れた (#2108)。以前は awaiting-approval として
        黙っていた形で、黙ると予約が外れたまま誰も掛け直さない。"""
        self.add_pr(
            3,
            auto=False,
            state="BLOCKED",
            checks=[check("ci-gate", "SUCCESS")],
            files=[".github/workflows/ci.yml"],
            events=[removed("failed_checks", 10)],
        )
        kind, action = self.classify(3, self.watch())
        self.assertEqual((kind, action), ("auto-merge-dropped", "name"))

    def test_queue_に居る_PR_は黙る(self):
        self.add_pr(5, auto=False, state="CLEAN", checks=[check("ci-gate", "SUCCESS")])
        kind, action = self.classify(5, self.watch(IN_QUEUE="true"))
        self.assertEqual((kind, action), ("in-queue", "quiet"))

    def test_予約が掛かり揃っても_queue_に入らないまま猶予を超えたら名乗る(self):
        """#2691 の形 (#2693)。予約が効いていれば揃ってから数秒で queue に入る。経過は check の
        最新の完了時刻から測り、どの分類にも当たらず黙って抜けていた。"""
        self.add_pr(
            40,
            auto=True,
            state="CLEAN",
            checks=[check("pr-gate", "SUCCESS", ago(40)), check("ci-gate", "SUCCESS", ago(27))],
        )
        # 必須でない check の赤 (render-pr) で UNSTABLE でも、予約は同じく queue へ動くはず
        self.add_pr(
            41,
            auto=True,
            state="UNSTABLE",
            checks=[check("ci-gate", "SUCCESS", ago(30)), check("render-pr", "FAILURE", ago(20))],
        )
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        line = next(l.split(maxsplit=4) for l in proc.stdout.splitlines() if l.startswith("40 "))
        self.assertEqual(line[1:3], ["queue-not-entered", "name"], proc.stdout)
        self.assertIn(int(line[3]), (26, 27), proc.stdout)
        self.assertIn("gh pr merge 40 --disable-auto", line[4], proc.stdout)
        self.assertIn("gh pr merge 40 --auto --squash", line[4], proc.stdout)
        self.assertEqual(self.classify(41, proc), ("queue-not-entered", "name"), proc.stdout)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)

    def test_揃った後に掛けた予約は_掛けてから猶予の内なら黙る(self):
        """経過は check の最新と予約を掛けた時刻の遅い方から測る。揃ってから 2 時間後に掛けた
        予約の、queue へ動く前の隙間を名乗らない。BEHIND も必須は揃っている形として見る。"""
        self.add_pr(46, auto=True, state="CLEAN", checks=[check("ci-gate", "SUCCESS", ago(120))])
        self.add_pr(47, auto=True, state="BEHIND", checks=[check("ci-gate", "SUCCESS", ago(120))])
        for number, at in ((46, ago(1)), (47, ago(20))):
            path = self.pr_dir / f"{number}.json"
            pr = json.loads(path.read_text(encoding="utf-8"))
            pr["autoMergeRequest"] = {"enabledAt": at}
            path.write_text(json.dumps(pr), encoding="utf-8")
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        self.assertEqual(self.classify(46, proc), (None, None), proc.stdout)
        line = next(l.split(maxsplit=4) for l in proc.stdout.splitlines() if l.startswith("47 "))
        self.assertEqual(line[1:3], ["queue-not-entered", "name"], proc.stdout)
        self.assertIn(int(line[3]), (19, 20), proc.stdout)

    def test_揃ってから猶予の内は_queue_に入っていなくても黙る(self):
        """予約が queue へ動くまでの隙間は正常。出すと毎回の注意になる (#642)。"""
        self.add_pr(42, auto=True, state="CLEAN", checks=[check("ci-gate", "SUCCESS", ago(5))])
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        self.assertEqual(self.classify(42, proc), (None, None), proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_必須が揃っていなければ_queue_に入らなくても名乗らない(self):
        """BLOCKED (必須の待ち・赤) は予約が待っているだけで、queue に入らないのが正しい。"""
        self.add_pr(43, auto=True, state="BLOCKED", checks=[check("ci-gate", "SUCCESS", ago(120))])
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        self.assertEqual(self.classify(43, proc), (None, None), proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_予約が掛かり揃って_queue_に居るなら黙る(self):
        self.add_pr(44, auto=True, state="CLEAN", checks=[check("ci-gate", "SUCCESS", ago(120))])
        proc = self.watch(QUEUE_ENTRY_MINUTES=15, IN_QUEUE="true")
        self.assertEqual(self.classify(44, proc), (None, None), proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_予約が掛かり揃った_PR_の_queue_を読めなければ読めなかったと名乗る(self):
        """読めずに空が返ったとき、居ないとも居るとも読まない (#1303)。"""
        self.add_pr(45, auto=True, state="CLEAN", checks=[check("ci-gate", "SUCCESS", ago(120))])
        proc = self.watch(QUEUE_ENTRY_MINUTES=15, QUEUE_FAILS=1)
        self.assertEqual(self.classify(45, proc), ("unreadable", "name"), proc.stdout)

    def test_衝突して_check_が_1_本も付かない_PR_を名乗る(self):
        self.add_pr(6, auto=True, state="UNKNOWN", checks=[])
        kind, action = self.classify(6, self.watch())
        self.assertEqual((kind, action), ("conflict", "name"))

    def test_古い失敗_check_が残る_PR_は打つに分類される(self):
        self.add_pr(
            9,
            auto=True,
            state="BLOCKED",
            checks=[
                check("ci-gate", "FAILURE", ago(90)),
                check("ci-gate", "SUCCESS", ago(10)),
            ],
        )
        kind, action = self.classify(9, self.watch())
        self.assertEqual((kind, action), ("stale-checks", "act"))

    # --- タイトルの赤は pr-gate のタイトルの step で読む (#2669) ---------------

    def test_最新の_pr_gate_のタイトルの_step_が落ちた_PR_は名乗るに分類される(self):
        # **stale-checks より先に判定されること。** 後ろだと打ち直すだけで名乗らない
        self.add_pr(
            10,
            auto=True,
            state="BLOCKED",
            checks=[
                check("pr-gate", "FAILURE", ago(10), run=300, job=901),
                check("ci-gate", "FAILURE", ago(90), run=100),
                check("ci-gate", "SUCCESS", ago(5), run=200),
            ],
        )
        self.write("job.901.json", gate_job("failure", review="failure"))
        proc = self.watch()
        self.assertEqual(self.classify(10, proc), ("bad-title", "name"), proc.stdout)
        line = next(ln for ln in proc.stdout.splitlines() if ln.startswith("10 "))
        self.assertIn("打ち直しも新しいコミットも要らない", line)
        self.assertNotIn("push", line)

    def test_pr_gate_がタイトル以外で赤いなら_bad_title_と名乗らない(self):
        self.add_pr(
            11,
            auto=True,
            state="BLOCKED",
            checks=[check("pr-gate", "FAILURE", ago(10), run=300, job=902)],
        )
        self.write("job.902.json", gate_job("success", review="failure"))
        proc = self.watch()
        self.assertNotEqual(self.classify(11, proc)[0], "bad-title", proc.stdout)
        self.assertIn("actions/jobs/902", self.gh_log())

    def test_タイトルを直した後の_PR_は名乗らず_古い_pr_gate_の_job_を読まない(self):
        """直した後の run (id 大) の pr-gate が緑なら、直す前の run の赤は判定に数えない (#2668)。"""
        self.add_pr(
            12,
            auto=False,
            state="CLEAN",
            checks=[
                check("pr-gate", "FAILURE", ago(90), run=100, job=903),
                check("pr-gate", "SUCCESS", ago(60), run=200, job=904),
                check("ci-gate", "SUCCESS", ago(60), run=150),
            ],
        )
        self.write("job.903.json", gate_job("failure"))
        proc = self.watch(IN_QUEUE="true")
        self.assertEqual(self.classify(12, proc), ("in-queue", "quiet"), proc.stdout)
        self.assertNotIn("actions/jobs/903", self.gh_log())

    def test_赤い_pr_gate_の_step_を読めなければ読めなかったと名乗る(self):
        """黙ると、タイトルの赤が「止まっていない」に混ざる (#1303)。"""
        self.add_pr(
            13,
            auto=True,
            state="BLOCKED",
            checks=[check("pr-gate", "FAILURE", ago(10), run=300, job=905)],
        )
        proc = self.watch(JOB_FAILS="1")
        self.assertEqual(self.classify(13, proc), ("unreadable", "name"), proc.stdout)
        self.assertIn("HTTP 502: Bad Gateway (job)", proc.stderr)

    def test_走っている_pr_gate_は読まない(self):
        self.add_pr(
            14,
            auto=True,
            state="BLOCKED",
            checks=[{"name": "pr-gate", "status": "IN_PROGRESS", "conclusion": "",
                     "detailsUrl": "https://github.com/o/r/actions/runs/300/job/906"}],
        )
        proc = self.watch()
        self.assertNotIn("actions/jobs/906", self.gh_log())
        self.assertNotEqual(self.classify(14, proc)[0], "bad-title", proc.stdout)

    def test_古い失敗_check_の判定も_完了時刻でなく_run_の_id_順で読む(self):
        """#2568。古い run (id 小) の赤が遅く完了しても、新しい run (id 大) の緑が最新である。"""
        self.add_pr(
            15,
            auto=True,
            state="BLOCKED",
            checks=[
                check("test-release", "SUCCESS", ago(60), run=200),
                check("test-release", "FAILURE", ago(5), run=100),
            ],
        )
        kind, action = self.classify(15, self.watch())
        self.assertEqual((kind, action), ("stale-checks", "act"))

    # --- pr-gate は同じ SHA の最新の run の結論が判定 (#2668) ------------------
    #
    # pr-gate は API を読むだけの数十秒のジョブで、直すと新しい run が付け直す。concurrency は
    # 走っている古い run を cancel する。古い赤・cancelled と新しい緑を stale-checks の組にすると、
    # 当番が head SHA の失敗ジョブを打ち直し、凍結された run の ci-gate まで「最新の赤」にしうる

    def test_古い_pr_gate_の赤と新しい緑を_stale_checks_の組にしない(self):
        self.add_pr(
            40,
            auto=True,
            state="BLOCKED",
            checks=[
                check("pr-gate", "FAILURE", ago(90), run=100),
                check("pr-gate", "SUCCESS", ago(60), run=200),
                check("ci-gate", "SUCCESS", ago(50), run=150),
            ],
        )
        kind, _ = self.classify(40, self.watch())
        self.assertNotEqual(kind, "stale-checks")

    def test_concurrency_が止めた_pr_gate_を_stale_checks_の組にしない(self):
        self.add_pr(
            41,
            auto=True,
            state="BLOCKED",
            checks=[
                check("pr-gate", "CANCELLED", ago(90), run=100),
                check("pr-gate", "SUCCESS", ago(60), run=200),
                check("ci-gate", "SUCCESS", ago(50), run=150),
            ],
        )
        kind, _ = self.classify(41, self.watch())
        self.assertNotEqual(kind, "stale-checks")

    def test_古い_pr_gate_を外しても_ほかの古い赤は_stale_checks_に残る(self):
        self.add_pr(
            42,
            auto=True,
            state="BLOCKED",
            checks=[
                check("pr-gate", "FAILURE", ago(90), run=100),
                check("pr-gate", "SUCCESS", ago(60), run=300),
                check("ci-gate", "FAILURE", ago(5), run=100),
                check("ci-gate", "SUCCESS", ago(50), run=300),
            ],
        )
        proc = self.watch()
        self.assertEqual(self.classify(42, proc), ("stale-checks", "act"))
        line = next(ln for ln in proc.stdout.splitlines() if ln.startswith("42 "))
        self.assertIn("(ci-gate)", line)
        self.assertNotIn("pr-gate", line)

    def test_最新の_pr_gate_の赤は隠さない(self):
        """外すのは古い run の pr-gate だけ。最新の赤は本物の差し戻しで、古い緑で覆わない。

        最新の赤が残っていれば、失敗の時刻 (行の分) はその赤の時刻になる。古い緑を残す
        読み違いでは、ci-gate の古い赤の時刻 (90 分前) に戻る。"""
        self.add_pr(
            43,
            auto=True,
            state="BLOCKED",
            checks=[
                check("pr-gate", "SUCCESS", ago(120), run=100),
                check("pr-gate", "FAILURE", ago(2), run=400),
                check("ci-gate", "FAILURE", ago(90), run=100),
                check("ci-gate", "SUCCESS", ago(50), run=300),
            ],
        )
        proc = self.watch()
        self.assertEqual(self.classify(43, proc), ("stale-checks", "act"))
        line = next(ln for ln in proc.stdout.splitlines() if ln.startswith("43 "))
        self.assertLess(int(line.split()[3]), 10, line)

    # --- 必須が読む最新の suite の pr-gate が cancelled で BLOCKED のまま (#2716) ---
    #
    # 必須は作成順で最新の check suite の pr-gate を読む (scripts/ci-gate.sh 冒頭・#2577)。#2712 は
    # 作成と同時のラベルで 2 本の run が立ち、新しい suite (105017324579・run 38752624025) が
    # cancelled、古い suite (105017320903・run 38752622858) が success で残った。必須が揃った後も
    # BLOCKED のまま queue に入らず、cancelled の run の打ち直しで CLEAN になった。#2710 は
    # cancelled が古い suite のほうで、止まらずに merge された

    def stale_gate_pr(self, number, *, suites=None, rollup=None, ci="SUCCESS", ci_at=20,
                      render="SKIPPED", state="BLOCKED"):
        """suites は (suite の id, run の id, run の status か conclusion[, ジョブがあるか]) の並び。

        既定は #2712 の形。rollup を渡さなければ、ジョブのある run を rollup の pr-gate に載せる。
        ジョブの無い run (待ちを置き換えられた cancelled) は check run を作らないので rollup に出ない。"""
        if suites is None:
            suites = [(105017320903, 38752622858, "success"), (105017324579, 38752624025, "cancelled")]
        suites = [tuple(x) + (True,) * (4 - len(x)) for x in suites]
        if rollup is None:
            rollup = [
                check("pr-gate", result.upper(), ago(40), run=run, job=number * 10 + i)
                for i, (_, run, result, jobs) in enumerate(suites) if jobs
            ]
        checks = list(rollup) + [check("ci-gate", ci, ago(ci_at), run=38752623159, job=number * 10 + 7)]
        if render is not None:
            checks.append(check("render", render, ago(39), run=38752623160, job=number * 10 + 8))
        self.add_pr(number, auto=True, state=state, checks=checks)
        runs = []
        for suite, run, result, _ in suites:
            item = {"id": run, "check_suite_id": suite, "event": "pull_request"}
            if result in ("queued", "in_progress"):
                item.update(status=result, conclusion=None)
            else:
                item.update(status="completed", conclusion=result)
            runs.append(item)
        self.write(f"{number}.gateruns.json", {"total_count": len(runs), "workflow_runs": runs})

    def stale_gate_line(self, number, proc):
        return next(l.split(maxsplit=4) for l in proc.stdout.splitlines() if l.startswith(f"{number} "))

    def test_必須が読む最新の_suite_の_pr_gate_が_cancelled_で_BLOCKED_のまま猶予を超えたら名乗る(self):
        """名乗りの行に最新の suite の run の番号を出し、猶予を超えたので 1 で終える。"""
        self.stale_gate_pr(60)
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        line = self.stale_gate_line(60, proc)
        self.assertEqual(line[1:3], ["stale-gate", "name"], proc.stdout)
        self.assertIn(int(line[3]), (19, 20), proc.stdout)
        self.assertIn("gh run rerun 38752624025", line[4], proc.stdout)
        self.assertNotIn("38752622858", line[4], "緑の run を打ち直しに挙げている")
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn(f"actions/workflows/pr-gate.yml/runs?head_sha=sha-60", self.gh_log())
        self.assertIn("--paginate", self.gh_log(), "run の一覧を 1 ページしか読んでいない (#2716 の反証 5)")

        # 当番は打たない (古い pr-gate を当番に打たせない決まり・#2668)
        self.calls.write_text("", encoding="utf-8")
        acted = self.act(proc.stdout.splitlines())
        self.assertEqual(acted.returncode, 0, acted.stdout + acted.stderr)
        self.assertNotIn("rerun", self.gh_log())

    def test_新旧は_run_の_id_ではなく_check_suite_の_id_で読む(self):
        """run の id が小さくても suite が新しければ、必須はそちらを読む。逆も同じ。"""
        self.stale_gate_pr(61, suites=[(900, 500, "success"), (901, 400, "cancelled")])
        self.stale_gate_pr(62, suites=[(901, 500, "success"), (900, 600, "cancelled")])
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        self.assertEqual(self.stale_gate_line(61, proc)[1], "stale-gate", proc.stdout)
        self.assertIn("gh run rerun 400", self.stale_gate_line(61, proc)[4], proc.stdout)
        self.assertEqual(self.classify(62, proc), (None, None), proc.stdout)

    def test_cancelled_が古い_suite_のほうなら_BLOCKED_でも名乗らない(self):
        """#2710 の形。必須を塞いでいないので、BLOCKED の理由は別にある。打ち直しを勧めない。"""
        self.stale_gate_pr(63, suites=[(104990765053, 38743419706, "cancelled"),
                                       (104990774366, 38743423023, "success")])
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        self.assertEqual(self.classify(63, proc), (None, None), proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_打ち直して最新の_suite_が緑になれば名乗らない(self):
        """打ち直した run は同じ run (同じ suite) のまま、一覧は最後の attempt の結論を返す。rollup に
        前の attempt の cancelled が残って見えても、run の一覧の側で読む。"""
        self.stale_gate_pr(
            64,
            suites=[(105017320903, 38752622858, "success"), (105017324579, 38752624025, "success")],
            rollup=[check("pr-gate", "CANCELLED", ago(40), run=38752624025, job=641),
                    check("pr-gate", "SUCCESS", ago(39), run=38752622858, job=642)],
        )
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        self.assertEqual(self.classify(64, proc), (None, None), proc.stdout)

    def test_必須が揃ってから猶予の内なら_cancelled_の_pr_gate_が残っても黙る(self):
        self.stale_gate_pr(65, ci_at=5)
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        self.assertEqual(self.classify(65, proc), (None, None), proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_必須が揃っていなければ_cancelled_の_pr_gate_が残っても_stale_gate_と名乗らない(self):
        """BLOCKED が正しく待っている形。pr-gate を打ち直しても進まない。"""
        self.stale_gate_pr(66, ci="FAILURE")  # 必須の赤
        self.stale_gate_pr(67, ci="IN_PROGRESS")  # 必須の待ち
        self.stale_gate_pr(68, render=None)  # 必須がまだ付いていない
        # 最新の suite の pr-gate が赤 (PR を読んだ結論。打ち直しても同じ赤・#2716 の反証 1)。rollup
        # には古い suite の cancelled が見えるので、suite の側で読んで外す
        self.stale_gate_pr(69, suites=[(900, 800, "cancelled"), (901, 900, "failure")])
        # 最新の suite の pr-gate が待っている (打ち直すと待っている run を cancel する)。時刻は猶予の
        # 外に置き、猶予ではなく待ちの判定で黙ることを見る。rollup の側にも待ちが見える
        self.stale_gate_pr(70, suites=[(900, 800, "success"), (901, 900, "cancelled"),
                                       (902, 1000, "queued")])
        # rollup には待ちが見えず (読んだ瞬間の食い違い)、suite の側で待っている
        self.stale_gate_pr(71, suites=[(900, 800, "success"), (901, 900, "in_progress")],
                           rollup=[check("pr-gate", "CANCELLED", ago(40), run=700, job=711),
                                   check("pr-gate", "SUCCESS", ago(39), run=800, job=712)])
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        for number in range(66, 72):
            self.assertNotEqual(self.classify(number, proc)[0], "stale-gate", f"#{number}: {proc.stdout}")

    def test_最新の_suite_の正当な赤は_古い_suite_が緑でも_stale_gate_と名乗らない(self):
        """#2716 の反証 1 の探査の形。絵・Issue の紐づけの赤は人が直すもので、打ち直しを勧めない。"""
        self.stale_gate_pr(77, suites=[(900, 800, "success"), (901, 900, "failure")])
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        self.assertNotIn("stale-gate", proc.stdout)
        self.assertNotIn("gh run rerun", proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_最新の_suite_が_cancelled_なら古い_suite_の結論によらず名乗る(self):
        """#2716 の反証 2。打ち切られた run は何も判定していない。古い suite が赤でも、cancelled
        だけでも、打ち直せば今の PR を読んで結論を返す。"""
        self.stale_gate_pr(78, suites=[(900, 800, "failure"), (901, 900, "cancelled")])
        self.stale_gate_pr(79, suites=[(900, 900, "cancelled")])
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        self.assertIn("gh run rerun 900", self.stale_gate_line(78, proc)[4], proc.stdout)
        self.assertEqual(self.stale_gate_line(78, proc)[1], "stale-gate", proc.stdout)
        self.assertEqual(self.stale_gate_line(79, proc)[1], "stale-gate", proc.stdout)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)

    def test_古い失敗_check_を打つ_PR_でも_cancelled_の_pr_gate_を名乗る(self):
        """#2716 の反証 6。stale-checks に当たって先へ進まなくても、stale-gate の行も出す。"""
        self.stale_gate_pr(
            80,
            rollup=[
                check("pr-gate", "SUCCESS", ago(40), run=38752622858, job=801),
                check("pr-gate", "CANCELLED", ago(40), run=38752624025, job=802),
                check("ci-check", "FAILURE", ago(90), run=100, job=803),
                check("ci-check", "SUCCESS", ago(30), run=300, job=804),
            ],
        )
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        kinds = [l.split()[1] for l in proc.stdout.splitlines() if l.startswith("80 ")]
        self.assertEqual(kinds, ["stale-checks", "stale-gate"], proc.stdout)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)

    def test_最新の_suite_が緑の_BLOCKED_は名乗らない(self):
        self.stale_gate_pr(72, suites=[(900, 800, "success")])
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        self.assertEqual(self.classify(72, proc), (None, None), proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_最新の_suite_がジョブの無い_cancelled_でも名乗る(self):
        """#2716 の 2 回目の反証 1・2。待ちを置き換えられた run はジョブを作らず、rollup にも
        check-runs にも出ない。run の一覧で suite の順を読む。#2730 (a0ad3c6) の実物の id。"""
        early = [(105060542702, 38767870619, "success"),
                 (105060661486, 38767911727, "cancelled", False),
                 (105060676655, 38767916918, "cancelled", False),
                 (105060749327, 38767942922, "cancelled", False)]
        self.stale_gate_pr(81, suites=early)
        # 実物ではこの後に success の run (suite 105060841346) が立って塞がなかった
        self.stale_gate_pr(82, suites=early + [(105060841346, 38767975569, "success")])
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        line = self.stale_gate_line(81, proc)
        self.assertEqual(line[1], "stale-gate", proc.stdout)
        self.assertIn("gh run rerun 38767942922", line[4], proc.stdout)
        self.assertEqual(self.classify(82, proc), (None, None), proc.stdout)

    def test_最新の_suite_にジョブが無ければ古い_suite_の_cancelled_を打ち直しに挙げない(self):
        """#2716 の 2 回目の反証 4。check run を持つ suite だけで「最新」を選ぶと、古い suite の
        ジョブを持った cancelled を返してしまう。"""
        self.stale_gate_pr(83, suites=[(900, 800, "cancelled"), (901, 850, "cancelled", False)])
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        line = self.stale_gate_line(83, proc)
        self.assertIn("gh run rerun 850", line[4], proc.stdout)
        self.assertNotIn("gh run rerun 800", line[4], proc.stdout)

    def test_rollup_に待っている_pr_gate_が見えれば_suite_を読まず名乗らない(self):
        self.stale_gate_pr(76, suites=[(900, 800, "success"), (901, 900, "cancelled"), (902, 1000, "queued")])
        proc = self.watch(QUEUE_ENTRY_MINUTES=15)
        self.assertEqual(self.classify(76, proc), (None, None), proc.stdout)
        self.assertNotIn("pr-gate.yml/runs", self.gh_log(), "走っている pr-gate のある PR で API を引いている")

    def test_必須の定義を読めなければ読めなかったと名乗る(self):
        """黙ると「止まっていない」に倒れる (#1303)。"""
        self.stale_gate_pr(73)
        empty = self.pr_dir / "ruleset.empty.json"
        empty.write_text(json.dumps({"rules": [{"type": "required_status_checks",
                                                "parameters": {"required_status_checks": []}}]}),
                         encoding="utf-8")
        for ruleset in (self.pr_dir / "missing.json", empty):
            proc = self.watch(QUEUE_ENTRY_MINUTES=15, RULESET=ruleset)
            self.assertEqual(self.classify(73, proc), ("unreadable", "name"), proc.stdout)

    def test_pr_gate_の_run_の一覧を読めなければ読めなかったと名乗る(self):
        self.stale_gate_pr(74)
        proc = self.watch(QUEUE_ENTRY_MINUTES=15, GATERUNS_FAIL=1)
        self.assertEqual(self.classify(74, proc), ("unreadable", "name"), proc.stdout)
        self.assertIn("Gateway Timeout", proc.stderr, "読めなかった理由を捨てている")

    # --- 作法のジョブを含む古い ci.yml の run (#2669 の移行) ------------------
    #
    # #2669 より前の ci.yml の run は、作法のジョブ (pr-title・review-gate・drawing-evidence) を
    # 含み、その ci-gate はそれらを待っていた。打ち直すと古いイベントを再生し (#699)、needs の赤で
    # ci-gate も赤く走り直して最新になる。古い run は丸ごと打ち直しの対象から外し、人へ返す

    def legacy_run(self, run, *, title="SUCCESS", review="SUCCESS", code="SUCCESS", gate="FAILURE", at=90):
        return [
            check("pr-title", title, ago(at), run=run),
            check("review-gate", review, ago(at), run=run),
            check("drawing-evidence", "SUCCESS", ago(at), run=run),
            check("ci-check", code, ago(at), run=run),
            check("ci-static", "SUCCESS", ago(at), run=run),
            check("ci-gate", gate, ago(at - 1), run=run),
        ]

    def hollow_run(self, run, at=30):
        """本文・タイトルの編集の run。段を走らせる 2 つが skipped で、ci-gate は緑。"""
        return [
            check("ci-check", "SKIPPED", ago(at), run=run),
            check("ci-static", "SKIPPED", ago(at), run=run),
            check("ci-gate", "SUCCESS", ago(at), run=run),
        ]

    def test_作法のジョブを含む古い_run_の赤を_stale_checks_の組にしない(self):
        """古い run でタイトルが赤く、直した後の edited の run が緑の ci-gate を付けた形。
        組にすると当番が古い pr-title と ci-gate を打ち直し、赤い ci-gate が最新になる。"""
        self.add_pr(
            50,
            auto=True,
            state="BLOCKED",
            checks=self.legacy_run(100, title="FAILURE")
            + self.hollow_run(200)
            + [check("pr-gate", "SUCCESS", ago(20), run=300)],
        )
        kind, _ = self.classify(50, self.watch())
        self.assertNotEqual(kind, "stale-checks")

    def test_古い_run_どうしの赤と緑も_stale_checks_の組にしない(self):
        """#2669 の前にタイトルを直した PR は、古い run が 2 つ並ぶ (赤い pr-title と、直した後の
        緑)。組にしても、対処は古い run を打たないので空打ちを繰り返すだけになる。"""
        self.add_pr(
            56,
            auto=True,
            state="BLOCKED",
            checks=self.legacy_run(100, title="FAILURE")
            + self.legacy_run(150, gate="SUCCESS", at=60)
            + [check("pr-gate", "SUCCESS", ago(20), run=300)],
        )
        kind, _ = self.classify(56, self.watch())
        self.assertNotEqual(kind, "stale-checks")

    def test_ラベルだけで直した古い_run_の赤い_ci_gate_は名乗る(self):
        """ci.yml はラベルでは起きないので、新しい ci-gate が付かない。stale でも bad-title でも
        ないまま、古い run の赤い ci-gate が最新として残り、無音で止まる。"""
        self.add_pr(
            51,
            auto=True,
            state="BLOCKED",
            checks=self.legacy_run(100, review="FAILURE")
            + [check("pr-gate", "SUCCESS", ago(20), run=300)],
        )
        proc = self.watch(STALL_MINUTES=60)
        self.assertEqual(self.classify(51, proc), ("legacy-gate", "name"), proc.stdout)
        line = next(ln for ln in proc.stdout.splitlines() if ln.startswith("51 "))
        self.assertIn("push", line)
        # 本文の編集では ci.yml の run が立たず、新しい ci-gate が付かない (#2718)
        self.assertNotIn("本文を編集", line)
        self.assertEqual(proc.returncode, 1, "猶予を超えた名乗りなのに赤くしない")

    def test_古い_run_の赤い_ci_gate_がコードの赤なら_legacy_gate_と名乗らない(self):
        # 本文を編集させると、段を走らせない緑の ci-gate でコードの赤を覆ってしまう
        self.add_pr(
            52,
            auto=True,
            state="BLOCKED",
            checks=self.legacy_run(100, code="FAILURE")
            + [check("pr-gate", "SUCCESS", ago(20), run=300)],
        )
        kind, _ = self.classify(52, self.watch())
        self.assertNotEqual(kind, "legacy-gate")

    def test_古い_run_の赤い_ci_gate_は_pr_gate_が緑でなければ名乗らない(self):
        self.add_pr(
            53,
            auto=True,
            state="BLOCKED",
            checks=self.legacy_run(100, review="FAILURE")
            + [check("pr-gate", "FAILURE", ago(20), run=300, job=907)],
        )
        kind, _ = self.classify(53, self.watch())
        self.assertNotEqual(kind, "legacy-gate")

    # --- 段を走らせていない run の緑は、直った証拠ではない ----------------------

    def test_段を走らせていない_run_の緑でコードの赤を直ったと読まず名乗る(self):
        """本文の編集の run の ci-gate は needs が skipped の緑である。それを「直った」と読むと、
        本当に赤いコードの検査を当番のたびに打ち直し、誰にも名乗らない。"""
        self.add_pr(
            54,
            auto=True,
            state="BLOCKED",
            checks=[
                check("ci-check", "FAILURE", ago(90), run=100),
                check("ci-static", "SUCCESS", ago(95), run=100),
                check("ci-gate", "FAILURE", ago(89), run=100),
            ]
            + self.hollow_run(200),
        )
        proc = self.watch()
        self.assertEqual(self.classify(54, proc), ("masked-red", "name"), proc.stdout)

    def test_段を走らせた新しい_run_の緑は直った証拠として打つ(self):
        # reopen の run は段を走らせる (base の変更では ci.yml の run が立たない・#2718)。古いコードの
        # 赤は打ち直しの対象のまま
        self.add_pr(
            55,
            auto=True,
            state="BLOCKED",
            checks=[
                check("ci-check", "FAILURE", ago(90), run=100),
                check("ci-static", "SUCCESS", ago(95), run=100),
                check("ci-gate", "FAILURE", ago(89), run=100),
                check("ci-check", "SUCCESS", ago(30), run=200),
                check("ci-static", "SUCCESS", ago(31), run=200),
                check("ci-gate", "SUCCESS", ago(29), run=200),
            ],
        )
        self.assertEqual(self.classify(55, self.watch()), ("stale-checks", "act"))

    def red_edited_run(self, run, at=60):
        """本文の編集の run。段を走らせる 2 つが skipped で、ci-gate は同じ SHA の検査を読んで赤 (#2690)。"""
        return [
            check("ci-check", "SKIPPED", ago(at), run=run),
            check("ci-static", "SKIPPED", ago(at), run=run),
            check("ci-gate", "FAILURE", ago(at), run=run),
        ]

    def test_本文の編集の_run_の赤い_ci_gate_は_検査を打ち直して緑になったら移行期の行で名乗る(self):
        """#2717・#2718。R1 の ci-check が赤で終わり、検査の途中に立った本文の編集の run (R2) の ci-gate が
        それを読んで赤で終わった。R1 を打ち直して緑にしても、id の大きい R2 の赤が最新に残って必須を
        塞ぐ。当番の打ち直し (reread) は外したので、打たずに名乗り、打ち直す run の番号を出す。黙ると
        (出力なし・0 で終わる) 誰も気付かない。"""
        self.add_pr(56, auto=True, state="BLOCKED", checks=[
            check("ci-check", "SUCCESS", ago(10), run=100),
            check("ci-static", "SUCCESS", ago(100), run=100),
            check("ci-gate", "SUCCESS", ago(9), run=100),
        ] + self.red_edited_run(200))
        proc = self.watch(STALL_MINUTES=30)
        self.assertEqual(self.classify(56, proc), ("edited-gate", "name"), proc.stdout)
        line = next(ln for ln in proc.stdout.splitlines() if ln.startswith("56 "))
        self.assertIn("gh run rerun 200 --failed", line)
        self.assertIn("push", line)
        self.assertEqual(proc.returncode, 1, "猶予を超えた名乗りなのに赤くしない")
        self.assertNotIn("/rerun", self.gh_log(), "判定が打ち直している")

    def test_本文の編集の_run_の赤い_ci_gate_は_検査の最新が赤なら名乗らない(self):
        # 打ち直しても同じ赤を返すだけ。直すのはコードの側
        self.add_pr(57, auto=True, state="BLOCKED", checks=[
            check("ci-check", "FAILURE", ago(70), run=100),
            check("ci-static", "SUCCESS", ago(100), run=100),
            check("ci-gate", "FAILURE", ago(69), run=100),
        ] + self.red_edited_run(200))
        proc = self.watch()
        self.assertNotEqual(self.classify(57, proc)[0], "edited-gate", proc.stdout)

    def test_本文の編集の_run_の赤い_ci_gate_は_検査が走っている間は名乗らない(self):
        # 打ち直しが終わる前に打つと、ci-gate は待ちに入って runner を占めるだけになる
        self.add_pr(58, auto=True, state="BLOCKED", checks=[
            check("ci-check", None, ago(5), run=100),
            check("ci-static", "SUCCESS", ago(100), run=100),
            check("ci-gate", None, ago(5), run=100),
        ] + self.red_edited_run(200))
        proc = self.watch()
        self.assertNotEqual(self.classify(58, proc)[0], "edited-gate", proc.stdout)

    def test_本文の編集の_run_の赤い_ci_gate_は_検査の片方が同じ_SHA_に無ければ名乗らない(self):
        # ci-gate は skipped の検査ごとに同じ SHA の最新を読む。片方が無ければ打ち直しても赤い
        self.add_pr(60, auto=True, state="BLOCKED", checks=[
            check("ci-check", "SUCCESS", ago(10), run=100),
            check("ci-gate", "SUCCESS", ago(9), run=100),
        ] + self.red_edited_run(200))
        proc = self.watch()
        self.assertNotEqual(self.classify(60, proc)[0], "edited-gate", proc.stdout)

    def test_本文の編集の_run_の赤い_ci_gate_は_検査の最新を_ci_gate_sh_と同じ_suite_の順で読む(self):
        """#2717 の反証 2 (読み方をその run の版の ci-gate.sh と揃える)。作成順で最新の suite の、その中の
        最後の attempt を読む (#2716)。R1 の検査を後から打ち直した赤 (job の id は最大) は古い suite に
        載るので読まない — 読むのは R3 の緑で、打ち直せば緑を返す。同じ run の中では後の attempt を読み、
        R3 の打ち直しが赤なら名乗らない。"""
        older_rerun_red = [
            check("ci-check", "FAILURE", ago(10), run=100, job=900),
            check("ci-static", "SUCCESS", ago(100), run=100, job=101),
        ]
        edited = [
            check("ci-check", "SKIPPED", ago(5), run=400, job=401),
            check("ci-static", "SKIPPED", ago(5), run=400, job=402),
            check("ci-gate", "FAILURE", ago(5), run=400, job=403),
        ]
        self.add_pr(61, auto=True, state="BLOCKED", checks=older_rerun_red + [
            check("ci-check", "SUCCESS", ago(40), run=300, job=301),
            check("ci-static", "SUCCESS", ago(40), run=300, job=302),
            check("ci-gate", "SUCCESS", ago(39), run=300, job=303),
        ] + edited)
        # R3 の ci-check を打ち直して赤 (同じ run・後の attempt)。ci-gate.sh はその赤を読む
        self.add_pr(63, auto=True, state="BLOCKED", checks=older_rerun_red + [
            check("ci-check", "SUCCESS", ago(40), run=300, job=301),
            check("ci-check", "FAILURE", ago(8), run=300, job=950),
            check("ci-static", "SUCCESS", ago(40), run=300, job=302),
            check("ci-gate", "SUCCESS", ago(39), run=300, job=303),
        ] + edited)
        proc = self.watch()
        self.assertEqual(self.classify(61, proc)[0], "edited-gate", proc.stdout)
        self.assertIn("gh run rerun 400 --failed", next(l for l in proc.stdout.splitlines() if l.startswith("61 ")))
        self.assertNotEqual(self.classify(63, proc)[0], "edited-gate", proc.stdout)

    def test_作法のジョブを含む古い本文の編集の_run_の赤い_ci_gate_は_legacy_gate_と名乗る(self):
        """#2717 の反証 1。段を走らせていない run の赤でも、作法のジョブを含む古い run のものは
        legacy-gate と名乗る (その run は打ち直さず、push で新しい ci-gate を付ける)。"""
        self.add_pr(62, auto=True, state="BLOCKED", checks=[
            check("ci-check", "SUCCESS", ago(90), run=100),
            check("ci-static", "SUCCESS", ago(90), run=100),
            check("ci-gate", "SUCCESS", ago(89), run=100),
            check("pr-title", "FAILURE", ago(80), run=200),
            check("pr-gate", "SUCCESS", ago(10), run=300),
        ] + self.red_edited_run(200, at=80))
        proc = self.watch()
        self.assertEqual(self.classify(62, proc), ("legacy-gate", "name"), proc.stdout)

    def test_判定は何も打たない(self):
        self.add_pr(11, auto=False, state="CLEAN", checks=[check("ci-gate", "SUCCESS")], events=[removed("failed_checks", 10)])
        self.watch()
        log = self.gh_log()
        self.assertNotIn("pr merge", log)
        self.assertNotIn("/rerun", log)

    def test_猶予の中の名乗りでは_0_で終える(self):
        self.add_pr(12, auto=True, state="UNKNOWN", checks=[], updated=ago(5))
        proc = self.watch(STALL_MINUTES=60)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_猶予を超えた名乗りでは_1_で終える(self):
        self.add_pr(13, auto=True, state="UNKNOWN", checks=[], updated=ago(120))
        proc = self.watch(STALL_MINUTES=60)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)

    def runner_line(self, proc):
        for line in proc.stdout.splitlines():
            parts = line.split(maxsplit=4)
            if parts[:1] == ["-"]:
                return parts
        return None

    def test_render_が拾われないまま猶予を超えたら_runner_を名乗る(self):
        self.write_runs("queued", ago(10), ago(30))
        proc = self.watch()
        line = self.runner_line(proc)
        self.assertIsNotNone(line, proc.stdout)
        # 経過は最古の queued から測る
        self.assertEqual(line[1:4], ["runner-offline", "name", "30"], proc.stdout)
        self.assertEqual(proc.returncode, 1, proc.stdout)

    def test_門番が走って_run_が_in_progress_でも_専用機の_job_が拾われなければ名乗る(self):
        """render.yml の run は門番 (GitHub ホスト) が走ると in_progress になる (#2062)。
        run の status で読むと、runner が落ちても「走っている」に倒れて黙る。"""
        self.write_runs("in_progress", ago(30), job_status="queued")
        self.write_runs("queued", ago(5))
        proc = self.watch()
        line = self.runner_line(proc)
        self.assertIsNotNone(line, proc.stdout)
        self.assertEqual(line[1:4], ["runner-offline", "name", "30"], proc.stdout)

    def test_門番の_job_が走っていても_runner_が生きている印にはしない(self):
        self.write_runs("in_progress", ago(30), job_status="queued", gate="in_progress")
        proc = self.watch()
        line = self.runner_line(proc)
        self.assertIsNotNone(line, proc.stdout)
        self.assertEqual(line[1], "runner-offline", proc.stdout)

    def test_job_を読めなければ読めなかったと名乗る(self):
        self.write_runs("queued", ago(30))
        proc = self.watch(JOBS_FAIL=1)
        line = self.runner_line(proc)
        self.assertIsNotNone(line, proc.stdout)
        self.assertEqual(line[1:3], ["unreadable", "name"], proc.stdout)

    def test_他の_run_を走らせている間は順番待ちとして黙る(self):
        self.write_runs("queued", ago(30))
        self.write_runs("in_progress", ago(33))
        proc = self.watch()
        self.assertIsNone(self.runner_line(proc), proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout)

    def test_runner_が_2_本で_1_本だけ走っていて_queued_が猶予を超えたら名乗る(self):
        """N=2 のとき、1 本が落ちて残りが走っている間も、空いた runner が queued を拾わない (#3320)。"""
        self.write_runs("in_progress", ago(25))
        self.write_runs("queued", ago(20))
        proc = self.watch(RENDER_TURN_SLOTS=2)
        line = self.runner_line(proc)
        self.assertIsNotNone(line, proc.stdout)
        self.assertEqual(line[1:4], ["runner-offline", "name", "20"], proc.stdout)
        self.assertEqual(proc.returncode, 1, proc.stdout)

    def test_runner_が_1_本なら_1_本走っている間の_queued_は同じ状況でも黙る(self):
        """同じ入力で N=1 (明示) なら従来どおり順番待ち。"""
        self.write_runs("in_progress", ago(25))
        self.write_runs("queued", ago(20))
        proc = self.watch(RENDER_TURN_SLOTS=1)
        self.assertIsNone(self.runner_line(proc), proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout)

    def test_RENDER_TURN_SLOTS_が未設定か空なら_1_として読む(self):
        self.write_runs("in_progress", ago(25))
        self.write_runs("queued", ago(20))
        for value in (None, ""):
            with self.subTest(value=value):
                extra = {} if value is None else {"RENDER_TURN_SLOTS": value}
                proc = self.watch(**extra)
                self.assertIsNone(self.runner_line(proc), proc.stdout)
                self.assertEqual(proc.returncode, 0, proc.stdout)

    def test_runner_が_2_本とも走っていれば_queued_が猶予を超えても黙る(self):
        """N 本そろって走っている間は順番待ち。"""
        self.write_runs("in_progress", ago(25), ago(24))
        self.write_runs("queued", ago(20))
        proc = self.watch(RENDER_TURN_SLOTS=2)
        self.assertIsNone(self.runner_line(proc), proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout)

    def test_runner_が_2_本で_queued_が猶予の内なら黙る(self):
        self.write_runs("in_progress", ago(25))
        self.write_runs("queued", ago(3))
        proc = self.watch(RENDER_TURN_SLOTS=2)
        self.assertIsNone(self.runner_line(proc), proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout)

    def test_RENDER_TURN_SLOTS_が整数でなければ読めなかったと名乗る(self):
        """黙って 1 に倒すと、runner を足した後の設定の誤りに気付けない。"""
        self.write_runs("in_progress", ago(25))
        self.write_runs("queued", ago(20))
        for bad in ("0", "two", "-1", "1.5", "02"):
            with self.subTest(bad=bad):
                proc = self.watch(RENDER_TURN_SLOTS=bad)
                line = self.runner_line(proc)
                self.assertIsNotNone(line, proc.stdout)
                self.assertEqual(line[1:3], ["unreadable", "name"], proc.stdout)
                self.assertIn("RENDER_TURN_SLOTS", proc.stdout)

    def test_stall_watch_yml_は変数を当番へ渡す(self):
        """render.yml (門番) と同じ vars.RENDER_TURN_SLOTS を渡す。渡さないと Actions 上では常に 1 になる。"""
        wf = (WORKFLOWS / "stall-watch.yml").read_text(encoding="utf-8")
        self.assertIn("RENDER_TURN_SLOTS: ${{ vars.RENDER_TURN_SLOTS }}", wf)

    # --- 着手印の残った Issue (stale-claim・#3366) ----------------------------

    def claim_line(self, number, proc):
        for line in proc.stdout.splitlines():
            parts = line.split(maxsplit=4)
            if parts and parts[0] == str(number) and parts[1:2] == ["stale-claim"]:
                return parts
        return None

    def test_人の手が閾値以上無い着手印を_Issue_の番号で名乗って赤くする(self):
        """#2507 の形 (印も人の最後の手も古い)・#2251 の形 (人の手が止まり bot の追記だけが続く) を
        ready-queue.sh の dropped が名乗る。当番はそれを Issue の番号で出し、1 で終える。"""
        self.write_ready_queue(
            [
                "2507 dropped 着手印が残ったまま 4320 分以上動いていない (専用機の設定)",
                "2251 dropped 着手印が残ったまま 4320 分以上動いていない (定期の検査の赤)",
            ],
            rc=1,
        )
        proc = self.watch()
        for n in (2507, 2251):
            line = self.claim_line(n, proc)
            self.assertIsNotNone(line, proc.stdout)
            self.assertEqual(line[1:4], ["stale-claim", "name", "4320"], proc.stdout)
        self.assertIn("印を外して", proc.stdout)
        self.assertIn("プランを更新", proc.stdout)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)

    def test_閾値は判定へそのまま渡す(self):
        """DROPPED_MINUTES が静けさの境目と bot の手を読む窓の両方を決める。渡さないと既定の 120 分で
        判定され、2 日前に人が触れた着手まで名乗る。"""
        self.watch()
        self.assertEqual((self.queue_dir / "seen-minutes").read_text(encoding="utf-8"), "4320")
        self.watch(CLAIM_STALL_MINUTES=90)
        self.assertEqual((self.queue_dir / "seen-minutes").read_text(encoding="utf-8"), "90")

    def test_dropped_以外の行は名乗らない(self):
        """2 日前に人がコメントした着手 (busy)・PR が出ているもの・ready は名乗らない。"""
        self.write_ready_queue(
            [
                "10 ready [Bug] 着手できる",
                "11 busy まだ動いている (人の手が 2 日前)",
                "12 busy PR #90 が出ている (なにか)",
                "13 stock [Task] 無印",
            ],
            rc=0,
        )
        proc = self.watch()
        self.assertEqual(proc.stdout.strip(), "", proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_ready_が_0_件の終了コード_1_は読めている(self):
        self.write_ready_queue(["2507 dropped 着手印が残ったまま 4320 分以上動いていない (x)"], rc=1)
        proc = self.watch()
        self.assertIsNotNone(self.claim_line(2507, proc), proc.stdout)
        self.assertNotIn("unreadable", proc.stdout)

    def test_判定を読めなければ読めなかったと名乗る(self):
        """一覧を読めなかった (2)・件数の行を出さずに落ちた (1) を、dropped が 0 件と読まない。
        黙ると名乗りが無いまま「正常」に混ざる (#1303)。読めなかっただけでは赤くしない。"""
        cases = {"終了コード 2": dict(rc=2), "件数の行が無い 1": dict(rc=1, summary=False)}
        for name, kw in cases.items():
            with self.subTest(name):
                self.write_ready_queue([], **kw)
                proc = self.watch()
                line = next(l.split(maxsplit=4) for l in proc.stdout.splitlines() if "unreadable" in l)
                self.assertEqual(line[:3], ["-", "unreadable", "name"], proc.stdout)
                self.assertIn("着手印", line[4], proc.stdout)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_着手印の判定は何も書き込まない(self):
        """印を外さず・起票もしない。当番に渡すのは issues: read だけ。"""
        self.write_ready_queue(["2507 dropped 着手印が残ったまま 4320 分以上動いていない (x)"], rc=1)
        self.watch()
        log = self.gh_log()
        for verb in ("issue edit", "issue comment", "issue close", "issue create", "--add-label", "--remove-label"):
            self.assertNotIn(verb, log)

    def test_当番の_watch_job_は_issues_read_だけを足す(self):
        """ready-queue.sh は Issue を読む。issues: write は渡さず、ほかの権限は変えない (#3366)。"""
        wf = (WORKFLOWS / "stall-watch.yml").read_text(encoding="utf-8")
        job = wf[wf.index("  watch:") :]
        perms = dict(re.findall(r"^      ([a-z-]+): (read|write)", job, re.M))
        self.assertEqual(
            perms,
            {"contents": "read", "pull-requests": "read", "actions": "write", "issues": "read"},
            job,
        )

    def test_stall_act_は着手印の行に何も打たない(self):
        proc = self.act(["2507 stale-claim name 4320 着手印が残ったまま"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.gh_log().strip(), "", self.gh_log())

    def test_猶予の内の_queued_は黙る(self):
        self.write_runs("queued", ago(3))
        proc = self.watch()
        self.assertIsNone(self.runner_line(proc), proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout)

    def test_run_を読めなければ読めなかったと名乗る(self):
        """黙ると「止まっていない」に倒れる (#1303)。"""
        proc = self.watch(RUNS_FAIL=1)
        line = self.runner_line(proc)
        self.assertIsNotNone(line, proc.stdout)
        self.assertEqual(line[1:3], ["unreadable", "name"], proc.stdout)

    def test_runner_の行には何も打たない(self):
        proc = self.act(["- runner-offline name 30 専用機の runner が render を拾っていない"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("pr merge", self.gh_log())
        self.assertNotIn("/rerun", self.gh_log())

    def test_猶予の内の外れは赤くしない(self):
        """弾かれた直後は、人が読んで掛け直すまでの時間である (#642)。"""
        self.add_pr(14, auto=False, state="CLEAN", checks=[check("ci-gate", "SUCCESS")], events=[removed("failed_checks", 5)])
        proc = self.watch(STALL_MINUTES=60)
        self.assertEqual(self.classify(14, proc), ("auto-merge-dropped", "name"), proc.stdout)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_読めなかった理由を捨てない(self):
        """unreadable と名乗るだけで理由を捨てると、何が読めなかったのか誰にも分からない (#2614)。"""
        self.add_pr(15, auto=False, state="CLEAN")
        proc = self.watch(RUNS_FAIL=1, VIEW_FAILS=1)
        self.assertEqual(self.classify(15, proc), ("unreadable", "name"), proc.stdout)
        self.assertIn("gh: 502", proc.stderr)
        self.assertIn("HTTP 502: Bad Gateway (pr view)", proc.stderr)

    # --- 対処 ---------------------------------------------------------------

    def test_集約の_ci_gate_は上流より後に打つ(self):
        """#1883。先に ci-gate を打つと、ci-gate だけが前の結論を読んで同じ赤を返し、その run が
        走っている間は上流 (ci-check) の打ち直しが拒まれる。check run の並びが同じなら毎回そうなる。"""
        self.add_pr(20)
        self.write(
            "20.checkruns.json",
            {
                "check_runs": [
                    {"name": "ci-gate", "conclusion": "failure", "id": 111},
                    {"name": "ci-check", "conclusion": "failure", "id": 222},
                ]
            },
        )
        proc = self.act(["20 stale-checks act 5 古い失敗 check"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        log = self.gh_log()
        self.assertIn("jobs/222/rerun", log, "上流の失敗ジョブへ打っていない")
        self.assertIn("jobs/111/rerun", log, "集約だけが落ちた回に打てない")
        self.assertLess(log.index("jobs/222/rerun"), log.index("jobs/111/rerun"), "ci-gate を上流より先に打っている")

    def test_作法のジョブを含む古い_run_は丸ごと打たない(self):
        """#2669 より前の ci.yml の run の pr-title を打つと古いタイトルを再生し (#699)、その run の
        ci-gate を打つと needs の赤で赤く返して最新になる。除外の名前では ci-gate を外せないので、
        run の単位で外す。"""
        self.add_pr(29)
        url = "https://github.com/o/r/actions/runs/{}/job/{}"
        self.write(
            "29.checkruns.json",
            {
                "check_runs": [
                    {"name": "pr-title", "conclusion": "failure", "id": 111, "details_url": url.format(100, 111)},
                    {"name": "review-gate", "conclusion": "success", "id": 113, "details_url": url.format(100, 113)},
                    {"name": "ci-gate", "conclusion": "failure", "id": 112, "details_url": url.format(100, 112)},
                    {"name": "ci-check", "conclusion": "failure", "id": 301, "details_url": url.format(300, 301)},
                    {"name": "ci-gate", "conclusion": "failure", "id": 302, "details_url": url.format(300, 302)},
                ]
            },
        )
        proc = self.act(["29 stale-checks act 5 古い失敗 check"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        log = self.gh_log()
        self.assertNotIn("jobs/111/rerun", log, "古い run の pr-title を打っている")
        self.assertNotIn("jobs/112/rerun", log, "古い run の ci-gate を打っている")
        self.assertIn("jobs/301/rerun", log, "新しい run の失敗ジョブへ打っていない")
        self.assertIn("#29: ci-gate は作法のジョブを含む古い ci.yml の run", proc.stdout)

    def test_cancel_された_render_pr_を巻き添えで_rerun_しない(self):
        """ジョブ単位の rerun は門番 (render-turn) を通らず、専用機へ直に積む (#2062)。"""
        self.add_pr(25)
        self.write(
            "25.checkruns.json",
            {
                "check_runs": [
                    {"name": "render-pr", "conclusion": "cancelled", "id": 333},
                    {"name": "ci-check", "conclusion": "failure", "id": 222},
                ]
            },
        )
        proc = self.act(["25 stale-checks act 5 古い失敗 check"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        log = self.gh_log()
        self.assertNotIn("jobs/333/rerun", log, "render-pr へ rerun を打っている")
        self.assertIn("jobs/222/rerun", log)

    def test_pr_gate_の古い失敗や_cancel_に_rerun_を打たない(self):
        """pr-gate は最新の run の結論が判定で、直せば新しい run が付け直す (#2668)。古い run を
        打ち直すと、同じ concurrency の group で走っている新しい run を cancel しうる。"""
        self.add_pr(26)
        self.write(
            "26.checkruns.json",
            {
                "check_runs": [
                    {"name": "pr-gate", "conclusion": "failure", "id": 444},
                    {"name": "pr-gate", "conclusion": "cancelled", "id": 555},
                    {"name": "ci-check", "conclusion": "failure", "id": 222},
                ]
            },
        )
        proc = self.act(["26 stale-checks act 5 古い失敗 check"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        log = self.gh_log()
        self.assertNotIn("jobs/444/rerun", log, "古い pr-gate へ rerun を打っている")
        self.assertNotIn("jobs/555/rerun", log, "cancel された pr-gate へ rerun を打っている")
        self.assertIn("jobs/222/rerun", log)

    def test_名乗る行には何も打たない(self):
        proc = self.act(["21 conflict name 90 main と衝突している"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        log = self.gh_log()
        self.assertNotIn("pr merge", log)
        self.assertNotIn("/rerun", log)

    def test_予約が外れた_PR_があっても当番は掛けず_対処は赤くならない(self):
        """判定の出力をそのまま対処へ渡す (stall-watch.yml と同じ流れ)。

        当番の GITHUB_TOKEN では予約を掛けられない (MERGE_FAILS が本物の FORBIDDEN に
        当たる・#2614)。以前は毎回「掛け直せなかった」で exit 1 になり、他の赤を埋もれさせた。
        赤で人に返すのは判定の終了コード (猶予) の役目で、対処は名乗りの行に何も打たない。"""
        self.add_pr(22, auto=False, state="BLOCKED", checks=[check("ci-gate", "SUCCESS")], events=[removed("failed_checks", 5)])
        watched = self.watch(STALL_MINUTES=60)
        self.assertEqual(watched.returncode, 0, watched.stdout + watched.stderr)
        self.assertEqual(self.classify(22, watched), ("auto-merge-dropped", "name"), watched.stdout)
        proc = self.act(watched.stdout.splitlines(), MERGE_FAILS="1")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertNotIn("pr merge", self.gh_log())

    def test_rerun_に失敗したら理由を添えて_1_で終える(self):
        self.add_pr(23)
        self.write("23.checkruns.json", {"check_runs": [{"name": "ci-check", "conclusion": "failure", "id": 222}]})
        proc = self.act(["23 stale-checks act 5 古い失敗 check"], RERUN_FAILS="1")
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertRegex(
            proc.stderr, r"#23: ci-check を rerun できなかった: gh: Resource not accessible by integration \(HTTP 403\)"
        )

    def test_同じ_run_が走り直している間の_rerun_の拒否は赤にしない(self):
        """同じ run の別の失敗ジョブを先に打つと run が走り出し、残りは 403 で拒まれる (#2614 の
        反証)。2026-09-30 の #1883 では 1 回の当番で、ci-gate を打った直後の review-gate と
        drawing-evidence が 9 本「rerun できなかった」になった (理由は捨てられていて残っていないが、同じ形を
        再現するとこの文面になる)。次の回に回せば済む。"""
        self.add_pr(27)
        self.write("27.checkruns.json", {"check_runs": [{"name": "review-gate", "conclusion": "failure", "id": 444}]})
        proc = self.act(["27 stale-checks act 5 古い失敗 check"], RERUN_RUNNING="1")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("#27: review-gate は同じ run が走り直している", proc.stdout)

    def test_古い_attempt_のジョブの_rerun_の拒否は赤にしない(self):
        """commit の check run の一覧には走り直す前の attempt のジョブも残る。それは打ち直せず、
        新しい attempt の側が同じ一覧に居る。毎回の赤にしない。"""
        self.add_pr(28)
        self.write("28.checkruns.json", {"check_runs": [{"name": "ci-gate", "conclusion": "failure", "id": 555}]})
        proc = self.act(["28 stale-checks act 5 古い失敗 check"], RERUN_OLD_ATTEMPT="1")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("#28: ci-gate は古い attempt のジョブ", proc.stdout)

    def test_check_run_を読めなかったら理由を添えて_1_で終える(self):
        self.add_pr(24)
        proc = self.act(["24 stale-checks act 5 古い失敗 check"], CHECKRUNS_FAIL="1")
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertRegex(proc.stderr, r"#24: check run の一覧を読めなかった.*HTTP 504: Gateway Timeout")

    def test_head_を読めなかったら理由を添えて_1_で終える(self):
        proc = self.act(["26 stale-checks act 5 古い失敗 check"], VIEW_FAILS="1")
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertRegex(proc.stderr, r"#26: head の commit を読めなかった.*HTTP 502: Bad Gateway \(pr view\)")

    def test_入力ファイルが無ければ_66_で終える(self):
        proc = subprocess.run(
            ["/bin/bash", str(ACT), str(Path(self.tmp.name) / "無い.log")],
            capture_output=True,
            text=True,
            env=self.env(),
        )
        self.assertEqual(proc.returncode, 66)


class RerunExclusionTest(unittest.TestCase):
    """凍結ペイロードの可変欄を読むジョブが、除外リストに載っているか (#801 と同じ形)。

    pull_request の rerun は元のイベントを再生するので、title / body / labels を
    ペイロードから受け取るジョブは古い値で判定される。番号や sha は run の中で
    変わらないので、それだけを受け取るジョブは rerun して安全である。いまは 1 本も
    無い (ci.yml の pr-title は #2669 で消え、pr-gate はタイトルも API から読む)。
    """

    MUTABLE = ("title", "body", "labels")

    def excluded_jobs(self):
        text = ACT.read_text(encoding="utf-8")
        found = re.search(r'RERUN_EXCLUDED=\$\{RERUN_EXCLUDED:-"([^"]*)"\}', text)
        self.assertIsNotNone(found, "stall-act.sh の除外リストを読めない")
        return set(found.group(1).split())

    def jobs_reading_mutable_payload(self, text):
        """ワークフローの本文を走査し、可変欄を式に含むジョブの名前を返す (コメントは読まない)。"""
        jobs = set()
        current = None
        in_jobs = False
        for line in text.splitlines():
            if line.lstrip().startswith("#"):
                continue
            if re.match(r"^jobs:\s*$", line):
                in_jobs = True
                continue
            if in_jobs and re.match(r"^\S", line):
                in_jobs = False
            if not in_jobs:
                continue
            named = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
            if named:
                current = named.group(1)
                continue
            if current and any(
                f"github.event.pull_request.{field}" in line for field in self.MUTABLE
            ):
                jobs.add(current)
        return jobs

    def test_可変欄を読むジョブが除外リストに載っている(self):
        reading = set()
        for name in PR_WORKFLOWS:
            reading |= self.jobs_reading_mutable_payload((WORKFLOWS / name).read_text(encoding="utf-8"))
        missing = reading - self.excluded_jobs()
        self.assertEqual(
            missing,
            set(),
            f"凍結されたペイロードを読むのに rerun の除外に載っていない: {sorted(missing)}"
            " — stall-act.sh の RERUN_EXCLUDED へ足す (#699)",
        )

    def test_走査は可変欄を読むジョブを拾う(self):
        # 読み手が壊れると、上の検査は黙って緑になる
        text = (
            "on: pull_request\njobs:\n  a:\n    steps:\n      - env:\n"
            "          TITLE: ${{ github.event.pull_request.title }}\n"
            "  b:\n    # github.event.pull_request.body はコメント\n    steps: []\n"
        )
        self.assertEqual(self.jobs_reading_mutable_payload(text), {"a"})

    # --- タイトルの赤の直し方 (#2669) -----------------------------------------
    #
    # pr-gate はタイトルを API から読むので、直せば新しい run が付け直し、その結論が同じコミットの
    # 最新になる。ci.yml の pr-title が居た頃の「新しいコミットを push して run を作り直す」に
    # 戻っていないこと、bad-title が読む step の名前が pr-gate.yml と一致することを固定する

    @staticmethod
    def squash(text):
        return re.sub(r"\s+", "", text)

    def test_読み分け表の_6_は打ち直しも新しいコミットも要らないと言う(self):
        header = self.squash(WATCH.read_text(encoding="utf-8").split("set -euo pipefail")[0])
        self.assertIn(self.squash("打ち直しも新しいコミットも要らない"), header)
        self.assertNotIn(self.squash("新しいコミットを push して run を作り直す"), header)
        self.assertNotIn("空コミット", header)

    def test_古い_run_の作法のジョブの名前は判定と対処で同じ(self):
        watch = re.search(r"^readonly LEGACY_JOBS='(\[[^']*\])'$", WATCH.read_text(encoding="utf-8"), re.M)
        act = re.search(r'^readonly LEGACY_JOBS="([^"]*)"$', ACT.read_text(encoding="utf-8"), re.M)
        self.assertIsNotNone(watch, "stall-watch.sh の LEGACY_JOBS を読めない")
        self.assertIsNotNone(act, "stall-act.sh の LEGACY_JOBS を読めない")
        self.assertEqual(json.loads(watch.group(1)), act.group(1).split())
        self.assertEqual(set(act.group(1).split()), {"pr-title", "review-gate", "drawing-evidence"})

    def test_bad_title_が読む_step_は_pr_gate_yml_に在る(self):
        found = re.search(r"^readonly TITLE_STEP='([^']+)'$", WATCH.read_text(encoding="utf-8"), re.M)
        self.assertIsNotNone(found, "stall-watch.sh の TITLE_STEP を読めない")
        self.assertEqual(found.group(1), TITLE_STEP)
        gate = (WORKFLOWS / "pr-gate.yml").read_text(encoding="utf-8")
        self.assertRegex(gate, rf"(?m)^      - name: {re.escape(found.group(1))}$")


class RequiredRuleTest(unittest.TestCase):
    """必須の判定がどの check run を読むかの規則は、scripts/ci-gate.sh の冒頭 1 か所に書く (#2577)。

    規則は観測からの推定で、ci.yml・stall-act.sh・stall-watch.sh・pr-gate.yml がそれぞれ別の言い方で
    写していた頃は、観測と食い違う言い方 (「run ごとの最新がどれも赤くない」「決まっていない」) が
    残った。写しを持たずに置き場を指すこと、置き場の見出しが在ることを固定する。
    """

    GATE = REPO / "scripts" / "ci-gate.sh"
    POINTER = "ci-gate.sh 冒頭の「必須の判定が読む check run」"
    READERS = (
        WORKFLOWS / "ci.yml", WORKFLOWS / "pr-gate.yml", ACT, WATCH,
        # 差し戻しの文面の前提も同じ規則に乗る (#2716 の反証 3)
        REPO / "scripts" / "review-gate.sh", REPO / "scripts" / "check-drawing-evidence.sh",
    )
    STALE = (
        "run ごとの最新", "run (check suite) ごとの最新", "どれも赤くない", "決まっていない (#2577)",
        # #2712 で成り立たなかった前提 (#2716 の反証 3)
        "同じコミットの最新", "concurrency が止める", "ラベルの run で付け直されます",
        # pr-gate が concurrency を持っていた頃の前提 (#2716 の 2 回目の反証 1)
        "3 つ以上重な", "cancel-in-progress: false では", "group の待ちを置き換えて",
    )

    @staticmethod
    def prose(path):
        """コメントの行頭の # と空白を外して 1 続きにする (折り返しで言い回しが割れても読めるように)。"""
        lines = [re.sub(r"^\s*#\s?", "", line) for line in path.read_text(encoding="utf-8").splitlines()]
        return re.sub(r"\s+", "", "".join(lines))

    def test_規則の置き場は_ci_gate_sh_の冒頭に在る(self):
        text = self.GATE.read_text(encoding="utf-8")
        self.assertRegex(text, r"(?m)^# ## 必須の判定が読む check run \(#2577\)$")
        header = self.prose(self.GATE)
        self.assertIn(re.sub(r"\s+", "", "作成順で最新の check suite (run) に載った"), header)
        self.assertIn("確かめていないこと(#2692)", header)

    def test_ほかは置き場を指し_食い違う言い方を残さない(self):
        pointer = re.sub(r"\s+", "", self.POINTER)
        for path in self.READERS:
            text = self.prose(path)
            self.assertIn(pointer, text, f"{path.name} が規則の置き場を指していない")
        for path in (self.GATE, *self.READERS):
            text = self.prose(path)
            for phrase in self.STALE:
                self.assertNotIn(re.sub(r"\s+", "", phrase), text, f"{path.name} に「{phrase}」が残っている")


if __name__ == "__main__":
    unittest.main()
