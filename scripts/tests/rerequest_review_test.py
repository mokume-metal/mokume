#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/rerequest-review.sh の検査 (#1177)。

固定したいのは 6 つ。

1. **承認が落ちていたら、過去に依頼が飛んだチームへ出し直す。** これが無いと、押し直しが
   要ることに気付く経路が当番の赤だけになる (実測で数時間おき・#1197)
2. **いま承認が付いている PR には打たない。** 落ちていないか、既に押し直された後である
3. **承認が落ちた出来事が無い PR には打たない。** 一度も承認されていない PR に依頼を出すのは
   「出し直し」ではない
4. **依頼が既に残っていたら打たない。** 同じ PR に 2 通目を出さない (#1177 完了条件 3)
5. **チームへの依頼が飛んだことが無い PR には打たない。** 承認が要らない (重要パスに触れない)
   PR に依頼を出しても merge は進むので、通知だけが増える (#642)
6. **打てなかったときだけ非 0。** 打つ必要が無かったことを赤くすると、走るたびに赤が出て
   意味を失う。逆に API が落ちたのを 0 で返すと、依頼が出ていないことに誰も気付けない

宛先を「その PR の timeline に残る過去の依頼先」から採るのは、ルールセットが reviewer を
id でしか持たないためである (2 と 5 の分かれ目もここから出る)。

gh は PATH の先頭に置いた偽物へ差し替える。偽物は **--jq を実際に適用する**ので、検査は
判定そのものを踏む (応答を素通しにすると、絞り込みの誤りが素通りする)。

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

# --jq の値を取り出して本物の jq を当てる。応答は $PR_DIR/pr.json から読む
FAKE_GH = """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALLS"

filter=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then filter=$a; fi
  prev=$a
done

if [ "$1 $2" = "api graphql" ]; then
  [ -f "$PR_DIR/pr.json" ] || { echo "偽 gh: 応答が無い" >&2; exit 1; }
  if [ -n "$filter" ]; then jq -r "$filter" < "$PR_DIR/pr.json"; else cat "$PR_DIR/pr.json"; fi
  exit 0
fi

case "$*" in
  *requested_reviewers*)
    [ -z "${POST_FAILS:-}" ] || { echo "gh: HTTP 422" >&2; exit 1; }
    echo '{}'
    exit 0 ;;
esac

echo "偽 gh が知らない呼び出し: $*" >&2
exit 1
"""


def team(slug):
    return {"__typename": "Team", "slug": slug}


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

    def write_pr(self, *, reviews=(), pending=(), requested=(), dismissed=True):
        """GraphQL の応答を置く。requested は過去に依頼が飛んだチーム。"""
        nodes = [{"__typename": "ReviewRequestedEvent", "requestedReviewer": team(s)} for s in requested]
        if dismissed:
            nodes.append(
                {"__typename": "ReviewDismissedEvent", "createdAt": "2026-09-14T10:29:56Z"}
            )
        payload = {
            "data": {
                "repository": {
                    "pullRequest": {
                        "latestReviews": {"nodes": [{"state": s} for s in reviews]},
                        "reviewRequests": {
                            "nodes": [{"requestedReviewer": team(s)} for s in pending]
                        },
                        "timelineItems": {"nodes": nodes},
                    }
                }
            }
        }
        (self.pr_dir / "pr.json").write_text(json.dumps(payload), encoding="utf-8")

    def run_script(self, number="1174", **env_extra):
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

    # 1. 落ちた承認 → 出し直す
    def test_dismissed_approval_is_rerequested(self):
        self.write_pr(reviews=["DISMISSED"], requested=["maintainers"])
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.posts()), 1, self.posts())
        self.assertIn("team_reviewers[]=maintainers", self.posts()[0])
        self.assertIn("repos/mokume-metal/mokume/pulls/1174/requested_reviewers", self.posts()[0])
        self.assertIn("出し直した", result.stdout)

    # 2. いま承認が付いている → 打たない
    def test_live_approval_is_left_alone(self):
        self.write_pr(reviews=["APPROVED"], requested=["maintainers"])
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.posts(), [])
        self.assertIn("いま承認が付いている", result.stdout)

    # 3. 落とした出来事が無い → 打たない
    def test_never_approved_is_left_alone(self):
        self.write_pr(requested=["maintainers"], dismissed=False)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.posts(), [])
        self.assertIn("承認が落ちた出来事が無い", result.stdout)

    # 4. 依頼が既に残っている → 2 通目を出さない
    def test_pending_request_is_not_duplicated(self):
        self.write_pr(reviews=["DISMISSED"], pending=["maintainers"], requested=["maintainers"])
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.posts(), [])
        self.assertIn("依頼が既に残っている", result.stdout)

    # 5. チームへの依頼が飛んだことが無い → 打たない
    def test_pr_without_team_request_is_left_alone(self):
        self.write_pr(reviews=["DISMISSED"])
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.posts(), [])
        self.assertIn("チームへの依頼が飛んだことが無い", result.stdout)

    # 6. 打てなかったときだけ赤
    def test_failed_request_is_red(self):
        self.write_pr(reviews=["DISMISSED"], requested=["maintainers"])
        result = self.run_script(POST_FAILS="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("出し直せなかった", result.stderr)


if __name__ == "__main__":
    unittest.main()
