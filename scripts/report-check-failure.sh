#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 定期検査の失敗を Issue で名乗る (#1295)。
#
#   report-check-failure.sh --title <固定タイトル> --log <検査の出力> \
#                           --body-file <本文> --source <出所の 1 行>
#
# **塞ぐのは「赤が誰にも拾われない」である。** 日次の検査は落ちても run の赤としてしか
# 現れず、その赤は GitHub が cron を最後に触った人へ通知するだけである。実際に
# publication の assets が **7 日連続で赤のまま見落とされ**、その間「外に置いた視覚証跡
# 178 本がすべて 404」という事象が誰にも届かなかった (#1294 / #1295)。追跡単位が要る、
# というのがこの部品の理由である。
#
# ## 呼び手が持つもの・ここが持つもの
#
# 呼び手 (scripts/report-*.sh) が持つのは**固定タイトルと本文**だけで、ここは
# 「起票して、重複しては立てない」の手続きを持つ。分けたのは ADR-0008 決定 6 の線
# (割れたときに黙って壊れるか) に照らした結果で、下の 3 つはどれも症状が「何も起きない」
# になり、run の赤にすら現れない — #1295 が踏んだ形そのままである:
#
#   完全一致の絞り     … 似た題の Issue を「既にある」と誤認し、本物の赤が一度も起票されない
#   verify: triaged    … 着手ゲートで誰も触れず、翌日以降の赤は追記として積もるだけになる (#205)
#   200 行の切り詰め   … 長い出力で gh issue create ごと落ち、報告そのものが失われる
#                        (assets の出力は指し先 178 本ぶん出る)
#
# **自動では閉じない。** 緑に戻ったことは「直った」を意味しない — 指し先を消しても緑になる
# (0 件だけは赤)。どの手で直したのかは緑からは読めず、そこを残すのが起票の値である。
# 「緑に戻ったのに Issue が open のまま残った」実害はまだ 1 度も出ていないので、閉じる機構は
# 足さない (ADR-0008 決定 3・5)。呼び手の本文には「直ったら閉じる」を書かせる — 動く人が
# 読む場所に置く。
#
# **open な Issue があれば、二重には立てず、その Issue へコメントで追記する** (#2658)。
# 以前は何も書かずに exit 0 で終わっていた。閉じ忘れや着手中の Issue が open のまま残ると、
# その間の赤は run のログにしか残らない — #1295 と同じ形である。実際に #2251 (着手中) が
# open の間、専用機の定期の赤 2 回が誰にも届かなかった。追記には新規起票と同じ本文 (呼び手の
# 文・出力の抜粋・run の URL) を載せる。後から出た赤は前の赤と別物でありうるので、中身を
# 省かない。代償は、赤が続く間、回ごとに 1 コメント増えることである (merge_group で走る
# 前検査の起票は、queue の group ごとに 1 コメント)。閉じる人は、追記された分も同じ直しで
# 解けたかを確かめる (呼び手の本文がそう言う)。追記に失敗したら黙らず
# 非 0 で返す (set -e)。
#
# **検査と発信を分けているのは、起票を CI に限るため** (report-ruleset-drift.sh と同じ)。
# 検査スクリプトに起票を足すと、手元で打っただけで Issue が立つ。
#
# 呼び手は scripts/report-ruleset-drift.sh / scripts/report-dead-assets.sh /
# scripts/report-scheduled-render.sh / scripts/report-runner-environment.sh、
# 検査は scripts/tests/report_check_failure_test.py。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"

# 起票と同時に付けるトリアージ済みの印。完了条件を呼び手の本文へ焼き込んでいるので、
# 議論を待たずに着手できる。機械が verify: を付けてよいのは「完了条件を知っている起票者」
# だけで、同じ根拠で sub-issue.sh --test も付ける (ADR-0002 決定 1 / #205)。
readonly VERIFY_LABEL="verify: triaged"

# 本文に載せる出力の上限。長いときに Issue 本文の上限へ当たって起票ごと失敗するより、
# 頭を見せて run へ送る
readonly MAX_LINES=200

