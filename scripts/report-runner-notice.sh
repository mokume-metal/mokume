#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 専用機の前検査が名乗った「job の置き場の外の重い負荷」(注意) が続いたことを、Issue に
# 続き 1 つにつき 1 度だけ追記する (#3633)。render は緑のまま、赤にはしない。
#
#   DUE=<数えの due> DETAIL=<注意の詳細 (1 行)> UNREADABLE=<読めなかった (1)> report-runner-notice.sh
#
# DUE は scripts/count-runner-notice.sh が数えた `due` (`<回数> <途切れの run> <名前>` の `|` 区切り)、
# DETAIL は前検査の `notice-detail`、UNREADABLE は count の `unreadable`。いずれも render.yml が
# job の出力を環境変数で渡す (引数で受けると `-` で始まる名前を選択肢と読み違える・反証の指摘 4)。
# **数え (何回続いたか) は count-runner-notice.sh が持ち、ここは「既に書いたか」を見て書くだけ** —
# 数えは前の run の記録を読む権限 (actions: read・checks: read)、ここは issues: write だけを
# 持つ job で呼ばれる。数え方と鍵 (プロセス名・pid ではない) は count-runner-notice.sh の冒頭。
#
# ## 1 度だけ: 注意の Issue の印で見る
#
# 書く追記の本文に、機械が読む印 (HTML のコメント) を名前ごとに 1 行入れる:
#
#   <!-- runner-notice run=<書いた run の ID> after=<途切れの run の ID> name=<名前> -->
#   <!-- runner-notice run=<書いた run の ID> unreadable -->
#
# 名前は前検査 (runner-preflight.sh) が安全な字 (英数字と `._ -`) に寄せてあるので、印の `-->` や
# `>` を含まない。
#
# 書く前に、open な注意の Issue の本文とコメントから印を読み、
#
#   ・名前ごと: **同じ名前で、書いた run が今回の途切れより後の印**が在れば、その名前は書かない。
#     途切れより後に書いた印は、いまの続きについて書いた印である。鍵を「続きの始まりの run」に
#     しないのは、runner 2 本の並行で始まりが食い違いうるから (片方は前の run がまだ終わって
#     いないので飛ばし、もう片方は終わった run を見る)。途切れは「前検査が走ったのに名前が無い」
#     終わった run で、終わった run はどちらからも同じに見える
#   ・読めない回: Issue の印のうち run が最も新しいものが「読めない」なら重ねない
#     (merge_group ごとに毎回書かない・#3633 の禁じ手)。普通に書いた印がその後に付けば、次の
#     「読めない」はまた 1 度書く
#
# 印を読めなかった (Issue の読み取りが落ちた) ときは、書く側に倒す (黙らない)。並行する 2 本が
# 互いの印を見落とさないよう、render.yml はこの job を concurrency で直列にしている。
#
# ## 書き先
#
# 固定タイトルの注意の Issue。赤の回の `専用機の環境が壊れていて…` (report-runner-environment.sh・
# `fix(` の Bug) とは題も本文も別にして、混ぜない。起票と「open なら追記」の手続きは
# report-check-failure.sh が持つ。鍵 (--key-file) は渡さない — 区画の書き換えで畳むと、途切れた後の
# 2 度目を書けないので、書くと決めた回は必ずコメントする。メンテナの名指しはしない (赤ではない)。
# 起票の直後に検索の索引が遅れると、同じ題の Issue が 2 本立ちうる。これは report-check-failure.sh を
# 使う他の発信と同じ既知の限界で、ここでは足さない。
# **何も殺さない・何も止めない。**
#
# 検査は scripts/tests/report_runner_notice_test.py。
set -euo pipefail
# 照合・バイトの扱いを GNU (CI の ubuntu) と BSD (手元の macOS) で揃える
export LC_ALL=C

# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"

# 重複起票を防ぐための固定タイトル。文言を変えると、変える前に立った Issue が見つからなくなり
# 二重に立つので、変えるときは open な分を先に畳む。`chore(` なので triage.sh は Task を付ける
readonly TITLE="chore(render): 専用機の置き場の外の重い負荷が、merge queue の render を遅くしうる (注意)"
readonly MARK='<!-- runner-notice '

usage() {
  echo "使い方: DUE=<数えの due> [DETAIL=<詳細>] [UNREADABLE=1] report-runner-notice.sh" >&2
  exit 64
}
[ $# -eq 0 ] || usage
DUE="${DUE:-}"
DETAIL="${DETAIL:-}"
UNREADABLE="${UNREADABLE:-}"
[ -n "$DUE" ] || usage
RUN="${GITHUB_RUN_ID:-}"
case "$RUN" in '' | *[!0-9]*) echo "GITHUB_RUN_ID (印に書く run の ID) が要る: ${RUN}" >&2; exit 64 ;; esac
STREAK_N="${NOTICE_STREAK:-3}"

