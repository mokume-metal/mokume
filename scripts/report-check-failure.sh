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
# 省かない。閉じる人は、追記された分も同じ直しで解けたかを確かめる (呼び手の本文がそう言う)。
# 追記に失敗したら黙らず非 0 で返す (set -e)。
#
# **同じ落ち方が続く間は、コメントせず本文の機械の区画だけを書き換える** (#2708)。#2658 の
# 「赤のたびに 1 コメント」は、同じ原因の赤が続くと専用機の定期なら最大で 1 日 4 回の通知に
# なった (Actions の通知を切り、機械の信号は Issue で受ける方針にしたので、コメントが失敗の
# 知らせの主な経路になる)。本文の編集は通知されない。
#
#   呼び手が --key-file で「同じ落ち方」の鍵を渡す。鍵のハッシュが open な Issue の本文の
#   区画のハッシュと同じなら、コメントせず、区画の連続回数と最後の run を書き換える。
#   違えば (落ち方が変わった・区画が無い) いまどおりコメントで追記し、区画を新しい鍵で
#   作り直す。**鍵を渡さない呼び手・空の鍵は、いまどおり毎回コメントする** (分からない
#   ときは知らせる側に倒す)
#
# 鍵は呼び手が決める。「同じ」の材料は呼び手ごとに違う — 出力の抜粋は通った検査の所要が
# 回ごとに揺れ (#2251 の 2 件は 6 行違った)、呼び手の本文は出力だけが変わる検査で
# 固定の文になる。**鍵に回ごとに揺れる値 (秒数・時刻・run の ID・全体の件数) を入れない**と
# 毎回「違う」になって知らせ過ぎ、**変わる中身を入れ損ねる**と別の赤が黙る (#2658 が塞いだ形)。
# 区画の外 (人が書いた文) は触らない。区画は Issue を閉じて開き直しても残る。
#
# 「連続」は、このスクリプトが同じ鍵で呼ばれた回数である (緑の回は呼ばれないので、間に緑が
# 挟まっても数え直さない — 自動では閉じないので、緑を数える口が無い)。
#
# **検査と発信を分けているのは、起票を CI に限るため** (report-ruleset-drift.sh と同じ)。
# 検査スクリプトに起票を足すと、手元で打っただけで Issue が立つ。
#
# 呼び手は scripts/report-ruleset-drift.sh / scripts/report-dead-assets.sh /
# scripts/report-scheduled-render.sh / scripts/report-runner-environment.sh /
# scripts/report-release-check.sh、
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
使い方: report-check-failure.sh --title <固定タイトル> --log <検査の出力> --body-file <本文> --source <出所の 1 行> [--key-file <鍵>]

  --title      重複判定に使う固定タイトル (Conventional Commits の接頭辞を付けると型も付く)
  --log        検査の出力ファイル。先頭 200 行を本文へ載せる
  --body-file  本文 (前置き・対処・解消の判定)。出力の抜粋と run の URL はここが足す
  --source     出所の 1 行 (例: ".github/workflows/publication.yml が自動起票した (#1295)")
  --key-file   「同じ落ち方」の鍵 (省略可)。同じ鍵が続く間は、コメントせず本文の区画だけを
               書き換える。回ごとに揺れる値 (秒数・時刻・run の ID) を入れない。省略するか
               空なら、毎回コメントする
USAGE
  exit 64
}

TITLE=""
LOG=""
BODY_FILE=""
SOURCE=""
KEY_FILE=""

while [ $# -gt 0 ]; do
  # 値を取る選択肢は 2 引数で来る。足りないまま shift 2 すると set -u の下で
  # 読めないエラーになるので、使い方の誤りとして返す
  case "$1" in
    --title | --log | --body-file | --source | --key-file)
      [ $# -ge 2 ] || usage
      case "$1" in
        --title) TITLE="$2" ;;
        --log) LOG="$2" ;;
        --body-file) BODY_FILE="$2" ;;
        --source) SOURCE="$2" ;;
        --key-file) KEY_FILE="$2" ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$TITLE" ] && [ -n "$LOG" ] && [ -n "$BODY_FILE" ] && [ -n "$SOURCE" ] || usage

[ -f "$LOG" ] || { echo "検査の出力ファイルが無い: $LOG" >&2; exit 66; }
[ -f "$BODY_FILE" ] || { echo "本文のファイルが無い: $BODY_FILE" >&2; exit 66; }

