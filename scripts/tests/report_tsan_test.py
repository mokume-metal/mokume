#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""ホストの定期の TSan の検査の赤を発信する検査 (#3220)。

`scripts/report-tsan.sh` が持つのは**固定タイトルと本文**だけで、起票の手続きは
`report-check-failure.sh` が 1 つ持つ (そちらは `report_check_failure_test.py` が留める)。
ここで固定するのは、この検査に固有の 5 つ:

  1. 固定タイトルが `fix(` で始まる — triage.sh が Bug を付ける
  2. 本文に TSan の報告 (`SUMMARY:` の行と最初の塊) が載る — 競合は xunit の記録に載らず、
     端末出力の途中に埋もれるので、末尾の tail だけでは読めない
  3. TSan の報告が無い回は、競合ではないと名乗る
  4. 記録も test-log も無くても起票する。切れた回は timeout と人の cancel を名乗る
  5. 共通部品を通っている — 同名の Issue が open なら二重に立てず追記する (#2658)
  6. 鍵は回ごとに揺れる値 (pid・アドレス) を持たない — 同じ競合が続く間はコメントせず区画だけを
     書き換え、競合の箇所が変われば追記する (#2708)

偽 gh は区画の読み書きまで演じる report_check_failure_test.py のもの、記録の組み立ては
scheduled_report_test.py のものを使う (写しを持たない)。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from report_check_failure_test import FAKE_GH
from scheduled_report_test import record

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "report-tsan.sh"

# report-tsan.sh の TITLE と同じ文字列。ここがずれたら重複判定が壊れる
TITLE = "fix(test): 定期の TSan の検査が落ちた (データ競合か、TSan の下で走らない検査)"

RED = record(
    ("MokumeAudioTests.SampleRingTests", "concurrentSnapshots()", "TSan の下で落ちた文面 GAMMA"),
)

# TSan の報告の塊。前後に検査の出力を挟み、塊が末尾に無い形にする
RACE_LOG = "\n".join(
    [
        "◇ Test started.",
        "==================",
        "WARNING: ThreadSanitizer: data race (pid=PID)",
        "  Write of size 8 at 0x7b0c00001234 by thread T3:",
        "    #0 SampleRing.latest.setter SampleRing.swift:57",
        "SUMMARY: ThreadSanitizer: data race SampleRing.swift:57 in SampleRing.latest.setter",
        "==================",
        "SUMMARY: ThreadSanitizer: data race SampleRing.swift:57 in SampleRing.latest.setter",
        "SUMMARY: ThreadSanitizer: data race SampleRing.swift:80 in SampleRing.snapshot(_:)",
    ]
    + ["✔ Test passed after 0.1 seconds."] * 300
    + ["検査の端末出力の末尾 DELTA", ""]
)


class ReportTSanTest(unittest.TestCase):
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
        self.edited = self.dir / "edited.md"
        self.issue_body = self.dir / "issue.md"

    def report(self, content=RED, result="failure", issue_list="[]", test_log=RACE_LOG.replace("PID", "4242")):
        """結論と記録・test-log (None なら無いまま渡す) で呼ぶ。"""
        xml = self.dir / "tsan.xml"
        log = self.dir / "tsan.log"
        if content is not None:
            xml.write_text(content, encoding="utf-8")
        if test_log is not None:
            log.write_text(test_log, encoding="utf-8")
        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "FAKE_GH_LOG": str(self.log),
                "FAKE_ISSUE_LIST": issue_list,
                "FAKE_BODY_OUT": str(self.body),
                "FAKE_EDIT_OUT": str(self.edited),
                "FAKE_ISSUE_BODY": str(self.issue_body),
                "GITHUB_REPOSITORY": "mokume-metal/mokume",
            }
        )
        for key in ("GITHUB_RUN_ID", "GITHUB_SERVER_URL"):
            env.pop(key, None)
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), result, str(xml), str(log)],
            capture_output=True,
            text=True,
            env=env,
            cwd=REPO,
            check=False,
        )

    def gh_log(self):
        return self.log.read_text()

    def test_赤なら固定タイトルで起票し_型が付く(self):
        r = self.report()
        self.assertEqual(r.returncode, 0, r.stderr)
        log = self.gh_log()
        self.assertIn("issue create", log)
        self.assertIn(f"--title {TITLE}", log)
        self.assertIn("--type Bug", log)

    def test_本文に_TSan_の報告と落ちた検査と出力の末尾が載る(self):
        self.report()
        body = self.body.read_text()
        # SUMMARY は重複を畳んで全部、塊は最初の 1 つ
        self.assertEqual(body.count("data race SampleRing.swift:57"), 2, body)  # 一覧と塊の中
        self.assertIn("data race SampleRing.swift:80", body)
        self.assertIn("Write of size 8 at 0x7b0c00001234 by thread T3", body)
        self.assertIn("MokumeAudioTests.SampleRingTests", body)
        self.assertIn("TSan の下で落ちた文面 GAMMA", body)
        self.assertIn("検査の端末出力の末尾 DELTA", body)
        # 値が合っても TSan がプロセスを止める — 落ちた検査が空でも赤だと言う
        self.assertIn("落ちた検査」が空でも赤", body)

    def test_TSan_の報告が無ければ競合ではないと名乗る(self):
        self.report(test_log="error: compile failed\n")
        body = self.body.read_text()
        self.assertIn("TSan の報告は無い", body)
        self.assertNotIn("競合した箇所", body)

    def test_記録も_test_log_も無くても起票する(self):
        r = self.report(content=None, test_log=None)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("issue create", self.gh_log())
        body = self.body.read_text()
        self.assertIn("記録が無い", body)
        self.assertIn("test-log が無い", body)

    def test_切れた回は_timeout_と人の_cancel_を名乗る(self):
        self.report(content=None, result="cancelled")
        body = self.body.read_text()
        self.assertIn("`cancelled`", body)
        self.assertIn("timeout", body)
        self.assertIn("人の cancel", body)

    def test_同じ_Issue_が_open_なら二重に立てずに追記する(self):
        r = self.report(issue_list=f'[{{"number":42,"title":"{TITLE}"}}]')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("issue create", self.gh_log())
        self.assertIn("issue comment 42", self.gh_log())
        self.assertIn("追記された分も同じ直しで解けたか", self.body.read_text())

    def open_issue_from_first_report(self):
        """1 回目の起票の本文を、open な Issue の本文として置く。"""
        self.report()
        self.issue_body.write_text(self.body.read_text())
        self.log.write_text("")
        return f'[{{"number":42,"title":"{TITLE}"}}]'

    def test_同じ競合の続きは_pid_が違ってもコメントせず区画だけを書き換える(self):
        issue_list = self.open_issue_from_first_report()
        r = self.report(issue_list=issue_list, test_log=RACE_LOG.replace("PID", "9999"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("issue comment", self.gh_log())
        self.assertIn("issue edit 42", self.gh_log())

    def test_競合の箇所が変われば追記する(self):
        issue_list = self.open_issue_from_first_report()
        other = RACE_LOG.replace("PID", "4242").replace("SampleRing.swift:80", "SampleRing.swift:99")
        r = self.report(issue_list=issue_list, test_log=other)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("issue comment 42", self.gh_log())

    def test_引数が足りなければ_64_で返る(self):
        r = subprocess.run(["/bin/bash", str(SCRIPT), "failure"], capture_output=True, text=True, check=False)
        self.assertEqual(r.returncode, 64)


if __name__ == "__main__":
    unittest.main()
