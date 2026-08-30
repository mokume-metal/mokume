#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/request-review.sh の検査 (#498)。

このスクリプトが埋めるのは「承認が要る PR にレビュー要求を飛ばす」4 象限の 1 マスだけ
で、ブロックの正本 (ルールセット / human-approval commit status) は触らない。だから
ここで固定したいのは 2 種類ある:

  投げる側  — 未要求・未レビューなら maintainers team へ要求が飛ぶ
              承認が push で外れた (DISMISSED) ら投げ直す
  投げない側 — 既に team へ要求が飛んでいる (パス由来と重なった PR に 2 通目を作らない)
              既にレビュー済み (一度見た人へ投げ直さない)

**失敗しても終了コードが 0 のまま**であることも固定する。要求の失敗がゲートの赤に
化けると「通知が届かない」が「マージできない」に化け、直したはずの害より大きくなる。

gh は PATH の先頭に置いた偽物へ差し替えるので、ネットワークも認証も要らない。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "request-review.sh"

# 偽 gh。request-review が呼ぶのは 2 つだけ:
#   gh pr view <n> -R <repo> --json author,reviewRequests,latestReviews
#   gh api -X POST repos/<repo>/pulls/<n>/requested_reviewers -f 'team_reviewers[]=<slug>' --silent
# 前者は環境変数の JSON を返し (FAKE_PR_STATUS が 0 以外なら失敗を演じる)、
# 後者は引数を GH_CALLS へ記録する。要求が飛んだかはこのファイルの中身で判定する
FAKE_GH = """#!/bin/sh
case "$1 $2" in
  "pr view")
    [ "${FAKE_PR_STATUS:-0}" = "0" ] || { echo "boom" >&2; exit "$FAKE_PR_STATUS"; }
    printf '%s' "$FAKE_PR_JSON"
    ;;
  "api "*)
    printf '%s\\n' "$*" >> "$GH_CALLS"
    exit "${FAKE_API_STATUS:-0}"
    ;;
  *) exit 1 ;;
esac
"""

APP = "app/mokume-agent"
MAINTAINER = "shinyaoguri"
TEAM = "maintainers"


def pr_json(author=APP, teams=(), users=(), reviews=()):
    """偽の gh pr view 応答。

    teams / users は Reviewers 欄に既に載っている要求、reviews は (login, state) の組。
    **チームの要素は login を持たない** — 要求済みの判定はこの違いだけに頼るので、
    綴り (name / slug / __typename) が変わっても壊れない。
    """
    return json.dumps(
        {
            "author": {"login": author},
            "reviewRequests": (
                [{"__typename": "Team", "name": n, "slug": n} for n in teams]
                + [{"__typename": "User", "login": n} for n in users]
            ),
            "latestReviews": [
                {"author": {"login": n}, "state": s} for n, s in reviews
            ],
        }
    )


class RequestReviewTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bindir = Path(self.tmp.name) / "bin"
        self.bindir.mkdir()
        stub = self.bindir / "gh"
        stub.write_text(FAKE_GH, encoding="utf-8")
        stub.chmod(0o755)
        self.calls = Path(self.tmp.name) / "gh-calls"

    def run_script(self, pr, team=None, api_status=0, pr_status=0):
        env = dict(os.environ)
        env["PATH"] = f"{self.bindir}:{env['PATH']}"
        env["FAKE_PR_JSON"] = pr
        env["FAKE_API_STATUS"] = str(api_status)
        env["FAKE_PR_STATUS"] = str(pr_status)
        env["GH_CALLS"] = str(self.calls)
        if team is not None:
            env["MAINTAINERS_TEAM"] = team
        env["GITHUB_REPOSITORY"] = "mokume-metal/mokume"
        return subprocess.run(
            ["bash", str(SCRIPT), "42"],
            env=env, capture_output=True, text=True,
        )

    def requested_teams(self):
        """偽 gh へ渡った team_reviewers[]= の値。呼ばれていなければ空。"""
        if not self.calls.exists():
            return []
        text = self.calls.read_text(encoding="utf-8")
        return [
            word.split("=", 1)[1]
            for word in text.split()
            if word.startswith("team_reviewers[]=")
        ]

    def assert_requested(self, result, teams):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(self.requested_teams()), sorted(teams))

    # --- 投げる側 ---

    def test_requests_maintainers_team(self):
        """未要求・未レビューなら team へ要求が飛ぶ (#498 の本題)。"""
        result = self.run_script(pr_json())
        self.assert_requested(result, [TEAM])

    def test_requests_again_after_dismissal(self):
        """承認が push で外れたら投げ直す。

        ルールセットが dismiss_stale_reviews_on_push: true なので、承認後の push で
        承認は外れる。パス由来は GitHub が自動で再要求するが、ラベル由来はここが
        投げ直さないと「承認が外れたのに誰も知らない」に戻る。
        """
        result = self.run_script(pr_json(reviews=[(MAINTAINER, "DISMISSED")]))
        self.assert_requested(result, [TEAM])

    def test_team_slug_is_overridable(self):
        """宛先の team は 1 か所で決まる (正典はルールセットの reviewer)。"""
        result = self.run_script(pr_json(), team="other-team")
        self.assert_requested(result, ["other-team"])

    # --- 投げない側 ---

    def test_skips_when_a_team_is_already_requested(self):
        """既に team へ要求が飛んでいるなら投げない。

        パス由来 (ルールセットの required_reviewers) と重なった PR には既に 1 通
        飛んでいる。ここが投げると同じ人に 2 通目が届く — #530 で畳んだ重複の再来。
        """
        result = self.run_script(pr_json(teams=[TEAM]))
        self.assert_requested(result, [])

    def test_skips_when_already_reviewed(self):
        """既にこの PR を見ている人が居るなら投げない。

        APPROVED なら review-gate が pending を出さないのでここまで来ず、
        CHANGES_REQUESTED は review-gate が差し戻す。実際に残るのは COMMENTED。
        """
        result = self.run_script(pr_json(reviews=[(MAINTAINER, "COMMENTED")]))
        self.assert_requested(result, [])

    def test_a_pending_user_request_does_not_suppress_the_team(self):
        """user 宛の要求は team の代わりにならない。

        誰か 1 人に声が掛かっていても、承認を課されているのは team である。
        login を持つ要素をチーム要求と読み違えると、ここが黙って素通りする。
        """
        result = self.run_script(pr_json(users=[MAINTAINER]))
        self.assert_requested(result, [TEAM])

    # --- 失敗してもブロックに変えない ---

    def test_survives_api_failure(self):
        """要求 API が落ちても終了コードは 0。

        通知の失敗をマージのブロックに変えないため。fork からの PR では
        GITHUB_TOKEN が read-only になるので、この性質がそのまま要る。
        """
        result = self.run_script(pr_json(), api_status=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requested_teams(), [TEAM])

    def test_survives_pr_view_failure(self):
        """PR を引けなくても終了コードは 0 で、要求は投げない。"""
        result = self.run_script(pr_json(), pr_status=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requested_teams(), [])


if __name__ == "__main__":
    unittest.main()
