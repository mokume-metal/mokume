#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ADR-0002 のマージ承認ルーティングを判定する (docs/decisions/0002)。
#   - PR は Issue に紐づく (Closes #N)。例外は no-issue ラベルでのみ許す
#   - 対象 Issue に verify: ラベルが無ければ、完了条件が未確定のまま実装に入っている
#   - verify: human、または重要パスに触れる PR は、メンテナの review: approved を待つ
# 使い方: review-gate.sh <PR番号> (要 GH_TOKEN / gh 認証)
set -euo pipefail

PR="${1:?PR 番号が必要}"
REPO="${GITHUB_REPOSITORY:-mokume-metal/mokume}"

# 重要パス (公開 API 面はコードが生まれた時点で追加する)
IMPORTANT_PATHS='^(docs/decisions/|\.github/|\.claude/)'

fail() {
  echo "review-gate: 差し戻し — $1" >&2
  echo "次にすること: $2" >&2
  exit 1
}

pr_json=$(gh pr view "$PR" -R "$REPO" --json body,labels,files,latestReviews)
pr_labels=$(jq -r '[.labels[].name] | join("\n")' <<<"$pr_json")
body=$(jq -r '.body // ""' <<<"$pr_json")

# 1. 対象 Issue の解決 (Closes/Fixes/Resolves #N — 複数あれば全て検査)
issues=$(grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' <<<"$body" | grep -oE '[0-9]+' | sort -u || true)
if [ -z "$issues" ]; then
  if grep -qx "no-issue" <<<"$pr_labels"; then
    echo "review-gate: no-issue ラベルによる例外 PR (Issue 紐づけなし)"
  else
    fail "PR が Issue に紐づいていない (本文に Closes #N が無い)" \
         "対象 Issue を本文の目的節に 'Closes #N' で書く。Issue を閉じない例外なら no-issue ラベルを付けて再実行する"
  fi
fi

# 2. 各対象 Issue の verify ラベル
need_human=false
for n in $issues; do
  ilabels=$(gh issue view "$n" -R "$REPO" --json labels --jq '[.labels[].name] | join("\n")')
  if grep -qx "verify: human" <<<"$ilabels"; then
    need_human=true
    echo "review-gate: #$n は verify: human"
  elif grep -qx "verify: machine" <<<"$ilabels"; then
    echo "review-gate: #$n は verify: machine"
  else
    fail "対象 Issue #$n に verify: ラベルが無い (完了条件が未確定のまま実装に入っている)" \
         "Issue で議論して完了条件を本文に固め、verify: machine / verify: human を付けてから、この check を再実行する (Actions の re-run か空 push。Issue 側のラベル操作では自動再実行されない)"
  fi
done

# 3. 重要パス
if jq -r '.files[].path' <<<"$pr_json" | grep -qE "$IMPORTANT_PATHS"; then
  need_human=true
  echo "review-gate: 重要パス (docs/decisions/ | .github/ | .claude/) に触れている"
fi

# 4. human 扱いなら承認を待つ — native の Approve レビューを第一級とし、
#    PR 作成者と承認者が同一アカウントで Approve できない間だけラベルを暫定 fallback にする
if $need_human; then
  reviews=$(jq -r '[.latestReviews[]?.state] | join("\n")' <<<"$pr_json")
  if grep -qx "CHANGES_REQUESTED" <<<"$reviews"; then
    fail "変更要求 (Changes requested) のレビューが未解消" \
         "指摘に対応して push し、レビュアーの承認をもらい直す (ラベルでは上書きできない)"
  fi
  if grep -qx "APPROVED" <<<"$reviews"; then
    echo "review-gate: メンテナ承認 (Approve レビュー) を確認"
  elif grep -qx "review: approved" <<<"$pr_labels"; then
    echo "review-gate: メンテナ承認 (review: approved ラベル — 同一アカウント運用の暫定 fallback) を確認"
  else
    fail "この PR はメンテナの承認が必要 (verify: human または重要パス)" \
         "メンテナが diff を確認し、レビューで Approve する (推奨)。PR 作成者と同一アカウントのため Approve できない場合のみ、暫定として review: approved ラベルを付ける (どちらも自動で再評価される)"
  fi
fi

echo "review-gate: ok"
