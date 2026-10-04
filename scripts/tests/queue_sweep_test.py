#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/queue-sweep.sh と、それを起こす queue-sweep.yml の検査 (#1265 / #1951)。

固定したいのは十一。

1. **ref が消えたグループの run は cancel する。** merge queue は捨てたグループの run を
   cancel しないので、放っておくと macOS の枠を使い続ける (#1265)
2. **ref が同名で作り直されていたら cancel する。** 名前だけ見ると、別のグループを
   今のグループと取り違える
3. **今のグループの run は cancel しない。** cancel されると PR が queue から外れ、
   人手で入れ直すことになる
4. **ref を読めなかったら cancel せず、非 0 で終える。** 判定できないものは生きている側に倒す
5. **--dry-run は cancel を打たない。** 手元で様子を見るために打っただけで run が止まると困る
6. **cancel の前に終わっていた run (409) では赤くしない。** 判定と cancel の間の競合で、
   捨てたかった run が既に居ないだけである
7. **まだ終わっていない run はどの status でも拾う。** queued だけを見ると、走り出した
   macOS ジョブ (in_progress) が止まらない — #1265 の 2 件目はそちらだった
8. **グループの ref の形をしていない run には触らない。** 読み違いを cancel に繋げない
9. **dequeued は pull_request_target で受ける。** pull_request で受けると、merge queue が
   外した PR の run は起動者が github-merge-queue[bot] になり、外部の人の承認の関門で
   止まって掃除が走らない (#1951)。関門はジョブより前にあるので、ワークフローの起動条件
   そのものを見る
10. **今のグループがある間、専用機でまだ拾われていない render-pr の run は cancel する。**
    門番 (render-turn.sh の yield) の判定は積む前の 1 回だけで、queue が空いている間に
    積まれた render-pr は、後からできた先頭の render と専用機を取り合う (#2064)。走っている
    render-pr と、render-pr の job がまだ無い run (門番の中) には触らない
11. **render.yml の今のグループの run が無ければ render-pr に触らない。jobs を読めなければ
    触らず、非 0 で終える。** 待たせる相手が居ないのに退かせても失うだけで (ci.yml だけが
    残る group では門番も render-pr を通す)、判定できないものは生きている側に倒す

gh は PATH の先頭に置いた偽物へ差し替える。偽物は **--jq を実際に適用する**ので、
検査は絞り込みそのものを踏む (stall_watch_test.py と同じ理由)。
実行は make ci-check (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SWEEP = REPO / "scripts" / "queue-sweep.sh"
WORKFLOW = REPO / ".github" / "workflows" / "queue-sweep.yml"

# 応答は $DATA の中の JSON から読む。ref の照会はブランチ名の / を _ にしたファイルへ振る
FAKE_GH = """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALLS"

filter=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then filter=$a; fi
  prev=$a
done

emit() { # $1=JSON ファイル
  [ -f "$1" ] || { echo '{"workflow_runs":[]}' | jq -r "$filter"; return 0; }
  if [ -n "$filter" ]; then jq -r "$filter" < "$1"; else cat "$1"; fi
}

# **展開は $all から取る。** ${*#…} は引数ごとに当たるので、1 本の文字列として切り出せない
all="$*"

case "$all" in
  *"/actions/runs?event=merge_group&status="*)
    status=${all#*status=}; status=${status%%&*}
    emit "$DATA/runs-$status.json"; exit 0 ;;
  *"/git/matching-refs/heads/"*)
    branch=${all#*/git/matching-refs/heads/}; branch=${branch%% *}
    [ -z "${REFS_FAIL:-}" ] || { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    file="$DATA/refs-${branch//\\//_}.json"
    if [ -f "$file" ]; then jq -r "$filter" < "$file"; else echo '[]' | jq -r "$filter"; fi
    exit 0 ;;
  *"/actions/workflows/render.yml/runs?event=pull_request&status="*)
    status=${all#*status=}; status=${status%%&*}
    emit "$DATA/pr-runs-$status.json"; exit 0 ;;
  *"/jobs?"*)
    id=${all%/jobs\?*}; id=${id##*/}
    [ -z "${JOBS_FAIL:-}" ] || { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    file="$DATA/jobs-$id.json"
    if [ -f "$file" ]; then jq -r "$filter" < "$file"; else echo '{"jobs":[]}' | jq -r "$filter"; fi
    exit 0 ;;
  *"/cancel"*)
    id=${all%/cancel*}; id=${id##*/}
    [ ! -f "$DATA/cancel-409-$id" ] || { echo "gh: Cannot cancel a workflow run that is completed. (HTTP 409)" >&2; exit 1; }
    exit 0 ;;
esac

echo "偽 gh が知らない呼び出し: $*" >&2
exit 1
"""

LIVE = "gh-readonly-queue/main/pr-1257-354c03f3f696172be44123d56c4cdfc90d536bb6"
GONE = "gh-readonly-queue/main/pr-1260-c3af40e4d7db9d77266c48b3d84a98f30f8e9daf"


class QueueSweepTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)

        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        gh = self.bin_dir / "gh"
        gh.write_text(FAKE_GH, encoding="utf-8")
        gh.chmod(0o755)

        self.data = root / "data"
        self.data.mkdir()
        self.calls = root / "gh-calls.txt"
        self.calls.write_text("", encoding="utf-8")

    def add_run(self, run_id, branch, sha, status="in_progress", workflow="ci.yml"):
        path = self.data / f"runs-{status}.json"
        payload = {"workflow_runs": []}
        if path.exists():
            payload = json.loads(path.read_text(encoding="utf-8"))
        payload["workflow_runs"].append(
            {
                "id": run_id,
                "head_branch": branch,
                "head_sha": sha,
                "path": f".github/workflows/{workflow}",
            }
        )
        path.write_text(json.dumps(payload), encoding="utf-8")

    def add_pr_run(self, run_id, branch, render_pr, status="in_progress"):
        """render.yml の pull_request の run と、その jobs を置く。render_pr=None は job が無い。"""
        path = self.data / f"pr-runs-{status}.json"
        payload = {"workflow_runs": []}
        if path.exists():
            payload = json.loads(path.read_text(encoding="utf-8"))
        payload["workflow_runs"].append({"id": run_id, "head_branch": branch})
        path.write_text(json.dumps(payload), encoding="utf-8")
        jobs = [{"name": "render-turn", "status": "completed"}]
        if render_pr is not None:
            jobs.append({"name": "render-pr", "status": render_pr})
        (self.data / f"jobs-{run_id}.json").write_text(
            json.dumps({"jobs": jobs}), encoding="utf-8"
        )

    def live_group(self):
        """render.yml の今のグループの run を置く (門番が見送りに使うのと同じ範囲)。"""
        self.add_run(100, LIVE, "tip", status="queued", workflow="render.yml")
        self.add_ref(LIVE, "tip")

    def add_ref(self, branch, sha):
        """ref を置く。matching-refs は前方一致なので、名前が伸びた別の ref も並べて返す。"""
        name = branch.replace("/", "_")
        refs = [
            {"ref": f"refs/heads/{branch}", "object": {"sha": sha}},
            {"ref": f"refs/heads/{branch}0", "object": {"sha": "other"}},
        ]
        (self.data / f"refs-{name}.json").write_text(json.dumps(refs), encoding="utf-8")

    def run_sweep(self, *args, **extra):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}:{env['PATH']}"
        env["GH_CALLS"] = str(self.calls)
        env["DATA"] = str(self.data)
        env.pop("GITHUB_REPOSITORY", None)
        env.update({k: str(v) for k, v in extra.items()})
        return subprocess.run(
            ["/bin/bash", str(SWEEP), *args],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )

    def cancels(self):
        return [
            line
            for line in self.calls.read_text(encoding="utf-8").splitlines()
            if "/cancel" in line
        ]

    def test_cancels_run_whose_group_ref_is_gone(self):
        self.add_run(101, GONE, "aaa")
        result = self.run_sweep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"101 cancel {GONE}", result.stdout)
        self.assertEqual(len(self.cancels()), 1)
        self.assertIn("actions/runs/101/cancel", self.cancels()[0])

    def test_cancels_run_whose_group_ref_was_rebuilt(self):
        self.add_run(102, LIVE, "old")
        self.add_ref(LIVE, "new")
        result = self.run_sweep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"102 cancel {LIVE}", result.stdout)
        self.assertEqual(len(self.cancels()), 1)

    def test_keeps_run_of_current_group(self):
        self.add_run(103, LIVE, "tip", status="queued")
        self.add_ref(LIVE, "tip")
        self.add_run(104, GONE, "aaa", status="queued")
        result = self.run_sweep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"103 keep {LIVE}", result.stdout)
        self.assertEqual(len(self.cancels()), 1)
        self.assertIn("actions/runs/104/cancel", self.cancels()[0])

    def test_reads_every_active_status(self):
        # queued だけでなく、走っている run も待っている run も拾う
        for i, status in enumerate(["queued", "in_progress", "waiting", "pending", "requested"]):
            self.add_run(200 + i, f"{GONE}{i}", "aaa", status=status)
        result = self.run_sweep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.cancels()), 5)

    def test_does_not_cancel_when_ref_cannot_be_read(self):
        self.add_run(105, LIVE, "tip")
        result = self.run_sweep(REFS_FAIL=1)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"105 unknown {LIVE}", result.stdout)
        self.assertEqual(self.cancels(), [])

    def test_does_not_cancel_run_without_group_ref_shape(self):
        self.add_run(106, "main", "tip")
        result = self.run_sweep()
        self.assertEqual(result.returncode, 1)
        self.assertIn("106 unknown main", result.stdout)
        self.assertEqual(self.cancels(), [])

    def test_dry_run_does_not_cancel(self):
        self.add_run(107, GONE, "aaa")
        result = self.run_sweep("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"107 cancel {GONE}", result.stdout)
        self.assertEqual(self.cancels(), [])

    def test_run_finished_before_cancel_is_not_a_failure(self):
        self.add_run(108, GONE, "aaa")
        (self.data / "cancel-409-108").write_text("", encoding="utf-8")
        result = self.run_sweep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"108 done {GONE}", result.stdout)

    def test_no_active_runs_does_nothing(self):
        result = self.run_sweep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.cancels(), [])

    def test_cancels_render_pr_still_queued_on_the_runner(self):
        # 2026-10-04 の形: queue が空いている間に門番を通った render-pr が専用機で待っている
        self.live_group()
        self.add_pr_run(301, "test/parallelization-width-guard", "queued")
        self.add_pr_run(302, "chore/compact", "queued", status="queued")
        result = self.run_sweep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("301 cancel test/parallelization-width-guard", result.stdout)
        self.assertIn("302 cancel chore/compact", result.stdout)
        self.assertEqual(
            sorted(c.split("/")[-2] for c in self.cancels()), ["301", "302"]
        )

    def test_cancels_render_pr_waiting_in_any_unstarted_state(self):
        # concurrency で待つ job は pending になる。拾われていなければどれも退かせる
        self.live_group()
        for i, state in enumerate(["pending", "waiting", "requested"]):
            self.add_pr_run(310 + i, f"b{i}", state)
        result = self.run_sweep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.cancels()), 3)

    def test_keeps_render_pr_already_running(self):
        self.live_group()
        self.add_pr_run(303, "feat/running", "in_progress")
        result = self.run_sweep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("303 keep feat/running", result.stdout)
        self.assertEqual(self.cancels(), [])

    def test_leaves_run_without_render_pr_job_to_the_gate(self):
        # 門番 (render-turn) の中の run は、門番が merge_group の run を見て見送る
        self.live_group()
        self.add_pr_run(304, "fix/at-gate", None)
        self.add_pr_run(305, "fix/finished", "completed")
        result = self.run_sweep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("304", result.stdout)
        self.assertNotIn("305", result.stdout)
        self.assertEqual(self.cancels(), [])

    def test_leaves_render_pr_alone_without_a_live_group(self):
        # 後ろにグループが居ない PR が外れた dequeued: 待たせる相手が居ない
        self.add_run(106, GONE, "aaa")
        self.add_pr_run(306, "feat/queued", "queued")
        result = self.run_sweep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("306", result.stdout)
        self.assertEqual(len(self.cancels()), 1)
        self.assertIn("actions/runs/106/cancel", self.cancels()[0])

    def test_leaves_render_pr_alone_when_only_ci_runs_of_the_group_remain(self):
        # group の render は終わり、ci.yml だけが走っている間は、門番も render-pr を通す
        self.add_run(110, LIVE, "tip", workflow="ci.yml")
        self.add_ref(LIVE, "tip")
        self.add_pr_run(311, "feat/queued", "queued")
        result = self.run_sweep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"110 keep {LIVE}", result.stdout)
        self.assertNotIn("311", result.stdout)
        self.assertEqual(self.cancels(), [])

    def test_does_not_cancel_render_pr_when_jobs_cannot_be_read(self):
        self.live_group()
        self.add_pr_run(307, "feat/unreadable", "queued")
        result = self.run_sweep(JOBS_FAIL=1)
        self.assertEqual(result.returncode, 1)
        self.assertIn("307 unknown feat/unreadable", result.stdout)
        self.assertEqual(self.cancels(), [])

    def test_dry_run_does_not_cancel_render_pr(self):
        self.live_group()
        self.add_pr_run(308, "feat/queued", "queued")
        result = self.run_sweep("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("308 cancel feat/queued", result.stdout)
        self.assertEqual(self.cancels(), [])

    def test_render_pr_finished_before_cancel_is_not_a_failure(self):
        self.live_group()
        self.add_pr_run(309, "feat/queued", "queued")
        (self.data / "cancel-409-309").write_text("", encoding="utf-8")
        result = self.run_sweep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("309 done feat/queued", result.stdout)

    def test_rejects_unknown_argument(self):
        result = self.run_sweep("--apply")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.cancels(), [])



class QueueSweepTriggerTest(unittest.TestCase):
    """起動条件の検査 (9.)。YAML は読まず、トップレベルの on: の行だけを見る。"""

    def triggers(self):
        lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
        start = lines.index("on:") + 1
        block = []
        for line in lines[start:]:
            if line and not line.startswith(" "):
                break
            block.append(line)
        return block

    def test_dequeued_is_received_by_pull_request_target(self):
        block = self.triggers()
        self.assertIn("  pull_request_target:", block)
        at = block.index("  pull_request_target:")
        self.assertEqual(block[at + 1].strip(), "types: [dequeued]")

    def test_does_not_receive_pull_request(self):
        self.assertNotIn("  pull_request:", self.triggers())


if __name__ == "__main__":
    unittest.main()
