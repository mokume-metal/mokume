#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 定期の「例の絵の前後の比較」が名指しした、画素の変わった例の絵を Issue で名乗る (#2706)。
#
#   report-example-drift.sh <記録のディレクトリ>
#
# 記録は専用機の job `scheduled-drift` が artifact に上げたもの (scripts/scheduled-drift.sh)。
# `drifts.tsv` (変わった絵 1 本 1 行) が空か無ければ、**何も起票しない** — 区間に変化が無い回
# (描画のパスに触れていない回を含む) は、毎回ここを通っても黙る。
#
# 発信の実体は scripts/report-check-failure.sh が持ち、ここが持つのは**固定タイトルと本文と鍵**
# だけである (report-scheduled-render.sh と同じ分け方)。呼ぶのは render.yml の
# scheduled-report (GitHub ホストの job) で、`issues: write` を持つのはそのジョブだけ。
# 専用機の job は引き続き権限も秘密も持たない (ADR-0019 決定 7)。
#
# **起票は merge の最大 6 時間後になる** (定期の run の間隔)。区間の起点は前回の比べ終えた run
# なので、1 度名指しした変化は次の区間には入らない — 同じ絵が毎回起票されることはない。
# 撮り直されないまま別の変更でまた変わったときは、同じ題の Issue が open なら追記される。
#
# **鍵は、変わった絵の指紋 (`snippet=`) の集合** (#2708)。違う画素の数・最大の差・説明文の
# 行は、区間と編集で動くので入れない。同じ絵が名指しされ続ける間は本文の区画だけを書き換え、
# 別の絵が加わったら知らせる。
#
# 検査は scripts/tests/report_check_failure_test.py (鍵) と scripts/tests/scheduled_drift_test.py。
# 環境変数 DRIFT_COUNT は、記録を落とせなかったときの本数 (下の「記録が無いのに」)。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"

# 重複起票を防ぐための固定タイトル。文言を変えると、変える前に立った Issue が見つからなく
# なり二重に立つので、変えるときは open な分を先に畳む。接頭辞が `fix(` なので triage.sh が
# Bug を付ける — 例の絵が説明文の実装と食い違っているのは、期待と違う状態である
readonly TITLE="fix(docs): 実装の変更で画素が変わった例の絵が、撮り直されないまま残っている"

[ $# -eq 1 ] || {
  echo "使い方: report-example-drift.sh <記録のディレクトリ>" >&2
  exit 64
}
RECORD="$1"
TSV="$RECORD/drifts.tsv"

# 記録が無いのに専用機の job が「変わった」と名乗った回 (artifact を落とせなかった) は、
# 起票する — ここで黙ると、名指しされた絵が誰にも届かない。本数は DRIFT_COUNT で受ける
missing=""
if [ ! -f "$TSV" ]; then
  case "${DRIFT_COUNT:-0}" in
    '' | 0 | *[!0-9]*)
      echo "report: 画素の変わった例の絵は無い — 起票しない"
      exit 0
      ;;
  esac
  missing=1
elif [ ! -s "$TSV" ]; then
  echo "report: 画素の変わった例の絵は無い — 起票しない"
  exit 0
fi

here="$(dirname "${BASH_SOURCE[0]}")"

body=$(mktemp)
log=$(mktemp)
key=$(mktemp)
trap 'rm -f "$body" "$log" "$key"' EXIT

if [ -n "$missing" ]; then
  echo "record-missing" > "$key"
  printf '(記録の drifts.tsv が無い。専用機の job は %s 本と名乗った。run の要約に表がある)\n' "$DRIFT_COUNT" > "$log"
  count="$DRIFT_COUNT"
else
  # 鍵: 変わった絵の指紋の集合 (重複を除いて並べる)
  cut -f2 "$TSV" | sort -u > "$key"
  # 検査の出力 (抜粋): 1 本 1 行
  {
    printf '説明文の場所\tsnippet=\t違う画素\t全画素\t最大の差\t動きの枚数\t一文の説明\n'
    cat "$TSV"
  } > "$log"
  count=$(grep -c '' "$TSV")
fi

# 区間 (起点と今の main の SHA)
range=""
if [ -s "$RECORD/range.txt" ]; then
  read -r base head_sha < "$RECORD/range.txt" || true
  if [ -n "${base:-}" ] && [ "$base" != none ] && [ -n "${head_sha:-}" ]; then
    range="${GITHUB_SERVER_URL:-https://github.com}/$REPO/compare/$base...$head_sha"
  fi
fi

adr_url="${GITHUB_SERVER_URL:-https://github.com}/$REPO/blob/main/docs/decisions/0019-drawing-verification.md"

{
  printf '専用機の定期の検査 (`.github/workflows/render.yml` の `scheduled-drift`・[ADR-0019](%s) 決定 7・#2706) が、前回の定期の run が比べ終えた main の SHA と今の main の間で、**例の絵 %s 本の画素が変わっている**と名指しした。\n\n' "$adr_url" "$count"
  if [ -n "$range" ]; then
    printf '区間: %s\n\n' "$range"
  fi
  cat <<'BODY'
実装だけが変わって、説明文に貼ってある絵が古くなっている疑いがある。例の絵の記録 (`// shot: N snippet=…`) の指紋が見るのは例のコードと撮影設定だけで、実装は入らないので、`make example-shots-check` は緑のまま通る (#1454・#1625・#2705)。render-pr の名指しは PR の上の警告で止まらず、merge queue が専用機を待っている間は出ないこともある。ここは、そうして main に入った分を拾う。**区間は main の全体で、特定の PR を指すものではない** — 上の区間の比較から、どの変更が絵を動かしたかを読む。

BODY
  cat "$RECORD/summary.md" 2>/dev/null || printf '(記録の summary.md が無い。run の要約に同じ表がある)\n'
  cat <<'BODY'

## 対処

1. 上の表の絵が、**意図した変化か**を見る。意図した変化なら、撮り直して書き戻す (`make example-shots`・Gyazo の鍵が要る)。撮り直しで `![…](…)` の URL が動かなければ、手元で今撮った画素が、貼ってある絵の撮影時の画素 (記録の `image=`) と同じだった — 画素の差は説明文の絵に出ていない (そのまま閉じてよい)。動いたものは画素が変わっている (OS の版の違いで動くこともあるので、絵を見て確かめる・#3459)
2. 意図しない変化なら、区間の変更が約束を破っている。`Bug` として別の Issue に起こし、最小のスケッチかテストに落とす (この Issue は撮り直しの追跡に残す)

## 解消の判定

名指しした絵の説明文が撮り直されて (または意図しない変化が別の Issue で追われて)、次の定期の run (6 時間以内) の区間に同じ絵が現れなければ解消。1 度名指しした変化は次の区間に入らないので、**次の回が緑なのは、直った証拠にならない** — 撮り直した PR が merge されたことで判定する。

**解消したらこの Issue を閉じる。** open な間は、次に名指しされた絵は新しく立たずにこの Issue へ追記される (同じ絵の組なら本文の区画だけが書き換わる)。**閉じる前に、追記された分も同じ撮り直しで解けたかを確かめる。**
BODY
} > "$body"

bash "$here/report-check-failure.sh" \
  --title "$TITLE" \
  --log "$log" \
  --body-file "$body" \
  --key-file "$key" \
  --source '.github/workflows/render.yml の scheduled-report が自動起票した (#2706)'
