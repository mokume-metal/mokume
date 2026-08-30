#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ADR-0002 / ADR-0003 / ADR-0007 のマージ判定のうち、**GitHub にできないことだけ**を見る。
#   - PR は Issue に紐づく (Closes #N)。**GitHub が実際に作った紐づけを読む** —
#     本文の文字列ではない (下の「1.」)。例外は no-issue ラベルでのみ許す
#     (この no-issue が、PR に付く唯一のラベルである — ADR-0005。dependabot の
#      PR には .github/dependabot.yml が自動で付ける)
#   - 対象 Issue に verify: ラベルが無ければ、完了条件が未確定のまま実装に入っている
#   - 承認が要る PR の author が、その PR を承認できる唯一の人であってはならない
#     (ADR-0007 の不変条件。破ると **誰も承認できない PR** ができる — #88)
#   - verify: human なら人間の Approve を要求する (パス照合では表現できないため)
#
# **ここは判定だけを行い、レビュー要求は投げない。** 承認待ち (終了コード 20) を人へ
# 届けるのは scripts/request-review.sh の役目で、ci.yml の approval-signal ジョブが
# この出力を受けて呼ぶ (#498)。分けてあるので、このスクリプトは手元から読み取り専用で
# 打てる。
#
# 重要パス (docs/decisions/ ・ .github/ ・ .claude/) の承認要求も自動要求も
# **ルールセットの required_reviewers が担う** (.github/rulesets/main-protection.json)。
# 3 パスに minimum_approvals: 1 が課してあり、team maintainers へ要求が飛ぶ。ここで
# 重ねて判定しない — 下の「4.」がそのパターンを読むのは、承認が要る PR かどうかを
# 知るためだけである。
# (当初は CODEOWNERS + 承認数 0 で必須化できるつもりでいたが、承認数 0 は
#  「0 件で足りる」と読まれて非ブロックになっていた — #211 / ADR-0003 決定 4 の改訂。
#  その CODEOWNERS も #530 で畳んだ — 自動要求が二重に飛ぶだけの写しになっていた)
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
# 20 を受け取った ci.yml は human-approval を commit status の pending で報告する。
# GitHub は pending をマージのブロック側に数えつつ failure とは別の値として扱うので、
# 「待っている」と「壊れている」が外から区別できる。check run ではなく status なのは、
# check run が最初に作った run の suite に居続け、後から届く承認が最新の suite に
# 現れないためである (#282)。
#
# 使い方: review-gate.sh <PR番号> (要 GH_TOKEN / gh 認証)
set -euo pipefail

# 承認待ちの終了コード。ci.yml の approval-signal ジョブと共有する値なので、
# 変えるときは両方を直す
readonly PENDING=20

PR="${1:?PR 番号が必要}"
REPO="${GITHUB_REPOSITORY:-mokume-metal/mokume}"
# 承認が要るパスの判定 (下の「4.」を参照)。**照合は 1 か所**に保つ — request-review.sh も
# 同じ判定でパス由来の要求が飛ぶ PR を見分ける (#584・ADR-0001 原則 9)
# shellcheck source=scripts/protected-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/protected-paths.sh"

fail() {
  echo "review-gate: 差し戻し — $1" >&2
  echo "次にすること: $2" >&2
  exit 1
}

