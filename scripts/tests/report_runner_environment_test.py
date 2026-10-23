#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""merge queue の render が専用機の前検査で落ちたことを発信する検査 (#2588)。

`scripts/report-runner-environment.sh` が持つのは**固定タイトルと本文**だけで、起票の手続きは
`report-check-failure.sh` が持つ (そちらは `report_check_failure_test.py` が留める)。
ここで固定するのは、この発信に固有の 5 つ:

  1. 固定タイトルが `fix(` で始まる — triage.sh は接頭辞から型を推定する
  2. 開いた同じ Issue が無ければ起票し、本文に前検査の理由が載る
  3. 開いた同じ Issue があれば起票しない — 壊れている間、merge_group ごとに立てない
  4. 本文が、PR の赤ではないこと・直した後の 1 手 (弾かれた PR の予約を手で掛け直す)・
     「解消したら閉じる」を言う。当番 (stall-watch) を走らせれば掛け直されるとは言わない —
     当番は名乗るだけで掛け直さない (#2614)
  5. 理由が空なら使い方の誤りで止まる — 空の理由で起票しない

偽 gh は PATH の先頭に置いた同型のスタブ (`scheduled_report_test.py` と同じ形)。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "report-runner-environment.sh"

TITLE = "fix(render): 専用機の環境が壊れていて、merge queue の render が前検査で落ちている"
REASON = "console: 表の GUI セッションが so で、job のユーザー (runner) ではない / screens: job のユーザーから見える画面が 0 枚"

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
  "issue comment")
    prev=
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && cp "$a" "$FAKE_BODY_OUT"
      prev=$a
    done
    exit 0 ;;
  "issue edit") exit 0 ;;
  *) exit 1 ;;
esac
if [ -n "$query" ]; then
  printf '%s' "$json" | jq -r "$query"
else
  printf '%s' "$json"
fi
"""


class ReportRunnerEnvironmentTest(unittest.TestCase):
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

    def run_script(self, *args, issue_list="[]"):
        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{self.bin_dir}{os.pathsep}{env['PATH']}",
                "FAKE_GH_LOG": str(self.log),
                "FAKE_ISSUE_LIST": issue_list,
                "FAKE_BODY_OUT": str(self.body),
                "GITHUB_REPOSITORY": "mokume-metal/mokume",
            }
        )
        for key in ("GITHUB_RUN_ID", "GITHUB_SERVER_URL"):
            env.pop(key, None)
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), *args], capture_output=True, text=True, env=env, timeout=30
        )

    def created(self):
        return [ln for ln in self.log.read_text().splitlines() if ln.startswith("issue create")]

    def test_タイトルは_fix_で始まる(self):
        self.assertTrue(TITLE.startswith("fix("))
        self.assertIn(f'readonly TITLE="{TITLE}"', SCRIPT.read_text(encoding="utf-8"))

    def test_開いた_Issue_が無ければ理由を載せて起票する(self):
        r = self.run_script(REASON)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len(self.created()), 1)
        self.assertIn(f"--title {TITLE}", self.created()[0])
        self.assertIn(REASON, self.body.read_text(encoding="utf-8"))

    def test_開いた同じ_Issue_があれば起票せず追記する(self):
        r = self.run_script(REASON, issue_list=json.dumps([{"number": 7, "title": TITLE}]))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.created(), [])
        self.assertIn("issue comment 7", self.log.read_text())
        self.assertIn("#7", r.stdout)

    def test_本文は_PR_の赤でないことと直した後の_1_手と閉じることを言う(self):
        self.run_script(REASON)
        body = self.body.read_text(encoding="utf-8")
        self.assertIn("PR の中身による赤ではない", body)
        self.assertIn("gh pr merge <番号> --auto --squash", body)
        self.assertIn("bash scripts/stall-watch.sh", body)
        self.assertIn("解消したらこの Issue を閉じる", body)
        # gpu-slot の期限切れの記録 (#2235) は、人が確かめて消す。直し方があり、そのまま打てる削除の行は無い
        self.assertIn("`gpu-slot`", body)
        self.assertIn("人が確かめてから", body)
        self.assertIn("wait-expired.json", body)
        self.assertNotIn("rm ", body.replace("gh pr merge", ""))
        # 当番を走らせても予約は戻らない (#2614)。そう読める案内を残さない
        self.assertNotIn("gh workflow run stall-watch.yml", body)

    def test_理由が空なら起票しない(self):
        r = self.run_script("")
        self.assertEqual(r.returncode, 64)
        self.assertEqual(self.created(), [])


if __name__ == "__main__":
    unittest.main()
