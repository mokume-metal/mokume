#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 専用機の前検査が名乗った「job の置き場の外の重い負荷」(注意) が続いたことを、Issue に
# 1 度だけ追記する (#3633)。render は緑のまま、赤にはしない。
#
#   report-runner-notice.sh <書く名前 (| 区切り)> [<注意の詳細 (1 行)> [<記録を読めなかった (1)>]]
#
# 書く名前は scripts/count-runner-notice.sh が数えた `due` (`名前 (連続 N 回)` の `|` 区切り)、
# 詳細は前検査の `notice-detail`、最後は count の `unreadable`。いずれも render.yml が job の
# 出力として渡す。**数え (何回続いたか・いつ書くか) は count-runner-notice.sh が持ち、ここは
# 書くだけ** — 数えは前の run の記録を読む権限 (actions: read・checks: read)、ここは issues: write
# だけを持つ job で呼ばれる。数え方と鍵 (プロセス名・pid ではない) は count-runner-notice.sh の冒頭。
#
# ## 書き先
#
# 固定タイトルの注意の Issue。赤の回の `専用機の環境が壊れていて…` (report-runner-environment.sh・
# `fix(` の Bug) とは題も本文も別にして、混ぜない。起票と「open なら追記」の手続きは
# report-check-failure.sh が持つ。鍵 (--key-file) は渡さない — 区画の書き換えで畳むと、途切れた後の
# 2 度目を書けないので、書くと決めた回は必ずコメントする。メンテナの名指しはしない (赤ではない)。
# **何も殺さない・何も止めない。**
#
# 検査は scripts/tests/report_runner_notice_test.py。
set -euo pipefail

# 重複起票を防ぐための固定タイトル。文言を変えると、変える前に立った Issue が見つからなくなり
# 二重に立つので、変えるときは open な分を先に畳む。`chore(` なので triage.sh は Task を付ける
readonly TITLE="chore(render): 専用機の置き場の外の重い負荷が、merge queue の render を遅くしうる (注意)"

[ $# -ge 1 ] && [ $# -le 3 ] && [ -n "$1" ] && [[ "$1" != -* ]] || {
  echo "使い方: report-runner-notice.sh <書く名前 (| 区切り)> [<詳細> [<読めなかった>]]" >&2
  exit 64
}
DUE="$1"
DETAIL="${2:-}"
UNREADABLE="${3:-}"
STREAK_N="${NOTICE_STREAK:-3}"

here="$(dirname "${BASH_SOURCE[0]}")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

body="$work/body.md"
log="$work/log.txt"
printf '%s\n' "$DETAIL" > "$log"

{
  cat <<'HEAD'
## 注意: render を遅くしうる、job の置き場の外の負荷

merge queue の `render` の前検査 (`scripts/runner-preflight.sh`) が、**job の置き場の外のプロセス** (OS の常駐やログイン項目のアプリ。前の job の残りではない) が CPU を使い続けているのを、同じ名前で続けて名乗った。**赤ではない。render は緑のまま通っている。** ただし検査 (特に CPU 律速の検査と build) は遅くなりうる (#3631・#3633)。何も止めていない。
HEAD
  if [ -n "$UNREADABLE" ]; then
    printf '\n**前の run の記録を読めなかったので、続いた回数を確かめられていない** (読めない回は 1 度書く)。\n'
  fi
  printf '\n続いた名前 (N = %s 回):\n\n' "$STREAK_N"
  printf '%s\n' "$DUE" | tr '|' '\n' | sed '/^$/d; s/^/- /'
  cat <<'TAIL'

## 対処

1. 下の「検査の出力」の名前で、専用機の前で出所を確かめる (`ps -o pid,%cpu,etime,command -p <PID>`・`lsof -a -p <PID> -d cwd`)。OS の常駐なら、負荷が下がるのを待つか、その機能 (写真の解析など) を切る。ログイン項目のアプリなら、専用機では要らないので外す
2. 止めるかは人が決める。前検査もこの発信も何も止めない
3. 実際に render が遅くなったかは、この注意が出た回の `render` の所要を、出ていない週の中央値と比べる (3 分以上長く、build や CPU 律速の検査が揃って伸びていれば、遅くしている)

## 解消の判定

注意が出なくなれば解消。**解消したらこの Issue を閉じる。** open な間は、新しい名前が N 回続くか、途切れた後にまた N 回続くたびに、ここへ追記される。
TAIL
} > "$body"

bash "$here/report-check-failure.sh" \
  --title "$TITLE" \
  --log "$log" \
  --body-file "$body" \
  --source '.github/workflows/render.yml の render-notice-report が自動起票した (#3633)'
