#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""専用機の置き場の外の重い負荷の注意が続いたら 1 度だけ追記する検査 (#3633)。

`scripts/count-runner-notice.sh` が**数え**を、`scripts/report-runner-notice.sh` が固定タイトルと本文を持ち、起票の手続きは
`report-check-failure.sh` が持つ。ここで固定するのは次の 8 つ:

  1. 同じプロセス名の注意が N (既定 3) 回続いた回に、1 度だけ書く (この run が 3 回目)
  2. 4 回目以降は書かない (同じ名前が続く間は重ねない)
  3. pid は数えの鍵ではない — pid が変わっても名前が同じなら続きと数える (材料に pid を持たない)
  4. 名前が変われば数え直す。途切れた (前検査が走ったのにその名前が無い) 後にまた N 回続けば、
     新しく 1 度書く
  5. render の job が成功でも失敗でもない run (cancelled・skipped) は数えない
  6. 記録 (run の一覧・job・annotation) を読めなければ、黙らず 1 度書く
  7. 書く先は赤の回の固定タイトル (`fix(`) と別の題で、本文は赤の回と区別できる。メンテナは名指さない
  8. 引数が空・`-` 始まりは使い方の誤りで、gh を呼ばずに 64 で止まる。数え (`count`・読むだけ) と
     書き込み (`report`・issues だけ) は別の呼び出しで、互いの gh を呼ばない (render.yml で job の権限が別)

偽 gh は PATH の先頭に置いた同型のスタブ。`gh api` は経路ごとに用意した出力を返す
(`--jq` で絞った後の形)。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "report-runner-notice.sh"
COUNT = REPO / "scripts" / "count-runner-notice.sh"
RED_TITLE = "fix(render): 専用機の環境が壊れていて、merge queue の render が前検査で落ちている"
NOTICE_TITLE = "chore(render): 専用機の置き場の外の重い負荷が、merge queue の render を遅くしうる (注意)"

