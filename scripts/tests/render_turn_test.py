#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/render-turn.sh (専用機へ積む順番の門番) の検査 (#2062)。

固定したいのは九つ。

1. **先頭の group は前の group を待たない。** base sha が main の先端なら、前の group の run が
   (人の rerun で) 走っていても数えない (render-pr が取る枠は 9 のとおり先頭も数える)
2. **1 つ前の group の run が終わるまで待つ。** 待つ相手は自分の base sha を head に持つ
   render.yml の merge_group の run で、門番で待っている間の run も数える。上限 (期限の
   直前) までは放さない — 早く放すと後ろの group がそろって積まれ、前の group と取り合う
3. **先頭でないのに前の run が無ければ、作られるまで猶予だけ待つ。** 組み直しの直後は、前の
   group の run がまだ作られていない。先頭と取り違えると、組み直しの場面で順番が崩れる
4. **API が続けて読めなければ通す (go=true・終了 0)。1 回の失敗では通さない。** 門番の
   失敗で検査が走らないほうが重いが、一過性の 502 で門を開けると元の症状に戻る
5. **yield は merge_group の run を status によらず数える。** queued でも in_progress でも 1 本と
   数え (門番で待っている group の run は in_progress)、N=1 なら 1 本でも残っていれば go=false
6. **wait は merge_group の run が無くなるまで待ってから通す**
7. **使い方の誤りだけ非 0 (2)**
8. **merge_group は RENDER_TURN_SLOTS (N) 本まで並走する** (#3319)。前の group を base sha の
   親を辿って N 段まで遡り、終わっていない run を持つ group が N 本未満なら通す。base ref の
   先端に着いたら遡らない。未設定なら 1 で、親を引かない (今までと同じ呼び出し)
9. **専用機の枠を run ごとに数える** (#4018)。merge_group は group と render-pr が取る枠の合計が
   N 本未満なら通す (先頭も数える・定期の job は数えない)。yield は merge_group の run が無ければ
   通し、あれば render-pr と定期の job も数えて N 本未満のときだけ通す (N=1 は今までと同じ結論)。
   門番が通してから専用機の job が一覧に出るまでの run と、この門番より前に走り出した門番の中の
   pull_request の run は数える側に倒す。yield は同じ PR の run を数えない。一覧はページを送って読み、
   門番は足りない枠が埋まった所で数えるのをやめる。job は queued と in_progress だけを走っていると読み、待っている job が並んでも run 1 本で
   1 枠。yield は枠を読めなければ引き直さずに見送る。slots の mode は同じ数え方を queue-sweep.sh へ
   1 本 1 行で出す (数え方を 1 か所に置く)

render.yml の run の一覧 (runs?status=) には、実物と同じく merge_group の run も載せる。数える側が
event で絞っていなければ、group を 2 度数えて赤になる。

gh は PATH の先頭に置いた偽物へ差し替える。偽物は **--jq を実際に適用する**ので、
検査は絞り込みそのものを踏む (queue_sweep_test.py と同じ理由)。応答は呼ばれた回数で
切り替え、待つ側の「何回目で相手が終わったか」を表す。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TURN = REPO / "scripts" / "render-turn.sh"

# 応答は $DATA/<種類>-<回>.json。<回> はその種類が呼ばれた回数で、ファイルが無い回は
# それより前の最後の応答を繰り返す。1 つも無ければ空の一覧を返す
FAKE_GH = """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALLS"
[ -z "${GH_FAIL:-}" ] || { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
if [ -n "${GH_FAIL_ONCE:-}" ] && [ ! -f "$DATA/failed-once" ]; then
  touch "$DATA/failed-once"; echo "gh: Server Error (HTTP 502)" >&2; exit 1
fi

filter=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then filter=$a; fi
  prev=$a
done

all="$*"
case "$all" in
  *"/actions/workflows/render.yml/runs?event=merge_group&head_sha="*)
    # prev-<sha>-<回>.json があればその sha 専用の応答 (並走の検査)、無ければ prev
    sha=${all#*head_sha=}; sha=${sha%%&*}
    if compgen -G "$DATA/prev-$sha-*.json" > /dev/null; then kind=prev-$sha; else kind=prev; fi ;;
  *"/commits/"*) sha=${all#*/commits/}; sha=${sha%% *}; kind=commit-$sha ;;
  *"/actions/workflows/render.yml/runs?event=merge_group&status="*)
    kind=${all#*status=}; kind=${kind%%&*} ;;
  *"/actions/workflows/render.yml/runs?status="*)
    kind=${all#*status=}; kind=all-${kind%%&*} ;;
  *"/actions/runs/"*"/jobs"*) id=${all#*/actions/runs/}; id=${id%%/*}; kind=jobs-$id ;;
  *"/git/matching-refs/heads/main"*) kind=tip ;;
  *"/git/matching-refs/heads/"*) kind=head ;;
  *) echo "偽 gh が知らない呼び出し: $*" >&2; exit 1 ;;
esac

if [ -n "${GH_FAIL_JOBS:-}" ] && [ "${kind#jobs-}" != "$kind" ]; then
  echo "gh: Server Error (HTTP 502)" >&2; exit 1
fi

counter="$DATA/count-$kind"
n=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$counter"

file=""
for ((i = n; i >= 1; i--)); do
  if [ -f "$DATA/$kind-$i.json" ]; then file="$DATA/$kind-$i.json"; break; fi
done
if [ -n "$file" ]; then
  jq -r "${filter:-.}" < "$file"
  # --paginate のときだけ次のページ (<kind>-<回>.page2.json) も読む
  case " $all " in *" --paginate "*) [ ! -f "${file%.json}.page2.json" ] || jq -r "${filter:-.}" < "${file%.json}.page2.json" ;; esac
elif [ "$kind" = tip ] || [ "$kind" = head ]; then echo '[]' | jq -r "${filter:-.}"
elif [ "${kind#jobs-}" != "$kind" ]; then echo '{"jobs":[]}' | jq -r "$filter"
else echo '{"workflow_runs":[]}' | jq -r "$filter"; fi
"""

BASE = "354c03f3f696172be44123d56c4cdfc90d536bb6"
# 並走の検査の queue: main の先端 TIP ← G1 (head は G1_HEAD) ← G2 (head は BASE) ← 自分。
# 自分の base は G2 の head で、その親が G1 の head
G1_HEAD = "1" * 40
TIP = "0" * 40
G1 = "gh-readonly-queue/main/pr-1250-" + TIP
PREV = "gh-readonly-queue/main/pr-1257-c3af40e4d7db9d77266c48b3d84a98f30f8e9daf"
OTHER = "gh-readonly-queue/main/pr-1260-0a1b2c3d4e5f60718293a4b5c6d7e8f901234567"


def run_of(run_id, branch, status, conclusion=None):
    return {"id": run_id, "head_branch": branch, "status": status, "conclusion": conclusion}


class RenderTurnTest(unittest.TestCase):
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
        self.output = root / "output.txt"
        self.summary = root / "summary.md"
        # render.yml の run の一覧 (runs?status=) に出す run。実物の一覧はどの event の run も返すので、
        # merge_group の run も載せる (枠を数える側が event で絞っているかを検査が踏む)
        self.group_listed = {"queued": [], "in_progress": []}
        self.listed = {1: {"queued": [], "in_progress": []}}
        # 既定では自分は先頭ではない (main の先端は別の commit)
        self.main_tip("e" * 40)

    def main_tip(self, sha):
        refs = [
            {"ref": "refs/heads/main", "object": {"sha": sha}},
            {"ref": "refs/heads/main-old", "object": {"sha": "other"}},
        ]
        (self.data / "tip-1.json").write_text(json.dumps(refs), encoding="utf-8")

    def answer(self, kind, round_no, runs):
        """<kind> の <round_no> 回目以降の応答を置く。"""
        (self.data / f"{kind}-{round_no}.json").write_text(
            json.dumps({"workflow_runs": runs}), encoding="utf-8"
        )

    def answer_for(self, sha, round_no, runs):
        """head_sha=<sha> の run の <round_no> 回目以降の応答を置く。"""
        (self.data / f"prev-{sha}-{round_no}.json").write_text(
            json.dumps({"workflow_runs": runs}), encoding="utf-8"
        )

    def parent(self, sha, parent_sha):
        (self.data / f"commit-{sha}-1.json").write_text(
            json.dumps({"sha": sha, "parents": [{"sha": parent_sha}]}), encoding="utf-8"
        )

    def turn(self, *args, **extra):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}:{env['PATH']}"
        env["GH_CALLS"] = str(self.calls)
        env["DATA"] = str(self.data)
        env["GITHUB_OUTPUT"] = str(self.output)
        env["GITHUB_STEP_SUMMARY"] = str(self.summary)
        env["RENDER_TURN_INTERVAL"] = "0"
        env.pop("GITHUB_REPOSITORY", None)
        env.pop("RENDER_TURN_LIMIT", None)
        env.pop("GH_FAIL", None)
        env.pop("RENDER_TURN_SLOTS", None)
        env.pop("RENDER_TURN_HEAD_SHA", None)
        env.pop("RENDER_TURN_HEAD_REF", None)
        env.pop("GITHUB_RUN_ID", None)
        env.update({k: str(v) for k, v in extra.items()})
        return subprocess.run(
            ["/bin/bash", str(TURN), *args],
            capture_output=True,
            text=True,
            env=env,
            check=False,
            timeout=30,
        )

    def go(self):
        lines = [ln for ln in self.output.read_text(encoding="utf-8").splitlines() if ln.startswith("go=")]
        self.assertEqual(len(lines), 1, lines)
        return lines[0].removeprefix("go=")

    def calls_of(self, needle):
        return [ln for ln in self.calls.read_text(encoding="utf-8").splitlines() if needle in ln]

    # --- merge_group ---------------------------------------------------------

    def test_先頭の_group_は待たない(self):
        self.main_tip(BASE)
        r = self.turn("merge_group", BASE)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "true")
        self.assertEqual(len(self.calls_of("head_sha=")), 0)

    def test_先頭は前の_group_の_run_が走り直していても待たない(self):
        """merge 済みの前の group の run を人が rerun している最中でも、先頭は先頭。"""
        self.main_tip(BASE)
        self.answer("prev", 1, [run_of(11, PREV, "in_progress")])
        r = self.turn("merge_group", BASE)
        self.assertEqual(self.go(), "true", r.stdout)
        self.assertNotIn("待っている相手", r.stdout)

    def test_前の_group_の_run_を自分の_base_sha_で引く(self):
        self.answer("prev", 1, [run_of(11, PREV, "completed", "success")])
        self.turn("merge_group", BASE)
        (call,) = self.calls_of("head_sha=")
        self.assertIn("/actions/workflows/render.yml/runs?", call)
        self.assertIn("event=merge_group", call)
        self.assertIn(f"head_sha={BASE}", call)

    def test_前の_group_の_run_が終わるまで待つ(self):
        # 門番で待っている (in_progress) → render が queued → 終わった
        self.answer("prev", 1, [run_of(11, PREV, "in_progress")])
        self.answer("prev", 2, [run_of(11, PREV, "queued")])
        self.answer("prev", 3, [run_of(11, PREV, "completed", "success")])
        r = self.turn("merge_group", BASE)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "true")
        self.assertEqual(len(self.calls_of("head_sha=")), 3)
        self.assertIn("待っている相手: 11 " + PREV, r.stdout)

    def test_前の_group_が_cancel_されていれば待たない(self):
        self.answer("prev", 1, [run_of(11, PREV, "completed", "cancelled")])
        r = self.turn("merge_group", BASE)
        self.assertEqual(self.go(), "true")
        self.assertEqual(len(self.calls_of("head_sha=")), 1, r.stdout)

    def test_上限を越えたら自分で終わって通す(self):
        """門番の timeout (GitHub の cancel) に任せず、自分で go=true で終わる。"""
        self.answer("prev", 1, [run_of(11, PREV, "in_progress")])
        r = self.turn("merge_group", BASE, RENDER_TURN_LIMIT=0)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "true")
        self.assertIn("::warning::", r.stdout)
        self.assertIn(PREV, self.summary.read_text(encoding="utf-8"))

    def test_merge_group_の上限は期限の直前の_90_分(self):
        text = TURN.read_text(encoding="utf-8")
        self.assertIn("mode=merge_group base=$2 base_ref=${3:-refs/heads/main} limit_default=90", text)

    def test_先頭でないのに前の_run_が無ければ作られるまで待つ(self):
        self.answer("prev", 2, [run_of(11, PREV, "in_progress")])
        self.answer("prev", 3, [run_of(11, PREV, "completed", "success")])
        r = self.turn("merge_group", BASE)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "true")
        self.assertEqual(len(self.calls_of("head_sha=")), 3, r.stdout)
        self.assertIn("まだ作られていない", r.stdout)

    def test_前の_run_が猶予を越えても作られなければ通す(self):
        r = self.turn("merge_group", BASE, RENDER_TURN_MISSING_GRACE=0)
        self.assertEqual(self.go(), "true")
        self.assertEqual(len(self.calls_of("head_sha=")), 1, r.stdout)

    def test_base_ref_を名指しすればその先端と比べる(self):
        self.main_tip(BASE)
        r = self.turn("merge_group", BASE, "refs/heads/main")
        self.assertEqual(self.go(), "true", r.stdout)
        self.assertEqual(len(self.calls_of("matching-refs/heads/main")), 1)

    def test_API_が続けて読めなければ通す(self):
        r = self.turn("merge_group", BASE, GH_FAIL=1)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "true")
        self.assertIn("::warning::", r.stdout)
        # 3 回引き直してから通す
        self.assertEqual(len(self.calls_of("matching-refs")), 3)

    def test_1_回の失敗では通さず引き直す(self):
        self.answer("prev", 1, [run_of(11, PREV, "in_progress")])
        self.answer("prev", 2, [run_of(11, PREV, "completed", "success")])
        r = self.turn("merge_group", BASE, GH_FAIL_ONCE=1)
        self.assertEqual(self.go(), "true")
        self.assertNotIn("::warning::", r.stdout)
        self.assertIn("引き直す", r.stdout)
        self.assertEqual(len(self.calls_of("head_sha=")), 2, r.stdout)

    # --- 並走 (RENDER_TURN_SLOTS) ----------------------------------------------

    def test_既定の_1_では親を引かない(self):
        self.answer("prev", 1, [run_of(11, PREV, "completed", "success")])
        self.turn("merge_group", BASE)
        self.assertEqual(self.calls_of("/commits/"), [])

    def test_空の値は_1_として扱う(self):
        self.answer("prev", 1, [run_of(11, PREV, "in_progress")])
        r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS="", RENDER_TURN_LIMIT=0)
        self.assertIn("待っていた相手", self.summary.read_text(encoding="utf-8"), r.stdout)

    def queue_of_two(self):
        self.main_tip(TIP)
        self.parent(BASE, G1_HEAD)

    def list_group(self, run_id, branch, status):
        """merge_group の run を render.yml の run の一覧 (runs?status=) にも載せ、専用機の render が
        走っている jobs を置く。終わった run は一覧に出ない。"""
        if status == "completed":
            return
        run = run_of(run_id, branch, status)
        run["event"] = "merge_group"
        self.group_listed[status].append(run)
        (self.data / f"jobs-{run_id}-1.json").write_text(
            json.dumps({"jobs": [
                {"name": "render-turn", "status": "completed", "labels": self.HOSTED},
                {"name": "render", "status": "in_progress", "labels": self.RUNNER},
            ]}),
            encoding="utf-8",
        )
        self.write_listing()

    def write_listing(self):
        for round_no, by_status in self.listed.items():
            for status in ("queued", "in_progress"):
                self.answer(f"all-{status}", round_no, self.group_listed[status] + by_status[status])

    def test_2_本なら前の_group_が走っていても通る(self):
        self.queue_of_two()
        self.answer_for(BASE, 1, [run_of(12, PREV, "in_progress")])
        self.answer_for(G1_HEAD, 1, [run_of(11, G1, "completed", "success")])
        r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=2)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "true")
        self.assertEqual(len(self.calls_of(f"head_sha={BASE}")), 1, r.stdout)
        self.assertIn("2 本未満", self.summary.read_text(encoding="utf-8"))

    def test_2_本とも走っていれば先の_group_が終わるまで待つ(self):
        self.queue_of_two()
        self.answer_for(BASE, 1, [run_of(12, PREV, "in_progress")])
        self.answer_for(G1_HEAD, 1, [run_of(11, G1, "in_progress")])
        self.answer_for(G1_HEAD, 3, [run_of(11, G1, "completed", "success")])
        r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=2)
        self.assertEqual(self.go(), "true")
        # G2 (BASE) は走ったままでも、G1 が終わった 3 周目で通る
        self.assertEqual(len(self.calls_of(f"head_sha={G1_HEAD}")), 3, r.stdout)
        self.assertIn(f"待っている相手: 11 {G1} 12 {PREV}", r.stdout)

    def test_2_本とも走ったまま上限を越えたら通す(self):
        self.queue_of_two()
        self.answer_for(BASE, 1, [run_of(12, PREV, "in_progress")])
        self.answer_for(G1_HEAD, 1, [run_of(11, G1, "in_progress")])
        r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=2, RENDER_TURN_LIMIT=0)
        self.assertEqual(self.go(), "true")
        self.assertIn("::warning::", r.stdout)

    def test_先端に着いたらそれより前は遡らない(self):
        """自分の base の親が main の先端なら、前の group は 1 本だけ。"""
        self.main_tip(G1_HEAD)
        self.parent(BASE, G1_HEAD)
        self.answer_for(BASE, 1, [run_of(12, PREV, "in_progress")])
        self.answer_for(G1_HEAD, 1, [run_of(11, G1, "in_progress")])
        r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=2)
        self.assertEqual(self.go(), "true", r.stdout)
        self.assertEqual(self.calls_of(f"head_sha={G1_HEAD}"), [])

    def test_3_本目の_group_は_N_段より前を数えない(self):
        """N=1 なら、さらに前の group が走っていても 1 つ前が終わっていれば通る。"""
        self.queue_of_two()
        self.answer_for(BASE, 1, [run_of(12, PREV, "completed", "success")])
        self.answer_for(G1_HEAD, 1, [run_of(11, G1, "in_progress")])
        r = self.turn("merge_group", BASE)
        self.assertEqual(self.go(), "true", r.stdout)
        self.assertEqual(self.calls_of(f"head_sha={G1_HEAD}"), [])

    def test_並走の数が整数でなければ_2_で終わる(self):
        for bad in ["0", "abc", "-1", "2x", "01"]:
            r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=bad)
            self.assertEqual(r.returncode, 2, bad)
            self.assertIn("RENDER_TURN_SLOTS", r.stderr)
        self.assertFalse(self.output.exists())

    def test_render_yml_は変数を門番へ渡す(self):
        wf = (REPO / ".github" / "workflows" / "render.yml").read_text(encoding="utf-8")
        self.assertIn("RENDER_TURN_SLOTS: ${{ vars.RENDER_TURN_SLOTS }}", wf)

    # --- yield ---------------------------------------------------------------

    def test_yield_は_queued_の_run_があれば見送る(self):
        self.answer("queued", 1, [run_of(21, OTHER, "queued")])
        r = self.turn("yield")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "false")
        self.assertIn("見送った", self.summary.read_text(encoding="utf-8"))

    def test_yield_は門番で待っている_run_でも見送る(self):
        self.answer("in_progress", 1, [run_of(22, OTHER, "in_progress")])
        r = self.turn("yield")
        self.assertEqual(self.go(), "false", r.stdout)

    def test_yield_は_run_が無ければ通す(self):
        r = self.turn("yield")
        self.assertEqual(self.go(), "true", r.stdout)
        # 待たない: どの status も 1 回ずつしか引かない
        self.assertEqual(len(self.calls_of("status=queued")), 1)

    def test_yield_は_API_が読めなければ通す(self):
        r = self.turn("yield", GH_FAIL=1)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "true")

    # --- 古い head (#3551) ------------------------------------------------------
    # render-pr の concurrency は「後から群に入った job が残る」ので、旧 head の門番が遅れて新 head の
    # job より後に群へ入ると、走っている新 head の job を取り消す。比べる場所は門番の出口

    OLD_HEAD = "a" * 40
    NEW_HEAD = "b" * 40

    def branch_tip(self, sha, ref="refs/heads/fix/x"):
        """matching-refs は前方一致で返すので、名前の似た別の branch も混ぜる。"""
        refs = [
            {"ref": ref + "-old", "object": {"sha": "c" * 40}},
            {"ref": ref, "object": {"sha": sha}},
        ]
        (self.data / "head-1.json").write_text(json.dumps(refs), encoding="utf-8")

    def test_yield_は_head_が_branch_の先端と違えば見送る(self):
        self.branch_tip(self.NEW_HEAD)
        r = self.turn("yield", RENDER_TURN_HEAD_SHA=self.OLD_HEAD, RENDER_TURN_HEAD_REF="fix/x")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "false", r.stdout)
        text = self.summary.read_text(encoding="utf-8")
        self.assertIn("aaaaaaaa", text)
        self.assertIn("bbbbbbbb", text)
        self.assertIn("#3551", text)

    def test_yield_は_head_が_branch_の先端のままなら通す(self):
        self.branch_tip(self.OLD_HEAD)
        r = self.turn("yield", RENDER_TURN_HEAD_SHA=self.OLD_HEAD, RENDER_TURN_HEAD_REF="fix/x")
        self.assertEqual(self.go(), "true", r.stdout)
        self.assertEqual(len(self.calls_of("matching-refs/heads/fix/x")), 1)

    def test_yield_は名前の似た別の_branch_の先端と取り違えない(self):
        """前方一致で返る `fix/x-old` の先端が違っても、`fix/x` 自身が同じなら通す。"""
        self.branch_tip(self.OLD_HEAD)
        r = self.turn("yield", RENDER_TURN_HEAD_SHA=self.OLD_HEAD, RENDER_TURN_HEAD_REF="fix/x")
        self.assertEqual(self.go(), "true", r.stdout)

    def test_yield_は_branch_が無ければ通す(self):
        """merge して消えた branch。先端が無いことは古いことの証拠にならない。"""
        r = self.turn("yield", RENDER_TURN_HEAD_SHA=self.OLD_HEAD, RENDER_TURN_HEAD_REF="fix/x")
        self.assertEqual(self.go(), "true", r.stdout)

    def test_yield_は先端を読めなければ通す(self):
        r = self.turn(
            "yield", GH_FAIL=1, RENDER_TURN_HEAD_SHA=self.OLD_HEAD, RENDER_TURN_HEAD_REF="fix/x")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "true")
        self.assertIn("head が古いかは見ずに通す", r.stdout)

    def test_yield_は環境変数が無ければ先端を引かない(self):
        self.branch_tip(self.NEW_HEAD)
        r = self.turn("yield")
        self.assertEqual(self.go(), "true", r.stdout)
        self.assertEqual(self.calls_of("matching-refs"), [])

    def test_yield_は_merge_queue_が忙しければ先端を引くまでもなく見送る(self):
        self.answer("queued", 1, [run_of(21, OTHER, "queued")])
        self.branch_tip(self.OLD_HEAD)
        r = self.turn("yield", RENDER_TURN_HEAD_SHA=self.OLD_HEAD, RENDER_TURN_HEAD_REF="fix/x")
        self.assertEqual(self.go(), "false", r.stdout)
        self.assertEqual(self.calls_of("matching-refs/heads/fix"), [])

    def test_wait_と_merge_group_は_head_を比べない(self):
        self.branch_tip(self.NEW_HEAD)
        env = {"RENDER_TURN_HEAD_SHA": self.OLD_HEAD, "RENDER_TURN_HEAD_REF": "fix/x"}
        self.turn("wait", **env)
        self.assertEqual(self.go(), "true")
        self.output.unlink()
        self.main_tip(BASE)
        self.turn("merge_group", BASE, **env)
        self.assertEqual(self.go(), "true")
        self.assertEqual(self.calls_of("matching-refs/heads/fix"), [])

    def test_render_yml_は_head_を門番へ渡し権限を広げない(self):
        text = (REPO / ".github" / "workflows" / "render.yml").read_text(encoding="utf-8")
        job = text.split("\n  render-turn:\n", 1)[1].split("\n  render:\n", 1)[0]
        self.assertIn("RENDER_TURN_HEAD_SHA: ${{ github.event.pull_request.head.sha }}", job)
        self.assertIn("RENDER_TURN_HEAD_REF: ${{ github.event.pull_request.head.ref }}", job)
        # 先端は contents: read で引く。権限は actions: read のまま
        self.assertIn("actions: read", job)
        self.assertNotIn(": write", job)
        self.assertNotIn("pull-requests", job)

    # --- wait ----------------------------------------------------------------

    def test_wait_は_run_が無くなるまで待ってから通す(self):
        self.answer("in_progress", 1, [run_of(22, OTHER, "in_progress")])
        self.answer("in_progress", 3, [])
        r = self.turn("wait")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "true")
        self.assertEqual(len(self.calls_of("status=in_progress")), 3)

    def test_wait_も上限を越えたら通す(self):
        self.answer("queued", 1, [run_of(21, OTHER, "queued")])
        r = self.turn("wait", RENDER_TURN_LIMIT=0)
        self.assertEqual(self.go(), "true")
        self.assertIn("::warning::", r.stdout)

    # --- 専用機の枠を数える (#4018) --------------------------------------------

    RUNNER = ["self-hosted", "mokume-render"]
    HOSTED = ["ubuntu-latest"]
    # 門番が走り出した時刻 (jobs API の started_at)。検査の門番の起動より前と後
    EARLIER = "2000-01-01T00:00:00Z"
    LATER = "2999-01-01T00:00:00Z"

    def runner_runs(self, *runs, round_no=1):
        """終わっていない render.yml の run (merge_group 以外) と、その jobs を置く。

        runs は (run id, event, 形) の並び。形は:
          "gate"  門番 (ホスト) がこの門番より前から走っていて、専用機の job はまだ走っていない
          "late-gate" 門番がこの門番より後に走り出した (started_at が未来)
          "queued-gate" 門番がホストの runner を待って queued
          "gap"   門番は終わったが、専用機の job がまだ一覧に無い (yield が通した直後の数秒)
          "hosted" 専用機の job は終わり、ホストの後続 (起票など) が走っている
          "completed" run ごと終わった (一覧に出ない)
          list    jobs の一覧そのもの ((名前, status, 専用機か) の並び)
          それ以外 専用機の job の status (render-pr か scheduled-debug)
        run の status は、専用機の job が queued なら queued、ほかは in_progress に置く。
        """
        by_status = {"queued": [], "in_progress": []}
        for run_id, event, shape in runs:
            if shape == "completed":
                continue
            run_status = "queued" if shape == "queued" else "in_progress"
            run = run_of(run_id, f"fix/pr-{run_id}" if event == "pull_request" else "main", run_status)
            run["event"] = event
            by_status[run_status].append(run)
            turn = "render-turn" if event == "pull_request" else "scheduled-release-turn"
            job = "render-pr" if event == "pull_request" else "scheduled-debug"
            # 門番の後の run には、実物と同じく if で外れた専用機の job が skipped (completed) で並ぶ
            # (どの専用機の job も門番を needs に持つので、門番の中には現れない)
            skipped = [
                {"name": n, "status": "completed", "conclusion": "skipped", "labels": self.RUNNER}
                for n in (("render", "scheduled-debug") if event == "pull_request" else ("render", "render-pr"))
            ]
            if isinstance(shape, list):
                listed = [
                    {"name": n, "status": s, "labels": self.RUNNER if on_runner else self.HOSTED,
                     "started_at": self.EARLIER}
                    for n, s, on_runner in shape
                ]
            elif shape in ("gate", "late-gate", "queued-gate"):
                listed = [{
                    "name": turn,
                    "status": "queued" if shape == "queued-gate" else "in_progress",
                    "started_at": self.LATER if shape == "late-gate" else self.EARLIER,
                    "labels": self.HOSTED,
                }]
            elif shape == "gap":
                listed = [{"name": turn, "status": "completed", "labels": self.HOSTED}, *skipped]
            elif shape == "hosted":
                listed = [
                    {"name": job, "status": "completed", "labels": self.RUNNER},
                    *skipped,
                    {"name": "scheduled-report", "status": "in_progress", "labels": self.HOSTED},
                ]
            else:
                listed = [
                    {"name": turn, "status": "completed", "labels": self.HOSTED},
                    *skipped,
                    {"name": job, "status": shape, "labels": self.RUNNER},
                ]
            (self.data / f"jobs-{run_id}-{round_no}.json").write_text(
                json.dumps({"jobs": listed}), encoding="utf-8"
            )
        self.listed[round_no] = by_status
        self.write_listing()

    def render_prs(self, *jobs, round_no=1):
        """pull_request の run。jobs は (run id, 形) の並び (形は runner_runs と同じ)。"""
        self.runner_runs(*[(i, "pull_request", s) for i, s in jobs], round_no=round_no)

    def groups_running(self, count):
        """merge_group の run が count 本終わっていない (yield / wait が引く一覧)。"""
        runs = [run_of(30 + i, f"{OTHER}-{i}", "in_progress") for i in range(count)]
        self.answer("in_progress", 1, runs)
        for run in runs:
            self.list_group(run["id"], run["head_branch"], run["status"])

    def test_yield_は_N_と_group_と_render_pr_の組で結論を出す(self):
        """N=1 は今までと同じ (group が 1 本でもあれば見送る・無ければ通す)。"""
        expected = {
            # (N, group, render-pr): go
            (1, 0, 0): "true", (1, 0, 1): "true",
            (1, 1, 0): "false", (1, 1, 1): "false",
            (1, 2, 0): "false", (1, 2, 1): "false",
            (2, 0, 0): "true", (2, 0, 1): "true",
            (2, 1, 0): "true", (2, 1, 1): "false",
            (2, 2, 0): "false", (2, 2, 1): "false",
        }
        for (slots, groups, prs), go in expected.items():
            with self.subTest(N=slots, group=groups, render_pr=prs):
                self.setUp()
                self.groups_running(groups)
                if prs:
                    self.render_prs((51, "in_progress"))
                r = self.turn("yield", RENDER_TURN_SLOTS=slots)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(self.go(), go, r.stdout)

    def test_yield_は定期の_job_も枠に数える(self):
        """N=2・group 1 本・定期の job 1 本: render-pr を通すと専用機に 3 本積まれる。"""
        for shape in ("in_progress", "queued", "gap"):
            with self.subTest(shape=shape):
                self.setUp()
                self.groups_running(1)
                self.runner_runs((61, "schedule", shape))
                r = self.turn("yield", RENDER_TURN_SLOTS=2)
                self.assertEqual(self.go(), "false", r.stdout)
                self.assertIn("61 main (", self.summary.read_text(encoding="utf-8"))

    def test_yield_は門番で待つ定期の_run_と後続だけの_run_を数えない(self):
        """定期の門番 (ホスト) の中・専用機の job が終わって起票だけが走る run は、枠を取っていない。"""
        self.groups_running(1)
        self.runner_runs((61, "schedule", "gate"), (62, "schedule", "hosted"))
        r = self.turn("yield", RENDER_TURN_SLOTS=2)
        self.assertEqual(self.go(), "true", r.stdout)

    def merge_group_queue(self, groups):
        """自分の前に group が並ぶ queue。groups 本の前の group の run が終わっていない。"""
        self.queue_of_two()
        status_12 = "in_progress" if groups >= 1 else "completed"
        status_11 = "in_progress" if groups >= 2 else "completed"
        self.answer_for(BASE, 1, [run_of(12, PREV, status_12)])
        self.answer_for(G1_HEAD, 1, [run_of(11, G1, status_11)])
        self.list_group(12, PREV, status_12)
        self.list_group(11, G1, status_11)

    def test_merge_group_は_N_と_group_と_render_pr_の組で待つかを決める(self):
        """待つ組は上限 0 で通し、警告 (待っていた相手) が出たかで読む。
        N=1 では先頭の group も走っている render-pr を待つ (以前は待たずに専用機の queue で待った)。"""
        expected = {
            # (N, group, render-pr): 待つか
            (1, 0, 0): False, (1, 0, 1): True,
            (1, 1, 0): True, (1, 1, 1): True,
            (1, 2, 0): True, (1, 2, 1): True,
            (2, 0, 0): False, (2, 0, 1): False,
            (2, 1, 0): False, (2, 1, 1): True,
            (2, 2, 0): True, (2, 2, 1): True,
        }
        for (slots, groups, prs), waits in expected.items():
            with self.subTest(N=slots, group=groups, render_pr=prs):
                self.setUp()
                self.merge_group_queue(groups)
                if prs:
                    self.render_prs((51, "in_progress"))
                r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=slots, RENDER_TURN_LIMIT=0)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(self.go(), "true")
                self.assertEqual("::warning::" in r.stdout, waits, r.stdout)
                if waits and prs and groups < slots:
                    self.assertIn("51 fix/pr-51 (render-pr)", self.summary.read_text(encoding="utf-8"))

    def test_merge_group_は_yield_が通した直後の_render_pr_を数える(self):
        """yield の job が終わり render-pr の job がまだ一覧に無い数秒を、通す側でなく数える側に倒す。
        N=2・G1 が走っている所で R と G2 が両方積まれる競合を塞ぐ。"""
        self.merge_group_queue(1)
        self.render_prs((51, "gap"))
        self.render_prs((51, "completed"), round_no=2)
        r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=2)
        self.assertEqual(self.go(), "true", r.stdout)
        self.assertIn(f"待っている相手: 12 {PREV} 51 fix/pr-51 (門番の後)", r.stdout)
        self.assertEqual(len(self.calls_of("/actions/runs/51/jobs")), 1, r.stdout)

    def test_merge_group_は定期の_job_を数えない(self):
        """定期の job は queue の期限で受け入れた割り込み (ADR-0019 決定 7)。この門番では広げない。"""
        self.merge_group_queue(1)
        self.runner_runs((61, "schedule", "in_progress"))
        r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=2, RENDER_TURN_LIMIT=0)
        self.assertNotIn("::warning::", r.stdout)
        self.assertEqual(self.calls_of("/actions/runs/61/jobs"), [])

    def test_render_pr_が終わるまで_group_は門番で待つ(self):
        """N=2・group 1 本・render-pr 1 本: render-pr が終わった周で通る。"""
        self.merge_group_queue(1)
        self.render_prs((51, "in_progress"))
        self.render_prs((51, "completed"), round_no=3)
        r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=2)
        self.assertEqual(self.go(), "true", r.stdout)
        self.assertNotIn("::warning::", r.stdout)
        self.assertIn(f"待っている相手: 12 {PREV} 51 fix/pr-51 (render-pr)", r.stdout)
        self.assertEqual(len(self.calls_of("/actions/runs/51/jobs")), 2, r.stdout)

    def test_先頭の_group_も_render_pr_を数える(self):
        """group の無い間に N 本通った render-pr の上に、先頭を積まない。"""
        self.main_tip(BASE)
        self.render_prs((51, "in_progress"), (52, "queued"))
        r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=2, RENDER_TURN_LIMIT=0)
        self.assertIn("::warning::", r.stdout)
        self.assertEqual(self.calls_of("head_sha="), [])
        self.output.unlink()
        self.render_prs((51, "in_progress"), round_no=2)
        r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=2, RENDER_TURN_LIMIT=0)
        self.assertNotIn("::warning::", r.stdout)

    def test_終わった_render_pr_は数えない(self):
        self.merge_group_queue(1)
        self.render_prs((51, "completed"), (53, "hosted"))
        r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=2, RENDER_TURN_LIMIT=0)
        self.assertNotIn("::warning::", r.stdout)

    def test_門番の中の_render_pr_の_run_は通るかもしれない_1_本と数える(self):
        """yield は group の run ができる直前に読んで通しうる。その門番が走っている間に読んだ merge_group の
        門番が数えないと、N=1 でも render と render-pr が同時に積まれる (反証 2 回目の #2)。"""
        for slots, groups in ((1, 0), (2, 1)):
            with self.subTest(N=slots, group=groups):
                self.setUp()
                self.merge_group_queue(groups)
                if groups == 0:
                    self.main_tip(BASE)
                self.render_prs((52, "gate"))
                self.render_prs((52, "completed"), round_no=2)
                r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=slots)
                self.assertEqual(self.go(), "true", r.stdout)
                self.assertNotIn("::warning::", r.stdout)
                self.assertIn("52 fix/pr-52 (門番の中)", r.stdout)
        # yield も、他の PR の門番の中の run を数える (自分の run は除く)
        self.setUp()
        self.groups_running(1)
        self.render_prs((52, "gate"))
        r = self.turn("yield", RENDER_TURN_SLOTS=2)
        self.assertEqual(self.go(), "false", r.stdout)
        self.assertIn("52 fix/pr-52 (門番の中)", self.summary.read_text(encoding="utf-8"))
        self.output.unlink()
        r = self.turn("yield", RENDER_TURN_SLOTS=2, GITHUB_RUN_ID=52)
        self.assertEqual(self.go(), "true", r.stdout)

    def test_後から走り出した門番は門番の中と数えない(self):
        """この門番より後に走り出す PR の門番 (ホストの runner を待って queued のものも) は、この門番の
        run を一覧に見て数える。数えると N=1 の先頭の group が、必ず見送られる yield を毎周待つ
        (反証 3 回目の #1)。"""
        for shape in ("late-gate", "queued-gate"):
            with self.subTest(shape=shape):
                self.setUp()
                self.main_tip(BASE)
                self.render_prs((52, shape))
                r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=1, RENDER_TURN_LIMIT=0)
                self.assertNotIn("::warning::", r.stdout)
                self.output.unlink()
                self.groups_running(1)
                r = self.turn("yield", RENDER_TURN_SLOTS=2)
                self.assertEqual(self.go(), "true", r.stdout)

    def test_yield_は同じ_PR_の_run_を数えない(self):
        """同じ PR の古い head の render-pr は、通せば concurrency (cancel-in-progress) が取り消す。数えると
        古い木の結果だけが残る (反証 3 回目の #4)。他の PR の run と、merge_group の門番は今までどおり数える。"""
        for shape in ("in_progress", "queued", "gate", "gap"):
            with self.subTest(shape=shape):
                self.setUp()
                self.groups_running(1)
                self.render_prs((51, shape))
                r = self.turn("yield", RENDER_TURN_SLOTS=2, RENDER_TURN_HEAD_REF="fix/pr-51")
                self.assertEqual(self.go(), "true", r.stdout)
                self.assertEqual(self.calls_of("/actions/runs/51/jobs"), [])
                self.output.unlink()
                r = self.turn("yield", RENDER_TURN_SLOTS=2, RENDER_TURN_HEAD_REF="fix/pr-5")
                self.assertEqual(self.go(), "false", r.stdout)
        self.setUp()
        self.merge_group_queue(1)
        self.render_prs((51, "in_progress"))
        r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=2, RENDER_TURN_LIMIT=0,
                      RENDER_TURN_HEAD_REF="fix/pr-51")
        self.assertIn("::warning::", r.stdout)

    def test_run_の一覧はページを送って読む(self):
        """終わっていない render.yml の run が 100 本を越えると、2 ページ目の render-pr を数え落とす (反証 3 回目の #3)。"""
        self.merge_group_queue(1)
        self.render_prs((55, "in_progress"))
        first = self.data / "all-in_progress-1.json"
        listing = json.loads(first.read_text(encoding="utf-8"))
        moved = [run for run in listing["workflow_runs"] if run["id"] == 55]
        listing["workflow_runs"] = [run for run in listing["workflow_runs"] if run["id"] != 55]
        first.write_text(json.dumps(listing), encoding="utf-8")
        (self.data / "all-in_progress-1.page2.json").write_text(
            json.dumps({"workflow_runs": moved}), encoding="utf-8")
        r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=2, RENDER_TURN_LIMIT=0)
        self.assertIn("::warning::", r.stdout)
        self.assertIn("55 fix/pr-55 (render-pr)", self.summary.read_text(encoding="utf-8"))
        r = self.turn("slots", "pull_request")
        self.assertIn("55 pull_request fix/pr-55 render-pr in_progress", r.stdout)

    def test_門番は足りない枠が埋まった所で数えるのをやめる(self):
        """専用機の queue に render-pr が積み上がっていても、毎周すべての run の jobs を引かない
        (API の上限・反証 3 回目の #2)。slots は queue-sweep が退かせる分を選ぶので全部数える。"""
        self.groups_running(1)
        self.render_prs((51, "queued"), (52, "queued"), (53, "queued"))
        r = self.turn("yield", RENDER_TURN_SLOTS=2)
        self.assertEqual(self.go(), "false", r.stdout)
        self.assertEqual(len(self.calls_of("/jobs")), 1, r.stdout)
        self.calls.write_text("", encoding="utf-8")
        r = self.turn("slots", "pull_request")
        self.assertEqual(len(r.stdout.splitlines()), 3, r.stdout)
        self.assertEqual(len(self.calls_of("/jobs")), 3, r.stdout)
        self.setUp()
        self.merge_group_queue(0)
        self.render_prs((51, "queued"), (52, "queued"), (53, "queued"))
        r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=2, RENDER_TURN_LIMIT=0)
        self.assertIn("::warning::", r.stdout)
        self.assertEqual(len(self.calls_of("/actions/runs/5")), 2, r.stdout)

    def test_待っている_job_は枠に数えず_run_は_1_本までと数える(self):
        """job の status は queued と in_progress だけを走っていると読む (stall-watch と同じ語・反証 2 回目の #3)。
        needs や concurrency で待つ job (waiting・pending) が一覧に出ても、runner を取っていない。"""
        cases = [
            # (N, 定期の run の jobs, yield の結論)
            # 門番 (wait) が走り、後ろの専用機の job が pending で並ぶ: 枠を取っていない
            (2, [("render-turn", "in_progress", False), ("scheduled-debug", "pending", True),
                 ("scheduled-release", "pending", True)], "true"),
            # debug が走り、後ろが waiting で並ぶ: 1 本だけ取っている
            (3, [("render-turn", "completed", False), ("scheduled-debug", "in_progress", True),
                 ("scheduled-release", "waiting", True), ("scheduled-drift", "waiting", True)], "true"),
            # 走っている job が無く、専用機の job が待っている (門番の後): 1 本取っている
            (2, [("render-turn", "completed", False), ("scheduled-debug", "pending", True),
                 ("scheduled-release", "pending", True)], "false"),
            (3, [("render-turn", "completed", False), ("scheduled-debug", "pending", True),
                 ("scheduled-release", "pending", True)], "true"),
        ]
        for slots, jobs, go in cases:
            with self.subTest(N=slots, jobs=jobs):
                self.setUp()
                self.groups_running(1)
                self.runner_runs((61, "schedule", jobs))
                r = self.turn("yield", RENDER_TURN_SLOTS=slots)
                self.assertEqual(self.go(), go, r.stdout)

    # --- slots (queue-sweep.sh が呼ぶ) -----------------------------------------

    def test_slots_は枠を_1_本_1_行で出す(self):
        self.groups_running(1)
        self.runner_runs(
            (51, "pull_request", "in_progress"), (52, "pull_request", "gate"),
            (53, "pull_request", "gap"), (54, "pull_request", "hosted"),
            (61, "schedule", "queued"), (62, "schedule", "gate"))
        r = self.turn("slots", "pull_request|schedule")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            sorted(r.stdout.splitlines()),
            [
                "51 pull_request fix/pr-51 render-pr in_progress",
                "52 pull_request fix/pr-52 門番の中",
                "53 pull_request fix/pr-53 門番の後",
                "61 schedule main scheduled-debug queued",
            ],
        )
        self.assertFalse(self.output.exists())
        r = self.turn("slots", "pull_request")
        self.assertNotIn("61 ", r.stdout)

    def test_slots_は読めなかった_run_を名乗って残りを数え_1_で終わる(self):
        self.render_prs((51, "in_progress"))
        r = self.turn("slots", "pull_request", GH_FAIL_JOBS=1)
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertEqual(r.stdout.splitlines(), ["51 pull_request fix/pr-51 読めなかった"])
        r = self.turn("slots", "pull_request", GH_FAIL=1)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout, "")

    def test_slots_の使い方の誤りは_2_で終わる(self):
        for args in [("slots",), ("slots", ""), ("slots", "pull_request)|.*"), ("slots", "a", "b")]:
            r = self.turn(*args)
            self.assertEqual(r.returncode, 2, args)
        self.assertEqual(self.calls.read_text(encoding="utf-8"), "")

    def test_門番の後ろの_job_を_GitHub_が先に出しても自分の_run_は数えない(self):
        """自分の門番が走っている間に、後ろの render-pr を GitHub が一覧へ出す場合の守り。
        普段は自分の門番が走っているので、除かなくても数えられない。"""
        self.groups_running(1)
        self.render_prs((51, "queued"))
        r = self.turn("yield", RENDER_TURN_SLOTS=2, GITHUB_RUN_ID=51)
        self.assertEqual(self.go(), "true", r.stdout)
        self.assertEqual(self.calls_of("/actions/runs/51/jobs"), [])

    def test_group_で埋まっていれば枠は引かない(self):
        self.merge_group_queue(2)
        self.turn("merge_group", BASE, RENDER_TURN_SLOTS=2, RENDER_TURN_LIMIT=0)
        self.assertEqual(self.calls_of("runs?status="), [])
        self.output.unlink()
        self.groups_running(1)
        self.turn("yield")
        self.assertEqual(self.calls_of("runs?status="), [])

    def test_group_が無ければ_yield_は枠を引かない(self):
        self.render_prs((51, "in_progress"))
        r = self.turn("yield", RENDER_TURN_SLOTS=2)
        self.assertEqual(self.go(), "true", r.stdout)
        self.assertEqual(self.calls_of("runs?status="), [])

    def test_yield_は枠を読めなければ引き直さずに見送る(self):
        """必須でない render-pr を通す理由は無い。group があるときの以前の結論 (見送り) に倒す。"""
        self.groups_running(1)
        self.render_prs((51, "in_progress"))
        r = self.turn("yield", RENDER_TURN_SLOTS=2, GH_FAIL_JOBS=1)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "false", r.stdout)
        self.assertNotIn("引き直す", r.stdout)
        self.assertEqual(len(self.calls_of("/actions/runs/51/jobs")), 1, r.stdout)
        self.assertIn("読めなかった", self.summary.read_text(encoding="utf-8"))

    def test_merge_group_は枠を続けて読めなければ通す(self):
        """必須の render の門番は、今までどおり引き直してから通す。"""
        self.merge_group_queue(1)
        self.render_prs((51, "in_progress"))
        r = self.turn("merge_group", BASE, RENDER_TURN_SLOTS=2, GH_FAIL_JOBS=1)
        self.assertEqual(self.go(), "true", r.stdout)
        self.assertIn("::warning::", r.stdout)
        self.assertEqual(len(self.calls_of("/actions/runs/51/jobs")), 3, r.stdout)

    def test_wait_は枠を数えない(self):
        self.render_prs((51, "in_progress"))
        r = self.turn("wait", RENDER_TURN_SLOTS=2)
        self.assertEqual(self.go(), "true", r.stdout)

    # --- 使い方 --------------------------------------------------------------

    def test_使い方の誤りは_2_で終わり_go_を書かない(self):
        for args in [(), ("merge_group",), ("merge_group", ""), ("merge_group", "a", "b", "c"), ("yield", "x"), ("nope",)]:
            r = self.turn(*args)
            self.assertEqual(r.returncode, 2, args)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.calls.read_text(encoding="utf-8"), "")

    def test_help_は冒頭の説明を出して_0_で終わる(self):
        r = self.turn("--help")
        self.assertEqual(r.returncode, 0)
        self.assertIn("render-turn.sh merge_group <base sha>", r.stdout)
        self.assertNotIn("set -euo", r.stdout)


if __name__ == "__main__":
    unittest.main()
