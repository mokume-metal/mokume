#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 専用機の self-hosted runner で、ジョブの始まりに作業ディレクトリを空にする (#878)。
#
# runner はリポジトリ単位で 1 度だけ登録した常駐のもので、ジョブの間でファイルシステムが
# 残る (ADR-0019 決定 7)。前のジョブが作業ディレクトリに残したもの (ビルドの成果物・
# 追跡外のファイル) の上で次のジョブが走ると、merge_group の結論 (必須チェック) が
# 前のジョブに左右されうる。**ビルドの成果物は持ち越さない** (メンテナの判断・
# 2026-09-28)。
#
# actions/checkout の clean も作業ツリーを掃除するが、あちらは checkout が成功した後の
# 話で、掃除するものも git の見える範囲に限る。ここはジョブの最初に、中身を問わず空にする。
#
# ## 専用機への置き方 (runner ユーザーで)
#
# runner は PR の木ではなく、専用機に写したこのファイルを実行する。**リポジトリの版を
# 直したら、専用機の写しも置き直す。**
#
#   install -m 755 scripts/runner-job-started.sh ~/actions-runner/job-started.sh
#   echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$HOME/actions-runner/job-started.sh" >> ~/actions-runner/.env
#   # runner を再起動して .env を読ませる (画面のセッションの LaunchAgent)
#   launchctl kickstart -k "gui/$(id -u)/$(basename ~/Library/LaunchAgents/actions.runner.*.plist .plist)"
#
# ## 使い方
#
#   bash scripts/runner-job-started.sh     (runner が GITHUB_WORKSPACE を渡して呼ぶ)
#
# **消すのは runner の作業場所の中だけ。** GITHUB_WORKSPACE が空か、`_work/<名前>/<名前>`
# の形でなければ何も消さずに赤で終える — 渡し間違いでホームを消さないため。
# テストは scripts/tests/runner_job_started_test.py。
set -euo pipefail

ws="${GITHUB_WORKSPACE:-}"
case "$ws" in
  */_work/*/*) ;;
  *)
    echo "runner-job-started: 作業ディレクトリが runner の作業場所の形でないので、何も消さない: '${ws}'" >&2
    exit 1
    ;;
esac

if [ ! -d "$ws" ]; then
  echo "runner-job-started: 作業ディレクトリはまだ無い (初回のジョブ): $ws"
  exit 0
fi

find "$ws" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
echo "runner-job-started: 作業ディレクトリを空にした: $ws"