# 鍵のハッシュ。鍵を渡さない・空の鍵は「同じ」と言えないので、空のままにする (毎回コメント)
KEY_HASH=""
if [ -n "$KEY_FILE" ]; then
  [ -f "$KEY_FILE" ] || { echo "鍵のファイルが無い: $KEY_FILE" >&2; exit 66; }
  if [ -s "$KEY_FILE" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      KEY_HASH=$(sha256sum < "$KEY_FILE" | cut -d' ' -f1)
    else
      KEY_HASH=$(shasum -a 256 < "$KEY_FILE" | cut -d' ' -f1)
    fi
  fi
fi

# --- 本文の機械の区画 (#2708) -------------------------------------------------
#
# 区画は HTML コメントで挟み、連続回数・初めて落ちた日・最後の run の URL・鍵のハッシュを持つ。
# 表示される 1 行 (連続回数など) と、読み戻す側が使う 1 行 (key= count= first=) の 2 行を挟む。
# 書き換えるのは begin と end の間だけで、区画の外は触らない
readonly STATE_BEGIN='<!-- check-failure-state:begin (機械の区画。report-check-failure.sh が書き換える。ここは直さない) -->'
readonly STATE_END='<!-- check-failure-state:end -->'

state_block() { # $1=連続回数 $2=初めて落ちた日 $3=最後の run の URL (空なら無し)
  printf '%s\n' "$STATE_BEGIN"
  printf '連続 %s 回 ・ 初めて落ちた日 %s ・ 最後の run: %s\n' "$1" "$2" "${3:-(run の URL なし)}"
  printf '<!-- check-failure-state key=%s count=%s first=%s -->\n' "$KEY_HASH" "$1" "$2"
  printf '%s\n' "$STATE_END"
}

# 本文 $1 の区画を、ブロックのファイル $2 に差し替えて標準出力へ。begin と end の両方が
# 無ければ、末尾に足す (片方だけある壊れた区画で、人の文を巻き込んで消さない)
with_state() {
  if grep -q '^<!-- check-failure-state:begin' "$1" && grep -q '^<!-- check-failure-state:end' "$1"; then
    awk -v blockfile="$2" '
      /^<!-- check-failure-state:begin/ && !skip {
        while ((getline line < blockfile) > 0) print line
        close(blockfile); skip = 1; next
      }
      skip { if (/^<!-- check-failure-state:end/) skip = 0; next }
      { print }' "$1"
  else
    cat "$1"
    printf '\n'
    cat "$2"
  fi
}

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
state=$(mktemp)
current=$(mktemp)
rewritten=$(mktemp)
trap 'rm -f "$tmp" "$state" "$current" "$rewritten"' EXIT

today=$(date -u +%Y-%m-%d)

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
    # 鍵を渡されていれば、起票の本文に区画を持たせる (次の回が読み戻す)
    if [ -n "$KEY_HASH" ]; then
      printf '\n'
      state_block 1 "$today" "$run_url"
    fi
  fi
} > "$tmp"

# 追記は **bot の手**として Issue の活動に混じる (CI の github.token で書くので作者は Bot)。
# 活動を読む道具 (ready-queue・plan-record・comment.sh) はそれを人の活動に数えない —
# 前提と判定は scripts/bot-hand.sh に 1 度だけ置いてある。ここで書き方を変えるとき
# (ラベル付け・再オープンなど) も、作者が Bot である限り読み手の側は変えなくてよい
if [ -n "$existing" ]; then
  # 区画を読み書きしてよい本文か。空の本文 (読み損ね) に区画だけを書いて、人の文を消さない
  can_edit=""
  if [ -n "$KEY_HASH" ]; then
    # --jq は文字列の後ろに改行を足す。そのまま書き戻すと、書き換えのたびに末尾の空行が 1 つずつ
    # 増える。コマンド置換で末尾の改行を落としてから、1 つだけ付けて書く (何度書き換えても同じ形)
    issue_body=$(gh issue view "$existing" -R "$REPO" --json body --jq '.body // ""')
    printf '%s\n' "$issue_body" > "$current"
    if grep -q '[^[:space:]]' "$current"; then can_edit=1; fi
  fi

  if [ -n "$can_edit" ]; then
    # 鍵が前回と同じなら、コメントせず区画だけを書き換える。区画が無い・数が読めないときは
    # 「同じ」と言えないので、いつもどおりコメントする
    meta=$(grep -o '<!-- check-failure-state key=[^ ]* count=[^ ]* first=[^ ]* -->' "$current" | tail -n 1 || true)
    prev_key=$(sed -n 's/.* key=\([^ ]*\) .*/\1/p' <<<"$meta")
    prev_count=$(sed -n 's/.* count=\([^ ]*\) .*/\1/p' <<<"$meta")
    prev_first=$(sed -n 's/.* first=\([^ ]*\) .*/\1/p' <<<"$meta")
    case "$prev_count" in '' | *[!0-9]*) prev_key="" ;; esac
    if [ -n "$prev_key" ] && [ "$prev_key" = "$KEY_HASH" ]; then
      count=$((prev_count + 1))
      state_block "$count" "$prev_first" "$run_url" > "$state"
      with_state "$current" "$state" > "$rewritten"
      gh issue edit "$existing" -R "$REPO" --body-file "$rewritten" >/dev/null
      echo "report: 既に open な #$existing と同じ落ち方 (連続 $count 回) — コメントせず、本文の区画を書き換えた"
      exit 0
    fi
  fi

  gh issue comment "$existing" -R "$REPO" --body-file "$tmp" >/dev/null
  echo "report: 既に open な #$existing がある — 二重には立てず、追記した"
  if [ -n "$can_edit" ]; then
    # 落ち方が変わった (または区画がまだ無い)。新しい鍵で区画を作り直し、次の回が比べられる
    # ようにする。書けなければ黙らず落ちる (書けないと次の回もコメントになる — 知らせる側)
    state_block 1 "$today" "$run_url" > "$state"
    with_state "$current" "$state" > "$rewritten"
    gh issue edit "$existing" -R "$REPO" --body-file "$rewritten" >/dev/null
  fi
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
