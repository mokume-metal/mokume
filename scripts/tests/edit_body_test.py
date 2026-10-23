#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/edit-body.sh の検査 (#2615)。

守りたいのは 1 つ — **土台にした版の後に本文が変わっていれば、書き込まずに止まる。**
#2610 では、別のエージェントが本文を改訂した 21 秒後に、古い写しを土台にした
`gh issue edit --body-file` がその改訂を丸ごと消した。

確かめ方は Issue の完了条件 1 のとおり: 本文を取得 → 別の経路で本文を書き換える →
取得した版を土台に書き込む、で拒まれること。土台が最新なら通ること。

gh は PATH のスタブに差し替える。スタブは本文の状態を JSON のファイルで持ち、
`gh api graphql` にはその状態を返し、`gh {issue,pr} edit` ではその状態を書き換える。
「別の経路の書き換え」は、検査がその状態のファイルを直接書き換えて表す。
ネットワークも認証も要らない。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WRAPPER = REPO / "scripts" / "edit-body.sh"

# 状態 ($STATE) を読み書きする gh。呼ばれた引数は 1 行ずつ $LOG へ残す
STATEFUL_GH = r"""#!/bin/bash
printf '%s\n' "$*" >> "$LOG"
if [ "$1" = api ] && [ "$2" = graphql ]; then
  exec jq '{data: {repository: {issueOrPullRequest:
    (if .typename == null then null
     else {__typename: .typename, body: .body, lastEditedAt: .lastEditedAt,
           editor: (if .editor then {login: .editor} else null end)} end)}}}' "$STATE"
fi
if [ "$2" = edit ]; then
  file=
  while [ $# -gt 0 ]; do
    if [ "$1" = --body-file ]; then file=$2; fi
    shift
  done
  jq --rawfile b "$file" '.body = $b | .editor = "wrapper-user" | .lastEditedAt = "2026-10-15T00:00:00Z"' \
    "$STATE" > "$STATE.new" && mv "$STATE.new" "$STATE"
  exit 0
fi
exit 1
"""

ORIGINAL = "## 完了条件\n\n1. 元の条件\n"


def iso(minutes_ago):
    at = datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)
    return at.strftime("%Y-%m-%dT%H:%M:%SZ")


