#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ルールセットのドリフトを発信する (#99 / ADR-0006 決定 4・5)。
#
#   report-ruleset-drift.sh <照合の出力ファイル>
#
# 発信の形は **契機で変わる** (#381)。GITHUB_EVENT_NAME を見て決める:
#
#   push 以外 (schedule / workflow_dispatch / 手元) … Issue を起票する
#   push (定義変更が main に入った直後)             … 起票せず、適用手順をログへ出す
#
# 検査 (scripts/check-rulesets.sh) と発信をスクリプトごと分けているのは、起票を CI に
# 限るため — check-rulesets.sh に起票を足すと、手元で照合を打っただけで Issue が立つ。
# token は照合も起票も GITHUB_TOKEN で、issues: write はドリフト検査のジョブにだけ
# 付く。検査専用の App を Administration: Read で立てて照合させる案は、ADR-0006 決定 5
# の改訂で廃止した (read-only では bypass_actors が見えず、匿名読み取りと同じものしか
# 見られない)。
#
# ロジックを workflow の YAML に埋めないのは、単体テストで固定できないため
# (#66 / triage.sh と同じ理由)。呼び出しは .github/workflows/ruleset-drift.yml、
# 検査は scripts/tests/ruleset_drift_test.py。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"

# 重複起票を防ぐための固定タイトル。文言を変えると、変える前に立った Issue が
# 見つからなくなり二重に立つので、変えるときは open な分を先に畳む
readonly TITLE="ci: ルールセットが定義とずれている"

# 起票と同時に付けるトリアージ済みの印。完了条件 (下の「解消の判定」) を本文へ焼き
# 込んでいるので、議論を待たずに着手できる。機械が verify: を付けてよいのは
# 「完了条件を知っている起票者」だけで、同じ根拠で sub-issue.sh --test も付ける
# (ADR-0002 決定 1 / #205)。付け損ねても「着手できない」に倒れるだけで危険側には
# 倒れない — status: needs-triage を廃止したときと同じ理由。
# (かつては verify: machine と綴っていた。ADR-0031 が完了条件の性質による二分を畳んで
#  以降、ラベルは「完了条件が固まっている」1 種類である)
readonly VERIFY_LABEL="verify: triaged"

# 本文に載せる差分の上限。ずれが大きいときに Issue 本文の上限へ当たって起票ごと
# 失敗するより、頭を見せて run へ送る
readonly MAX_LINES=200

LOG="${1:?照合の出力ファイルが必要}"
[ -f "$LOG" ] || { echo "照合の出力ファイルが無い: $LOG" >&2; exit 66; }

# 定義変更を main へ入れた直後は、**まだ適用していないのが正常な状態**である。ここで
# 起票すると、定義を変えるたびに人が処理すべき Issue が積み増される — 毎回鳴る狼になり、
# 本物のドリフト (管理画面での直接変更) の起票まで反射で閉じられるようになる (#381)。
#
# push 契機では起票せず、適用の手順をログへ出して終わる。催促は run の赤とその失敗通知が
# 運ぶ。それを見落としても、翌日の schedule が従来どおり起票する — 赤 → 翌日 Issue の
# 段階的な上げ方で、機構は 1 つも増えない (ADR-0008 決定 5 の段 1)。
#
# 副作用として、push と同時に無関係なドリフトが起きていた回は起票されない。これも翌日の
# schedule が拾うので、失われるのは検知そのものではなく 1 日ぶんの早さだけである。
if [ "${GITHUB_EVENT_NAME:-}" = "push" ]; then
  cat <<'NUDGE'
report: 定義が main に入ったが、実設定への適用がまだである (起票はしない — #381)。

  bash scripts/apply-rulesets.sh          # 適用の差分を見る
  bash scripts/apply-rulesets.sh --apply  # 適用する (メンテナのみ。ADR-0003 決定 1)

適用したら、この workflow を Actions から workflow_dispatch で回し直すか、手元で
`bash scripts/check-rulesets.sh` を引数なしで打つと緑に戻ることを確かめられる
(引数なしの照合は bypass_actors まで見る)。
NUDGE
  exit 0
fi

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

## 解消の判定

`bash scripts/check-rulesets.sh` を**引数なし**で打ち、ルールセット 3 本すべてが緑になれば解消。引数なしの照合は `bypass_actors` まで見る (読めなければ赤になる) ので、この検査が見ていない範囲もそこで塞がる。
BODY
  if [ -n "$run_url" ]; then
    printf '\n検出した run: %s\n' "$run_url"
  fi
  printf '\n<sub>🤖 この Issue は .github/workflows/ruleset-drift.yml が自動起票した (#99)。完了条件が本文で確定しているため `verify: triaged` も自動で付く (#205)</sub>\n'
} > "$tmp"

url=$(gh issue create -R "$REPO" --title "$TITLE" --body-file "$tmp" --label "$VERIFY_LABEL")
echo "report: 起票した $url"

num="${url##*/}"
case "$num" in
  '' | *[!0-9]*) echo "report: 起票の応答から Issue 番号を取れなかった: $url" >&2; exit 1 ;;
esac

# GITHUB_TOKEN が作った Issue には workflow が発火しない (再帰防止の仕様) ため、
# triage.yml は走らない。人が起票したときと同じ下書きになるよう自分で呼ぶ
bash "$(dirname "$0")/triage.sh" "$num" "$TITLE"
