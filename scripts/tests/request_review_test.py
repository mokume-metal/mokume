#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/request-review.sh の検査 (#498)。

このスクリプトが埋めるのは「承認が要る PR にレビュー要求を飛ばす」4 象限の 1 マスだけ
で、ブロックの正本 (ルールセット / human-approval commit status) は触らない。だから
ここで固定したいのは 2 種類ある:

  投げる側  — 未要求・未レビュー・author でない owner には要求が飛ぶ
              承認が push で外れた (DISMISSED) ら投げ直す
  投げない側 — 既に要求済み (パス由来と重なった PR に 3 通目を作らない)
              既にレビュー済み (一度見た人へ投げ直さない)
              author 本人 (GitHub は自己要求に 422 を返す)

**失敗しても終了コードが 0 のまま**であることも固定する。要求の失敗がゲートの赤に
化けると「通知が届かない」が「マージできない」に化け、直したはずの害より大きくなる。

gh は PATH の先頭に置いた偽物へ差し替え、CODEOWNERS も一時ファイルへ差し替えるので、
ネットワークも認証も実ファイルの内容も要らない。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "request-review.sh"

# 実物と同じ形の CODEOWNERS (owner はメンテナ 1 人)
CODEOWNERS = """# 重要パス
/docs/decisions/ @shinyaoguri
/.github/        @shinyaoguri
/.claude/        @shinyaoguri
"""

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


def pr_json(author=APP, requested=(), reviews=()):
    """偽の gh pr view 応答。

    requested は Reviewers 欄に既に載っている login、reviews は (login, state) の組。
    reviewRequests はチームも返しうるので、実物と同じく login を持たない要素を混ぜる。
    """
    return json.dumps(
        {
            "author": {"login": author},
            "reviewRequests": (
                [{"__typename": "Team", "name": "maintainers"}]
                + [{"__typename": "User", "login": n} for n in requested]
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
        self.codeowners = Path(self.tmp.name) / "CODEOWNERS"
        self.codeowners.write_text(CODEOWNERS, encoding="utf-8")
        self.calls = Path(self.tmp.name) / "gh-calls"

    def run_script(self, pr, codeowners=None, api_status=0, pr_status=0):
        if codeowners is not None:
            self.codeowners.write_text(codeowners, encoding="utf-8")
        env = dict(os.environ)
        env["PATH"] = f"{self.bindir}:{env['PATH']}"
        env["FAKE_PR_JSON"] = pr
        env["FAKE_API_STATUS"] = str(api_status)
        env["FAKE_PR_STATUS"] = str(pr_status)
        env["GH_CALLS"] = str(self.calls)
        env["CODEOWNERS_FILE"] = str(self.codeowners)
        env["GITHUB_REPOSITORY"] = "mokume-metal/mokume"
        return subprocess.run(
            ["bash", str(SCRIPT), "42"],
            env=env, capture_output=True, text=True,
        )

    def requested_logins(self):
        """偽 gh へ渡った reviewers[]= の値。呼ばれていなければ空。"""
        if not self.calls.exists():
            return []
        text = self.calls.read_text(encoding="utf-8")
        return [
            word.split("=", 1)[1]
            for word in text.split()
            if word.startswith("reviewers[]=")
        ]

    def assert_requested(self, result, logins):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(self.requested_logins()), sorted(logins))

    # --- 投げる側 ---

    def test_requests_maintainer(self):
        """未要求・未レビュー・author でない owner には要求が飛ぶ (#498 の本題)。"""
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

    # --- 投げない側 ---

    def test_skips_when_already_requested(self):
        """既に Reviewers 欄に居るなら投げない。

        パス由来 (CODEOWNERS + ルールセット) と重なった PR には既に 2 通飛んでいる
        ので、ここが投げると 3 通目になる。
        """
        result = self.run_script(pr_json(requested=[MAINTAINER]))
        self.assert_requested(result, [])

    def test_skips_when_already_reviewed(self):
        """既にこの PR を見ている人へ投げ直さない。

        APPROVED なら review-gate が pending を出さないのでここまで来ず、
        CHANGES_REQUESTED は review-gate が差し戻す。実際に残るのは COMMENTED。
        """
        result = self.run_script(pr_json(reviews=[(MAINTAINER, "COMMENTED")]))
        self.assert_requested(result, [])

    def test_skips_author(self):
        """author 本人には投げない (GitHub は自己要求に 422 を返す)。"""
        result = self.run_script(pr_json(author=MAINTAINER))
        self.assert_requested(result, [])

    def test_skips_when_no_owner(self):
        """CODEOWNERS に owner が居なければ何もしない。"""
        result = self.run_script(pr_json(), codeowners="# owner なし\n")
        self.assert_requested(result, [])

    def test_ignores_team_entries(self):
        """CODEOWNERS のチーム表記は落とす (要求 API の配列が別)。"""
        result = self.run_script(
            pr_json(), codeowners="/.github/ @mokume-metal/maintainers\n"
        )
        self.assert_requested(result, [])

    # --- 失敗してもブロックに変えない ---

    def test_survives_api_failure(self):
        """要求 API が落ちても終了コードは 0。

        通知の失敗をマージのブロックに変えないため。fork からの PR では
        GITHUB_TOKEN が read-only になるので、この性質がそのまま要る。
        """
        result = self.run_script(pr_json(), api_status=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requested_logins(), [MAINTAINER])

    def test_survives_pr_view_failure(self):
        """PR を引けなくても終了コードは 0 で、要求は投げない。"""
        result = self.run_script(pr_json(), pr_status=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requested_logins(), [])


if __name__ == "__main__":
    unittest.main()
