#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/rerequest-review.sh の検査 (#1177)。

固定したいのは 7 つ。

1. **承認が落ちていたら、落ちた承認の主へ出し直す。** これが無いと、押し直しが要ることに
   気付く経路が当番の赤だけになる (実測で数時間おき・#1197)
2. **いま承認が付いている PR には打たない。** 落ちていないか、既に押し直された後である
3. **承認が落ちた出来事が無い PR には打たない。** 一度も承認されていない PR に依頼を出すのは
   「出し直し」ではない
4. **依頼が既に残っていたら打たない。** 同じ PR に 2 通目を出さない (#1177 完了条件 3)
5. **承認が要らない PR には打たない。** 重要パスに触れていなければ merge は進むので、
   通知だけが増える (#642)
6. **変更ファイルが読めなかったら、出し直す側に倒す。** 落ちた承認が放置される害のほうが、
   要らない依頼が 1 通増える害より大きい
7. **打てなかったときだけ非 0。** 打つ必要が無かったことを赤くすると、走るたびに赤が出て
   意味を失う。逆に API が落ちたのを 0 で返すと、依頼が出ていないことに誰も気付けない

宛先が Team ではなく User なのは実測による — **GITHUB_TOKEN は Team のノードを解決できず**
(GraphQL は null・`POST team_reviewers[]` は 422)、`POST reviewers[]=<User>` だけが通る
(#1232 の探り)。理由はスクリプトの冒頭にある。

gh は PATH の先頭に置いた偽物へ差し替える。偽物は **--jq を実際に適用する**ので、検査は
判定そのものを踏む (応答を素通しにすると、絞り込みの誤りが素通りする)。重要パスの判定は
**本物のルールセットを読む** — 写しを置くと、パスが動いたときに検査だけが古いままになる。

実行は make ci-check (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "rerequest-review.sh"

# --jq の値を取り出して本物の jq を当てる。応答は $PR_DIR の中の JSON から読む
FAKE_GH = """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALLS"

filter=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then filter=$a; fi
  prev=$a
done

emit() { # $1=JSON ファイル
  [ -f "$1" ] || { printf '%s' ""; return 0; }
  if [ -n "$filter" ]; then jq -r "$filter" < "$1"; else cat "$1"; fi
}

if [ "$1 $2" = "api graphql" ]; then emit "$PR_DIR/pr.json"; exit 0; fi

case "$*" in
  *requested_reviewers*)
    [ -z "${POST_FAILS:-}" ] || { echo "gh: HTTP 422" >&2; exit 1; }
    echo '{}'
    exit 0 ;;
  */files*)
    [ -z "${FILES_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
    emit "$PR_DIR/files.json"; exit 0 ;;
esac

echo "偽 gh が知らない呼び出し: $*" >&2
exit 1
"""

PROTECTED = ".github/workflows/review-request.yml"
UNPROTECTED = "Sources/MokumeCore/Draw.swift"


class RerequestReviewTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)

        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        gh = self.bin_dir / "gh"
        gh.write_text(FAKE_GH, encoding="utf-8")
        gh.chmod(0o755)

        self.pr_dir = root / "pr"
        self.pr_dir.mkdir()
        self.calls = root / "gh-calls.txt"
        self.calls.write_text("", encoding="utf-8")
        self.write_files([PROTECTED])

    def write_pr(self, *, reviews=(), pending=(), dismissed=("shinyaoguri",)):
        """GraphQL の応答を置く。dismissed は落とされた review の主。"""
        payload = {
            "data": {
                "repository": {
                    "pullRequest": {
                        "latestReviews": {
                            "nodes": [
                                {"state": s, "author": {"login": who}} for who, s in reviews
                            ]
                        },
                        "reviewRequests": {
                            "nodes": [
                                {"requestedReviewer": {"__typename": "User", "login": who}}
                                for who in pending
                            ]
                        },
                        "timelineItems": {
                            "nodes": [
                                {
                                    "createdAt": "2026-09-15T06:51:30Z",
                                    "review": {"author": {"login": who}},
                                }
                                for who in dismissed
                            ]
                        },
                    }
                }
            }
        }
        (self.pr_dir / "pr.json").write_text(json.dumps(payload), encoding="utf-8")

    def write_files(self, paths):
        (self.pr_dir / "files.json").write_text(
            json.dumps([{"filename": p} for p in paths]), encoding="utf-8"
        )

    def run_script(self, number="1234", **env_extra):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env['PATH']}"
        env["PR_DIR"] = str(self.pr_dir)
        env["GH_CALLS"] = str(self.calls)
        env["GITHUB_REPOSITORY"] = "mokume-metal/mokume"
        env.update(env_extra)
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), number],
            capture_output=True,
            text=True,
            env=env,
        )

    def posts(self):
        return [
            line
            for line in self.calls.read_text(encoding="utf-8").splitlines()
            if "requested_reviewers" in line
        ]

    # 1. 落ちた承認 → その主へ出し直す
    def test_dismissed_approval_is_rerequested(self):
        self.write_pr(reviews=[("shinyaoguri", "DISMISSED")])
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.posts()), 1, self.posts())
        self.assertIn("reviewers[]=shinyaoguri", self.posts()[0])
        self.assertIn("repos/mokume-metal/mokume/pulls/1234/requested_reviewers", self.posts()[0])
        self.assertIn("出し直した", result.stdout)

    # 2. いま承認が付いている → 打たない
    def test_live_approval_is_left_alone(self):
        self.write_pr(reviews=[("shinyaoguri", "APPROVED")])
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.posts(), [])
        self.assertIn("いま承認が付いている", result.stdout)

    # 3. 落とした出来事が無い → 打たない
    def test_never_approved_is_left_alone(self):
        self.write_pr(dismissed=())
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.posts(), [])
        self.assertIn("承認が落ちた出来事が無い", result.stdout)

    # 4. 依頼が既に残っている → 2 通目を出さない
    def test_pending_request_is_not_duplicated(self):
        self.write_pr(reviews=[("shinyaoguri", "DISMISSED")], pending=["shinyaoguri"])
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.posts(), [])
        self.assertIn("依頼が既に残っている", result.stdout)

    # 5. 承認が要らない PR → 打たない
    def test_pr_without_protected_path_is_left_alone(self):
        self.write_pr(reviews=[("shinyaoguri", "DISMISSED")])
        self.write_files([UNPROTECTED])
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.posts(), [])
        self.assertIn("承認が要らない PR", result.stdout)

    # 6. 変更ファイルが読めない → 出し直す側に倒す
    def test_unreadable_files_fall_back_to_rerequest(self):
        self.write_pr(reviews=[("shinyaoguri", "DISMISSED")])
        result = self.run_script(FILES_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.posts()), 1, self.posts())
        self.assertIn("変更ファイルを読めなかった", result.stdout)

    # 7. 打てなかったときだけ赤
    def test_failed_request_is_red(self):
        self.write_pr(reviews=[("shinyaoguri", "DISMISSED")])
        result = self.run_script(POST_FAILS="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("出し直せなかった", result.stderr)


if __name__ == "__main__":
    unittest.main()