here="$(dirname "${BASH_SOURCE[0]}")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- open な注意の Issue の印を読む ---------------------------------------------
# $work/marks の 1 行 = 1 つの印 (`<run> unreadable` か `<run> <after> <名前>`)。
# 読めなかったら marks_ok を空にし、書く側に倒す
marks_ok=1
: > "$work/marks"
if existing=$(gh issue list -R "$REPO" --state open --search "\"$TITLE\" in:title" \
  --json number,title \
  --jq "[.[] | select(.title == \"$TITLE\")] | .[0].number // empty" 2>/dev/null); then
  if [ -n "$existing" ]; then
    # gh issue view はコメントを全件返す (2026-11-13 に 86 件の #2802・67 件の #2251 で、
    # gh api --paginate の issues/<N>/comments と同じ数を確かめた)
    if texts=$(gh issue view "$existing" -R "$REPO" --json body,comments \
      --jq '(.body // ""), ((.comments // [])[] | .body // "")' 2>/dev/null); then
      grep -o "${MARK}run=[0-9]* [^>]*-->" <<<"$texts" \
        | sed -n \
          -e 's/^<!-- runner-notice run=\([0-9][0-9]*\) unreadable -->$/\1 unreadable/p' \
          -e 's/^<!-- runner-notice run=\([0-9][0-9]*\) after=\([0-9][0-9]*\) name=\(.*\) -->$/\1 \2 \3/p' \
          > "$work/marks" || true
    else
      marks_ok=""
    fi
  fi
else
  marks_ok=""
fi

# --- 書く名前を決める ------------------------------------------------------------
entries="$work/entries" # 書く行: `<回数> <途切れ> <名前>`
: > "$entries"
if [ -n "$UNREADABLE" ]; then
  # 最も新しい印が「読めない」なら重ねない
  latest=$(sort -n -k1,1 "$work/marks" | tail -n 1)
  if [ -n "$marks_ok" ] && [ "${latest#* }" = unreadable ]; then
    echo "report: 前の run の記録を読めなかったが、注意の Issue の最後の印も「読めない」(run ${latest%% *}) — 重ねない"
    exit 0
  fi
  printf '%s\n' "$DUE" | tr '|' '\n' | sed '/^$/d' > "$entries"
else
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    read -r count since name <<<"$entry"
    case "$count$since" in *[!0-9]*) echo "due の形が違う: $entry" >&2; exit 65 ;; esac
    written=""
    if [ -n "$marks_ok" ]; then
      while read -r m_run m_after m_name; do
        [ "$m_after" != unreadable ] || continue
        if [ "$m_name" = "$name" ] && [ "$m_run" -gt "$since" ]; then
          written="$m_run"
          break
        fi
      done < "$work/marks"
    fi
    if [ -n "$written" ]; then
      echo "report: ${name} はこの続き (途切れ: run ${since}) について run ${written} で書いた — 重ねない"
    else
      printf '%s\n' "$entry" >> "$entries"
    fi
  done < <(printf '%s\n' "$DUE" | tr '|' '\n')
  if [ ! -s "$entries" ]; then
    echo "report: 書く名前が無い (どれもこの続きについて書いてある)"
    exit 0
  fi
fi
[ -n "$marks_ok" ] || echo "report: 注意の Issue の印を読めなかった — 書く側に倒す"

# --- 本文 ----------------------------------------------------------------------
body="$work/body.md"
log="$work/log.txt"
printf '%s\n' "$DETAIL" > "$log"

{
  cat <<'HEAD'
## 注意: render を遅くしうる、job の置き場の外の負荷

merge queue の `render` の前検査 (`scripts/runner-preflight.sh`) が、**job の置き場の外のプロセス** (OS の常駐やログイン項目のアプリ。前の job の残りではない) が CPU を使い続けているのを、同じ名前で続けて名乗った。**赤ではない。render は緑のまま通っている。** ただし検査 (特に CPU 律速の検査と build) は遅くなりうる (#3631・#3633)。何も止めていない。
HEAD
  if [ -n "$UNREADABLE" ]; then
    printf '\n**前の run の記録を読めなかったので、続いた回数を確かめられていない** (読めない間は、この追記を重ねない)。\n\n注意の名前:\n\n'
    while read -r _ _ name; do printf -- '- %s\n' "$name"; done < "$entries"
  else
    printf '\n続いた名前 (N = %s 回):\n\n' "$STREAK_N"
    while read -r count _ name; do printf -- '- %s (連続 %s 回)\n' "$name" "$count"; done < "$entries"
  fi
  cat <<'TAIL'

## 対処

1. 下の「検査の出力」の名前で、専用機の前で出所を確かめる (`ps -o pid,%cpu,etime,command -p <PID>`・`lsof -a -p <PID> -d cwd`)。OS の常駐なら、負荷が下がるのを待つか、その機能 (写真の解析など) を切る。ログイン項目のアプリなら、専用機では要らないので外す
2. 止めるかは人が決める。前検査もこの発信も何も止めない
3. 実際に render が遅くなったかは、この注意が出た回の `render` の所要を、出ていない週の中央値と比べる (3 分以上長く、build や CPU 律速の検査が揃って伸びていれば、遅くしている)

## 解消の判定

注意が出なくなれば解消。**解消したらこの Issue を閉じる。** open な間は、新しい名前が N 回続くか、途切れた後にまた N 回続くたびに、ここへ 1 度ずつ追記される。
TAIL
  # 次の回が「この続きについて書いたか」を読む印 (表示されない)
  printf '\n'
  if [ -n "$UNREADABLE" ]; then
    printf '%srun=%s unreadable -->\n' "$MARK" "$RUN"
  else
    while read -r _ since name; do
      printf '%srun=%s after=%s name=%s -->\n' "$MARK" "$RUN" "$since" "$name"
    done < "$entries"
  fi
} > "$body"

bash "$here/report-check-failure.sh" \
  --title "$TITLE" \
  --log "$log" \
  --body-file "$body" \
  --source '.github/workflows/render.yml の render-notice-report が自動起票した (#3633)'
