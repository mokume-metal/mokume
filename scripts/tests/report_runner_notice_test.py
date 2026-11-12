#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""専用機の置き場の外の重い負荷の注意が続いたら、続き 1 つにつき 1 度だけ追記する検査 (#3633)。

`scripts/count-runner-notice.sh` が**数え** (名前ごとの続いた回数と途切れの run) を、
`scripts/report-runner-notice.sh` が「この続きについて既に書いたか」(注意の Issue の印) と固定タイトル・
本文を持ち、起票の手続きは `report-check-failure.sh` が持つ。ここで固定するのは次の 10 個:

  1. 同じプロセス名の注意が N (既定 3) 回続いた回に書き、同じ続きの間は重ねない (印で見る)
  2. pid は数えの鍵ではない — pid が変わっても名前が同じなら続きと数える (材料に pid を持たない)
  3. 名前が変われば数え直す。途切れた (前検査が走ったのにその名前が無い) 後にまた N 回続けば、
     新しく 1 度書く
  4. **runner 2 本の並行**: まだ終わっていない前の run は途切れでなく「分からない」。ちょうど N 回目の
     run が無くても書き (反証の指摘 1)、同じ続きを並行して数えた 2 本は 1 度しか書かない (指摘 2)
  5. 再実行 (同じ run の ID) では重ねない (指摘 3)
  6. render が成功でも失敗でもない run・前検査の step が走っていない run は、途切れにしない (指摘 5)
  7. 記録 (run の一覧・job・annotation) を読めなければ黙らず 1 度書き、最後の印が「読めない」の間は
     重ねない (指摘 6)
  8. 書く先は赤の回の固定タイトル (`fix(`) と別の題で、本文は赤の回と区別できる。メンテナは名指さない
  9. 名前は環境変数で受け、`-` で始まる名前でも止まらない (指摘 4)。数え (`count`・読むだけ) と
     書き込み (`report`・issues だけ) は互いの gh を呼ばない (render.yml で job の権限が別)
 10. 前検査が実際に出す `::warning` の文面を、数えがそのまま読める (指摘 8)。印や区切りを壊す字
     (`〕`・`|`・`>`) を含む名前も、前検査が寄せた名前で数えて 1 度だけ書く (2 回目の反証 1・2)
 11. API の一時的な失敗は試し直し、読めない扱いにしない (2 回目の反証 6)

偽 gh は run の一覧の `event`・`per_page`・`page` と、Issue の一覧の `--state`・`--search` を実際に効かせる
(2 回目の反証 9。絞り込みを外せば検査が赤になる)。

偽 gh は PATH の先頭に置いた同型のスタブで、**GitHub の API の実際の形の JSON を持ち、渡された
`--jq` の式を実物の jq に掛けて返す** (指摘 7。式を壊せば検査が赤になる)。run の一覧は
`per_page`・`page` で切って返し (ページ送り)、Issue への追記は偽の Issue に積む (次の run が印を読む)。
JSON の形は 2026-11-13 に実物 (`actions/workflows/render.yml/runs`・`actions/runs/<id>/jobs`・
`check-runs/<id>/annotations`) を引いて合わせた。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import runner_preflight_test as preflight  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "report-runner-notice.sh"
COUNT = REPO / "scripts" / "count-runner-notice.sh"
RED_TITLE = "fix(render): 専用機の環境が壊れていて、merge queue の render が前検査で落ちている"
NOTICE_TITLE = "chore(render): 専用機の置き場の外の重い負荷が、merge queue の render を遅くしうる (注意)"
PREFLIGHT_STEP_NAME = "Run bash scripts/runner-preflight.sh"

