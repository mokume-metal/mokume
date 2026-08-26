#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ADR-0002 / ADR-0003 のマージ判定のうち、**GitHub にできないことだけ**を見る。
#   - PR は Issue に紐づく (Closes #N)。例外は no-issue ラベルでのみ許す
#     (この no-issue が、PR に付く唯一のラベルである — ADR-0005。dependabot の
#      PR には .github/dependabot.yml が自動で付ける)
#   - 対象 Issue に verify: ラベルが無ければ、完了条件が未確定のまま実装に入っている
#   - verify: human なら人間の Approve を要求する (CODEOWNERS では表現できないため)
#
# 重要パス (docs/decisions/ ・ .github/ ・ .claude/) の承認要求は **CODEOWNERS が担う**。
# エージェントは GitHub App の identity で PR を作るので、自分の PR を自分で承認できず、
# CODEOWNERS にはユーザーとチームしか書けない。ここで重ねて判定する必要はない。
#
# 承認をこのスクリプトで判定するほど「承認待ち」が CI の赤になり、外から見て故障と
# 区別できなくなる。判定を native へ寄せた分だけ、ci-gate の赤は本物の故障に近づく。
#
# 使い方: review-gate.sh <PR番号> (要 GH_TOKEN / gh 認証)
set -euo pipefail

PR="${1:?PR 番号が必要}"
REPO="${GITHUB_REPOSITORY:-mokume-metal/mokume}"

fail() {
  echo "review-gate: 差し戻し — $1" >&2
  echo "次にすること: $2" >&2
  exit 1
}

pr_json=$(gh pr view "$PR" -R "$REPO" --json body,labels,latestReviews)
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

# 3. verify: human は人間の Approve を待つ。
#    完了条件が機械で判定できないと宣言した以上、誰かが見るまで通さない。
#    重要パスの場合は CODEOWNERS も並行して承認を要求する (こちらが緑でも native 側で止まる)
reviews=$(jq -r '[.latestReviews[]?.state] | join("\n")' <<<"$pr_json")
if grep -qx "CHANGES_REQUESTED" <<<"$reviews"; then
  fail "変更要求 (Changes requested) のレビューが未解消" \
       "指摘に対応して push し、レビュアーの承認をもらい直す"
fi

if $need_human; then
  if grep -qx "APPROVED" <<<"$reviews"; then
    echo "review-gate: メンテナ承認 (Approve レビュー) を確認"
  else
    fail "verify: human の Issue に紐づく PR はメンテナの承認が必要" \
         "メンテナが diff を確認して Approve する (Files changed → Review changes → Approve、または gh pr review $PR --approve)。承認すると自動で再評価される"
  fi
fi

echo "review-gate: ok"
