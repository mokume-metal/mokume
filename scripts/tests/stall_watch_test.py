#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/stall-watch.sh の検査 (#961)。

固定したいのは八。

1. **BLOCKED で予約が外れた PR は、重要パスに触れていても名乗る。** 承認のゲートは
   ADR-0044 で外れた (#2108) ので、承認待ちと読んで黙ると予約が外れたまま誰も直さない
2. **判定は何も打たない。** 手元で様子を見るために打っただけで auto-merge が掛かったり
   再実行が走ったりしてはならない
3. **Draft と fork からの PR は見ない。** 作業中の PR を Draft にしておくのが opt-out で、
   fork の PR に予約を掛けるかは引き取るメンテナが決める (#1361)
4. **猶予の中の名乗りでは赤くしない。** 走るたびに通知が飛ぶと「毎回出る注意は意味を
   失う」(#642) を踏む
5. **専用機の runner が止まったことを、順番待ちと分けて名乗る** (#1774)。必須の render が
   走らないと、描画に触れない PR も含めて queue 全体が止まる。1 台なので、他の run を
   走らせている間の queued は正常な順番待ちで、名乗ると毎回の注意になる (#642)。runner が
   RENDER_TURN_SLOTS (N) 本のときは、専用機の job が N 本そろって走っている間だけ順番待ちで、
   N 本未満なら空いた runner が拾わない queued を名乗る (#3320)。N は門番と同じ値を読み、
   未設定なら 1 (従来どおり)
6. **予約が外れた PR があっても、当番は予約を掛けない** (#2614)。当番の GITHUB_TOKEN では
   掛けられない (`enablePullRequestAutoMerge` が FORBIDDEN)。**代わりに、外れた出来事
   (queue から弾かれた・人の操作でなく外された) から猶予を超えたら赤で人に返す。**
   一度も予約を掛けていない PR と、人が外した予約は「外れた」と名乗らない
7. **gh が失敗した理由 (stderr) を捨てない** (#2614)。捨てると、失敗が何十回続いても
   理由がどこにも残らない
8. **人の手が閾値 (既定 3 日) 以上無い着手印を、Issue の番号で名乗って赤くする** (#3366)。判定は
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
WORKFLOWS = REPO / ".github" / "workflows"

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
  # ジョブの中身 (step の結論)。bad-title が赤い pr-gate のタイトルの step を読む (#2669)。
  # 既定は空 (step が見つからない)
  */actions/jobs/*)
    [ -z "${JOB_FAILS:-}" ] || { echo "gh: HTTP 502: Bad Gateway (job)" >&2; exit 1; }
    emit "$PR_DIR/job.${url##*/}.json"; exit 0 ;;
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

    def write_ready_queue(self, lines, *, rc=1, summary=True, incomplete=None):
        """差し替える ready-queue.sh。lines を標準出力へ出し、rc で終わる。

        渡された DROPPED_MINUTES は seen-minutes へ控える。summary=False は件数の行を出さない
        (途中で落ちた回の形)。incomplete は一部を読めないまま完走した印 (標準エラーの最後の 1 行)。"""
        (self.queue_dir / "out.txt").write_text("".join(f"{l}\n" for l in lines), encoding="utf-8")
        script = self.queue_dir / "ready-queue.sh"
        script.write_text(
            "#!/bin/bash\n"
            f'printf "%s" "${{DROPPED_MINUTES-unset}}" > "{self.queue_dir}/seen-minutes"\n'
            f'cat "{self.queue_dir}/out.txt"\n'
            + ('echo "ready 0 / stock 0 / dropped 0 / busy 0 / decide 0" >&2\n' if summary else 'echo "boom" >&2\n')
            + (f'echo "incomplete: {incomplete}" >&2\n' if incomplete else "")
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
        """読めずに空が返ったとき、居ないと読んで外れたに落とさない (#1303)。"""
        self.add_pr(37, auto=False, state="BLOCKED", events=[removed("failed_checks", 120)])
        proc = self.watch(QUEUE_FAILS=1)
        self.assertEqual(self.classify(37, proc), ("unreadable", "name"), proc.stdout)
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

    def test_衝突して_check_が_1_本も付かない_PR_を名乗る(self):
        self.add_pr(6, auto=True, state="UNKNOWN", checks=[])
        kind, action = self.classify(6, self.watch())
        self.assertEqual((kind, action), ("conflict", "name"))

    # --- タイトルの赤は pr-gate のタイトルの step で読む (#2669) ---------------

    def test_最新の_pr_gate_のタイトルの_step_が落ちた_PR_は名乗るに分類される(self):
        # **auto-merge-dropped より先に判定されること。** 後ろだと掛け直しを勧めるだけで名乗らない
        self.add_pr(
            10,
            auto=False,
            state="BLOCKED",
            checks=[
                check("pr-gate", "FAILURE", ago(10), run=300, job=901),
                check("ci-gate", "SUCCESS", ago(5), run=200),
            ],
            events=[enabled(90), removed("failed_checks", 20)],
        )
        self.write("job.901.json", gate_job("failure", review="failure"))
        proc = self.watch()
        self.assertEqual(self.classify(10, proc), ("bad-title", "name"), proc.stdout)
        lines = [ln for ln in proc.stdout.splitlines() if ln.startswith("10 ")]
        self.assertEqual(len(lines), 1, proc.stdout)
        self.assertIn("打ち直しも新しいコミットも要らない", lines[0])
        self.assertNotIn("push", lines[0])

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
        """DROPPED_MINUTES が静けさの境目と bot の手を読むウィンドウの両方を決める。渡さないと既定の 120 分で
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

    def test_一部を読めないまま完走した回は読めなかったと名乗る(self):
        """読めなかった番号は busy へ倒れて名乗られない。dropped が 0 件の緑と区別する (#3366)。
        見つかった dropped は続けて名乗り、赤にするのはそちらだけ。"""
        self.write_ready_queue([], rc=1, incomplete="hands-unread capped-Issue")
        proc = self.watch()
        line = next(l.split(maxsplit=4) for l in proc.stdout.splitlines() if "unreadable" in l)
        self.assertEqual(line[:3], ["-", "unreadable", "name"], proc.stdout)
        self.assertIn("hands-unread capped-Issue", line[4], proc.stdout)
        self.assertEqual(proc.returncode, 0, "読めなかっただけで赤くしている: " + proc.stdout)

        self.write_ready_queue(
            ["2507 dropped 着手印が残ったまま 4320 分以上動いていない (x)"], rc=1, incomplete="hands-unread"
        )
        proc = self.watch()
        self.assertIn("unreadable", proc.stdout)
        self.assertIsNotNone(self.claim_line(2507, proc), proc.stdout)
        self.assertEqual(proc.returncode, 1, proc.stdout)

    def test_全部読めた回は読めなかったと名乗らない(self):
        self.write_ready_queue([], rc=1)
        proc = self.watch()
        self.assertNotIn("unreadable", proc.stdout)

    def run_result_step(self, log_lines, status):
        """stall-watch.yml の最後の step の run を、stall.log と STATUS を渡して走らせる。"""
        wf = (WORKFLOWS / "stall-watch.yml").read_text(encoding="utf-8")
        block = wf[wf.index("name: 名乗りの結果") :]
        body = block[block.index("run: |\n") + len("run: |\n") :]
        script = "\n".join(l[10:] if l.startswith(" " * 10) else l for l in body.splitlines())
        work = Path(self.tmp.name) / "step"
        work.mkdir(exist_ok=True)
        (work / "stall.log").write_text("".join(f"{l}\n" for l in log_lines), encoding="utf-8")
        summary = work / "summary.md"
        summary.write_text("", encoding="utf-8")
        proc = subprocess.run(
            ["/bin/bash", "-eo", "pipefail", "-c", script],
            cwd=work,
            capture_output=True,
            text=True,
            env={**os.environ, "STATUS": str(status), "GITHUB_STEP_SUMMARY": str(summary)},
        )
        return proc, summary.read_text(encoding="utf-8")

    def test_読めなかった判定は赤にせず_run_の要約と_annotation_に出す(self):
        """既存の unreadable の扱い (終了コードに数えない) は変えず、続けて読めなくても誰かの目に入るようにする (#3366)。"""
        proc, summary = self.run_result_step(
            ["- unreadable name 0 着手印の判定の一部を読めないまま終わった (hands-unread)", "12 unreadable name 0 PR を読めなかった"],
            status=0,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        warnings = [l for l in proc.stdout.splitlines() if l.startswith("::warning")]
        self.assertEqual(len(warnings), 2, proc.stdout)
        self.assertIn("hands-unread", warnings[0])
        self.assertIn("hands-unread", summary)
        self.assertIn("PR を読めなかった", summary)

    def test_読めなかった判定が無ければ_annotation_は出ない_赤は従来どおり(self):
        proc, summary = self.run_result_step(["2507 stale-claim name 4320 x"], status=1)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertNotIn("::warning", proc.stdout)
        self.assertEqual(summary, "")

    def test_着手印の判定は何も書き込まない(self):
        """印を外さず・起票もしない。当番に渡すのは issues: read だけ。"""
        self.write_ready_queue(["2507 dropped 着手印が残ったまま 4320 分以上動いていない (x)"], rc=1)
        self.watch()
        log = self.gh_log()
        for verb in ("issue edit", "issue comment", "issue close", "issue create", "--add-label", "--remove-label"):
            self.assertNotIn(verb, log)

    def test_当番の_watch_job_は読み取りの権限だけを持つ(self):
        """判定は読み取りしかしない。Issue (ready-queue.sh・#3366) と Actions の run・job (render.yml の
        run と job・pr-gate の job の step) を読むので、それぞれ read を渡し、write は渡さない。"""
        wf = (WORKFLOWS / "stall-watch.yml").read_text(encoding="utf-8")
        job = wf[wf.index("  watch:") :]
        perms = dict(re.findall(r"^      ([a-z-]+): (read|write)", job, re.M))
        self.assertEqual(
            perms,
            {"contents": "read", "pull-requests": "read", "actions": "read", "issues": "read"},
            job,
        )

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


class TitleFixTest(unittest.TestCase):
    """タイトルの赤の直し方 (#2669)。

    pr-gate はタイトルを API から読むので、直せば新しい run が付け直し、その結論が必須の読む
    最新になる。ci.yml の pr-title が居た頃の「新しいコミットを push して run を作り直す」に
    戻っていないこと、bad-title が読む step の名前が pr-gate.yml と一致することを固定する。
    """

    @staticmethod
    def squash(text):
        return re.sub(r"\s+", "", text)

    def test_読み分け表の_5_は打ち直しも新しいコミットも要らないと言う(self):
        header = self.squash(WATCH.read_text(encoding="utf-8").split("set -euo pipefail")[0])
        self.assertIn(self.squash("打ち直しも新しいコミットも要らない"), header)
        self.assertNotIn(self.squash("新しいコミットを push して run を作り直す"), header)
        self.assertNotIn("空コミット", header)

    def test_bad_title_が読む_step_は_pr_gate_yml_に在る(self):
        found = re.search(r"^readonly TITLE_STEP='([^']+)'$", WATCH.read_text(encoding="utf-8"), re.M)
        self.assertIsNotNone(found, "stall-watch.sh の TITLE_STEP を読めない")
        self.assertEqual(found.group(1), TITLE_STEP)
        gate = (WORKFLOWS / "pr-gate.yml").read_text(encoding="utf-8")
        self.assertRegex(gate, rf"(?m)^      - name: {re.escape(found.group(1))}$")


class RequiredRuleTest(unittest.TestCase):
    """必須の判定がどの check run を読むかの規則は、scripts/ci-gate.sh の冒頭 1 か所に書く (#2577)。

    規則は観測からの推定で、ci.yml・stall-watch.sh・pr-gate.yml などがそれぞれ別の言い方で
    写していた頃は、観測と食い違う言い方 (「run ごとの最新がどれも赤くない」「決まっていない」) が
    残った。写しを持たずに置き場を指すこと、置き場の見出しが在ることを固定する。
    """

    GATE = REPO / "scripts" / "ci-gate.sh"
    POINTER = "ci-gate.sh 冒頭の「必須の判定が読む check run」"
    READERS = (
        WORKFLOWS / "ci.yml", WORKFLOWS / "pr-gate.yml", WATCH,
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
