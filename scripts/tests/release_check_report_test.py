#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""版を出す前の release の検査の赤を発信する検査 (#2662)。

`scripts/report-release-check.sh` が持つのは**固定タイトルと本文**だけで、起票の手続きは
`report-check-failure.sh` が 1 つ持つ (そちらは `report_check_failure_test.py` が留める)。
ここで固定するのは、この検査に固有の 5 つ:

  1. 固定タイトルが `fix(` で始まる — triage.sh は接頭辞から型を推定する。動いていたものが
     赤になった事象なので Bug である
  2. 本文が「この回は版を出していない」と言う — release-check が赤の日は release が
     タグを打たない (release.yml)。読む人が、配布が止まっていることを本文から知る
  3. 本文に落ちた検査の名前と文面が載る
  4. 記録も test-log も無くても起票する — ビルドで落ちた回は記録が上がらない (#1295 と同じ形)。
     切れた (`cancelled`) 回は timeout と人の cancel を名乗る
  5. 共通部品を通っている — 同名の Issue が open なら二重に立てず追記する (#2658)

偽 gh と記録の組み立ては scheduled_report_test.py のものを使う (写しを持たない)。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from scheduled_report_test import FAKE_GH, record

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "report-release-check.sh"

# report-release-check.sh の TITLE と同じ文字列。ここがずれたら重複判定が壊れる
TITLE = "fix(release): 下限 OS の release の検査が落ちて、版を見送っている"

RED = record(
    ("MokumeCoreTests.HeadingTests", "measuresInRelease()", "release でだけ落ちた文面 GAMMA"),
)


class ReportReleaseCheckTest(unittest.TestCase):
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

    def report(self, content=RED, result="failure", issue_list="[]", has_log=None):
        """結論と記録 (None なら無いまま渡す) で呼ぶ。test-log は既定で記録と同じく置く。"""
        xml = self.dir / "release.xml"
        log = self.dir / "release.log"
        if content is not None:
            xml.write_text(content, encoding="utf-8")
        if has_log if has_log is not None else content is not None:
            log.write_text("release の端末出力の末尾 DELTA\n", encoding="utf-8")
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

    def test_本文が版を出していないと言う(self):
        self.report()
        body = self.body.read_text()
        self.assertIn("この回は版を出していない", body)
        self.assertIn("make test-release", body)

    def test_本文に落ちた検査と出力の末尾が載る(self):
        self.report()
        body = self.body.read_text()
        self.assertIn("MokumeCoreTests.HeadingTests", body)
        self.assertIn("release でだけ落ちた文面 GAMMA", body)
        self.assertIn("release の端末出力の末尾 DELTA", body)

    def test_記録も_test_log_も無くても起票する(self):
        r = self.report(content=None)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("issue create", self.gh_log())
        body = self.body.read_text()
        self.assertIn("記録が無い", body)
        self.assertIn("test-log が無い", body)

    def test_切れた回は_timeout_と人の_cancel_を名乗る(self):
        self.report(content=None, result="cancelled", has_log=True)
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

    def test_引数が足りなければ_64_で返る(self):
        r = subprocess.run(["/bin/bash", str(SCRIPT), "failure"], capture_output=True, text=True, check=False)
        self.assertEqual(r.returncode, 64)


if __name__ == "__main__":
    unittest.main()
