#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ホストの定期の TSan の検査 (host-scheduled.yml の tsan) の赤を発信する (#3220)。
#
#   report-tsan.sh <結論> <記録> <test-log>
#
# 結論は `needs.tsan.result` (failure / cancelled)。記録は xunit XML、test-log は検査の端末
# 出力で、どちらも artifact から落とした先のパスである。**無くてもよい** — ビルドで落ちた回や、
# TSan が検査のプロセスを止めた回は記録が無いので、そう名乗って起票する (#1295 と同じ形)。
#
# **競合の報告は記録 (xunit) に載らない。** TSan は検査のプロセスの stderr に
# `WARNING: ThreadSanitizer: data race` の塊を書き、xunit が持つのは落ちた検査の名前だけである。
# 本文には test-log から `SUMMARY: ThreadSanitizer:` の行 (競合した箇所の 1 行) を全部と、
# 最初の報告の塊を抜いて載せる。末尾の tail だけでは、塊が出力の途中に埋もれる。
#
# 発信の実体は scripts/report-check-failure.sh が持ち、ここが持つのは**固定タイトルと本文**
# だけである (report-release-check.sh と同じ分け方)。鍵は本文で、競合の箇所か落ちた検査が
# 変われば追記になり、同じ落ち方が続く間は本文の区画だけが書き換わる (#2708)。
#
# 呼ぶのは host-scheduled.yml の tsan-report で、GitHub ホストのジョブである。
# **`issues: write` を持つのはそのジョブだけ**で、検査を走らせる tsan には持たせない。
# 形は scripts/tests/host_scheduled_workflow_test.py、本文は scripts/tests/report_tsan_test.py。
set -euo pipefail

# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"

# 重複起票を防ぐための固定タイトル。文言を変えると、変える前に立った Issue が
# 見つからなくなり二重に立つので、変えるときは open な分を先に畳む。
# 接頭辞が `fix(` なので triage.sh が Bug を付ける — 競合は検査が緑でも在った誤りである
readonly TITLE="fix(test): 定期の TSan の検査が落ちた (データ競合か、TSan の下で走らない検査)"

[ $# -eq 3 ] || {
  echo "使い方: report-tsan.sh <結論> <記録> <test-log>" >&2
  exit 64
}
RESULT="$1"
RECORD="$2"
LOG="$3"

here="$(dirname "${BASH_SOURCE[0]}")"

body=$(mktemp)
log=$(mktemp)
trap 'rm -f "$body" "$log"' EXIT

# 端末出力の末尾。上限は report-check-failure.sh の 200 行に収める
{
  printf '=== TSan (make test-tsan) ===\n'
  if [ -s "$LOG" ]; then
    tail -n 180 "$LOG"
  else
    printf '(test-log が無い: %s)\n' "$LOG"
  fi
} > "$log"

{
  cat <<'BODY'
ホストの定期の TSan の検査 (`.github/workflows/host-scheduled.yml` の `tsan`) が緑で終わらなかった (落ちたか、切れた)。

見ているのは、その回の main の木を GitHub ホストの `macos-26` で `make test-tsan` (`swift test --sanitize=thread`) したものである。描画の検査はホストでは飛ぶので、CPU の suite だけが TSan の下で走る。**TSan の赤は検査の値が合っていても出る** — 値の整合しか見ない検査を緑のまま通った競合 (#2916) を拾うための検査である。

BODY
  printf '## 結論\n\n'
  case "$RESULT" in
    cancelled)
      printf '結論: `cancelled` — **job の timeout (`host-scheduled.yml` の `timeout-minutes`) か、人の cancel で切れた。** TSan は検査を数倍遅くするので、期限を持つ検査 (待つ側が期限を持つ形) が先に越えることもある。どこまで走ったかは下の「検査の出力」の末尾で読む\n\n'
      ;;
    *)
      printf '結論: `%s`\n\n' "${RESULT:-不明}"
      ;;
  esac
  printf '## TSan の報告\n\n'
  if [ -s "$LOG" ] && grep -q 'ThreadSanitizer' "$LOG"; then
    printf '競合した箇所 (`SUMMARY:` の行・重複を畳んだ):\n\n```\n'
    grep -o 'SUMMARY: ThreadSanitizer:.*' "$LOG" | sort -u | sed -n '1,40p' || true
    printf '```\n\n最初の報告:\n\n```\n'
    # 塊は `WARNING: ThreadSanitizer:` から `SUMMARY: ThreadSanitizer:` まで。長すぎる塊は切る
    awk '/WARNING: ThreadSanitizer:/ { on = 1 } on { print; n++ } /SUMMARY: ThreadSanitizer:/ && on { exit } n >= 80 { exit }' "$LOG"
    printf '```\n\n'
  else
    printf 'test-log に TSan の報告は無い — 競合ではなく、ビルドか検査そのものが落ちたか、切れた。下の落ちた検査と出力を読む\n\n'
  fi
  printf '## 落ちた検査\n\n'
  python3 "$here/read-test-record.py" --failure-messages "$RECORD"
  printf '\n'
  cat <<'BODY'

## 対処

1. 上の報告から、競合か (TSan の報告がある)、ビルド・検査の赤か、期限切れかを読む
2. 手元で再現する: `make test-tsan TEST_TSAN_ARGS='--filter <落ちた Suite>'` (素で打つと描画の検査も TSan の下で走る — 理由は `Makefile` の `test-tsan` の上)
3. 競合なら、報告の 2 つのアクセスの片方を同期に入れて直し、直す前の版で同じ報告が出る最小の検査を足す。TSan の誤報 (Apple の framework の内部など) と読むなら、抑える前に理由を Issue に書く

## 解消の判定

直す PR が merge された後、**次の定期の `host-scheduled.yml` の run (`workflow_dispatch` で起こしてもよい) で `tsan` が緑になれば解消**。

**解消したらこの Issue を閉じる。** open な間は、次の赤は新しく立たずにこの Issue へ追記される (#2658)。**閉じる前に、追記された分も同じ直しで解けたかを確かめる** — 別の競合なら、閉じる前に別の Issue へ起こす。
BODY
} > "$body"

bash "$here/report-check-failure.sh" \
  --title "$TITLE" \
  --log "$log" \
  --body-file "$body" \
  --key-file "$body" \
  --source '.github/workflows/host-scheduled.yml の tsan-report が自動起票した (#3220)'
