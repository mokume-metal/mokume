#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/request-review.sh の検査 (#498)。

このスクリプトが埋めるのは「承認が要る PR にレビュー要求を飛ばす」4 象限の 1 マスだけ
で、ブロックの正本 (ルールセット / human-approval commit status) は触らない。だから
ここで固定したいのは 2 種類ある:

  投げる側  — 未要求・未レビューならメンテナ (user) へ要求が飛ぶ
              承認が push で外れた (DISMISSED) ら投げ直す
  投げない側 — 既に team へ要求が飛んでいる (パス由来と重なった PR に 2 通目を作らない)
              既に同じ user へ要求が飛んでいる (CI の走り直しで 2 通目を作らない)
              既にレビュー済み (一度見た人へ投げ直さない)

**宛先が user であることも固定する。** 一度 team へ揃えたが、GITHUB_TOKEN は org
スコープを持たないので team_reviewers は 422 で落ちた (#576)。ここは偽 gh なので
422 自体は再現しないが、投げる先の綴りが変わったら気付ける。

**声が掛かったかを終了コードで返す**ことも固定する (#577)。0 は投げた / 投げる必要が
無かった、20 は投げようとして失敗した。ci.yml が set +e で受けて human-approval の
description へ回すので、**20 でもゲートは赤くならない** — 要求の失敗がゲートの赤に
化けると「通知が届かない」が「マージできない」に化け、直したはずの害より大きくなる。
赤くしないことと、黙ることは別である。

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
#   gh api -X POST repos/<repo>/pulls/<n>/requested_reviewers -f 'reviewers[]=<login>' --silent
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

    def run_script(self, pr, user=None, api_status=0, pr_status=0):
        env = dict(os.environ)
        env["PATH"] = f"{self.bindir}:{env['PATH']}"
        env["FAKE_PR_JSON"] = pr
        env["FAKE_API_STATUS"] = str(api_status)
        env["FAKE_PR_STATUS"] = str(pr_status)
        env["GH_CALLS"] = str(self.calls)
        if user is not None:
            env["MAINTAINERS_USER"] = user
        env["GITHUB_REPOSITORY"] = "mokume-metal/mokume"
        return subprocess.run(
            ["bash", str(SCRIPT), "42"],
            env=env, capture_output=True, text=True,
        )

    def requested_reviewers(self):
        """偽 gh へ渡った reviewers[]= の値。呼ばれていなければ空。

        team_reviewers[]= は前方一致しないので、宛先を team へ戻す変更が入れば
        ここが空になって落ちる。
        """
        if not self.calls.exists():
            return []
        text = self.calls.read_text(encoding="utf-8")
        return [
            word.split("=", 1)[1]
            for word in text.split()
            if word.startswith("reviewers[]=")
        ]

    def assert_requested(self, result, reviewers):
        """投げた / 投げる必要が無かった側は 0 を返す (#577)。"""
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(self.requested_reviewers()), sorted(reviewers))

    # --- 投げる側 ---

    def test_requests_the_maintainer(self):
        """未要求・未レビューならメンテナへ要求が飛ぶ (#498 の本題)。"""
        result = self.run_script(pr_json())
        self.assert_requested(result, [MAINTAINER])

    def test_requests_again_after_dismissal(self):
        """承認が push で外れたら投げ直す。

        ルールセットが dismiss_stale_reviews_on_push: true なので、承認後の push で
        承認は外れる。パス由来は GitHub が自動で再要求するが、ラベル由来はここが
        投げ直さないと「承認が外れたのに誰も知らない」に戻る。
        """
        result = self.run_script(pr_json(reviews=[(MAINTAINER, "DISMISSED")]))
        self.assert_requested(result, [MAINTAINER])

    def test_maintainer_is_overridable(self):
        """宛先は 1 か所で決まる (承認を課している集合の正典はルールセットの team)。"""
        result = self.run_script(pr_json(), user="someone-else")
        self.assert_requested(result, ["someone-else"])

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

    def test_skips_when_the_maintainer_is_already_requested(self):
        """既に同じ user へ要求が飛んでいるなら投げない。

        CI は Approve やラベルの付け外しでも走り直すので、見ないと同じ人へ 2 通目を
        作る。宛先が team だった頃はこの経路が無かった (#576)。
        """
        result = self.run_script(pr_json(users=[MAINTAINER]))
        self.assert_requested(result, [])

    def test_another_users_request_does_not_suppress_ours(self):
        """別の人への要求は、メンテナへの声掛けの代わりにならない。"""
        result = self.run_script(pr_json(users=["someone-else"]))
        self.assert_requested(result, [MAINTAINER])

    # --- 届かなかったことは 20 で返す (ブロックには変えない) ---

    def test_reports_undelivered_when_the_api_fails(self):
        """要求 API が落ちたら 20。

        ci.yml が set +e で受けて human-approval の description へ回すので、
        ゲートは赤くならない。0 で返すと「届かなかった」が success したジョブの
        ログにしか残らない (#577)。fork からの PR では GITHUB_TOKEN が read-only に
        なるので、この経路は実際に通る。
        """
        result = self.run_script(pr_json(), api_status=1)
        self.assertEqual(result.returncode, 20, result.stderr)
        self.assertEqual(self.requested_reviewers(), [MAINTAINER])

    def test_reports_undelivered_when_the_pr_cannot_be_read(self):
        """PR を引けなければ投げようがないので 20。要求も投げない。

        声が掛かっていないという点で、投げて失敗したときと変わらない。
        """
        result = self.run_script(pr_json(), pr_status=1)
        self.assertEqual(result.returncode, 20, result.stderr)
        self.assertEqual(self.requested_reviewers(), [])


if __name__ == "__main__":
    unittest.main()
