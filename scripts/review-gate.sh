#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ADR-0002 / ADR-0003 / ADR-0007 のマージ判定のうち、**GitHub にできないことだけ**を見る。
#   - PR は Issue に紐づく (Closes #N)。例外は no-issue ラベルでのみ許す
#     (この no-issue が、PR に付く唯一のラベルである — ADR-0005。dependabot の
#      PR には .github/dependabot.yml が自動で付ける)
#   - 対象 Issue に verify: ラベルが無ければ、完了条件が未確定のまま実装に入っている
#   - 承認が要る PR の author が、その PR を承認できる唯一の人であってはならない
#     (ADR-0007 の不変条件。破ると **誰も承認できない PR** ができる — #88)
#   - verify: human なら人間の Approve を要求する (CODEOWNERS では表現できないため)
#
# 重要パス (docs/decisions/ ・ .github/ ・ .claude/) の承認要求は
# **ルールセットの required_reviewers が担う** (.github/rulesets/main-protection.json)。
# 同じ 3 パスに minimum_approvals: 1 が課してあり、CODEOWNERS はメンテナへの
# 自動要求と、下の「4.」が承認者集合を読むための代理を担う。ここで重ねて判定しない。
# (当初は CODEOWNERS + 承認数 0 で必須化できるつもりでいたが、承認数 0 は
#  「0 件で足りる」と読まれて非ブロックになっていた — #211 / ADR-0003 決定 4 の改訂)
#
# 承認をこのスクリプトで判定するほど「承認待ち」が CI の赤になり、外から見て故障と
# 区別できなくなる。判定を native へ寄せた分だけ、ci-gate の赤は本物の故障に近づく。
#
# 終了コードは三つに分かれる。**承認待ちだけが正常な状態**で、これを故障と同じ赤で
# 表していたために二つの害が出ていた (#111 監視の誤検出 / #256 承認しても進まない)。
#
#   0   通過
#   20  承認待ち (verify: human で Approve がまだ。人が Approve すれば解ける)
#   1   差し戻し (Issue 紐づけなし・verify ラベルなし・変更要求・誰も承認できない)
#
# 20 を受け取った ci.yml は human-approval check run を action_required で報告する。
# GitHub は action_required をマージのブロック側に数えつつ failure とは別の値として
# 扱うので、「待っている」と「壊れている」が外から区別できる。
#
# 使い方: review-gate.sh <PR番号> (要 GH_TOKEN / gh 認証)
set -euo pipefail

# 承認待ちの終了コード。ci.yml の approval-signal ジョブと共有する値なので、
# 変えるときは両方を直す
readonly PENDING=20

PR="${1:?PR 番号が必要}"
REPO="${GITHUB_REPOSITORY:-mokume-metal/mokume}"
# 承認者集合の読める代理 (下の「4.」を参照)。テストは別のファイルを指す
CODEOWNERS_FILE="${CODEOWNERS_FILE:-$(cd "$(dirname "$0")/.." && pwd)/.github/CODEOWNERS}"

fail() {
  echo "review-gate: 差し戻し — $1" >&2
  echo "次にすること: $2" >&2
  exit 1
}

# CODEOWNERS の 1 パターンが 1 ファイルに一致するか。
# git のパターン照合のうち、CODEOWNERS が実際に使う形を扱う — ルート起点の
# ディレクトリ接頭辞 (/.github/)、パスの完全一致とその配下 (docs/x.md)、
# スラッシュ無しの任意階層一致 (*.md)。glob は bash に委ねるので `*` が
# パス区切りをまたぐ点だけ git と違う (このリポジトリの CODEOWNERS には無い形)
codeowners_match() { # $1=パターン $2=ファイルパス
  local pattern=${1#/} path=$2
  case "$pattern" in
    */) [[ $path == $pattern* ]] ;;
    */*) [[ $path == $pattern || $path == $pattern/* ]] ;;
    *) [[ ${path##*/} == $pattern || $path == $pattern/* || $path == */$pattern/* ]] ;;
  esac
}

# CODEOWNERS に名前が挙がっている owner をすべて出す (@ は落とす)
codeowners_all() {
  [ -f "$CODEOWNERS_FILE" ] || return 0
  sed 's/#.*//' "$CODEOWNERS_FILE" |
    awk 'NF > 1 { for (i = 2; i <= NF; i++) { sub(/^@/, "", $i); print $i } }' | sort -u
}

