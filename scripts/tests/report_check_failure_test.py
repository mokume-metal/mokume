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
  2. 同じ Issue が open なら二重に立てず、その Issue へ追記する — 日次で回るので、放置
     された赤が毎日 1 本ずつ Issue を産まない。一方で**黙りもしない** (#2658。着手中の
     Issue が open の間、専用機の定期の赤 2 回が run のログにしか残らなかった)。追記にも
     呼び手の文・出力・run の URL が載り、追記が落ちたら非 0 で返る
  3. 重複判定はタイトルの完全一致で行う — GitHub の検索は語で当たるため、似たタイトルの
     別 Issue を「既にある」と誤認すると**本物の赤が一度も起票されない**
  4. 起票と同時に verify: triaged が付く — 付かないと AGENTS.md の着手ゲートに引っかかって
     誰も対処できず、しかも重複抑止で翌日以降の起票まで止まる (#205)
  5. 起票の後に triage を通す — GITHUB_TOKEN が作った Issue には workflow が発火しない
     (再帰防止の仕様) ので、triage.yml は走らない
  6. 長い出力は切り詰める — assets の出力は指し先 178 本ぶん出る。切り詰めを落とすと
     Issue 本文の上限で `gh issue create` ごと落ち、**報告そのものが失われる**

  7. **同じ落ち方の間はコメントせず、本文の区画だけを書き換える** (#2708)。呼び手が渡す鍵が
     前回と同じなら `gh issue edit`、違うか鍵が無いか空なら従来どおりコメントする。壊しても
     run の赤には出ず、通知の量 (知らせ過ぎ) か見落とし (別の赤が黙る) にだけ出る。呼び手ごとの
     鍵 (`CallerKeysTest`) は、揺れる値だけが違う回で黙り、落ち方が違う回で知らせることを見る

加えて、使い方の誤りが `usage_exit_test.py` と同じ 64 で返ること (呼ぶ側が「使い方の誤り」と
「判定が落ちた」を区別できるように) と、出所の 1 行が本文に残ることを留める。

偽 gh は PATH の先頭に置いた同型のスタブで、ネットワークも認証も要らない
(`ruleset_drift_test.py` と同じ形。**畳まない** — 割れれば検査そのものが落ちて目に見える)。
実行は make ci-check (CI もこれを呼ぶ)。
"""

import hashlib
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from scheduled_report_test import record

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
#   gh issue view  … --jq  → ラベル無し / 型無しの Issue を演じる。`--json body` には
#                            FAKE_ISSUE_BODY (ファイル) の中身を本文として返す (#2708)
#   gh issue comment …     → 本文を FAKE_BODY_OUT へ写して成功する (FAKE_COMMENT_FAIL で落ちる)
#   gh issue edit  …       → 本文を FAKE_EDIT_OUT へ写して成功する (FAKE_EDIT_FAIL で落ちる)
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
      *"--json body"*)
        json=$(jq -Rs '{body: .}' < "${FAKE_ISSUE_BODY:-/dev/null}") ;;
      *) json='{"labels":[]}' ;;
    esac ;;
  "issue comment")
    [ -n "${FAKE_COMMENT_FAIL:-}" ] && exit 1
    prev=
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && cp "$a" "$FAKE_BODY_OUT"
      prev=$a
    done
    exit 0 ;;
  "issue edit")
    [ -n "${FAKE_EDIT_FAIL:-}" ] && exit 1
    prev=
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && cp "$a" "$FAKE_EDIT_OUT"
      prev=$a
    done
    exit 0 ;;
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
        self.edited = self.dir / "edited.md"

    def run_script(self, argv, env_extra=None):
        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "FAKE_GH_LOG": str(self.log),
                "FAKE_ISSUE_LIST": "[]",
                "FAKE_BODY_OUT": str(self.body),
                "FAKE_EDIT_OUT": str(self.edited),
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

    def report(
        self,
        log=LOG,
        body=BODY,
        issue_list="[]",
        title=TITLE,
        env_extra=None,
        key=None,
        issue_body=None,
    ):
        """key は「同じ落ち方」の鍵 (None なら渡さない)。issue_body は open な Issue の本文 (#2708)"""
        log_file = self.dir / "check.log"
        log_file.write_text(log)
        body_file = self.dir / "prose.md"
        body_file.write_text(body)
        env = {"FAKE_ISSUE_LIST": issue_list}
        argv = [
            "--title",
            title,
            "--log",
            str(log_file),
            "--body-file",
            str(body_file),
            "--source",
            SOURCE,
        ]
        if key is not None:
            key_file = self.dir / "key.txt"
            key_file.write_text(key)
            argv += ["--key-file", str(key_file)]
        if issue_body is not None:
            issue_body_file = self.dir / "issue-body.md"
            issue_body_file.write_text(issue_body)
            env["FAKE_ISSUE_BODY"] = str(issue_body_file)
        env.update(env_extra or {})
        return self.run_script(argv, env_extra=env)

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

    def test_同じ_Issue_が_open_なら二重に立てずに追記する(self):
        r = self.report(
            issue_list=f'[{{"number":42,"title":"{TITLE}"}}]',
            env_extra={"GITHUB_RUN_ID": "1234", "GITHUB_SERVER_URL": "https://github.com"},
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("issue create", self.gh_log())
        self.assertIn("issue comment 42", self.gh_log())
        self.assertIn("#42", r.stdout)
        # 後から出た赤は前の赤と別物でありうるので、追記も中身を省かない
        body = self.body.read_text()
        self.assertIn("## 解消の判定", body)
        self.assertIn("NG: 例の検査が落ちた", body)
        self.assertIn("https://github.com/mokume-metal/mokume/actions/runs/1234", body)
        self.assertIn(SOURCE, body)
        # 追記は起票ではないので、起票の印の文面を名乗らない
        self.assertNotIn("自動で付く", body)

    def test_追記に失敗したら黙らずに落ちる(self):
        r = self.report(
            issue_list=f'[{{"number":42,"title":"{TITLE}"}}]',
            env_extra={"FAKE_COMMENT_FAIL": "1"},
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("issue create", self.gh_log())

    # --- 同じ落ち方の間は、コメントせず本文の区画を書き換える (#2708) ---------------

    HUMAN_HEAD = "人が書いた先頭の文。\n\n"
    HUMAN_TAIL = "\n\n人が足した末尾の文。\n"

    def created_body(self, key="鍵 A\n"):
        """鍵つきで起票した本文 (区画を持つ)。2 回目以降の「open な Issue の本文」に使う"""
        r = self.report(key=key)
        self.assertEqual(r.returncode, 0, r.stderr)
        # 起票の呼び出し (triage の型付けを含む) は、2 回目の検査の対象ではない
        self.log.write_text("")
        return self.body.read_text()

    def second_run(self, issue_body, key="鍵 A\n", env_extra=None, **kwargs):
        env = {"GITHUB_RUN_ID": "2222", "GITHUB_SERVER_URL": "https://github.com"}
        env.update(env_extra or {})
        return self.report(
            key=key,
            issue_list=f'[{{"number":42,"title":"{TITLE}"}}]',
            issue_body=issue_body,
            env_extra=env,
            **kwargs,
        )

    def test_鍵つきの起票は本文に区画を持つ(self):
        body = self.created_body()
        self.assertIn("<!-- check-failure-state:begin", body)
        self.assertIn("<!-- check-failure-state:end -->", body)
        self.assertIn("連続 1 回", body)
        self.assertRegex(body, r"key=[0-9a-f]{64} count=1 first=\d{4}-\d{2}-\d{2}")

    def test_鍵を渡さない起票には区画が付かない(self):
        self.report()
        self.assertNotIn("check-failure-state", self.body.read_text())

    def test_同じ鍵の続きはコメントせず区画だけを書き換える(self):
        # 初めて落ちた日は、前の回から引き継ぐ (今日にしない) — 昔の日付に置き換えて渡す
        first = re.sub(r"\d{4}-\d{2}-\d{2}", "2020-01-01", self.created_body())
        issue_body = self.HUMAN_HEAD + first + self.HUMAN_TAIL
        # 出力の所要だけが違う 2 回目 (#2251 の 2 件の形)
        r = self.second_run(issue_body, log="NG: 例の検査が落ちた\n  passed after 0.002 seconds\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        log = self.gh_log()
        self.assertNotIn("issue comment", log, "同じ落ち方なのにコメントしている")
        self.assertIn("issue edit 42", log)
        edited = self.edited.read_text()
        self.assertIn("連続 2 回", edited)
        self.assertIn("https://github.com/mokume-metal/mokume/actions/runs/2222", edited)
        self.assertEqual(edited.count("<!-- check-failure-state:begin"), 1, "区画が増えている")
        # 区画の外 (人が書いた文) と、初めて落ちた日は動かない
        self.assertTrue(edited.startswith(self.HUMAN_HEAD))
        self.assertTrue(edited.endswith(self.HUMAN_TAIL))
        self.assertIn("本文の区画を書き換えた", r.stdout)
        self.assertIn("初めて落ちた日 2020-01-01", edited)
        self.assertIn("first=2020-01-01", edited)

    def test_同じ鍵が続くたびに連続回数が増える(self):
        body = self.created_body()
        for expected in (2, 3, 4):
            r = self.second_run(body)
            self.assertEqual(r.returncode, 0, r.stderr)
            body = self.edited.read_text()
            self.assertIn(f"連続 {expected} 回", body)
            # 読み戻した本文の末尾の改行を増やさない (書き換えのたびに空行が積もらない)
            self.assertFalse(body.endswith("\n\n"), repr(body[-40:]))
        self.assertNotIn("issue comment", self.gh_log())

    def test_鍵が変わったらコメントで追記し区画を作り直す(self):


        issue_body = self.HUMAN_HEAD + self.created_body("鍵 A\n") + self.HUMAN_TAIL
        r = self.second_run(issue_body, key="鍵 B\n", log="NG: 別の落ち方\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        log = self.gh_log()
        self.assertIn("issue comment 42", log, "落ち方が変わったのにコメントしていない")
        # 追記には呼び手の文と出力が載る (#2658 の保証は保たれる)
        comment = self.body.read_text()
        self.assertIn("## 解消の判定", comment)
        self.assertIn("NG: 別の落ち方", comment)
        # 新しい鍵で区画を作り直す (次の回が同じ鍵なら黙れる)
        edited = self.edited.read_text()
        self.assertIn("連続 1 回", edited)
        self.assertIn(f"key={hashlib.sha256('鍵 B\n'.encode()).hexdigest()} ", edited)
        self.assertTrue(edited.startswith(self.HUMAN_HEAD))
        self.assertTrue(edited.endswith(self.HUMAN_TAIL))

    def test_鍵を渡さない呼び手は毎回コメントする(self):
        issue_body = self.created_body()
        r = self.report(
            issue_list=f'[{{"number":42,"title":"{TITLE}"}}]', issue_body=issue_body
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        log = self.gh_log()
        self.assertIn("issue comment 42", log)
        self.assertNotIn("issue edit", log)
        self.assertNotIn("issue view", log, "鍵が無いのに本文を読んでいる")

    def test_空の鍵は鍵として扱わず毎回コメントする(self):
        issue_body = self.created_body()
        r = self.second_run(issue_body, key="")
        self.assertEqual(r.returncode, 0, r.stderr)
        log = self.gh_log()
        self.assertIn("issue comment 42", log)
        self.assertNotIn("issue edit", log)

    def test_区画の無い本文にはコメントしたうえで区画を足す(self):
        r = self.second_run("人が書いた文。\n\n## 解消の判定\n\n...\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("issue comment 42", self.gh_log())
        edited = self.edited.read_text()
        self.assertTrue(edited.startswith("人が書いた文。\n"))
        self.assertIn("連続 1 回", edited)

    def test_本文が読めなければ区画に触らずコメントする(self):
        # 空の本文に区画だけを書くと、人の文を消してしまう
        r = self.second_run("")
        self.assertEqual(r.returncode, 0, r.stderr)
        log = self.gh_log()
        self.assertIn("issue comment 42", log)
        self.assertNotIn("issue edit", log)

    def test_終わりの印が無い壊れた区画でも人の文を消さない(self):
        broken = (
            "人が書いた文。\n<!-- check-failure-state:begin (壊れた) -->\n人が後から足した文。\n"
        )
        r = self.second_run(broken, key="鍵 B\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        edited = self.edited.read_text()
        self.assertIn("人が後から足した文。", edited)
        self.assertIn("連続 1 回", edited)

    def test_本文の書き換えに失敗したら黙らずに落ちる(self):
        body = self.created_body()
        # 同じ鍵 (書き換えだけで済ませる回)
        r = self.second_run(body, env_extra={"FAKE_EDIT_FAIL": "1"})
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("issue comment", self.gh_log())

    def test_区画を作り直せなければ黙らずに落ちる(self):
        body = self.created_body("鍵 A\n")
        # 鍵が変わった回: コメントは付くが、区画を書けなければ非 0 (次の回も知らせる側に倒れる)
        r = self.second_run(body, key="鍵 B\n", env_extra={"FAKE_EDIT_FAIL": "1"})
        self.assertNotEqual(r.returncode, 0)

    def test_鍵のファイルが無ければ落ちる(self):
        log_file = self.dir / "check.log"
        log_file.write_text(LOG)
        body_file = self.dir / "prose.md"
        body_file.write_text(BODY)
        r = self.run_script(
            [
                "--title",
                TITLE,
                "--log",
                str(log_file),
                "--body-file",
                str(body_file),
                "--source",
                SOURCE,
                "--key-file",
                str(self.dir / "missing-key"),
            ]
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("鍵のファイルが無い", r.stderr)

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


class CallerKeysTest(unittest.TestCase):
    """5 つの呼び手が渡す鍵 (#2708)。実物の呼び手を、偽 gh の上で 3 回ずつ呼ぶ。

    1 回目は起票 (本文が区画を持つ)、2 回目は**回ごとに揺れる値だけが違う**同じ落ち方、
    3 回目は落ち方そのものが違う。鍵に揺れる値が入っていれば 2 回目がコメントになり
    (知らせ過ぎ)、変わる中身が入っていなければ 3 回目が黙る (別の赤が埋もれる —
    #2658 が塞いだ形)。どちらも run の赤には現れず、通知の量と見落としにだけ出る。
    """

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
        self.body = self.dir / "body.md"
        self.edited = self.dir / "edited.md"
        self.issue_body = None
        self.title = None

    def invoke(self, script, args):
        """呼び手を 1 回呼ぶ。open な Issue が無ければ起票し、あればその本文 (前回の結果) を渡す。"""
        self.log.write_text("")
        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "FAKE_GH_LOG": str(self.log),
                "FAKE_BODY_OUT": str(self.body),
                "FAKE_EDIT_OUT": str(self.edited),
                "FAKE_ISSUE_LIST": "[]"
                if self.issue_body is None
                else f'[{{"number":42,"title":"{self.title}"}}]',
                "GITHUB_REPOSITORY": "mokume-metal/mokume",
            }
        )
        if self.issue_body is not None:
            issue_body = self.dir / "issue-body.md"
            issue_body.write_text(self.issue_body)
            env["FAKE_ISSUE_BODY"] = str(issue_body)
        for key in ("GITHUB_RUN_ID", "GITHUB_SERVER_URL"):
            env.pop(key, None)
        done = subprocess.run(
            ["/bin/bash", str(REPO / "scripts" / script), *args],
            capture_output=True,
            text=True,
            env=env,
            cwd=REPO,
            check=False,
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        log = self.log.read_text()
        # 次の回が読む本文: 起票なら起票の本文、続きなら書き換えた本文
        self.issue_body = (self.body if "issue create" in log else self.edited).read_text()
        return log

    def check(self, script, title, first, same, different):
        """first → same (揺れる値だけが違う) → different の順に呼び、2 回目は黙り 3 回目は知らせる"""
        self.title = title
        log = self.invoke(script, first())
        self.assertIn("issue create", log)
        self.assertIn("check-failure-state", self.issue_body)
        log = self.invoke(script, same())
        self.assertNotIn("issue comment", log, "同じ落ち方 (揺れる値だけが違う) なのにコメントしている")
        self.assertIn("issue edit 42", log)
        self.assertIn("連続 2 回", self.issue_body)
        log = self.invoke(script, different())
        self.assertIn("issue comment 42", log, "落ち方が変わったのに知らせていない")
        self.assertIn("連続 1 回", self.issue_body)

    def write(self, name, text):
        path = self.dir / name
        path.write_text(text, encoding="utf-8")
        return str(path)

    def test_ruleset_drift(self):
        def log(diff):
            return [self.write("drift.log", f"NG: main がずれている\n  {diff}\n")]

        self.check(
            "report-ruleset-drift.sh",
            "ci: ルールセットが定義とずれている",
            lambda: log("差分 1"),
            lambda: log("差分 1"),
            lambda: log("差分 2"),
        )

    def test_dead_assets(self):
        def log(total, url):
            # 出力の頭の本数と、ホストごとの内訳の分母は、日次の版や新しい絵で動く
            return [
                self.write(
                    "assets.log",
                    f"外部資産の指し先: {total} 本 ({total + 5} 箇所から)\n"
                    f"リリースノートの絵: 直近 5 版のうち 3 版に {total // 2} 本\n"
                    "外に置いた資産が引けない (ホストごとの内訳):\n"
                    f"  example.com: 指し先 {total} 本のうち 1 本\n\n"
                    "引けなかった指し先と出所:\n"
                    f"  {url} — HTTP 404\n    docs/a.md:3\n\n"
                    "撮り直しの手順は .claude/skills/visual-evidence/ が持つ。\n",
                )
            ]

        self.check(
            "report-dead-assets.sh",
            "fix(docs): 外に置いた視覚証跡が引けない",
            lambda: log(120, "https://example.com/a.png"),
            lambda: log(140, "https://example.com/a.png"),
            lambda: log(140, "https://example.com/b.png"),
        )

    def test_dead_assets_with_unrecognised_log_falls_back_to_the_whole_output(self):
        """節が取れない形の出力は、出力の全体を鍵にする — 毎回違うほうに倒れて、黙らない。"""
        self.title = "fix(docs): 外に置いた視覚証跡が引けない"
        self.invoke("report-dead-assets.sh", [self.write("assets.log", "形の違う出力 1\n")])
        log = self.invoke("report-dead-assets.sh", [self.write("assets.log", "形の違う出力 2\n")])
        self.assertIn("issue comment 42", log)

    def test_runner_environment(self):
        self.check(
            "report-runner-environment.sh",
            "fix(render): 専用機の環境が壊れていて、merge queue の render が前検査で落ちている",
            lambda: ["console: 表の GUI セッションが so で、job のユーザー (runner) ではない"],
            lambda: ["console: 表の GUI セッションが so で、job のユーザー (runner) ではない"],
            lambda: ["metal: Metal の既定のデバイスが取れない"],
        )

    def test_scheduled_render(self):
        def args(message, tail):
            out = []
            for name in ("debug", "release"):
                xml = self.write(f"{name}.xml", record(("Suite", f"{name}Test()", f"{message} {name}")))
                # 端末出力の末尾 (所要の秒数が回ごとに揺れる) は --log 側で、鍵に入らない
                log = self.write(f"{name}.log", f"{name}: passed after {tail} seconds\n")
                out += ["failure", xml, log]
            return out

        self.check(
            "report-scheduled-render.sh",
            "fix(render): 専用機の定期の検査が落ちている",
            lambda: args("同じ文面", "0.002"),
            lambda: args("同じ文面", "0.001"),
            lambda: args("別の文面", "0.001"),
        )

    def test_example_drift(self):
        """変わった絵の指紋が同じ間は黙り、別の絵が加われば知らせる。違う画素・最大の差は鍵に入らない。"""

        def args(*rows):
            record = self.dir / "drift-record"
            record.mkdir(exist_ok=True)
            (record / "summary.md").write_text("## 例の絵の前後の比較\n\n表\n", encoding="utf-8")
            (record / "range.txt").write_text("a" * 40 + " " + "b" * 40 + "\n", encoding="utf-8")
            tsv = "".join(
                f"Sources/Sketch.swift:{line}\t{fingerprint}\t{pixels}\t1000\t{largest}\t0\t絵\n"
                for line, fingerprint, pixels, largest in rows
            )
            (record / "drifts.tsv").write_text(tsv, encoding="utf-8")
            return [str(record)]

        self.check(
            "report-example-drift.sh",
            "fix(docs): 実装の変更で画素が変わった例の絵が、撮り直されないまま残っている",
            lambda: args((10, "3f9a1c8d", 120, 17)),
            # 行・違う画素・最大の差は区間と編集で動く
            lambda: args((12, "3f9a1c8d", 99, 5)),
            lambda: args((12, "3f9a1c8d", 99, 5), (40, "0badf00d", 7, 2)),
        )

    def test_release_check(self):
        def args(message, tail):
            xml = self.write("release.xml", record(("Suite", "releaseTest()", message)))
            log = self.write("release.log", f"release: passed after {tail} seconds\n")
            return ["failure", xml, log]

        self.check(
            "report-release-check.sh",
            "fix(release): 下限 OS の release の検査が落ちて、版を見送っている",
            lambda: args("同じ文面", "0.002"),
            lambda: args("同じ文面", "0.001"),
            lambda: args("別の文面", "0.001"),
        )


if __name__ == "__main__":
    unittest.main()