# 「誰も承認できない」の差し戻し文言。**$( … ) の中に置かない** — macOS の bash 3.2 は
# $( … ) の対応括弧を探すとき、ヒアドキュメントの本文まで走査対象にする。本文に $( や
# 行頭の # が現れるとネストや行コメントを誤認して bad substitution になる (#160 と同じ形。
# ここの文言は案内として GH_TOKEN="$(…)" と Issue 番号の両方を含むので、正しく書くほど
# 壊れる)。関数に切り出すとヒアドキュメントが $( … ) の外へ出るので誤解されない
unapprovable_message() {
  cat <<'EOF'
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

作り直したら、**新しい PR の側の run を rerun** してください。詰んだ側の run が付けた
この赤は同じ commit に残り続けるので、新しい PR の check が全部緑になっても ci-gate は
赤のままです。**詰んだ側の run を rerun してはいけません** — その run は古い PR の
イベントを持つので、何度走らせても同じ赤を再生産します (#259 の一般形とは打つ先が逆で、
#513 に実測があります):

  gh run rerun <新しい PR の run-id> --failed

メンテナ自身の PR も同じです (ADR-0007 決定 2 — 例外を作らない)。
EOF
}

pr_json=$(gh pr view "$PR" -R "$REPO" \
  --json labels,latestReviews,author,files,closingIssuesReferences)
pr_labels=$(jq -r '[.labels[].name] | join("\n")' <<<"$pr_json")

# 1. 対象 Issue の解決 — **GitHub が実際に作った紐づけを読む** (複数あれば全て検査)。
#
#    本文を正規表現で照合していた頃は、コードスパンに入れた `Closes #N` を通していた。
#    GitHub は closing keyword をコードスパン・引用・打ち消しの中では読まないので、
#    検査は緑のままマージされ、Issue は開いたまま残った (#307 の実例 → #309)。この検査が
#    守りたいのは「本文にそれらしい文字列があること」ではなく「マージしたら Issue が
#    閉じること」なので、GitHub 自身の答え (closingIssuesReferences) を見る。
#    書いてあるが効かない形はこれでまとめて弾ける。
#
#    追加の API 呼び出しは要らない — 上の gh pr view のフィールドが 1 つ増えるだけ。
#
#    他リポジトリを指す紐づけ (Closes owner/repo#N) は落とす。下の verify ラベル照会は
#    自リポの番号を前提にしており、別リポの番号をそのまま渡すと**同じ番号の無関係な
#    Issue** を見にいく (正規表現の頃はこの形に一致しなかったので、素直に読むと
#    かえって新しい誤りが入る)
issues=$(jq -r --arg repo "$REPO" '
    [ .closingIssuesReferences[]?
      | select((.repository.owner.login + "/" + .repository.name) == $repo)
      | .number ] | unique | .[]' <<<"$pr_json")
if [ -z "$issues" ]; then
  if grep -qx "no-issue" <<<"$pr_labels"; then
    echo "review-gate: no-issue ラベルによる例外 PR (Issue 紐づけなし)"
  else
    # 下のヒアドキュメントで Issue 番号を「空白 + #」の形で書かないこと。bash 3.2
    # (macOS の /bin/bash) は $( ) の対応括弧を探すときに空白直後の # を行コメントと
    # 読み、閉じ括弧ごと飲んで bad substitution になる
    fail "PR が Issue に紐づいていない (GitHub が Closes #N を認識していない)" \
         "$(cat <<'EOF'
対象 Issue を本文の目的節に 'Closes #N' で書いてください。**コードスパン (バックティック)・
引用・打ち消しの中に入れると GitHub は読まず**、書いてあっても紐づきません (#307・#309)。
書いたのに差し戻される場合は、まずそこを疑ってください。

Issue を閉じない例外 PR なら no-issue ラベルを付けて再実行します。
EOF
)"
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
#    ここは経路を問わない保険にあたる (ADR-0007 決定 3)。**常道が黙る経路がある** —
#    フックは「そのセッションが主として開いたディレクトリ」の .claude/settings.json
#    しか読まないので、別のリポジトリを主とするセッションには効かない (#513)。
#
#    判定は 2 つに分かれる。**承認が要るか**は、対象 Issue が verify: human であるか、
#    変更がルールセットの required_reviewers の file_patterns に当たるかで決まる。
#    パスの正本はルールセット (.github/rulesets/main-protection.json) で、ここでは
#    写しを持たない — CODEOWNERS を代理に読んでいた頃は同じ 3 パスが 2 ファイルに
#    綴り違いで写されていて、整合を見る検査が無かった (#530)。
#
#    **承認できる人が author しかいないか**は author_association を見る。org の中の人
#    (MEMBER / OWNER) なら、単独メンテナ構成では author 自身が唯一の承認者になる。
#    実測: App の PR は CONTRIBUTOR (#529 / #528)、#88 のメンテナの PR は MEMBER。
#    これは gh pr view --json には無いので REST を引く (ci.yml の review-gate ジョブが
#    宣言している pull-requests: read で足りる)。reviewDecision は使えない —
#    **このリポジトリでは常に空で返る**。required_approving_review_count は 0 のままで
#    (ADR-0003 決定 4)、重要パスの承認を課している required_reviewers ルールの要求は
#    reviewDecision に映らない (#249 で実測。承認して BLOCKED が CLEAN に変わった後も
#    空のまま)。承認の要否を機械で読むなら mergeStateStatus だが、CI の時点では
#    review-gate 自身の pending が混ざるので使えない。
#
#    App が作った PR は org の外なので自動的に通る。外部コントリビューターも通る —
#    メンテナが承認できるので詰んでいない。**メンテナが 2 人目に増えたときは自動で
#    緩まない** (所属しか読めず、人数を数えられないため)。そのときは 2 人目の Approve
#    が付いた時点でこの検査を抜けるので詰みはしないが、それまで赤が出る。緩めるかは
#    ADR-0007 影響が言うとおり、そのとき別途判断する。
if ! grep -qx "APPROVED" <<<"$reviews"; then
  author=$(jq -r '.author.login // ""' <<<"$pr_json")
  need_approval=$need_human
  if ! $need_approval &&
     jq -r '.files[]?.path // empty' <<<"$pr_json" | touches_protected_path; then
    need_approval=true
  fi
  if $need_approval; then
    assoc=$(gh api "repos/$REPO/pulls/$PR" --jq '.author_association' 2>/dev/null || true)
    if [ "$assoc" = "MEMBER" ] || [ "$assoc" = "OWNER" ]; then
      fail "この PR は誰も承認できない — 承認が要る PR の author ($author) が、唯一の承認者になっている (ADR-0007 / #88)" \
           "$(unapprovable_message)"
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
