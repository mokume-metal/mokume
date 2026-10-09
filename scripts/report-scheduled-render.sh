#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 専用機の定期の検査の赤を発信する (#1983 / ADR-0019 決定 7 の段階 D)。
#
#   report-scheduled-render.sh <debug の結論> <debug の記録> <debug の test-log> \
#                              <release の結論> <release の記録> <release の test-log>
#
# 結論は専用機の job の `needs.<job>.result` (success / failure / cancelled / skipped)。
# 記録は xunit XML、test-log は検査の端末出力で、どれも artifact から落とした先のパスである。
# 記録と test-log は**無くてもよい** — ビルドで落ちた回は記録が無いので、そう名乗って
# 起票する (黙ると赤が誰にも届かない・#1295 と同じ形)。
#
# **結論を名乗るのは、記録が無い理由が結論で変わるからである** (#2084)。落ちて (failure)
# 記録が無いなら、検査が走る前 (ビルドかジョブの開始) に落ちている。切れて (cancelled)
# 記録が無いなら、検査が走っている途中で job の timeout か人の cancel に止められ、記録を
# 書き切れなかった — どこまで走ったかは test-log の末尾にある。結論を知らずに 1 通りの
# 案内を出すと、切れた回を「ビルドで落ちた」と読み違えさせる (#2211)。timeout と人の
# cancel は見分けない (ADR-0019 決定 7)。
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

[ $# -eq 6 ] || {
  echo "使い方: report-scheduled-render.sh <debug の結論> <debug の記録> <debug の test-log> <release の結論> <release の記録> <release の test-log>" >&2
  exit 64
}
DEBUG_RESULT="$1"
DEBUG_RECORD="$2"
DEBUG_LOG="$3"
RELEASE_RESULT="$4"
RELEASE_RECORD="$5"
RELEASE_LOG="$6"

here="$(dirname "${BASH_SOURCE[0]}")"

body=$(mktemp)
log=$(mktemp)
trap 'rm -f "$body" "$log"' EXIT

# job の結論と、落ちた検査の名前と文面。記録が無い・読めないときは read-test-record.py が
# そう名乗り、無い理由の読み方は結論ごとにここが添える (冒頭の「結論を名乗るのは」)
job_section() { # $1=見出し $2=結論 $3=記録
  printf '### %s\n\n' "$1"
  case "$2" in
    cancelled)
      printf '結論: `cancelled` — **job の timeout (`render.yml` の `timeout-minutes`) か、人の cancel で切れた。** どちらかは見分けない (ADR-0019 決定 7)。run の画面の annotation に `exceeded the maximum execution time` があれば timeout である\n\n'
      if [ -s "$3" ]; then
        python3 "$here/read-test-record.py" --failure-messages "$3"
      else
        printf '記録は、検査が書き切る前に切れたので無い (`%s`)。どこまで走ったかは、下の「検査の出力」の test-log の末尾で読む\n' "$3"
      fi
      ;;
    *)
      printf '結論: `%s`\n\n' "${2:-不明}"
      python3 "$here/read-test-record.py" --failure-messages "$3"
      if [ "$2" = failure ] && [ ! -s "$3" ]; then
        printf '\n落ちて記録が無いのは、検査が走る前 — ビルドかジョブの開始で落ちている。下の「検査の出力」と run の画面を読む\n'
      fi
      ;;
  esac
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
  printf '専用機の定期の検査 (`.github/workflows/render.yml` の schedule・[ADR-0019](%s) 決定 7 の段階 D) が緑で終わらなかった (落ちたか、切れた)。\n\n' "$adr_url"
  cat <<'BODY'
この検査が見ているのは、**どの PR の前提でもない、main の最新の木**である。GPU を要する検査は GitHub ホストでは飛ぶので、落ちるのは手元か専用機でだけ見える赤で、放っておくと誰にも読まれない (#1086 は 9 日間、そのまま main に残った)。

走らせているのは 2 つ:

- **debug**: `make ci-check CI_CHECK_STEPS="build test gpu-ran" CI=` (台帳を含む。`render` と同じ)
- **release**: `make test-release-scheduled` — release の検査から台帳 (`SceneLedgerTests`) だけを外したもの。release で台帳が合うべきかは #1736 が決める途中で、素で走らせると決着するまで毎回赤になるため外してある (代償: 台帳にだけ出る release の差は、この検査では見えない)

BODY
  job_section "debug" "$DEBUG_RESULT" "$DEBUG_RECORD"
  job_section "release" "$RELEASE_RESULT" "$RELEASE_RECORD"
  cat <<'BODY'
## 対処

1. 上の debug・release の節から、**どちらの実行が・どう終わったか** (落ちた検査・切れた) を読む。記録が無いときの読み方は、その節が結論ごとに添えている
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