# FAKE_DIR/runs.json: run の一覧 (新しい順・API の形)。jobs-<run>.json・ann-<job>.json・issues.json・
# issue-<番号>.json は API の形。FAKE_FAIL が `runs` / `jobs` / `ann` / `view` ならその API が落ちる
FAKE_GH = r"""#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
query=
prev=
for a in "$@"; do
  [ "$prev" = "--jq" ] && query=$a
  prev=$a
done
emit() {
  if [ -n "$query" ]; then jq -r "$query"; else cat; fi
}
# FAKE_FAIL=<種類> はその API が毎回落ち、FAKE_FAIL_ONCE=<種類> は最初の 1 回だけ落ちる
fail() {
  [ "$FAKE_FAIL" = "$1" ] && exit 1
  if [ "$FAKE_FAIL_ONCE" = "$1" ] && [ ! -f "$FAKE_DIR/failed-$1" ]; then
    : > "$FAKE_DIR/failed-$1"
    exit 1
  fi
}
# 実物と同じく、渡された問い合わせの値を効かせる。per_page・page は明示を求める (既定に頼らない)
param() {
  printf '%s' "$path" | sed -n "s/.*[?&]$1=\\([^&]*\\).*/\\1/p"
}
case "$1 $2" in
  "api repos/"*)
    path=$2
    case "$path" in
      */workflows/render.yml/runs*)
        fail runs
        per=$(param per_page)
        page=$(param page)
        event=$(param event)
        { [ -n "$per" ] && [ -n "$page" ]; } || { echo "fake gh: per_page と page を明示する" >&2; exit 2; }
        jq --argjson n "$per" --argjson p "$page" --arg e "$event" \
          '[.workflow_runs[] | select($e == "" or .event == $e)]
           | {total_count: length, workflow_runs: .[(($p - 1) * $n):($p * $n)]}' \
          "$FAKE_DIR/runs.json" | emit ;;
      */actions/runs/*/jobs*)
        fail jobs
        run=${path#*/actions/runs/}; run=${run%%/*}
        if [ -f "$FAKE_DIR/jobs-$run.json" ]; then emit < "$FAKE_DIR/jobs-$run.json"
        else echo '{"total_count":0,"jobs":[]}' | emit; fi ;;
      */check-runs/*/annotations*)
        fail ann
        job=${path#*/check-runs/}; job=${job%%/*}
        if [ -f "$FAKE_DIR/ann-$job.json" ]; then emit < "$FAKE_DIR/ann-$job.json"
        else echo '[]' | emit; fi ;;
      *) exit 1 ;;
    esac
    exit 0 ;;
  "issue list")
    state=
    search=
    prev=
    for a in "$@"; do
      [ "$prev" = "--state" ] && state=$a
      [ "$prev" = "--search" ] && search=$a
      prev=$a
    done
    # --search の "<題>" in:title は題の部分一致 (実物は語の照合)。--state は open / closed / all
    words=$(printf '%s' "$search" | sed -n 's/^"\(.*\)" in:title$/\1/p')
    [ -n "$state" ] || state=open
    jq --arg s "$state" --arg w "$words" \
      '[.[] | select(($s == "all" or .state == $s) and ($w == "" or (.title | contains($w))))]' \
      "$FAKE_DIR/issues.json" | emit
    exit 0 ;;
  "issue create")
    prev=
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && body=$a
      [ "$prev" = "--title" ] && title=$a
      prev=$a
    done
    cp "$body" "$FAKE_BODY_OUT"
    printf '%s' "$title" > "$FAKE_TITLE_OUT"
    jq --arg t "$title" '. + [{"number": 4242, "title": $t, "state": "open"}]' "$FAKE_DIR/issues.json" > "$FAKE_DIR/issues.tmp"
    mv "$FAKE_DIR/issues.tmp" "$FAKE_DIR/issues.json"
    jq -n --rawfile b "$body" '{"body": $b, "comments": []}' > "$FAKE_DIR/issue-4242.json"
    echo "https://github.com/mokume-metal/mokume/issues/4242"
    exit 0 ;;
  "issue view")
    case "$*" in
      *issueType*) echo '{"issueType":null}' | emit ;;
      *body,comments*)
        [ "$FAKE_FAIL" = view ] && exit 1
        emit < "$FAKE_DIR/issue-$3.json" ;;
      *) echo '{"labels":[]}' ;;
    esac
    exit 0 ;;
  "issue comment")
    prev=
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && body=$a
      prev=$a
    done
    cp "$body" "$FAKE_BODY_OUT"
    jq --rawfile b "$body" '.comments += [{"body": $b}]' "$FAKE_DIR/issue-$3.json" > "$FAKE_DIR/issue.tmp"
    mv "$FAKE_DIR/issue.tmp" "$FAKE_DIR/issue-$3.json"
    exit 0 ;;
  *) exit 0 ;;
esac
"""


def notice_message(names, pid):
    """前検査の注意の annotation の文面 (runner-preflight.sh の形・末尾にタグ)。"""
    return (
        "orphan-load: job の置き場の外のプロセスが CPU を使い続けている (前の job の残りではないので赤にしない。"
        f"検査は遅くなりうる): x (pid {pid}, 60.0%, 経過 01-00:00:00) 〔注意の名前: {names}〕"
    )


class ReportRunnerNoticeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.bin_dir = self.dir / "bin"
        self.bin_dir.mkdir()
        gh = self.bin_dir / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        self.fake = self.dir / "fake"
        self.fake.mkdir()
        self.log = self.dir / "gh.log"
        self.log.write_text("")
        self.body = self.dir / "body.md"
        self.title = self.dir / "title.txt"
        self.runs = {}  # run の ID → API の形の run
        (self.fake / "issues.json").write_text("[]")

    # ---- 偽の記録

    def add_run(self, run, names, conclusion="success", status="completed", preflight="success", message=None, event="merge_group"):
        """merge_group の run を 1 本足す。names=None は注意なし。preflight=None は前検査の step が無い。"""
        job = run * 10
        self.runs[run] = {
            "id": run,
            "name": "Render",
            "event": event,
            "status": status,
            "conclusion": conclusion if status == "completed" else None,
            "run_attempt": 1,
        }
        done = status == "completed"
        steps = [
            {"name": "Set up job", "status": "completed", "conclusion": "success", "number": 1},
            {"name": "Run actions/checkout@v7", "status": "completed", "conclusion": "success", "number": 3},
        ]
        if preflight is not None:
            steps.append({"name": PREFLIGHT_STEP_NAME, "status": "completed", "conclusion": preflight, "number": 4})
        steps.append({"name": "Run make ci-check", "status": "completed" if done else "in_progress", "conclusion": conclusion if done else None, "number": 5})
        jobs = {
            "total_count": 3,
            "jobs": [
                {"id": job - 1, "run_id": run, "name": "render-turn", "status": "completed", "conclusion": "success", "steps": []},
                {"id": job, "run_id": run, "name": "render", "status": status, "conclusion": conclusion if done else None, "steps": steps},
                {"id": job + 1, "run_id": run, "name": "render-pr", "status": "completed", "conclusion": "skipped", "steps": []},
            ],
        }
        (self.fake / f"jobs-{run}.json").write_text(json.dumps(jobs, ensure_ascii=False))
        annotations = [
            {"path": ".github", "annotation_level": "notice", "title": "", "message": "Process completed", "raw_details": ""},
        ]
        if message is None and names is not None:
            message = notice_message(names, run)
        if message is not None:
            annotations.append(
                {"path": ".github", "start_line": 5, "annotation_level": "warning", "title": "専用機の環境", "message": message, "raw_details": ""}
            )
        (self.fake / f"ann-{job}.json").write_text(json.dumps(annotations, ensure_ascii=False))

    def write_runs(self):
        runs = [self.runs[r] for r in sorted(self.runs, reverse=True)]
        (self.fake / "runs.json").write_text(json.dumps({"total_count": len(runs), "workflow_runs": runs}, ensure_ascii=False))

    def env(self, current, fail="", fail_once="", streak=None, output=None, per_page=None, max_pages=None, **extra):
        self.write_runs()
        env = {k: v for k, v in os.environ.items() if not k.startswith(("NOTICE", "GITHUB_", "DUE", "DETAIL", "UNREADABLE"))}
        env.update(
            {
                "PATH": f"{self.bin_dir}{os.pathsep}{os.environ['PATH']}",
                "FAKE_GH_LOG": str(self.log),
                "FAKE_DIR": str(self.fake),
                "FAKE_FAIL": fail,
                "FAKE_FAIL_ONCE": fail_once,
                "NOTICE_RETRY_WAIT": "0",
                "FAKE_BODY_OUT": str(self.body),
                "FAKE_TITLE_OUT": str(self.title),
                "GITHUB_REPOSITORY": "mokume-metal/mokume",
                "GITHUB_RUN_ID": str(current),
            }
        )
        for key, value in (("NOTICE_STREAK", streak), ("NOTICE_PER_PAGE", per_page), ("NOTICE_MAX_PAGES", max_pages), ("GITHUB_OUTPUT", output)):
            if value is not None:
                env[key] = str(value)
        env.update({k: str(v) for k, v in extra.items()})
        return env

    # ---- 2 つの job

    def count(self, current, names, **kwargs):
        """render-notice-count。$GITHUB_OUTPUT の値を返す。"""
        output = self.dir / f"output-{current}"
        output.write_text("")
        r = subprocess.run(["/bin/bash", str(COUNT)], capture_output=True, text=True, timeout=60, env=self.env(current, output=output, NOTICE=names, **kwargs))
        self.assertEqual(r.returncode, 0, r.stderr)
        values = dict(ln.split("=", 1) for ln in output.read_text(encoding="utf-8").splitlines())
        self.assertIn("due", values, r.stdout)
        return values

    def report(self, current, values, detail="d", fail=""):
        """render-notice-report (due が空なら render.yml は走らせない)。書いたら True。"""
        if not values["due"]:
            return False
        before = self.writes()
        r = subprocess.run(
            ["/bin/bash", str(SCRIPT)],
            capture_output=True,
            text=True,
            timeout=60,
            env=self.env(current, fail=fail, DUE=values["due"], DETAIL=detail, UNREADABLE=values.get("unreadable", "")),
        )
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        return self.writes() > before

    def step(self, run, names, **kwargs):
        """run が終わって数え → 書き込みまで走った後、その run を履歴に足す (並行なし)。書いたら True。"""
        wrote = self.report(run, self.count(run, names, **kwargs))
        self.add_run(run, names)
        return wrote

    def writes(self):
        return sum(1 for ln in self.log.read_text().splitlines() if ln.startswith(("issue create", "issue comment")))

    def issue_text(self):
        data = json.loads((self.fake / "issue-4242.json").read_text(encoding="utf-8"))
        return "\n".join([data["body"], *(c["body"] for c in data["comments"])])

    # ---- 数え

    def test_同じ名前が_3_回続いた回に_1_度だけ書き_続く間は重ねない(self):
        self.add_run(800, None)
        wrote = [self.step(run, "mediaanalysisd") for run in (801, 802, 803, 804, 805)]
        self.assertEqual(wrote, [False, False, True, False, False])
        self.assertIn("mediaanalysisd (連続 3 回)", self.body.read_text(encoding="utf-8"))
        self.assertIn("<!-- runner-notice run=803 after=800 name=mediaanalysisd -->", self.issue_text())

    def test_数えは途切れの_run_と回数を出す(self):
        self.add_run(800, None)
        self.add_run(801, "mediaanalysisd")
        self.add_run(802, "mediaanalysisd|cloudphotod")
        values = self.count(803, "mediaanalysisd|cloudphotod")
        self.assertEqual(values["due"], "3 800 mediaanalysisd")
        self.assertEqual(values["unreadable"], "")

    def test_2_回では書かない(self):
        self.add_run(800, None)
        self.add_run(801, "mediaanalysisd")
        self.assertEqual(self.count(802, "mediaanalysisd")["due"], "")

    def test_pid_が変わっても名前が同じなら続きと数える(self):
        # annotation の本文は run ごとに pid が違う (add_run が pid=run を入れる)。数えの材料は名前だけ
        self.add_run(801, "StorageManagementService")
        self.add_run(802, "StorageManagementService")
        self.assertTrue(self.report(803, self.count(803, "StorageManagementService")))

    def test_名前が変われば数え直す(self):
        self.add_run(801, "mediaanalysisd")
        self.add_run(802, "mediaanalysisd")
        self.assertEqual(self.count(803, "StorageManagementService")["due"], "")

    def test_途切れた後にまた_3_回続けば新しく書く(self):
        self.add_run(800, None)
        first = [self.step(run, "mediaanalysisd") for run in (801, 802, 803)]
        self.add_run(804, None)  # 途切れ (前検査は走ったが注意なし)
        second = [self.step(run, "mediaanalysisd") for run in (805, 806, 807)]
        self.assertEqual(first + second, [False, False, True, False, False, True])
        self.assertIn("<!-- runner-notice run=807 after=804 name=mediaanalysisd -->", self.issue_text())

    def test_途切れていれば_3_回に満たない(self):
        self.add_run(800, "mediaanalysisd")
        self.add_run(801, None)
        self.add_run(802, "mediaanalysisd")
        self.assertEqual(self.count(803, "mediaanalysisd")["due"], "")

    def test_複数の名前は名前ごとに数える(self):
        self.add_run(801, "mediaanalysisd")
        self.add_run(802, "mediaanalysisd|photoanalysisd")
        self.report(803, self.count(803, "mediaanalysisd|photoanalysisd"))
        body = self.body.read_text(encoding="utf-8")
        self.assertIn("mediaanalysisd (連続 3 回)", body)
        self.assertNotIn("photoanalysisd (連続", body)

    def test_タグの無い注意は名前を読めず途切れと数える(self):
        # この PR より前の実物の文面 (run 42255607348) には 〔注意の名前: …〕 が無い
        self.add_run(801, None, message="orphan-load: job の置き場の外のプロセスが CPU を使い続けている (前の job の残りではないので赤にしない。検査は遅くなりうる): mediaanalysisd (pid 501, 58.1%, 経過 01-01:18:26)")
        self.add_run(802, "mediaanalysisd")
        self.assertEqual(self.count(803, "mediaanalysisd")["due"], "")

    def test_N_は_NOTICE_STREAK_で変えられる(self):
        self.add_run(801, "mediaanalysisd")
        self.assertEqual(self.count(802, "mediaanalysisd", streak=2)["due"], "2 0 mediaanalysisd")

    # ---- 並行・再実行・分からない run (反証の指摘 1・2・3・5)

    def test_並行でちょうど_3_回目の_run_が無くても_次の回が書く(self):
        # 履歴は 801 の 1 回分。803・804 が並行し、互いに終わっていない (803 は 804 を前の run に数えず、
        # 804 は走っている 803 を飛ばす)。どちらも 2 回目。次の 805 は 4 回目でも、印が無いので書く
        self.add_run(800, None)
        self.add_run(801, "mediaanalysisd")
        self.add_run(803, None, status="in_progress")
        self.add_run(804, None, status="in_progress")
        a = self.count(803, "mediaanalysisd")
        b = self.count(804, "mediaanalysisd")
        self.assertEqual((a["due"], b["due"]), ("", ""))
        self.add_run(803, "mediaanalysisd")
        self.add_run(804, "mediaanalysisd")
        values = self.count(805, "mediaanalysisd")
        self.assertEqual(values["due"], "4 800 mediaanalysisd")
        self.assertTrue(self.report(805, values))

    def test_並行で同じ続きを数えた_2_本は_1_度しか書かない(self):
        self.add_run(800, None)
        self.add_run(801, "mediaanalysisd")
        self.add_run(802, "mediaanalysisd")
        self.add_run(803, None, status="in_progress")
        self.add_run(804, None, status="in_progress")
        a = self.count(803, "mediaanalysisd")
        b = self.count(804, "mediaanalysisd")
        self.assertEqual(a["due"], "3 800 mediaanalysisd")
        self.assertEqual(b["due"], "3 800 mediaanalysisd")
        # 書き込みは concurrency で直列。後の側が先の側の印を見る
        self.assertTrue(self.report(803, a))
        self.assertFalse(self.report(804, b))
        self.assertEqual(self.writes(), 1)

    def test_並行で片方だけが先の_run_の終わりを見ても_1_度しか書かない(self):
        # 804 の数えのときには 803 が終わっていた (始まりは同じ 801・途切れも同じ 800)
        self.add_run(800, None)
        self.add_run(801, "mediaanalysisd")
        self.add_run(802, "mediaanalysisd")
        self.add_run(803, None, status="in_progress")
        a = self.count(803, "mediaanalysisd")
        self.add_run(803, "mediaanalysisd")
        b = self.count(804, "mediaanalysisd")
        self.assertEqual(b["due"], "4 800 mediaanalysisd")
        self.assertTrue(self.report(804, b))
        self.assertFalse(self.report(803, a), "書いた側の順は問わない")

    def test_再実行では重ねない(self):
        self.add_run(800, None)
        self.add_run(801, "mediaanalysisd")
        self.add_run(802, "mediaanalysisd")
        self.assertTrue(self.report(803, self.count(803, "mediaanalysisd")))
        # 803 を再実行する間に 804 が終わった。ID は同じ 803 で、後の run は前の run に数えない
        self.add_run(803, "mediaanalysisd")
        self.add_run(804, "mediaanalysisd")
        values = self.count(803, "mediaanalysisd")
        self.assertEqual(values["due"], "3 800 mediaanalysisd")
        self.assertFalse(self.report(803, values))

    def test_分からない_run_は途切れにせず飛ばす(self):
        self.add_run(800, None)
        self.add_run(801, "mediaanalysisd")
        for run, kwargs in (
            (802, {"conclusion": "cancelled"}),
            (803, {"conclusion": "skipped", "preflight": None}),
            (804, {"conclusion": "failure", "preflight": None}),  # checkout で落ちて前検査に届かない
            (805, {"conclusion": "failure", "preflight": "skipped"}),
            (806, {"status": "in_progress"}),
        ):
            self.add_run(run, None, **kwargs)
        self.add_run(807, "mediaanalysisd")
        self.assertEqual(self.count(808, "mediaanalysisd")["due"], "3 800 mediaanalysisd")

    def test_前検査が走って注意が無い_run_は途切れ(self):
        # 検査で赤 (failure) でも前検査は走っている。注意が無ければ途切れ
        self.add_run(801, "mediaanalysisd")
        self.add_run(802, None, conclusion="failure", preflight="success")
        self.add_run(803, "mediaanalysisd")
        self.assertEqual(self.count(804, "mediaanalysisd")["due"], "")

    def test_この_run_自身と後の_run_は前の_run_として数えない(self):
        self.add_run(801, "mediaanalysisd")
        self.add_run(900, "mediaanalysisd")
        self.add_run(901, "mediaanalysisd")
        self.assertEqual(self.count(900, "mediaanalysisd")["due"], "", "900 は現在の run・901 は後の run")

    # ---- ページ送り

    def test_続きがページをまたいでも数え_上限で止める(self):
        self.add_run(790, None)
        for run in range(791, 800):
            self.add_run(run, "mediaanalysisd")
        # 1 ページ 2 本。800 自身も一覧に居る (走っている) — 9 本の続きを 5 ページ先の 790 まで遡る
        self.add_run(800, None, status="in_progress")
        self.assertEqual(self.count(800, "mediaanalysisd", per_page=2, max_pages=6)["due"], "10 790 mediaanalysisd")
        # 上限が手前なら途切れは見つからず 0 (書く側は同じ名前の印が 1 つでも在れば書かない)
        self.log.write_text("")
        self.assertEqual(self.count(800, "mediaanalysisd", per_page=2, max_pages=2)["due"], "4 0 mediaanalysisd")
        pages = [ln for ln in self.log.read_text().splitlines() if "/runs?" in ln]
        self.assertEqual(len(pages), 2, pages)

    def test_途切れを見つけたら先のページを読まない(self):
        for run in range(780, 798):
            self.add_run(run, "mediaanalysisd")
        self.add_run(798, None)
        self.add_run(799, "mediaanalysisd")
        self.count(800, "mediaanalysisd", per_page=2)
        pages = [ln for ln in self.log.read_text().splitlines() if "/runs?" in ln]
        self.assertEqual(len(pages), 1, pages)

    def test_途切れが上限の外なら同じ名前の印で重ねない(self):
        self.add_run(500, "mediaanalysisd")
        (self.fake / "issues.json").write_text(json.dumps([{"number": 4242, "title": NOTICE_TITLE, "state": "open"}]))
        (self.fake / "issue-4242.json").write_text(json.dumps({"body": "x\n<!-- runner-notice run=500 after=499 name=mediaanalysisd -->\n", "comments": []}))
        self.assertFalse(self.report(800, {"due": "4 0 mediaanalysisd", "unreadable": ""}))
        self.assertTrue(self.report(800, {"due": "4 0 cloudphotod", "unreadable": ""}))

    # ---- 読めないとき (反証の指摘 6)

    def test_記録を読めなければ黙らず書き_読めない間は重ねない(self):
        for fail in ("runs", "jobs", "ann"):
            with self.subTest(fail=fail):
                self.setUp()
                self.add_run(801, None)
                values = self.count(802, "mediaanalysisd", fail=fail)
                self.assertEqual(values["unreadable"], "1")
                self.assertTrue(self.report(802, values))
                body = self.body.read_text(encoding="utf-8")
                self.assertIn("読めなかった", body)
                self.assertIn("<!-- runner-notice run=802 unreadable -->", body)
                self.assertFalse(self.report(803, self.count(803, "mediaanalysisd", fail=fail)), "読めない回を重ねない")

    def test_一時的な失敗は試し直して読めない扱いにしない(self):
        # レート制限・502 の 1 回で、1 回目の続きの名前まで due に載せて Issue を立てない (2 回目の反証 6)
        for kind in ("runs", "jobs", "ann"):
            with self.subTest(kind=kind):
                self.setUp()
                self.add_run(800, None)
                self.add_run(801, "mediaanalysisd")
                values = self.count(802, "mediaanalysisd", fail_once=kind)
                self.assertEqual(values, {"due": "", "unreadable": ""})
                self.assertTrue((self.fake / f"failed-{kind}").exists(), "偽の gh が 1 回落ちていない")

    def test_試し直しても落ちれば読めない扱い(self):
        self.add_run(801, "mediaanalysisd")
        values = self.count(802, "mediaanalysisd", fail="jobs")
        self.assertEqual(values["unreadable"], "1")
        jobs_calls = [ln for ln in self.log.read_text().splitlines() if "/jobs?" in ln]
        self.assertEqual(len(jobs_calls), 3, jobs_calls)

    # ---- 絞り込み (2 回目の反証 9)

    def test_merge_group_の外の_run_は数えない(self):
        # pull_request・schedule の render.yml の run は render の job が走らず前検査も無い。混ぜると
        # 前検査が走って注意の無い run に見え、続きが途切れる
        self.add_run(800, None)
        self.add_run(801, "mediaanalysisd")
        self.add_run(802, None, event="pull_request")
        self.add_run(803, None, event="schedule")
        self.add_run(804, "mediaanalysisd")
        self.assertEqual(self.count(805, "mediaanalysisd")["due"], "3 800 mediaanalysisd")

    def test_閉じた注意の_Issue_と別の題の_Issue_の印は読まない(self):
        self.add_run(800, None)
        self.add_run(801, "mediaanalysisd")
        self.add_run(802, "mediaanalysisd")
        mark = "<!-- runner-notice run=900 after=800 name=mediaanalysisd -->"
        (self.fake / "issues.json").write_text(
            json.dumps(
                [
                    # 検索は語の照合なので、題を含む別の題も返る。完全一致で絞る
                    {"number": 4102, "title": NOTICE_TITLE + " の振り返り", "state": "open"},
                    {"number": 4100, "title": NOTICE_TITLE, "state": "closed"},
                    {"number": 4101, "title": RED_TITLE, "state": "open"},
                ]
            )
        )
        for n in (4100, 4101, 4102):
            (self.fake / f"issue-{n}.json").write_text(json.dumps({"body": mark, "comments": []}))
        self.assertTrue(self.report(803, self.count(803, "mediaanalysisd")))
        self.assertIn("issue create", self.log.read_text())

    def test_普通に書いた後の読めない回はまた_1_度書く(self):
        self.add_run(801, "mediaanalysisd")
        self.add_run(802, "mediaanalysisd")
        self.assertTrue(self.report(803, self.count(803, "mediaanalysisd", fail="runs")))
        self.assertTrue(self.report(804, self.count(804, "mediaanalysisd")), "読めるようになった 3 回以上の続き")
        self.assertTrue(self.report(805, self.count(805, "mediaanalysisd", fail="ann")))
        self.assertFalse(self.report(806, self.count(806, "mediaanalysisd", fail="jobs")))

    def test_Issue_の印を読めなければ書く側に倒す(self):
        self.add_run(801, "mediaanalysisd")
        self.add_run(802, "mediaanalysisd")
        self.assertTrue(self.report(803, self.count(803, "mediaanalysisd")))
        self.assertTrue(self.report(803, self.count(803, "mediaanalysisd"), fail="view"))

    # ---- 書き先と本文

    def test_赤の回の題とは別の題で起票し本文は注意だと言う(self):
        self.add_run(801, "mediaanalysisd")
        self.add_run(802, "mediaanalysisd")
        self.report(803, self.count(803, "mediaanalysisd"))
        title = self.title.read_text(encoding="utf-8")
        self.assertEqual(title, NOTICE_TITLE)
        self.assertTrue(title.startswith("chore("), title)
        self.assertNotEqual(title, RED_TITLE)
        body = self.body.read_text(encoding="utf-8")
        self.assertIn("## 注意: render を遅くしうる", body)
        self.assertIn("赤ではない", body)
        self.assertIn("何も止めていない", body)
        self.assertNotIn("@shinyaoguri", body, "赤ではないのでメンテナを名指さない")

    def test_open_な注意の_Issue_があれば起票せずコメントで追記する(self):
        self.add_run(801, "mediaanalysisd")
        self.add_run(802, "mediaanalysisd")
        (self.fake / "issues.json").write_text(json.dumps([{"number": 4300, "title": NOTICE_TITLE, "state": "open"}]))
        (self.fake / "issue-4300.json").write_text(json.dumps({"body": "人の文", "comments": []}))
        self.report(803, self.count(803, "mediaanalysisd"))
        lines = self.log.read_text().splitlines()
        self.assertFalse(any(ln.startswith("issue create") for ln in lines), lines)
        self.assertTrue(any(ln.startswith("issue comment 4300") for ln in lines), lines)

    # ---- 入口 (反証の指摘 4)

    def test_引数の誤りは_gh_を呼ばずに_64_で止まる(self):
        for script, args, extra in (
            (COUNT, (), {}),
            (COUNT, (), {"NOTICE": ""}),
            (COUNT, (), {"NOTICE": "|"}),
            (COUNT, ("mediaanalysisd",), {"NOTICE": "mediaanalysisd"}),
            (SCRIPT, (), {}),
            (SCRIPT, (), {"DUE": ""}),
            (SCRIPT, ("x",), {"DUE": "3 0 x"}),
        ):
            with self.subTest(script=script.name, args=args, extra=extra):
                r = subprocess.run(["/bin/bash", str(script), *args], capture_output=True, text=True, env=self.env(900, **extra), timeout=60)
                self.assertEqual(r.returncode, 64, r.stderr)
        self.assertEqual(self.log.read_text(), "")

    def test_ハイフンで始まる名前でも止まらず数えて書く(self):
        for name in ("-zsh", "--help", "-"):
            with self.subTest(name=name):
                self.setUp()
                self.add_run(801, name)
                self.add_run(802, name)
                values = self.count(803, name)
                self.assertEqual(values["due"], f"3 0 {name}")
                self.assertTrue(self.report(803, values))
                self.assertIn(f"- {name} (連続 3 回)", self.body.read_text(encoding="utf-8"))
                self.assertFalse(self.report(804, self.count(804, name)), "印も名前で読み戻せる")

    def test_数えは_gh_api_だけを呼び_書き込みは_api_を呼ばない(self):
        # render.yml は 2 つを別の job (権限が別) で呼ぶ。数えが書かず、書き込みが読まない
        self.add_run(801, "mediaanalysisd")
        self.add_run(802, "mediaanalysisd")
        values = self.count(803, "mediaanalysisd")
        calls = self.log.read_text().splitlines()
        self.assertTrue(calls)
        self.assertTrue(all(ln.startswith("api ") for ln in calls), calls)
        self.log.write_text("")
        self.report(803, values)
        self.assertFalse([ln for ln in self.log.read_text().splitlines() if ln.startswith("api")])

    # ---- 前検査の文面との結び (反証の指摘 8)

    def test_前検査が実際に出す注意の文面を数えが読む(self):
        pre = preflight.RunnerPreflightTest("run")
        pre.setUp()
        self.addCleanup(pre.tmp.cleanup)
        ps = preflight.RunnerPreflightTest.MEDIA_ANALYSIS + "\n  1905     1  60.0 18-09:23:07 -zsh"
        r = pre.run_preflight(FAKE_PS=ps, FAKE_CWDS="1904=/\n1905=/")
        self.assertEqual(r.returncode, 0, r.stdout)
        warnings = [ln for ln in r.stdout.splitlines() if ln.startswith("::warning title=専用機の環境::orphan-load: job の置き場の外")]
        self.assertEqual(len(warnings), 1, r.stdout)
        message = re.sub(r"^::warning [^:]*::", "", warnings[0])
        notice = pre.output_value("notice")
        self.assertEqual(set(notice.split("|")), {"-zsh", "mediaanalysisd"})
        for run in (801, 802):
            self.add_run(run, None, message=message)
        self.assertEqual(set(self.count(803, notice)["due"].split("|")), {"3 0 -zsh", "3 0 mediaanalysisd"})

    def test_印や区切りを壊す字を含む名前も寄せた名前で数えて_1_度だけ書く(self):
        # 2 回目の反証 1・2: `〕` はタグを、`|` は区切りを、`>`・`-->` は印を壊す。前検査が安全な字に寄せる
        pre = preflight.RunnerPreflightTest("run")
        pre.setUp()
        self.addCleanup(pre.tmp.cleanup)
        comm = "/Applications/A App.app/Contents/MacOS/a>b〕c d=e|f-->g"
        r = pre.run_preflight(FAKE_PS=f"  1904     1  68.0 18-09:23:07 {comm}", FAKE_CWDS="1904=/")
        # 人が読む文面は元の名前のまま (一覧の `|` を `, ` にするのは前からの書き方)
        self.assertIn("a>b〕c d=e, f-->g (pid 1904", r.stdout)
        notice = pre.output_value("notice")
        self.assertEqual(notice, "a_b___c d_e_f--_g")
        message = re.sub(r"^::warning [^:]*::", "", next(ln for ln in r.stdout.splitlines() if ln.startswith("::warning")))
        for run in (801, 802):
            self.add_run(run, None, message=message)
        values = self.count(803, notice)
        self.assertEqual(values["due"], f"3 0 {notice}")
        self.assertTrue(self.report(803, values))
        self.add_run(803, None, message=message)
        self.assertFalse(self.report(804, self.count(804, notice)), "印を読み戻せる")


if __name__ == "__main__":
    unittest.main()
