#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 専用機の定期の検査の赤を発信する (#1983 / ADR-0019 決定 7 の段階 D)。
#
#   report-scheduled-render.sh <debug の記録> <debug の test-log> <release の記録> <release の test-log>
#
# 記録は xunit XML、test-log は検査の端末出力。どれも artifact から落とした先のパスで、
# **無くてもよい** — ビルドで落ちた回は記録が無いので、そう名乗って起票する (黙ると赤が
# 誰にも届かない・#1295 と同じ形)。
#
# 発信の実体は scripts/report-check-failure.sh が持ち、ここが持つのは**固定タイトルと本文**
# だけである (report-dead-assets.sh と同じ分け方)。落ちた検査の名前と文面は
# scripts/read-test-record.py --failure-messages が読む。
#
# 呼ぶのは .github/workflows/render.yml の scheduled-report で、GitHub ホストのジョブである。
# **`issues: write` を持つのはそのジョブだけ**で、専用機のジョブは contents: read・秘密なしの
# まま (ADR-0019 決定 7 の前提)。後続ジョブは専用機のジョブの結論と記録の artifact を読む
# だけである。検査は scripts/tests/scheduled_report_test.py。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"

# 重複起票を防ぐための固定タイトル。文言を変えると、変える前に立った Issue が
# 見つからなくなり二重に立つので、変えるときは open な分を先に畳む。
# 接頭辞が `fix(` なので triage.sh が Bug を付ける — 動いていたものが赤になった事象で、
# AGENTS.md の「迷ったら Bug > Design > Docs > Task」に従う
readonly TITLE="fix(render): 専用機の定期の検査が落ちている"

[ $# -eq 4 ] || {
  echo "使い方: report-scheduled-render.sh <debug の記録> <debug の test-log> <release の記録> <release の test-log>" >&2
  exit 64
}
DEBUG_RECORD="$1"
DEBUG_LOG="$2"
RELEASE_RECORD="$3"
RELEASE_LOG="$4"

here="$(dirname "${BASH_SOURCE[0]}")"

body=$(mktemp)
log=$(mktemp)
trap 'rm -f "$body" "$log"' EXIT

# 落ちた検査の名前と文面。記録が無い・読めないときは read-test-record.py がそう名乗る
failure_section() { # $1=見出し $2=記録
  printf '### %s\n\n' "$1"
  python3 "$here/read-test-record.py" --failure-messages "$2"
  printf '\n'
}

# 端末出力の末尾。落ちた理由は後ろに出る。上限は report-check-failure.sh の 200 行に収める
log_tail() { # $1=見出し $2=test-log
  printf '=== %s ===\n' "$1"
  if [ -s "$2" ]; then
    tail -n 90 "$2"
  else
    printf '(test-log が無い: %s)\n' "$2"
  fi
}

{
  log_tail "debug (make ci-check の build・test・gpu-ran)" "$DEBUG_LOG"
  log_tail "release (make test-release-scheduled)" "$RELEASE_LOG"
} > "$log"

# Issue 本文の相対リンクは解決されないので、ADR へは絶対 URL で張る
adr_url="${GITHUB_SERVER_URL:-https://github.com}/$REPO/blob/main/docs/decisions/0019-drawing-verification.md"

{
  printf '専用機の定期の検査 (`.github/workflows/render.yml` の schedule・[ADR-0019](%s) 決定 7 の段階 D) が落ちた。\n\n' "$adr_url"
  cat <<'BODY'
この検査が見ているのは、**どの PR の前提でもない、main の最新の木**である。GPU を要する検査は GitHub ホストでは飛ぶので、落ちるのは手元か専用機でだけ見える赤で、放っておくと誰にも読まれない (#1086 は 9 日間、そのまま main に残った)。

走らせているのは 2 つ:

- **debug**: `make ci-check CI_CHECK_STEPS="build test gpu-ran" CI=` (台帳を含む。`render` と同じ)
- **release**: `make test-release-scheduled` — release の検査から台帳 (`SceneLedgerTests`) だけを外したもの。release で台帳が合うべきかは #1736 が決める途中で、素で走らせると決着するまで毎回赤になるため外してある (代償: 台帳にだけ出る release の差は、この検査では見えない)

BODY
  failure_section "debug" "$DEBUG_RECORD"
  failure_section "release" "$RELEASE_RECORD"
  cat <<'BODY'
## 対処

1. 上の「落ちた検査」から、**どちらの実行で・どの検査が**落ちたかを読む。記録が無いと名乗っているときは、ビルドかジョブの開始で落ちている (下の「検査の出力」と run の画面を読む)
2. 手元で再現する (どちらも GPU が要る):
   - debug: `make ci-check CI_CHECK_STEPS="build test gpu-ran"`
   - release: `make test-release-scheduled`
3. 落ちた検査が同じ根の PR で入ったものなら、その PR か Issue に戻して直す。台帳の行が動いたのなら、書き換える前に絵を目で見る (ADR-0019 決定 3)。絵は run の artifact の `ledger-shots` にある

## 解消の判定

手元で上の 2 つが緑になり、**次の定期の run (6 時間以内) も緑になれば解消**。定期の run は `workflow_dispatch` を持たない (ADR-0019 決定 7) ので、手で起こさず次の回を待つ。

**解消したらこの Issue を閉じる。** open な間は重複起票を抑えるので、残したままにすると次の赤が起票されない。
BODY
} > "$body"

bash "$here/report-check-failure.sh" \
  --title "$TITLE" \
  --log "$log" \
  --body-file "$body" \
  --source '.github/workflows/render.yml の scheduled-report が自動起票した (#1983)'
