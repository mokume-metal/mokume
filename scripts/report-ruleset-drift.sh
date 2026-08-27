#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ルールセットのドリフトを Issue として起票する (#99 / ADR-0006 決定 4・5)。
#
#   report-ruleset-drift.sh <照合の出力ファイル>
#
# 検査 (scripts/check-rulesets.sh) と発信をスクリプトごと分けているのは、token も
# 権限も別だから — 照合は検査専用 App の Administration: Read で行い、起票は
# GITHUB_TOKEN の issues: write で行う (検査 App に Issues write を持たせない)。
# check-rulesets.sh に起票を足すと、手元で打っただけで Issue が立つことにもなる。
#
# ロジックを workflow の YAML に埋めないのは、scheduled workflow が既定ブランチの
# 定義しか実行しないため。埋めると main に入るまで誰も確かめられない (#66 / triage.sh
# と同じ理由)。呼び出しは .github/workflows/ruleset-drift.yml、検査は
# scripts/tests/ruleset_drift_test.py。
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-mokume-metal/mokume}"

# 重複起票を防ぐための固定タイトル。文言を変えると、変える前に立った Issue が
# 見つからなくなり二重に立つので、変えるときは open な分を先に畳む
readonly TITLE="ci: ルールセットが定義とずれている"

# 本文に載せる差分の上限。ずれが大きいときに Issue 本文の上限へ当たって起票ごと
# 失敗するより、頭を見せて run へ送る
readonly MAX_LINES=200

LOG="${1:?照合の出力ファイルが必要}"
[ -f "$LOG" ] || { echo "照合の出力ファイルが無い: $LOG" >&2; exit 66; }

# 同じ内容で毎日立てない。GitHub の検索は前方一致や語での照合なので、返ってきた
# ものをタイトル完全一致で絞ってから採る
existing=$(gh issue list -R "$REPO" --state open --search "\"$TITLE\" in:title" \
  --json number,title \
  --jq "[.[] | select(.title == \"$TITLE\")] | .[0].number // empty")

if [ -n "$existing" ]; then
  echo "report: 既に open な #$existing がある — 重複起票しない (差分は run のログに残る)"
  exit 0
fi

run_url=""
if [ -n "${GITHUB_RUN_ID:-}" ]; then
  run_url="${GITHUB_SERVER_URL:-https://github.com}/$REPO/actions/runs/$GITHUB_RUN_ID"
fi

total=$(wc -l < "$LOG" | tr -d ' ')
excerpt=$(head -n "$MAX_LINES" "$LOG")
truncated=""
if [ "$total" -gt "$MAX_LINES" ]; then
  truncated="

(差分が長いため先頭 $MAX_LINES 行のみ。全文は run のログにある)"
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Issue 本文の相対リンクは解決されないので、ADR へは絶対 URL で張る
adr_url="${GITHUB_SERVER_URL:-https://github.com}/$REPO/blob/main/docs/decisions/0006-github-settings-as-code.md"

{
  printf '定期のドリフト検査で、ブランチ保護のルールセットが `.github/rulesets/` の定義とずれていることを検出した。\n\n'
  printf '正本は定義ファイルで、GitHub 側の状態はその写しである ([ADR-0006](%s))。ずれているということは、**管理画面から直接変えられたか、定義の適用が済んでいないか**のどちらかを意味する。\n\n' "$adr_url"
  printf '## 検出された差分\n\n```text\n'
  printf '%s\n' "$excerpt"
  printf '```\n%s\n' "$truncated"
  cat <<'BODY'

## どちらかを選ぶ

- **実設定のほうが正しくない** → 定義を適用し直す: `bash scripts/apply-rulesets.sh --apply` (メンテナのみ。ADR-0003 決定 1 によりエージェントの token では通らない)
- **実設定のほうが正しい** → 変更の意図を PR に書いて定義ファイルを更新する

どちらの場合も、**なぜ変わったのか**をこの Issue に残してから閉じる。管理画面での直接変更を拾うことがこの検査の目的なので、経緯が残らないと次に同じことが起きたときに区別が付かない。
BODY
  if [ -n "$run_url" ]; then
    printf '\n検出した run: %s\n' "$run_url"
  fi
  printf '\n<sub>🤖 この Issue は .github/workflows/ruleset-drift.yml が自動起票した (#99)</sub>\n'
} > "$tmp"

url=$(gh issue create -R "$REPO" --title "$TITLE" --body-file "$tmp")
echo "report: 起票した $url"

num="${url##*/}"
case "$num" in
  '' | *[!0-9]*) echo "report: 起票の応答から Issue 番号を取れなかった: $url" >&2; exit 1 ;;
esac

# GITHUB_TOKEN が作った Issue には workflow が発火しない (再帰防止の仕様) ため、
# triage.yml は走らない。人が起票したときと同じ下書きになるよう自分で呼ぶ
bash "$(dirname "$0")/triage.sh" "$num" "$TITLE"
