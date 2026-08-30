#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ADR-0002 / ADR-0007 / ADR-0031 のマージ判定のうち、**GitHub にできないことだけ**を見る。
#   - PR は Issue に紐づく (Closes #N)。**GitHub が実際に作った紐づけを読む** —
#     本文の文字列ではない (下の「1.」)。例外は no-issue ラベルでのみ許す
#     (この no-issue が、PR に付く唯一のラベルである — ADR-0005。dependabot の
#      PR には .github/dependabot.yml が自動で付ける)
#   - 対象 Issue に verify: ラベルが無ければ、完了条件が未確定のまま実装に入っている
#   - PR 本文の「確認方法」節に、閉じる Issue の番号がすべて現れる (ADR-0031 決定 2)
#   - 承認が要る PR の author が、その PR を承認できる唯一の人であってはならない
#     (ADR-0007 の不変条件。破ると **誰も承認できない PR** ができる — #88)
#
# **承認そのものはここで判定しない。** 要求も必須化もルールセットの required_reviewers
# が担う (.github/rulesets/main-protection.json — 3 パスに minimum_approvals: 1 を課して
# team maintainers へ要求が飛ぶ)。下の「4.」がそのパターンを読むのは、承認が要る PR か
# どうかを知るためだけである。
# (当初は CODEOWNERS + 承認数 0 で必須化できるつもりでいたが、承認数 0 は
#  「0 件で足りる」と読まれて非ブロックになっていた — #211 / ADR-0003 決定 4 の改訂。
#  その CODEOWNERS も #530 で畳んだ — 自動要求が二重に飛ぶだけの写しになっていた)
#
# ## かつてここには承認待ちがあった
#
# verify: human の Issue に紐づく PR には Approve を要求し、待っている間を終了コード 20 で
# 表していた (ADR-0002 決定 3)。263 件のマージで測ったところ、**この経路が固有に承認を
# 要求したのは 36 件で、変更要求は 1 件も出ず、初承認までの中央値は 11 分**だった —
# 止めていたのではなく待たせていただけである (#618)。ADR-0031 がこれを畳み、代わりに
# 上の 3 つ目 (対応表) を置いた。
#
# 承認をこのスクリプトで判定しないほど、ci-gate の赤は本物の故障に近づく。20 を扱う
# ci.yml の approval-signal ジョブと scripts/request-review.sh も一緒に消えた —
# #111 / #256 / #282 / #494 / #575 / #577 / #583 / #584 が積んだ修正は、どれも
# 「ラベル由来の承認がある」前提では正しかった。前提のほうを畳んだのであって、
# それらが間違っていたわけではない。
#
# 終了コードは 2 つ。
#
#   0   通過
#   1   差し戻し (Issue 紐づけなし・verify ラベルなし・対応表なし・変更要求・
#       誰も承認できない)
#
# 使い方: review-gate.sh <PR番号> (要 GH_TOKEN / gh 認証)
set -euo pipefail

PR="${1:?PR 番号が必要}"
REPO="${GITHUB_REPOSITORY:-mokume-metal/mokume}"
# 承認が要るパスの判定 (下の「4.」を参照)。**照合は 1 か所**に保つ (ADR-0001 原則 9)
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

# 対応表が無いときの差し戻し文言。上と同じ理由で $( … ) の外に置く
missing_table_message() {
  cat <<'EOF'
PR 本文の「## 確認方法」節に、閉じる Issue ごとに **完了条件と、それを何でどう
確かめたか** を書いてください。まとめて閉じるなら Issue ごとに分けて書きます。

  ## 確認方法

  ### Closes #123

  | 完了条件 | 着手時の現況 | 確かめたこと |
  | --- | --- | --- |
  | 1. …… | まだ有効 | `make ci-check` が緑 (…) |

**見ているのは番号が現れることだけで、中身の正しさは見ていません** (絵の検査と同じ形
— ADR-0019 決定 1)。防いでいるのは書き忘れであって、正しさの担い手は読む人間と AI の
目です。本文を編集すれば CI は自動で再評価されます。

Issue を閉じない例外 PR なら no-issue ラベルを付けてください (この検査ごと外れます)。
EOF
}

