#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 描画の検査が走ったことを local-render として commit status に報告する (#304)。
#
# CI はこの世代のコマンド構造を持たない GPU の上で動くので、絵を作る検査を 1 本も
# 走らせられない (#180・ADR-0019 決定 7 で恒久の決定)。走らせられるのは手元だけで、
# 走らせたかどうかを GitHub が知る経路がこれまで無かった — 打ち忘れた PR が緑で
# 通っていた。
#
# そこで **報告する主体を Actions ではなく手元の実行**にする。check run ではなく
# commit status を選ぶのは #282 と同じ理由 (suite に縛られず、同じ context の最新が
# 常に勝つ)。
#
# ## 使い方
#
#   bash scripts/render-status.sh local   # make ci-check の最後。全検査が通ったときだけ打つ
#   bash scripts/render-status.sh proxy   # CI から。打たなくてよい場合の代理報告だけ
#
# ## 何を防いでいるか
#
# 防いでいるのは**打ち忘れ**であって、意図的な偽装ではない。status の 1 行は手でも
# 打てる。偽装はまだ起きていないので、いまは対象にしない (ADR-0008 決定 1)。
#
# どちらのモードも**失敗しない** — 報告しない理由を述べて 0 で終える。報告が無い
# ことは GitHub 側で「必須チェックの待ち」として現れるので、ここで赤くする必要が無い。
set -euo pipefail

# 「描画に触れているか」の判定は #306 と共有する (照合の実体は 1 つ)
# shellcheck source=scripts/drawing-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/drawing-paths.sh"

readonly CONTEXT=local-render
# scene-ledger の suite 名。**この名前が走って通ったこと**を、GPU のある機械で
# 全検査が回った証拠として使う (SceneLedgerTests.swift の @Suite 名と一致させる)。
readonly LEDGER_SUITE='代表シーンの台帳'

TEST_LOG=${RENDER_TEST_LOG:-.build/test-log.txt}
LEDGER=${RENDER_LEDGER:-Tests/MokumeCoreTests/scene-ledger.txt}

say() { echo "$CONTEXT: $*"; }
give_up() { say "報告しない — $1"; exit 0; }

# 対象リポジトリを origin から導く (owner/repo)。
resolve_repo() {
  local url
  url=$(git config --get remote.origin.url || true)
  [ -n "$url" ] || return 1
  url=${url%.git}
  url=${url#git@github.com:}
  url=${url#https://github.com/}
  printf '%s' "$url"
}

# 報告できなくても**失敗しない**。いちばん多い理由は「まだ push していない」で、
# それは作業の途中というだけである (remote に無い commit へは status を打てない)。
# push のあとに make render-status をもう一度打てば、同じ記録から報告し直せる。
post() {
  local repo=$1 sha=$2 description=$3
  if gh api -X POST "repos/$repo/statuses/$sha" \
    -f state=success -f context="$CONTEXT" -f description="$description" --silent; then
    say "報告: $sha → success ($description)"
  else
    say "報告できなかった — この commit がまだ remote に無いか、権限が無い"
    say "push してから make render-status を打つと、同じ記録から報告し直せる"
  fi
}

mode=${1:-}
case "$mode" in
  local)
    # 1. 走らせたものと HEAD が指すものが同じでなければ、報告に意味が無い
    [ -z "$(git status --porcelain)" ] || give_up "作業ツリーが汚れている"

    # 2. テストの記録が要る (make の test ターゲットが残す)
    [ -f "$TEST_LOG" ] || give_up "テストの記録が無い ($TEST_LOG)"

    # 3. **台帳の suite が通っていること**を、絵の検査が実際に回った証拠にする。
    #    スキップの数を数えるのではなく、走ってほしいものが走ったかを見る —
    #    出力の書式が変わったときに、黙って通る側へ倒れないため
    grep -q "Suite \"$LEDGER_SUITE\".*passed" "$TEST_LOG" \
      || give_up "「${LEDGER_SUITE}」が通っていない (この世代の GPU が無い機械の実行)"

    # 4. 報告先と資格情報。CI からここへ来ても、認証が無いのでここで止まる
    command -v gh >/dev/null 2>&1 || give_up "gh が無い"
    gh auth status >/dev/null 2>&1 || give_up "gh が認証されていない"
    repo=$(resolve_repo) || give_up "origin が無い"

    skipped=$(grep -c 'skipped:' "$TEST_LOG" || true)
    ledger_digest=$(grep -vE '^[[:space:]]*(#|$)' "$LEDGER" | shasum -a 256 | cut -c1-8)
    post "$repo" "$(git rev-parse HEAD)" \
      "手元で全検査が通った skipped=$skipped ledger=$ledger_digest"
    ;;

  proxy)
    # CI からの代理報告。**描画に触れている PR には打たない** — 打たないことが
    # そのまま「手元の報告待ち」になる。pending を打たないのは順序の危険を避ける
    # ためで、手元の報告が CI より先に届くことがあるから (後から pending を打つと
    # 成立した報告を打ち消す)。
    : "${GITHUB_REPOSITORY:?}" "${GITHUB_EVENT_NAME:?}"
    if [ "$GITHUB_EVENT_NAME" = "merge_group" ]; then
      # queue が作る SHA には手元の報告が付きようがない。PR 段階で必須チェックとして
      # 既に効いているので無条件に通す (human-approval と同じ理屈)。**必須チェックは
      # merge queue でも報告が要る** — 報告が無いと queue が待ち続ける
      post "$GITHUB_REPOSITORY" "${MERGE_GROUP_SHA:?}" "merge queue (PR 段階で満たされている)"
      exit 0
    fi

    if gh api "repos/$GITHUB_REPOSITORY/pulls/${PR_NUMBER:?}/files" --paginate \
      --jq '.[].filename' | touches_drawing; then
      say "描画に触れている PR — 手元の報告を待つ (報告しない)"
      exit 0
    fi
    post "$GITHUB_REPOSITORY" "${PR_HEAD_SHA:?}" "描画に触れていない"
    ;;

  *)
    echo "使い方: $0 local|proxy" >&2
    exit 2
    ;;
esac