usage() {
  cat >&2 <<'USAGE'
使い方: report-check-failure.sh --title <固定タイトル> --log <検査の出力> --body-file <本文> --source <出所の 1 行>

  --title      重複判定に使う固定タイトル (Conventional Commits の接頭辞を付けると型も付く)
  --log        検査の出力ファイル。先頭 200 行を本文へ載せる
  --body-file  本文 (前置き・対処・解消の判定)。出力の抜粋と run の URL はここが足す
  --source     出所の 1 行 (例: ".github/workflows/publication.yml が自動起票した (#1295)")
USAGE
  exit 64
}

TITLE=""
LOG=""
BODY_FILE=""
SOURCE=""

while [ $# -gt 0 ]; do
  # 値を取る選択肢は 2 引数で来る。足りないまま shift 2 すると set -u の下で
  # 読めないエラーになるので、使い方の誤りとして返す
  case "$1" in
    --title | --log | --body-file | --source)
      [ $# -ge 2 ] || usage
      case "$1" in
        --title) TITLE="$2" ;;
        --log) LOG="$2" ;;
        --body-file) BODY_FILE="$2" ;;
        --source) SOURCE="$2" ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$TITLE" ] && [ -n "$LOG" ] && [ -n "$BODY_FILE" ] && [ -n "$SOURCE" ] || usage

[ -f "$LOG" ] || { echo "検査の出力ファイルが無い: $LOG" >&2; exit 66; }
[ -f "$BODY_FILE" ] || { echo "本文のファイルが無い: $BODY_FILE" >&2; exit 66; }

# 同じ内容で毎日立てない。GitHub の検索は前方一致や語での照合なので、返ってきた
# ものをタイトル完全一致で絞ってから採る
existing=$(gh issue list -R "$REPO" --state open --search "\"$TITLE\" in:title" \
  --json number,title \
  --jq "[.[] | select(.title == \"$TITLE\")] | .[0].number // empty")

run_url=""
if [ -n "${GITHUB_RUN_ID:-}" ]; then
  run_url="${GITHUB_SERVER_URL:-https://github.com}/$REPO/actions/runs/$GITHUB_RUN_ID"
fi

total=$(wc -l < "$LOG" | tr -d ' ')
excerpt=$(head -n "$MAX_LINES" "$LOG")
truncated=""
if [ "$total" -gt "$MAX_LINES" ]; then
  truncated="
(出力が長いため先頭 $MAX_LINES 行のみ。全文は run のログにある)"
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

{
  cat "$BODY_FILE"
  printf '\n## 検査の出力\n\n```text\n'
  printf '%s\n' "$excerpt"
  printf '```\n%s\n' "$truncated"
  if [ -n "$run_url" ]; then
    printf '\n検出した run: %s\n' "$run_url"
  fi
  if [ -n "$existing" ]; then
    printf '\n<sub>🤖 出所: %s。同じ題の Issue が open なので、新しく立てずにここへ追記した (#2658)</sub>\n' \
      "$SOURCE"
  else
    printf '\n<sub>🤖 この Issue は %s。完了条件が本文で確定しているため `%s` も自動で付く (#205)</sub>\n' \
      "$SOURCE" "$VERIFY_LABEL"
  fi
} > "$tmp"

if [ -n "$existing" ]; then
  gh issue comment "$existing" -R "$REPO" --body-file "$tmp" >/dev/null
  echo "report: 既に open な #$existing がある — 二重には立てず、追記した"
  exit 0
fi

url=$(gh issue create -R "$REPO" --title "$TITLE" --body-file "$tmp" --label "$VERIFY_LABEL")
echo "report: 起票した $url"

num="${url##*/}"
case "$num" in
  '' | *[!0-9]*) echo "report: 起票の応答から Issue 番号を取れなかった: $url" >&2; exit 1 ;;
esac

# GITHUB_TOKEN が作った Issue には workflow が発火しない (再帰防止の仕様) ため、
# triage.yml は走らない。人が起票したときと同じ下書きになるよう自分で呼ぶ
bash "$(dirname "${BASH_SOURCE[0]}")/triage.sh" "$num" "$TITLE"