pr_json=$(gh pr view "$PR" -R "$REPO" \
  --json body,labels,latestReviews,author,files,closingIssuesReferences)
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
#    **複数を閉じてよい** (ADR-0031 決定 3)。1 PR の粒度は「1 つの説明で筋が通る範囲」で、
#    同じ親の sub-issue 群も、作業中に踏んで起票した障害もまとめられる。粒度が大きく
#    なっても追跡が効くのは、下の「3.」が Issue ごとに対応表を要求するからである。
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

# 2. 各対象 Issue の verify ラベル。
#
#    **見るのは有無だけである** (ADR-0031 決定 1)。かつては verify: machine と
#    verify: human を読み分け、後者に人間の Approve を要求していたが、分類そのものが
#    実測で機能していなかった (#618 — 上の「かつてここには承認待ちがあった」)。
#    ラベルが表すのは「完了条件が固まっている」ことだけになった。
#
#    **不在が未トリアージを表す**構造は変わらない。付け損ねれば Issue はラベルを
#    持たないまま = 着手できない状態で残る (ADR-0002 決定 1 が status: needs-triage を
#    廃止したときと向きが揃っている)
for n in $issues; do
  ilabels=$(gh issue view "$n" -R "$REPO" --json labels --jq '[.labels[].name] | join("\n")')
  if grep -q '^verify: ' <<<"$ilabels"; then
    echo "review-gate: #$n はトリアージ済み"
  else
    fail "対象 Issue #$n に verify: ラベルが無い (完了条件が未確定のまま実装に入っている)" \
         "Issue で議論して完了条件を本文に固め、verify: triaged を付けてから、この check を再実行する (Actions の re-run か空 push。Issue 側のラベル操作では自動再実行されない)"
  fi
done

