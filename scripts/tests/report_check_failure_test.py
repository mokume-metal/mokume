#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""定期検査の失敗を起票する共通部品の検査 (#1295)。

`scripts/report-check-failure.sh` は、日次の検査が落ちたことを Issue で名乗る手続きを
1 つだけ持つ。呼び手 (`report-ruleset-drift.sh` / `report-dead-assets.sh`) が持つのは
固定タイトルと本文だけである。

**固定したいのは、割れても run の赤に現れない 6 つ**である (ADR-0008 決定 6 の線 —
片方だけが直ったとき誰かが気付くか):

  1. 落ちたら Issue が立ち、本文に呼び手の文と検査の出力の両方が載る
     (run のログを開かないと何が起きたか分からない起票は、無いのとあまり変わらない)
  2. 同じ Issue が open なら二重に立てない — 日次で回るので、放置された赤が毎日 1 本
     ずつ Issue を産まない
  3. 重複判定はタイトルの完全一致で行う — GitHub の検索は語で当たるため、似たタイトルの
     別 Issue を「既にある」と誤認すると**本物の赤が一度も起票されない**
  4. 起票と同時に verify: triaged が付く — 付かないと AGENTS.md の着手ゲートに引っかかって
     誰も対処できず、しかも重複抑止で翌日以降の起票まで止まる (#205)
  5. 起票の後に triage を通す — GITHUB_TOKEN が作った Issue には workflow が発火しない
     (再帰防止の仕様) ので、triage.yml は走らない
  6. 長い出力は切り詰める — assets の出力は指し先 178 本ぶん出る。切り詰めを落とすと
     Issue 本文の上限で `gh issue create` ごと落ち、**報告そのものが失われる**

加えて、使い方の誤りが `usage_exit_test.py` と同じ 64 で返ること (呼ぶ側が「使い方の誤り」と
「判定が落ちた」を区別できるように) と、出所の 1 行が本文に残ることを留める。

偽 gh は PATH の先頭に置いた同型のスタブで、ネットワークも認証も要らない
(`ruleset_drift_test.py` と同じ形。**畳まない** — 割れれば検査そのものが落ちて目に見える)。
実行は make ci-check (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "report-check-failure.sh"

# 呼び手が持つもののかわりに使う値。型が付くことを見たいので接頭辞は付ける
TITLE = "ci: 例の検査が落ちている"
SOURCE = ".github/workflows/example.yml が自動起票した (#1295)"
BODY = """前置きの段落。

## 解消の判定

`bash scripts/example.sh` が緑になれば解消。
"""
LOG = "NG: 例の検査が落ちた\n  詳しい理由\n"

# 偽 gh。report-check-failure.sh と、その後に呼ばれる triage.sh の分だけ答える。
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


class ReportCheckFailureTest(unittest.TestCase):
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

    def run_script(self, argv, env_extra=None):
        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "FAKE_GH_LOG": str(self.log),
                "FAKE_ISSUE_LIST": "[]",
                "FAKE_BODY_OUT": str(self.body),
                "GITHUB_REPOSITORY": "mokume-metal/mokume",
            }
        )
        # 実行の残骸 (run URL) が既定では本文に混じらないよう、Actions の変数は落とす
        for key in ("GITHUB_RUN_ID", "GITHUB_SERVER_URL"):
            env.pop(key, None)
        env.update(env_extra or {})
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), *argv],
            capture_output=True,
            text=True,
            env=env,
            cwd=REPO,
            check=False,
        )

    def report(self, log=LOG, body=BODY, issue_list="[]", title=TITLE, env_extra=None):
        log_file = self.dir / "check.log"
        log_file.write_text(log)
        body_file = self.dir / "prose.md"
        body_file.write_text(body)
        env = {"FAKE_ISSUE_LIST": issue_list}
        env.update(env_extra or {})
        return self.run_script(
            [
                "--title",
                title,
                "--log",
                str(log_file),
                "--body-file",
                str(body_file),
                "--source",
                SOURCE,
            ],
            env_extra=env,
        )

    def gh_log(self):
        return self.log.read_text()

    def test_落ちたら起票する(self):
        r = self.report()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("issue create", self.gh_log())

    def test_本文に呼び手の文と検査の出力が載る(self):
        self.report()
        body = self.body.read_text()
        self.assertIn("## 解消の判定", body)
        self.assertIn("NG: 例の検査が落ちた", body)
        self.assertIn("## 検査の出力", body)

    def test_本文に出所が載る(self):
        # どの機構が立てた Issue かが本文から読めないと、止め方も直し方も辿れない
        self.report()
        self.assertIn(SOURCE, self.body.read_text())

    def test_同じ_Issue_が_open_なら二重に立てない(self):
        r = self.report(issue_list=f'[{{"number":42,"title":"{TITLE}"}}]')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("issue create", self.gh_log())
        self.assertIn("#42", r.stdout)

    def test_似たタイトルの別_Issue_は重複とみなさない(self):
        # 検索は語で当たるので、こういうものが返ってくる。完全一致で絞れていないと
        # 本物の赤が黙って捨てられる
        r = self.report(issue_list='[{"number":7,"title":"ci: 例の検査を足す"}]')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("issue create", self.gh_log())

    def test_起票にトリアージ済みの印を付ける(self):
        self.report()
        self.assertIn("--label verify: triaged", self.gh_log())

    def test_起票の後に_triage_を通す(self):
        self.report()
        self.assertIn("--type Task", self.gh_log())

    def test_出力が長ければ切り詰めて起票する(self):
        r = self.report(log="".join(f"line {i}\n" for i in range(1, 301)))
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.body.read_text()
        self.assertIn("line 200", body)
        self.assertNotIn("line 300", body)
        self.assertIn("先頭 200 行", body)

    def test_run_の_URL_を本文に載せる(self):
        self.report(
            env_extra={
                "GITHUB_RUN_ID": "1234",
                "GITHUB_SERVER_URL": "https://github.com",
            }
        )
        self.assertIn(
            "https://github.com/mokume-metal/mokume/actions/runs/1234",
            self.body.read_text(),
        )

    def test_検査の出力ファイルが無ければ落ちる(self):
        body_file = self.dir / "prose.md"
        body_file.write_text(BODY)
        r = self.run_script(
            [
                "--title",
                TITLE,
                "--log",
                str(self.dir / "missing.log"),
                "--body-file",
                str(body_file),
                "--source",
                SOURCE,
            ]
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("検査の出力ファイルが無い", r.stderr)

    def test_本文のファイルが無ければ落ちる(self):
        log_file = self.dir / "check.log"
        log_file.write_text(LOG)
        r = self.run_script(
            [
                "--title",
                TITLE,
                "--log",
                str(log_file),
                "--body-file",
                str(self.dir / "missing.md"),
                "--source",
                SOURCE,
            ]
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("本文のファイルが無い", r.stderr)

    def test_選択肢が足りなければ_64_で返る(self):
        # 値を伴わない選択肢 (`--title` で終わる) は set -u の下で読めないエラーになりうる
        # ので、使い方の誤りとして返す。**知らない選択肢**のぶんは usage_exit_test.py が
        # すべての CLI に対してまとめて見ているので、ここでは重ねない
        for argv in ([], ["--title"], ["--title", TITLE]):
            with self.subTest(argv=argv):
                r = self.run_script(argv)
                self.assertEqual(r.returncode, 64, f"{argv}: {r.stderr}")
                self.assertNotIn("issue create", self.gh_log())


if __name__ == "__main__":
    unittest.main()