# FAKE_DIR/runs: 新しい順の run の ID。FAKE_DIR/jobs-<run>: `<job id> <conclusion>`。
# FAKE_DIR/ann-<job id>: annotation の message の行。FAKE_FAIL が `runs` / `jobs` / `ann` なら
# その API が落ちる
FAKE_GH = """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_GH_LOG"
query=
prev=
for a in "$@"; do
  [ "$prev" = "--jq" ] && query=$a
  prev=$a
done
case "$1 $2" in
  "api repos/"*)
    path=$2
    case "$path" in
      */workflows/render.yml/runs*)
        [ "$FAKE_FAIL" = runs ] && exit 1
        cat "$FAKE_DIR/runs" ;;
      */actions/runs/*/jobs*)
        [ "$FAKE_FAIL" = jobs ] && exit 1
        run=${path#*/actions/runs/}; run=${run%%/*}
        cat "$FAKE_DIR/jobs-$run" 2>/dev/null || true ;;
      */check-runs/*/annotations*)
        [ "$FAKE_FAIL" = ann ] && exit 1
        job=${path#*/check-runs/}; job=${job%%/*}
        cat "$FAKE_DIR/ann-$job" 2>/dev/null || true ;;
      *) exit 1 ;;
    esac
    exit 0 ;;
  "issue list") printf '%s' "$FAKE_ISSUE_LIST" | jq -r "$query"; exit 0 ;;
  "issue create")
    prev=
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && cp "$a" "$FAKE_BODY_OUT"
      [ "$prev" = "--title" ] && printf '%s' "$a" > "$FAKE_TITLE_OUT"
      prev=$a
    done
    echo "https://github.com/mokume-metal/mokume/issues/4242"
    exit 0 ;;
  "issue view")
    case "$*" in
      *issueType*) echo '{"issueType":null}' | jq -r "$query" ;;
      *) echo '{"labels":[]}' ;;
    esac
    exit 0 ;;
  "issue comment")
    prev=
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && cp "$a" "$FAKE_BODY_OUT"
      prev=$a
    done
    exit 0 ;;
  *) exit 0 ;;
esac
"""


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
        self.runs = []

    def add_run(self, run, names, conclusion="success"):
        """前の run を 1 本足す (足した順 = 新しい順)。names=None は注意なし。"""
        job = run * 10
        self.runs.append(run)
        (self.fake / f"jobs-{run}").write_text(f"{job} {conclusion}\n")
        messages = ["Process completed"]
        if names is not None:
            messages.append(
                f"orphan-load: job の置き場の外のプロセスが CPU を使い続けている: x (pid {run}, 60.0%) 〔注意の名前: {names}〕"
            )
        (self.fake / f"ann-{job}").write_text("\n".join(messages) + "\n")

    def env(self, fail="", issue_list="[]", streak=None, current="900", output=None):
        (self.fake / "runs").write_text("".join(f"{r}\n" for r in self.runs))
        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{self.bin_dir}{os.pathsep}{env['PATH']}",
                "FAKE_GH_LOG": str(self.log),
                "FAKE_DIR": str(self.fake),
                "FAKE_FAIL": fail,
                "FAKE_ISSUE_LIST": issue_list,
                "FAKE_BODY_OUT": str(self.body),
                "FAKE_TITLE_OUT": str(self.title),
                "GITHUB_REPOSITORY": "mokume-metal/mokume",
                "GITHUB_RUN_ID": current,
            }
        )
        env.pop("NOTICE_STREAK", None)
        env.pop("GITHUB_OUTPUT", None)
        if streak:
            env["NOTICE_STREAK"] = str(streak)
        if output:
            env["GITHUB_OUTPUT"] = str(output)
        return env

    def sh(self, env, *args):
        """`count` は数え (count-runner-notice.sh)、`report` は書き込み (report-runner-notice.sh)。"""
        script, rest = (COUNT, args[1:]) if args and args[0] == "count" else (SCRIPT, args[1:] if args and args[0] == "report" else args)
        return subprocess.run(["/bin/bash", str(script), *rest], capture_output=True, text=True, env=env, timeout=60)

    def run_script(self, names, detail="", **kwargs):
        """render.yml の 2 つの job と同じ順で、数え (count) → 書き込み (report) を走らせる。"""
        output = self.dir / "github-output"
        output.write_text("")
        r = self.sh(self.env(output=output, **kwargs), "count", names)
        if r.returncode != 0:
            return r
        values = dict(ln.split("=", 1) for ln in output.read_text(encoding="utf-8").splitlines())
        self.assertIn("due", values, r.stdout)
        if not values["due"]:
            return r
        return self.sh(self.env(**kwargs), "report", values["due"], detail, values.get("unreadable", ""))

    def due_of(self, names, **kwargs):
        output = self.dir / "github-output"
        output.write_text("")
        self.sh(self.env(output=output, **kwargs), "count", names)
        return dict(ln.split("=", 1) for ln in output.read_text(encoding="utf-8").splitlines())

    def wrote(self):
        return any(ln.startswith(("issue create", "issue comment")) for ln in self.log.read_text().splitlines())

    # ---- 数え

    def test_同じ名前が_3_回続いた回に書く(self):
        self.add_run(802, "mediaanalysisd")
        self.add_run(801, "mediaanalysisd")
        r = self.run_script("mediaanalysisd", "mediaanalysisd (pid 5, 58.1%, 経過 3-00:00:00)")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.wrote(), r.stdout)
        self.assertIn("mediaanalysisd (連続 3 回)", self.body.read_text(encoding="utf-8"))

    def test_2_回では書かない(self):
        self.add_run(801, "mediaanalysisd")
        r = self.run_script("mediaanalysisd")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.wrote())

    def test_4_回目は書かない(self):
        for run in (803, 802, 801):
            self.add_run(run, "mediaanalysisd")
        r = self.run_script("mediaanalysisd")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.wrote(), "続く間は重ねない")

    def test_pid_が変わっても名前が同じなら続きと数える(self):
        # annotation の本文は run ごとに pid が違う (add_run が pid=run を入れる)。数えの材料は名前だけ
        self.add_run(802, "StorageManagementService")
        self.add_run(801, "StorageManagementService")
        r = self.run_script("StorageManagementService", "StorageManagementService (pid 32358, 52.3%)")
        self.assertTrue(self.wrote(), r.stdout)

    def test_名前が変われば数え直す(self):
        self.add_run(802, "mediaanalysisd")
        self.add_run(801, "mediaanalysisd")
        r = self.run_script("StorageManagementService")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.wrote())

    def test_途切れた後にまた_3_回続けば新しく書く(self):
        # 新しい順: 802=続き・801=続き・800=途切れ (注意なし)・799 以前は古い続き
        self.add_run(802, "mediaanalysisd")
        self.add_run(801, "mediaanalysisd")
        self.add_run(800, None)
        for run in (799, 798, 797):
            self.add_run(run, "mediaanalysisd")
        r = self.run_script("mediaanalysisd")
        self.assertTrue(self.wrote(), r.stdout)

    def test_途切れていれば_3_回に満たない(self):
        self.add_run(802, "mediaanalysisd")
        self.add_run(801, None)
        self.add_run(800, "mediaanalysisd")
        self.run_script("mediaanalysisd")
        self.assertFalse(self.wrote())

    def test_複数の名前は名前ごとに数える(self):
        self.add_run(802, "mediaanalysisd|photoanalysisd")
        self.add_run(801, "mediaanalysisd")
        self.run_script("mediaanalysisd|photoanalysisd")
        body = self.body.read_text(encoding="utf-8")
        self.assertIn("mediaanalysisd (連続 3 回)", body)
        self.assertNotIn("photoanalysisd (連続", body)

    def test_cancelled_と_skipped_の_run_は数えず飛ばす(self):
        self.add_run(803, None, conclusion="cancelled")
        self.add_run(802, "mediaanalysisd")
        self.add_run(801, None, conclusion="skipped")
        self.add_run(800, "mediaanalysisd")
        r = self.run_script("mediaanalysisd")
        self.assertTrue(self.wrote(), r.stdout)

    def test_この_run_自身は前の_run_として数えない(self):
        self.add_run(900, "mediaanalysisd")
        self.add_run(801, "mediaanalysisd")
        self.run_script("mediaanalysisd", current="900")
        self.assertFalse(self.wrote(), "900 は現在の run。数えると 3 回になる")

    def test_N_は_NOTICE_STREAK_で変えられる(self):
        self.add_run(801, "mediaanalysisd")
        r = self.run_script("mediaanalysisd", streak=2)
        self.assertTrue(self.wrote(), r.stdout)

    # ---- 読めないとき

    def test_記録を読めなければ黙らず書く(self):
        for fail in ("runs", "jobs", "ann"):
            with self.subTest(fail=fail):
                self.log.write_text("")
                self.runs.clear()
                self.add_run(801, None)
                r = self.run_script("mediaanalysisd", fail=fail)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertTrue(self.wrote(), r.stdout)
                self.assertIn("読めなかった", self.body.read_text(encoding="utf-8"))

    # ---- 書き先と本文

    def test_赤の回の題とは別の題で起票し本文は注意だと言う(self):
        self.add_run(802, "mediaanalysisd")
        self.add_run(801, "mediaanalysisd")
        self.run_script("mediaanalysisd")
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
        self.add_run(802, "mediaanalysisd")
        self.add_run(801, "mediaanalysisd")
        listing = '[{"number":4300,"title":"%s"}]' % NOTICE_TITLE
        self.run_script("mediaanalysisd", issue_list=listing)
        lines = self.log.read_text().splitlines()
        self.assertFalse(any(ln.startswith("issue create") for ln in lines), lines)
        self.assertTrue(any(ln.startswith("issue comment 4300") for ln in lines), lines)

    # ---- 入口

    def test_引数の誤りは_gh_を呼ばずに_64_で止まる(self):
        env = self.env()
        for script, args in (
            (COUNT, ()),
            (COUNT, ("",)),
            (COUNT, ("--help",)),
            (COUNT, ("a", "b")),
            (SCRIPT, ()),
            (SCRIPT, ("",)),
            (SCRIPT, ("-h",)),
            (SCRIPT, ("a", "b", "c", "d")),
        ):
            with self.subTest(script=script.name, args=args):
                r = subprocess.run(["/bin/bash", str(script), *args], capture_output=True, text=True, env=env, timeout=60)
                self.assertEqual(r.returncode, 64, r.stderr)
        self.assertEqual(self.log.read_text(), "")

    def test_数えは_gh_api_だけを呼び_書き込みは_api_を呼ばない(self):
        # render.yml は 2 つを別の job (権限が別) で呼ぶ。数えが書かず、書き込みが読まない
        self.add_run(802, "mediaanalysisd")
        self.add_run(801, "mediaanalysisd")
        self.run_script("mediaanalysisd")
        verbs = [ln.split()[0] + " " + ln.split()[1] for ln in self.log.read_text().splitlines()]
        count_calls = [v for v in verbs if v.startswith("api")]
        self.assertTrue(count_calls)
        self.log.write_text("")
        self.sh(self.env(), "report", "mediaanalysisd (連続 3 回)", "d", "")
        self.assertFalse([ln for ln in self.log.read_text().splitlines() if ln.startswith("api")])
        self.log.write_text("")
        self.sh(self.env(output=self.dir / "o"), "count", "mediaanalysisd")
        self.assertFalse([ln for ln in self.log.read_text().splitlines() if ln.startswith("issue")])


if __name__ == "__main__":
    unittest.main()
