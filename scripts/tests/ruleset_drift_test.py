#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""ルールセットのドリフト起票の検査 (#99)。

固定したいのは四つ:

  1. ドリフトを検出したら Issue が立ち、本文に差分そのものが載る
     (run のログを開かないと何がずれたか分からない起票は、無いのとあまり変わらない)
  2. 同じ Issue が open なら二重に立てない — 日次で回る検査なので、放置された
     ドリフトが毎日 1 本ずつ Issue を産まない
  3. 重複判定はタイトルの完全一致で行う — GitHub の検索は語で当たるため、似た
     タイトルの別 Issue を「既にある」と誤認すると、本物のドリフトが黙殺される
  4. 起票の後に triage を通す — GITHUB_TOKEN が作った Issue には workflow が
     発火しない (再帰防止の仕様) ので、triage.yml は走らない

ワークフロー本体 (.github/workflows/ruleset-drift.yml) には判断を埋めていない。
スクリプト側に置いてあるのは、ここで単体テストとして固定でき、日次で回る検査の
判断が毎回 CI で確かめられるようにするため (#66 / triage.sh と同じ理由)。

gh は PATH の先頭に置いた偽物へ差し替えるので、ネットワークも認証も要らない。
実行は make ci-check (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "report-ruleset-drift.sh"

# report-ruleset-drift.sh の TITLE と同じ文字列。ここがずれたら重複判定が壊れる
TITLE = "ci: ルールセットが定義とずれている"

# 偽 gh。report-ruleset-drift.sh と、その後に呼ばれる triage.sh の分だけ答える。
#   gh issue list  … --jq  → FAKE_ISSUE_LIST に jq を当てる
#   gh issue create …      → 本文を FAKE_BODY_OUT へ写し、URL を返す
#   gh issue view  … --jq  → ラベル無し / 型無しの Issue を演じる
#   gh issue edit  …       → 記録だけして成功する
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

DRIFT_LOG = """NG: main-protection が定義とずれている
--- 定義 main-protection
+++ 実設定 main-protection
-      "required_approving_review_count": 0
+      "required_approving_review_count": 1
"""


class ReportDriftTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

        bin_dir = self.dir / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)

        self.log = self.dir / "gh.log"
        self.log.write_text("")
        self.body = self.dir / "body.md"
        self.bin_dir = bin_dir

    def report(self, drift=DRIFT_LOG, issue_list="[]"):
        drift_file = self.dir / "drift.log"
        drift_file.write_text(drift)
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
            ["/bin/bash", str(SCRIPT), str(drift_file)],
            capture_output=True,
            text=True,
            env=env,
            cwd=REPO,
            check=False,
        )

    def gh_log(self):
        return self.log.read_text()

    def test_ドリフトを検出したら起票する(self):
        r = self.report()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("issue create", self.gh_log())

    def test_本文に差分そのものが載る(self):
        self.report()
        body = self.body.read_text()
        self.assertIn("required_approving_review_count", body)
        self.assertIn("main-protection", body)

    def test_同じ_Issue_が_open_なら二重に立てない(self):
        r = self.report(issue_list=f'[{{"number":42,"title":"{TITLE}"}}]')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("issue create", self.gh_log())
        self.assertIn("#42", r.stdout)

    def test_似たタイトルの別_Issue_は重複とみなさない(self):
        # 検索は語で当たるので、こういうものが返ってくる。完全一致で絞れていないと
        # 本物のドリフトが黙って捨てられる
        r = self.report(issue_list='[{"number":7,"title":"ci: ルールセットの定義ファイルを置く"}]')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("issue create", self.gh_log())

    def test_起票の後に_triage_を通す(self):
        self.report()
        log = self.gh_log()
        self.assertIn("--type Task", log)

    def test_差分が長ければ切り詰めて起票する(self):
        long_drift = "".join(f"line {i}\n" for i in range(1, 301))
        r = self.report(drift=long_drift)
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.body.read_text()
        self.assertIn("line 200", body)
        self.assertNotIn("line 300", body)
        self.assertIn("先頭 200 行", body)

    def test_照合の出力ファイルが無ければ落ちる(self):
        env = dict(os.environ)
        env.update({"PATH": f"{self.bin_dir}:{env['PATH']}", "FAKE_GH_LOG": str(self.log)})
        r = subprocess.run(
            ["/bin/bash", str(SCRIPT), str(self.dir / "missing.log")],
            capture_output=True,
            text=True,
            env=env,
            cwd=REPO,
            check=False,
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("照合の出力ファイルが無い", r.stderr)


if __name__ == "__main__":
    unittest.main()