# 3. 完了条件 × 検証の対応表 (ADR-0031 決定 2)。
#
#    承認を外した代わりに置いた記録である。**見るのは構造の有無だけ** — 「確認方法」の
#    節があり、閉じる Issue の番号がそこにすべて現れることを見て、書いてある内容が
#    正しいかは見ない。scripts/check-drawing-evidence.sh と同じ形で (ADR-0019 決定 1)、
#    防いでいるのは書き忘れであって意図的な迂回ではない。
#
#    節の綴りは .github/pull_request_template.md と揃える。見出しの階層は問わない
#    (## でも ### でもよい) が、「確認方法」を含む見出しから次の同階層以上の見出しまでを
#    節とみなす。
#
#    no-issue の PR には閉じる Issue が無いので、対応する完了条件も無い — 検査ごと外れる。
#
#    実測の背景: 直近 100 PR に付いたコメントは 32 件 (0.32/PR)、行単位のレビューは
#    0 件だった。承認が形式であっても「人が一度見た」という印ではあったので、外すなら
#    代わりの記録が要る (#618)
if [ -n "$issues" ]; then
  # 「確認方法」を含む見出しから、開始より浅い (または同じ) 見出しが来るまでを節とみなす。
  # 節の中の小見出し (### Closes #N) は内容として残す — 番号がそこにしか無い書き方が
  # 自然だからである
  section=$(jq -r '.body // ""' <<<"$pr_json" | awk '
    /^#+[[:space:]]/ {
      match($0, /^#+/); lvl = RLENGTH
      if ($0 ~ /確認方法/) { inside = 1; start = lvl; next }
      if (inside && lvl <= start) inside = 0
    }
    inside { print }
  ')
  missing=""
  # -w で境界を見る。#618 は拾い #6180 は拾わない。**グループの中に ^ や $ を書かない** —
  # POSIX の ERE ではアンカーの位置が未定義で、BSD grep は (^|[^0-9])#N([^0-9]|$) を
  # 一致させない (macOS の手元だけ静かに素通りする形になる)
  for n in $issues; do
    grep -qw "#$n" <<<"$section" || missing="$missing #$n"
  done
  if [ -n "$missing" ]; then
    fail "PR 本文の「確認方法」節に、閉じる Issue の対応表が無い (${missing# })" \
         "$(missing_table_message)"
  fi
  echo "review-gate: 確認方法の節に対象 Issue の対応表を確認"
fi

# 4. 変更要求は承認より強い
reviews=$(jq -r '[.latestReviews[]?.state] | join("\n")' <<<"$pr_json")
if grep -qx "CHANGES_REQUESTED" <<<"$reviews"; then
  fail "変更要求 (Changes requested) のレビューが未解消" \
       "指摘に対応して push し、レビュアーの承認をもらい直す"
fi

# 5. 承認可能性の不変条件 (ADR-0007 決定 1)。
#    「承認が要る PR の author は、その PR を承認できる集合の要素であってはならない」。
#    破ると承認を待っても永久に来ない — GitHub は自分の PR を自分で承認できず、author は
#    後から変えられない。PR 作成前のフック (scripts/pr-identity-guard.sh) が常道で、
#    ここは経路を問わない保険にあたる (ADR-0007 決定 3)。**常道が黙る経路がある** —
#    フックは「そのセッションが主として開いたディレクトリ」の .claude/settings.json
#    しか読まないので、別のリポジトリを主とするセッションには効かない (#513)。
#
#    判定は 2 つに分かれる。**承認が要るか**は、変更がルールセットの required_reviewers の
#    file_patterns に当たるかで決まる。パスの正本はルールセット
#    (.github/rulesets/main-protection.json) で、ここでは写しを持たない — CODEOWNERS を
#    代理に読んでいた頃は同じ 3 パスが 2 ファイルに綴り違いで写されていて、整合を見る
#    検査が無かった (#530)。
#    (verify: human も承認を要求していた頃は、この判定に「対象 Issue の性質」が
#     混ざっていた。ADR-0031 がラベル由来を畳んだので、いま読むのはパスだけである)
#
#    **承認できる人が author しかいないか**は author_association を見る。org の中の人
#    (MEMBER / OWNER) なら、単独メンテナ構成では author 自身が唯一の承認者になる。
#    実測: App の PR は CONTRIBUTOR (#529 / #528)、#88 のメンテナの PR は MEMBER。
#    これは gh pr view --json には無いので REST を引く (ci.yml の review-gate ジョブが
#    宣言している pull-requests: read で足りる)。reviewDecision は使えない —
#    **このリポジトリでは常に空で返る**。required_approving_review_count は 0 のままで
#    (ADR-0003 決定 4)、重要パスの承認を課している required_reviewers ルールの要求は
#    reviewDecision に映らない (#249 で実測。承認して BLOCKED が CLEAN に変わった後も
#    空のまま)。
#
#    App が作った PR は org の外なので自動的に通る。外部コントリビューターも通る —
#    メンテナが承認できるので詰んでいない。**メンテナが 2 人目に増えたときは自動で
#    緩まない** (所属しか読めず、人数を数えられないため)。そのときは 2 人目の Approve
#    が付いた時点でこの検査を抜けるので詰みはしないが、それまで赤が出る。緩めるかは
#    ADR-0007 影響が言うとおり、そのとき別途判断する。
if ! grep -qx "APPROVED" <<<"$reviews"; then
  author=$(jq -r '.author.login // ""' <<<"$pr_json")
  if jq -r '.files[]?.path // empty' <<<"$pr_json" | touches_protected_path; then
    assoc=$(gh api "repos/$REPO/pulls/$PR" --jq '.author_association' 2>/dev/null || true)
    if [ "$assoc" = "MEMBER" ] || [ "$assoc" = "OWNER" ]; then
      fail "この PR は誰も承認できない — 承認が要る PR の author ($author) が、唯一の承認者になっている (ADR-0007 / #88)" \
           "$(unapprovable_message)"
    fi
  fi
fi

echo "review-gate: ok"
