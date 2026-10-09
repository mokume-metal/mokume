#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""専用機の定期の検査の赤を発信する検査 (#1983)。

`scripts/report-scheduled-render.sh` が持つのは**固定タイトルと本文**だけで、起票の手続きは
`report-check-failure.sh` が 1 つ持つ (そちらの 6 点は `report_check_failure_test.py` が
留める)。ここで固定するのは、この検査に固有の 8 つ:

  1. 固定タイトルが `fix(` で始まる — triage.sh は接頭辞から型を推定するので、ここが
     崩れると型の無い Issue になる。動いていたものが赤になった事象なので Bug である
  2. 本文に、落ちた検査の名前と文面が debug・release の両方について載る — 赤を読む
     最初の手がかりで、run を開かないと何が落ちたか分からない起票は無いのとあまり変わらない
  3. 記録が無くても起票する — ビルドで落ちた回は記録が上がらない。ここで止まると、
     いちばん重い赤 (何も走らなかった) が誰にも届かない (#1295 と同じ形)
  4. 本文に解消の判定が載り、手元の再現と判定が **Makefile の的** を指す — 定期の
     release の範囲の正本は `make test-release-scheduled` の 1 箇所で、本文に範囲の写しを
     持たせない (ADR-0001 原則 9)
  5. 本文が「解消したら閉じる」を言う — 自動では閉じないので、閉じ忘れが次の赤を
     黙らせることを動く人が読む場所へ書く
  6. 共通部品を通っている — 同名の Issue が open なら二重に立てない。ここが写しに
     なると、片方だけが直ったときに黙って壊れる (ADR-0008 決定 6)
  7. 本文が job ごとの結論を名乗り、分かっていることだけを言う (#2084。#2211 はここを
     読み違えさせた)。切れた (`cancelled`) job は切れる 3 つの経路 (timeout・人の cancel・
     concurrency の置き換え) を並べ、記録が無いのを「ビルドかジョブの開始で落ちた」とは
     案内しない。「走っている途中で切れた」と言うのは test-log があるときだけ。落ちて
     (`failure`) 記録が無い job には、ビルドかジョブの開始で落ちた回と、検査のプロセスが
     記録を残さずに消えた回 (#1526) を並べて案内する
  8. 台帳の絵の案内が、定期の run の artifact の名前 (`scheduled-debug-ledger-shots`) を
     指す — `ledger-shots` は render / render-pr の名前で、定期の run には上がらない

偽 gh は PATH の先頭に置いた同型のスタブ (`dead_assets_test.py` と同じ形)。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "report-scheduled-render.sh"

# report-scheduled-render.sh の TITLE と同じ文字列。ここがずれたら重複判定が壊れる
TITLE = "fix(render): 専用機の定期の検査が落ちている"

FAKE_GH = """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_GH_LOG"
query=
prev=
for a in "$@"; do
  [ "$prev" = "--jq" ] && query=$a
  prev=$a
done
case "$1 $2" in
  "issue list") json=$FAKE_ISSUE_LIST ;;
  "issue create")
    prev=
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && cp "$a" "$FAKE_BODY_OUT"
      prev=$a
    done
    echo "https://github.com/mokume-metal/mokume/issues/4242"
    exit 0 ;;
  "issue view")
    case "$*" in
      *issueType*) json='{"issueType":null}' ;;
      *) json='{"labels":[]}' ;;
    esac ;;
  "issue edit") exit 0 ;;
  *) exit 1 ;;
esac
if [ -n "$query" ]; then
  printf '%s' "$json" | jq -r "$query"
else
  printf '%s' "$json"
fi
"""


def record(*cases):
    """xunit の記録。cases は (classname, name, 失敗の文面 or None)。"""
    body = ""
    for classname, name, failure in cases:
        if failure is None:
            body += f'    <testcase classname="{classname}" name="{name}" time="0.1" />\n'
        else:
            body += (
                f'    <testcase classname="{classname}" name="{name}" time="0.1">\n'
                f'      <failure message="{failure}" />\n    </testcase>\n'
            )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n'
        f'  <testsuite name="TestResults" tests="{len(cases)}">\n{body}  </testsuite>\n</testsuites>\n'
    )


DEBUG_RED = record(
    ("MokumeCoreTests.CanvasTests", "draws()", "debug 側で落ちた文面 ALPHA"),
)
RELEASE_RED = record(
    ("MokumeCoreTests.ShapeTests", "replayingBeatsRebuildingForManyElements()", "release 側で落ちた文面 BETA"),
)
GREEN = record(("MokumeCoreTests.CanvasTests", "draws()", None))


class ReportScheduledRenderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

        self.bin_dir = self.dir / "bin"
        self.bin_dir.mkdir()
        gh = self.bin_dir / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)

        self.log = self.dir / "gh.log"
        self.log.write_text("")
        self.body = self.dir / "body.md"

    def report(
        self,
        debug=DEBUG_RED,
        release=RELEASE_RED,
        issue_list="[]",
        results=("failure", "failure"),
        logs=None,
    ):
        """debug / release の結論と記録 (None なら無いまま渡す) で呼ぶ。

        logs は (debug, release) の test-log を置くか。既定は記録と同じで、記録が無ければ
        test-log も無い (ビルドで落ちた回の姿)。
        """
        if logs is None:
            logs = (debug is not None, release is not None)
        args = []
        for name, result, content, has_log in zip(("debug", "release"), results, (debug, release), logs):
            xml = self.dir / f"{name}.xml"
            log = self.dir / f"{name}.log"
            if content is not None:
                xml.write_text(content, encoding="utf-8")
            if has_log:
                log.write_text(f"{name} の端末出力の末尾\n", encoding="utf-8")
            args += [result, str(xml), str(log)]
        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "FAKE_GH_LOG": str(self.log),
                "FAKE_ISSUE_LIST": issue_list,
                "FAKE_BODY_OUT": str(self.body),
                "GITHUB_REPOSITORY": "mokume-metal/mokume",
            }
        )
        # 実行の残骸 (run URL) が本文に混じらないよう、Actions の変数は落とす
        for key in ("GITHUB_RUN_ID", "GITHUB_SERVER_URL"):
            env.pop(key, None)
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), *args],
            capture_output=True,
            text=True,
            env=env,
            cwd=REPO,
            check=False,
        )

    def gh_log(self):
        return self.log.read_text()

    def test_赤なら起票する(self):
        r = self.report()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("issue create", self.gh_log())

    def test_固定タイトルから型が付く(self):
        self.report()
        log = self.gh_log()
        self.assertIn(f"--title {TITLE}", log)
        self.assertIn("--type Bug", log)

    def test_本文に落ちた検査の名前と文面が両方の実行について載る(self):
        self.report()
        body = self.body.read_text()
        self.assertIn("MokumeCoreTests.CanvasTests", body)
        self.assertIn("debug 側で落ちた文面 ALPHA", body)
        self.assertIn("replayingBeatsRebuildingForManyElements()", body)
        self.assertIn("release 側で落ちた文面 BETA", body)

    def test_片方だけ赤でも起票し_緑の側は落ちた検査なしと言う(self):
        r = self.report(debug=GREEN, release=RELEASE_RED, results=("success", "failure"))
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.body.read_text()
        self.assertIn("release 側で落ちた文面 BETA", body)
        self.assertIn("記録に落ちた検査は無い", body)

    def test_記録が無くても起票する(self):
        # ビルドで落ちた回の姿。記録が上がらないまま、そう名乗って起票する
        r = self.report(debug=None, release=None)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("issue create", self.gh_log())
        body = self.body.read_text()
        self.assertIn("記録が無い", body)
        self.assertIn("test-log が無い", body)
        # 落ちて記録が無いのは、検査が記録を書く前に止まったとき。原因は 1 つに決めつけず、
        # ビルドかジョブの開始で落ちた回と、検査のプロセスが記録を残さずに消えた回 (#1526) を
        # 並べ、消えた回の材料の置き場 (scheduled-debug-record の test-vanished/) を案内する
        self.assertIn("ビルドかジョブの開始で落ち", body)
        self.assertIn("記録を残さずに消えた", body)
        self.assertIn("`scheduled-debug-record`", body)
        self.assertIn("test-vanished/", body)

    def test_切れた_job_は_cancelled_と名乗り_ビルドの案内をしない(self):
        # 10-05 08:54Z の回 (run 37286561725) の姿。debug は緑、release は 30 分の timeout で
        # 切れ、記録は書き切る前に切れたので無く、test-log だけが上がった。#2211 はこの形を
        # 「記録が無い = ビルドかジョブの開始で落ちた」と案内した (#2084)
        r = self.report(
            debug=GREEN,
            release=None,
            results=("success", "cancelled"),
            logs=(True, True),
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("issue create", self.gh_log())
        body = self.body.read_text()
        release = body[body.index("### release") : body.index("## 対処")]
        self.assertIn("`cancelled`", release)
        # 切れる経路は 3 つで、見分けない (ADR-0019 決定 7)。並べて名乗る
        self.assertIn("timeout", release)
        self.assertIn("人の cancel", release)
        self.assertIn("concurrency", release)
        self.assertNotIn("ビルドかジョブの開始で落ち", body)
        # test-log があるので、走っている途中で切れたと言える。どこまで走ったかは末尾にある
        self.assertIn("途中で切れた", release)
        self.assertIn("test-log の末尾で読む", release)
        self.assertIn("release の端末出力の末尾", body)
        # 緑の側も、結論を名乗る
        debug = body[body.index("### debug") : body.index("### release")]
        self.assertIn("`success`", debug)

    def test_切れた_job_に_test_log_も無ければ_途中で切れたと決めつけない(self):
        # 始まる前に切れた job (門番で待っている間の cancel・concurrency の置き換え) と、
        # debug が ci-check の build 段で切れた回 (build 段は test-log に写さない) の姿。
        # 記録も test-log も無いので、どこまで走ったかは本文からは言えない
        r = self.report(
            debug=GREEN,
            release=None,
            results=("success", "cancelled"),
            logs=(True, False),
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.body.read_text()
        release = body[body.index("### release") : body.index("## 対処")]
        self.assertIn("`cancelled`", release)
        self.assertIn("test-log も無い", release)
        self.assertNotIn("途中", release)
        self.assertNotIn("test-log の末尾で読む", release)
        self.assertNotIn("ビルドかジョブの開始で落ち", body)

    def test_台帳の絵の案内は定期の_artifact_の名前を指す(self):
        # 定期の debug の絵は `scheduled-debug-ledger-shots` に、落ちた回にだけ上がる
        # (render.yml)。`ledger-shots` は render / render-pr の名前で、定期の run には無い
        ledger = record(
            (
                "MokumeCoreTests.SceneLedgerTests",
                "ledgerMatches()",
                "シーン disc の絵が変わった。&#10;&#10;    disc " + "0" * 64,
            ),
        )
        r = self.report(debug=ledger, release=GREEN, results=("failure", "success"))
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.body.read_text()
        # 記録の読み手が出す台帳の塊と、「対処」の 3 の両方
        self.assertIn("台帳の書き換え後の行", body)
        self.assertEqual(body.count("`scheduled-debug-ledger-shots`"), 2, body)
        self.assertNotIn("`ledger-shots`", body)
        self.assertIn("落ちた (`failure`) 回にだけ", body)

    def test_本文に端末出力の末尾が載る(self):
        self.report()
        body = self.body.read_text()
        self.assertIn("debug の端末出力の末尾", body)
        self.assertIn("release の端末出力の末尾", body)

    def test_本文の解消の判定と再現が_Makefile_の的を指す(self):
        # 範囲の写しを本文に持たせない。定期の release の範囲は的が持つ
        self.report()
        body = self.body.read_text()
        self.assertIn("## 解消の判定", body)
        self.assertIn("make test-release-scheduled", body)
        self.assertIn('make ci-check CI_CHECK_STEPS="build test gpu-ran"', body)
        self.assertNotIn("--skip", body)

    def test_台帳を外している理由を言う(self):
        self.report()
        self.assertIn("#1736", self.body.read_text())

    def test_本文が解消したら閉じることを言う(self):
        self.report()
        body = self.body.read_text()
        self.assertIn("解消したらこの Issue を閉じる", body)
        self.assertIn("重複起票を抑える", body)

    def test_同じ_Issue_が_open_なら二重に立てない(self):
        r = self.report(issue_list=f'[{{"number":42,"title":"{TITLE}"}}]')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("issue create", self.gh_log())
        self.assertIn("#42", r.stdout)

    def test_引数が足りなければ_64_で返る(self):
        r = subprocess.run(
            ["/bin/bash", str(SCRIPT), "only-one"],
            capture_output=True,
            text=True,
            cwd=REPO,
            check=False,
        )
        self.assertEqual(r.returncode, 64)
        self.assertIn("使い方", r.stderr)


if __name__ == "__main__":
    unittest.main()
