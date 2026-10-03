#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""専用機の定期の検査の赤を発信する検査 (#1983)。

`scripts/report-scheduled-render.sh` が持つのは**固定タイトルと本文**だけで、起票の手続きは
`report-check-failure.sh` が 1 つ持つ (そちらの 6 点は `report_check_failure_test.py` が
留める)。ここで固定するのは、この検査に固有の 6 つ:

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

    def report(self, debug=DEBUG_RED, release=RELEASE_RED, issue_list="[]"):
        """debug / release の記録 (None なら無いまま渡す) で呼ぶ。"""
        paths = []
        for name, content in (("debug", debug), ("release", release)):
            xml = self.dir / f"{name}.xml"
            log = self.dir / f"{name}.log"
            if content is not None:
                xml.write_text(content, encoding="utf-8")
                log.write_text(f"{name} の端末出力の末尾\n", encoding="utf-8")
            paths += [str(xml), str(log)]
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
            ["/bin/bash", str(SCRIPT), *paths],
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
        r = self.report(debug=GREEN, release=RELEASE_RED)
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