@unittest.skipUnless(shutil.which("jq"), "jq が PATH に無い")
class EditBodyTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        bindir = self.dir / "bin"
        bindir.mkdir()
        gh = bindir / "gh"
        gh.write_text(STATEFUL_GH, encoding="utf-8")
        gh.chmod(0o755)
        self.state = self.dir / "state.json"
        self.log = self.dir / "gh.log"
        self.set_state(body=ORIGINAL, editor="maintainer", edited=iso(60 * 24))
        self.env = {
            k: v for k, v in os.environ.items() if k not in ("GITHUB_REPOSITORY", "GH_REPO", "DRAWING_PATHS")
        }
        self.env.update(PATH=f"{bindir}:{os.environ['PATH']}", STATE=str(self.state), LOG=str(self.log))
        self.file = self.dir / "body.md"

    def set_state(self, body, editor, edited, typename="Issue"):
        """別の経路 (人・別のエージェント) が本文を書き換えたことを表す。"""
        self.state.write_text(
            json.dumps({"typename": typename, "body": body, "lastEditedAt": edited, "editor": editor}),
            encoding="utf-8",
        )

    def body(self):
        return json.loads(self.state.read_text(encoding="utf-8"))["body"]

    def edits(self):
        if not self.log.exists():
            return []
        return [line for line in self.log.read_text(encoding="utf-8").splitlines() if " edit " in f" {line} "]

    def run_wrapper(self, *args):
        return subprocess.run(
            ["/bin/bash", str(WRAPPER), *map(str, args)],
            capture_output=True,
            text=True,
            cwd=REPO,
            env=self.env,
        )

    def fetch(self, kind="issue", number=42):
        proc = self.run_wrapper(kind, number, "--fetch", self.file)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc

    # --- 完了条件 1: 土台の後に変わっていれば止まる --------------------------

    def test_body_changed_after_fetch_is_not_overwritten(self):
        """#2610 の形: 取得 → 別の経路で改訂 → 古い版を土台に書き込む、は拒まれる。"""
        self.fetch()
        self.file.write_text(ORIGINAL + "2. 手元で足した条件\n", encoding="utf-8")
        revised = "## 完了条件\n\n1. 判断ごとに書き直した条件\n"
        self.set_state(body=revised, editor="other-agent", edited=iso(0))

        proc = self.run_wrapper("issue", 42, "--body-file", self.file)

        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertEqual(self.body(), revised, "先の改訂が上書きされた")
        self.assertEqual(self.edits(), [], "書き込みのコマンドが呼ばれた")
        # 誰がいつ変えたかを名乗る
        self.assertIn("other-agent", proc.stderr)
        self.assertRegex(proc.stderr, r"\d+ 秒前")
        # 土台から最新への差分を見せる
        self.assertIn("+1. 判断ごとに書き直した条件", proc.stderr)
        self.assertIn("-1. 元の条件", proc.stderr)
        # 取り直しを案内する
        self.assertIn("--fetch", proc.stderr)

    def test_base_that_is_still_latest_is_written(self):
        """土台が最新なら通る。宛先は -R で明示し、本文はファイルで渡す。"""
        self.fetch()
        self.assertEqual(self.file.read_text(encoding="utf-8"), ORIGINAL, "取得した本文が写しと違う")
        edited = ORIGINAL + "2. 足した条件\n"
        self.file.write_text(edited, encoding="utf-8")

        proc = self.run_wrapper("issue", 42, "--body-file", self.file)

        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.body(), edited)
        [call] = self.edits()
        self.assertEqual(call, f"issue edit 42 -R mokume-metal/mokume --body-file {self.file}")

    def test_pull_request_body_is_guarded_too(self):
        self.set_state(body=ORIGINAL, editor="maintainer", edited=iso(60), typename="PullRequest")
        self.fetch(kind="pr", number=7)
        self.file.write_text("手元の版\n", encoding="utf-8")
        self.set_state(body="先の改訂\n", editor="other-agent", edited=iso(3), typename="PullRequest")

        proc = self.run_wrapper("pr", 7, "--body-file", self.file)

        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertEqual(self.body(), "先の改訂\n")
        self.assertIn("3 分前", proc.stderr)

    def test_change_outside_the_body_does_not_stop_the_write(self):
        """比べるのは本文の内容。編集の時刻や人だけが動いても (同じ本文) 止めない。"""
        self.fetch()
        self.set_state(body=ORIGINAL, editor="other-agent", edited=iso(0))
        self.file.write_text(ORIGINAL + "2. 足した条件\n", encoding="utf-8")

        proc = self.run_wrapper("issue", 42, "--body-file", self.file)

        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(self.edits()), 1)

    # --- 土台の扱い ------------------------------------------------------------

    def test_without_a_base_it_refuses(self):
        """どの版の上で直したか分からない本文は書かない (手元の古い写しがこれに当たる)。"""
        self.file.write_text("手元の写し\n", encoding="utf-8")

        proc = self.run_wrapper("issue", 42, "--body-file", self.file)

        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn("土台が無い", proc.stderr)
        self.assertEqual(self.body(), ORIGINAL)
        self.assertEqual(self.edits(), [])

    def test_base_is_used_up_by_a_write(self):
        """書き込んだら土台は消える。続けて直すには取り直す。"""
        self.fetch()
        self.file.write_text(ORIGINAL + "2.\n", encoding="utf-8")
        self.assertEqual(self.run_wrapper("issue", 42, "--body-file", self.file).returncode, 0)
        self.file.write_text(ORIGINAL + "3.\n", encoding="utf-8")

        proc = self.run_wrapper("issue", 42, "--body-file", self.file)

        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn("土台が無い", proc.stderr)
        self.assertEqual(len(self.edits()), 1)

    def test_base_of_another_destination_is_refused(self):
        self.fetch(number=42)
        self.file.write_text("直した\n", encoding="utf-8")
        other = self.dir / "other.md"
        other.write_text("直した\n", encoding="utf-8")

        proc = self.run_wrapper("issue", 43, "--body-file", other, "--base", f"{self.file}.base.json")

        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn("#42", proc.stderr)
        self.assertEqual(self.edits(), [])

    def test_explicit_base_lets_another_file_be_written(self):
        self.fetch()
        other = self.dir / "other.md"
        other.write_text(ORIGINAL + "2.\n", encoding="utf-8")

        proc = self.run_wrapper("issue", 42, "--body-file", other, "--base", f"{self.file}.base.json")

        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.body(), ORIGINAL + "2.\n")

    def test_kind_mismatch_is_refused(self):
        """issue の番号へ pr で書く取り違えを止める (gh issue view は PR の番号も読める)。"""
        proc = self.run_wrapper("pr", 42, "--fetch", self.file)

        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn("取り違え", proc.stderr)
        self.assertFalse(self.file.exists())

    def test_unchanged_body_is_not_written(self):
        self.fetch()

        proc = self.run_wrapper("issue", 42, "--body-file", self.file)

        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.edits(), [])

    def test_dry_run_neither_writes_nor_uses_up_the_base(self):
        self.fetch()
        self.file.write_text(ORIGINAL + "2.\n", encoding="utf-8")

        proc = self.run_wrapper("issue", 42, "--body-file", self.file, "--dry-run")

        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("gh issue edit 42 -R mokume-metal/mokume --body-file", proc.stdout)
        self.assertEqual(self.edits(), [])
        self.assertTrue(Path(f"{self.file}.base.json").exists())

    def test_body_is_fetched_byte_for_byte(self):
        """末尾の改行の有無も写す。足すと、直していない本文まで変更として書き込む。"""
        self.set_state(body="改行で終わらない本文", editor="maintainer", edited=iso(5))
        self.fetch()
        self.assertEqual(self.file.read_bytes(), "改行で終わらない本文".encode("utf-8"))

    # --- 素の gh issue edit が見ていた照合 (#2195) を引き継ぐ -----------------

    def test_personal_info_in_body_is_announced_but_still_written(self):
        """#3075: 個人情報らしきものは名乗るが、書き込みは止めない。"""
        self.fetch()
        edited = ORIGINAL + "連絡先 so@example.com\n"
        self.file.write_text(edited, encoding="utf-8")

        proc = self.run_wrapper("issue", 42, "--body-file", self.file)

        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("メールアドレス", proc.stderr)
        self.assertNotIn("so@example.com", proc.stderr)
        self.assertEqual(self.body(), edited)

    def test_issue_body_naming_a_drawing_file_needs_evidence(self):
        self.fetch()
        self.file.write_text("`Shapes.metal` の mokume_formPaint が細い塗りで透ける\n", encoding="utf-8")

        proc = self.run_wrapper("issue", 42, "--body-file", self.file)

        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn("drawing-evidence", proc.stderr)
        self.assertEqual(self.edits(), [])

    def test_usage_error_is_64(self):
        for args in ([], ["issue"], ["bug", "1", "--fetch", "x"], ["issue", "x", "--fetch", "y"],
                     ["issue", "1"], ["issue", "1", "--fetch", "a", "--body-file", "b"]):
            with self.subTest(args=args):
                proc = self.run_wrapper(*args)
                self.assertEqual(proc.returncode, 64, proc.stderr)
                self.assertIn("使い方", proc.stderr)


if __name__ == "__main__":
    unittest.main()