# 標準入力のファイル群 (1 行 1 件) に効く owner を出す。
# CODEOWNERS は **最後に一致した規則が勝つ**ので、規則を上から舐めて上書きする
# (owner を書かない規則は所有を外すため、上書きの結果が空なら所有者なし)
codeowners_owners_for() {
  local paths path line pattern rest hit
  paths=$(cat)
  [ -f "$CODEOWNERS_FILE" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    hit=""
    while IFS= read -r line; do
      line=${line%%#*}
      [ -n "${line//[[:space:]]/}" ] || continue
      pattern=${line%%[[:space:]]*}
      rest=${line#"$pattern"}
      if codeowners_match "$pattern" "$path"; then hit=$rest; fi
    done < "$CODEOWNERS_FILE"
    printf '%s\n' $hit
  done <<<"$paths" | sed 's/^@//' | awk 'NF' | sort -u
}

pr_json=$(gh pr view "$PR" -R "$REPO" --json body,labels,latestReviews,author,files)
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

# 3. 変更要求は承認より強い
reviews=$(jq -r '[.latestReviews[]?.state] | join("\n")' <<<"$pr_json")
if grep -qx "CHANGES_REQUESTED" <<<"$reviews"; then
  fail "変更要求 (Changes requested) のレビューが未解消" \
       "指摘に対応して push し、レビュアーの承認をもらい直す"
fi

# 4. 承認可能性の不変条件 (ADR-0007 決定 1)。
#    「承認が要る PR の author は、その PR を承認できる集合の要素であってはならない」。
#    破ると承認を待っても永久に来ない — GitHub は自分の PR を自分で承認できず、author は
#    後から変えられない。PR 作成前のフック (scripts/pr-identity-guard.sh) が常道で、
#    ここは経路を問わない保険にあたる (ADR-0007 決定 3)。
#
#    承認者集合の**読める代理は .github/CODEOWNERS だけ**である。collaborator の一覧は
#    Administration 権限を要求し、ADR-0003 決定 1 でエージェントの App は持たない
#    (ci.yml の review-gate ジョブも contents/issues/pull-requests の read しか宣言
#    していない)。reviewDecision も使えない — **このリポジトリでは常に空で返る**。
#    required_approving_review_count は 0 のままで (ADR-0003 決定 4)、重要パスの
#    承認を課している required_reviewers ルールの要求は reviewDecision に映らない
#    (#249 で実測。承認して BLOCKED が CLEAN に変わった後も空のまま)。承認の要否を
#    機械で読むなら mergeStateStatus を見る。CODEOWNERS ならチェックアウト済みの
#    ファイルを読むだけで済む。
#
#    App が作った PR は集合に入りようがない (CODEOWNERS にはユーザーとチームしか
#    書けない) ので自動的に通る。外部コントリビューターも通る — メンテナが承認できる
#    ので詰んでいない。詰むのは「author が唯一の承認者」のときだけで、これはメンテナが
#    増えれば自動で緩む。
if ! grep -qx "APPROVED" <<<"$reviews"; then
  author=$(jq -r '.author.login // ""' <<<"$pr_json")
  if $need_human; then
    # verify: human が求めるのは「メンテナの承認」で、その集合は CODEOWNERS 全体を代理にする
    approvers=$(codeowners_all)
  else
    approvers=$(jq -r '.files[]?.path // empty' <<<"$pr_json" | codeowners_owners_for)
  fi
  if [ -n "$author" ] && [ -n "$approvers" ] && grep -qxF "$author" <<<"$approvers"; then
    others=$(grep -vxF "$author" <<<"$approvers" || true)
    if [ -z "$others" ]; then
      fail "この PR は誰も承認できない — 承認が要る PR の author ($author) が、唯一の承認者になっている (ADR-0007 / #88)" \
           "$(cat <<'EOF'
この PR を close し、GitHub App の identity で作り直してください。**承認を待っても
永久に来ません** — GitHub は自分の PR を自分で承認できず、PR の author は後から
変えられないためです。

  GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && gh pr create ...

代入から始めるのが要点です。export を先頭に付けると終了コードが 0 に化けて、token の
発行に失敗しても後段が走り、同じ詰みを繰り返します (#122)。

`MOKUME_APP_PRIVATE_KEY_CMD` が未設定でも「鍵が無い」と即断しないでください。手元の
秘密管理には「自動化から読んでよい秘密の一覧」があるのが普通なので、まずその一覧を
引いて、このリポジトリの App の鍵が載っていないかを見ます (在処そのものを読む必要は
ありません)。一覧にも無ければ PR を作らず、鍵の渡し方を人に尋ねてください。

メンテナ自身の PR も同じです (ADR-0007 決定 2 — 例外を作らない)。
EOF
)"
    fi
  fi
fi

# 5. verify: human は人間の Approve を待つ。
#    完了条件が機械で判定できないと宣言した以上、誰かが見るまで通さない。
#    重要パスの場合はルールセットの required_reviewers も並行して承認を要求する
#    (こちらが緑でも native 側で止まる)
#
#    **ここだけは差し戻しではなく「承認待ち」で抜ける** (終了コード 20)。上の 1〜4 は
#    直さないと進めない故障だが、承認待ちは正常な途中経過で、人が Approve すれば解ける。
#    区別しないと ci-gate が承認待ちで赤くなり、二つの害が出る (#111 / #256 — 詳細は
#    冒頭のコメント)。
if $need_human && ! grep -qx "APPROVED" <<<"$reviews"; then
  echo "review-gate: 承認待ち — verify: human の Issue に紐づく PR はメンテナの承認が必要"
  echo "次にすること: メンテナが diff を確認して Approve する (Files changed → Review changes → Approve、または gh pr review $PR --approve)。承認すると自動で再評価される"
  exit "$PENDING"
fi
if $need_human; then echo "review-gate: メンテナ承認 (Approve レビュー) を確認"; fi

echo "review-gate: ok"
