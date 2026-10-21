#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 版を出す前の release の検査 (release.yml の release-check) の赤を発信する (#2662)。
#
#   report-release-check.sh <結論> <記録> <test-log>
#
# 結論は release-check の `needs.release-check.result` (failure / cancelled)。記録は xunit XML、
# test-log は検査の端末出力で、どちらも artifact から落とした先のパスである。記録と test-log は
# **無くてもよい** — ビルドで落ちた回は記録が無いので、そう名乗って起票する (黙ると赤が誰にも
# 届かない・#1295 と同じ形)。
#
# **この赤が届いた日は、版が出ていない。** release-check が緑のときだけ release がタグを打つ
# (release.yml)。本文はそれを名乗り、直す PR が merge されれば次の日次で出ることを案内する。
#
# 発信の実体は scripts/report-check-failure.sh が持ち、ここが持つのは**固定タイトルと本文**
# だけである (report-scheduled-render.sh と同じ分け方)。落ちた検査の名前と文面は
# scripts/read-test-record.py --failure-messages が読む。
#
# 呼ぶのは release.yml の release-check-report で、GitHub ホストのジョブである。
# **`issues: write` を持つのはそのジョブだけ**で、検査を走らせる release-check には持たせない。
# 検査は scripts/tests/release_check_report_test.py。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"

# 重複起票を防ぐための固定タイトル。文言を変えると、変える前に立った Issue が
# 見つからなくなり二重に立つので、変えるときは open な分を先に畳む。
# 接頭辞が `fix(` なので triage.sh が Bug を付ける — 動いていたものが赤になった事象である
readonly TITLE="fix(release): 下限 OS の release の検査が落ちて、版を見送っている"

[ $# -eq 3 ] || {
  echo "使い方: report-release-check.sh <結論> <記録> <test-log>" >&2
  exit 64
}
RESULT="$1"
RECORD="$2"
LOG="$3"

here="$(dirname "${BASH_SOURCE[0]}")"

body=$(mktemp)
log=$(mktemp)
trap 'rm -f "$body" "$log"' EXIT

# 端末出力の末尾。落ちた理由は後ろに出る。上限は report-check-failure.sh の 200 行に収める
{
  printf '=== release (make test-release) ===\n'
  if [ -s "$LOG" ]; then
    tail -n 180 "$LOG"
  else
    printf '(test-log が無い: %s)\n' "$LOG"
  fi
} > "$log"

{
  cat <<'BODY'
版を出す前の release の検査 (`.github/workflows/release.yml` の `release-check`) が緑で終わらなかった (落ちたか、切れた)。**この回は版を出していない** — 版は、この検査が緑の SHA にだけ打つ (#2662)。

見ているのは、**版にしようとした main の木**を下限 OS (GitHub ホストの `macos-26`) で `make test-release` したものである。GPU を要する検査は GitHub ホストではスキップされる (GPU 付きの release は専用機の定期が見る)。release でだけ出る赤は merge の前には止めないので、main には入りうる。

BODY
  printf '## 結論\n\n'
  case "$RESULT" in
    cancelled)
      printf '結論: `cancelled` — **job の timeout (`release.yml` の `timeout-minutes`) か、人の cancel で切れた。** 記録が無ければ、どこまで走ったかは下の「検査の出力」の末尾で読む\n\n'
      ;;
    *)
      printf '結論: `%s`\n\n' "${RESULT:-不明}"
      ;;
  esac
  python3 "$here/read-test-record.py" --failure-messages "$RECORD"
  printf '\n'
  cat <<'BODY'

## 対処

1. 上の落ちた検査 (記録が無ければ下の「検査の出力」) から、ビルドで落ちたか、検査が落ちたかを読む
2. 手元で再現する: `make test-release`
3. 落ちた検査を入れた PR を探して直す。日次の 1 回には前の版からの PR が並ぶので、`git log <前の版のタグ>..<この run の SHA>` で候補を絞る

## 解消の判定

直す PR が merge された後、**次の日次の `release.yml` の run で `release-check` が緑になり、版が出れば解消**。急ぐなら、直す PR に `release:now` を付ける (merge の直後にこの検査を通って版が出る)。

**解消したらこの Issue を閉じる。** open な間は、次の赤は新しく立たずにこの Issue へ追記される (#2658)。閉じ忘れると、別の事象が前の事象の続きに見える。**閉じる前に、追記された分も同じ直しで解けたかを確かめる** — 別の原因なら、閉じる前に別の Issue へ起こす。
BODY
} > "$body"

bash "$here/report-check-failure.sh" \
  --title "$TITLE" \
  --log "$log" \
  --body-file "$body" \
  --key-file "$body" \
  --source '.github/workflows/release.yml の release-check-report が自動起票した (#2662)'
