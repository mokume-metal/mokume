#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ADR-0002 / ADR-0031 のマージ判定のうち、**GitHub にできないことだけ**を見る。
#   - PR は Issue に紐づく (Closes #N)。**GitHub が実際に作った紐づけを読む** —
#     本文の文字列ではない (下の「1.」)。例外は no-issue ラベルでのみ許す
#     (この no-issue が、PR に付く唯一のラベルである — ADR-0005。dependabot の
#      PR には .github/dependabot.yml が自動で付ける)
#   - 対象 Issue に verify: ラベルが無ければ、完了条件が未確定のまま実装に入っている
#   - PR 本文の「確認方法」節に、閉じる Issue の番号がすべて現れる (ADR-0031 決定 2)
#   - 閉じる Issue に Bug が含まれるなら、PR 本文に空でない「反証」の節がある
#     (ADR-0040 決定 4 — 下の「4.」)
#   - AGENTS.md を合流先との分岐点より長くした PR は、本文に増分の宣言があり実測と一致する
#     (#1668 — 下の「AGENTS.md の増分」)
#
# **承認はどこでも判定しない。** ルールセットは承認を要求せず (ADR-0044)、ここが見るのは
# 変更要求 (Changes requested) が残っていないことだけである (下の「5.」)。
# かつてはルールセットの required_reviewers が重要パスに承認を要求し、下に「誰も承認できない
# PR」を差し戻す節 (ADR-0007 の不変条件) があった。ADR-0044 が承認のゲートごと外した (#2108)。
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
#   1   差し戻し (Issue 紐づけなし・verify ラベルなし・対応表なし・反証の節なし・
#       変更要求・対象 Issue を読めない・AGENTS.md の増分が宣言と
#       合わない・AGENTS.md を読めない)
#
# 使い方: review-gate.sh <PR番号> (要 GH_TOKEN / gh 認証)
set -euo pipefail

PR="${1:?PR 番号が必要}"
# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"
# 変更ファイルの取り方は 1 か所に保つ (#793) — gh pr view の files は上限のある口なので、
# 大きな PR では一覧からファイルが落ちる
# shellcheck source=scripts/pr-files.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-files.sh"

fail() { # $1=理由 $2=次にすること (省略可)
  echo "review-gate: 差し戻し — $1" >&2
  # **省いた呼び出しを bash のエラーにしない。** set -u の下で素の $2 を読むと、
  # 理由の行の直後に「unbound variable」が並ぶ (#864)
  [ $# -lt 2 ] || echo "次にすること: $2" >&2
  exit 1
}

# 差し戻しの後に本文を直す・ラベルを付ける人への案内 (#2134)。**「本文を編集すれば CI は
# 自動で再評価される」と約束してはならない。** 編集やラベルの付け外しで新しい run は走り、
# このゲートは付け直されるが、先の run の ci-gate (このゲートが赤だった run のもの) は同じ
# コミットに赤く残り、新しい run が緑でも必須チェックを固定する (#259 の実測)。「再評価
# される」と「必須チェックが緑になる」は別なので、打ち直しまで案内する。このゲートは実行の
# たびに API から本文とラベルを読むので、打ち直せば通る。差し戻しの文言 2 つが同じ末尾を
# 持つので、ここ 1 箇所に置く。呼び出し側と違い heredoc を引用しない — run の id を埋める
# ため。bash 3.2 の $( … ) の件 (下) は、この関数が $( … ) の外にあるので当たらない
rerun_note() {
  cat <<EOF
**本文を直したり、ラベルを付けたりしただけでは、必須チェックは緑になりません。** 新しい run が
走ってこのゲートは付け直されますが、同じコミットに残る古い赤い ci-gate は、新しい run が緑
でも必須チェックを固定します (#259)。直したあと、赤い run が終わってから、その run を
打ち直してください (赤い run が複数あればそれぞれ):

  gh run rerun ${GITHUB_RUN_ID:-<run-id>} --failed

このゲートは実行のたびに本文とラベルを読み直すので、打ち直せば通ります。打たなくても
stall-watch の当番がいずれ打ち直します (数時間おき・Draft を除く)。pr-title も赤い run は、
打ち直すと元のタイトルを再生して同じ赤を返します (#699) — 新しいコミットを push して run を
作り直してください。
EOF
}

# 対応表が無いときの差し戻し文言。**$( … ) の中に置かない** — macOS の bash 3.2 は
# $( … ) の対応括弧を探すとき、ヒアドキュメントの本文まで走査対象にし、本文の $( や行頭の #
# を誤認して bad substitution になる (#160 と同じ形)。関数に切り出すと $( … ) の外へ出る
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
目です。

Issue を閉じない例外 PR なら no-issue ラベルを付けてください (この検査ごと外れます)。

EOF
  rerun_note
}

# 反証の節が無い・空のときの差し戻し文言。上と同じ理由で $( … ) の外に置く
missing_refute_message() {
  cat <<'EOF'
閉じる Issue に Bug が含まれる PR は、本文に「## 反証」節を置き、独立した反証役の
指摘と、それぞれへの応えを書いてください (ADR-0040 決定 4)。

  ## 反証

  | 指摘 | 根拠 | 応え |
  | --- | --- | --- |
  | 同じ形の口がもう 1 つある | Sources/…/Foo.swift:42 | 直した (この PR) |
  | 呼び出し元の … が壊れうる | Sources/…/Bar.swift:17 | 起票した #N |
  | 根ではなく症状を塞いでいる | Sources/…/Baz.swift:88 | 当たらない: 理由 |

反証役はプランも完了条件も渡されないサブエージェントで、Issue の症状と差分だけから
兄弟の口・壊しうる経路・根か症状かを探します。起動手順は
.claude/skills/bug-refute/SKILL.md にあります。指摘が 1 件も無かったなら、そう書けば
空ではありません。

**見ているのは節があって中身が空でないことだけで、中身の正しさは見ていません**
(確認方法の対応表と同じ形 — ADR-0019 決定 1)。HTML コメントだけの節は空とみなします。

EOF
  rerun_note
}

# PR 本文 (標準入力) から、$1 を含む見出しの節を切り出す。開始より浅い (または同じ)
# 見出しが来るまでを節とみなし、節の中の小見出しは内容として残す。見出しの階層は
# 問わない (## でも ### でもよい)。
#
# **切り出しの形は 1 つに保つ** — 「確認方法」(下の「3.」) と「反証」(下の「4.」) で
# 同じ規則を使う。写しを 2 つ持つと、片方だけが直って節の境界が食い違う (#1662)
body_section() {
  awk -v word="$1" '
    /^#+[[:space:]]/ {
      match($0, /^#+/); lvl = RLENGTH
      if (index($0, word)) { inside = 1; start = lvl; next }
      if (inside && lvl <= start) inside = 0
    }
    inside { print }
  '
}

# 標準入力から HTML コメント (<!-- … -->、行をまたいでよい) を除く。テンプレートの
# 案内はコメントで書かれているので、見出しだけ残して中身を書かなかった節は、これを
# 通すと空白だけになる
strip_html_comments() {
  awk '
    {
      line = $0; out = ""
      while (1) {
        if (incomment) {
          e = index(line, "-->")
          if (!e) { line = ""; break }
          line = substr(line, e + 3); incomment = 0
        }
        s = index(line, "<!--")
        if (!s) { out = out line; break }
        out = out substr(line, 1, s - 1); line = substr(line, s + 4); incomment = 1
      }
      print out
    }
  '
}

pr_json=$(gh pr view "$PR" -R "$REPO" \
  --json body,labels,latestReviews,closingIssuesReferences,baseRefName,headRefOid)
pr_labels=$(jq -r '[.labels[].name] | join("\n")' <<<"$pr_json")
# **変更ファイルだけ別の口から取る** (#793)。同じ gh pr view にまとめると呼び出しは
# 1 回で済むが、files は GraphQL の接続で上限があり、大きな PR では後半が落ちる —
# 落ちても赤くならず、AGENTS.md の増分の判定 (下の「6.」) が黙って素通りする。呼び出しが 1 回増えるのは
# 正しさとの引き換えである。読めなければここで落ちる (上の pr_json と同じ向き)
pr_paths=$(pr_files "$REPO" "$PR")

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
対象 Issue を本文の「確認方法」節に '### Closes #N' の小見出しで書いてください (PR テンプレートの
見本の形)。**コードスパン (バックティック)・引用・打ち消しの中に入れると GitHub は読まず**、
書いてあっても紐づきません (#307・#309)。
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
#
#    同じ応答から Issue の型も控える (下の「4.」が読む)。問い合わせを分けないのは、
#    1 回で取れるものを 2 回引かないためである。
#
#    **読めなかったら理由を名乗って落ちる。** 代入の中の gh が失敗すると set -e で
#    そのまま終わり、review-gate としては何も言わずに赤くなる。issueType は gh 2.94.0
#    からの欄で (scripts/ready-queue.sh の冒頭)、CI の gh がそれより古ければここに当たる。
#    欄が応答に無いときも同じに扱う — 型が分からないまま Bug でないと読むと、4. が
#    黙って外れる (#1662)
bug_issues=""
for n in $issues; do
  ijson=$(gh issue view "$n" -R "$REPO" --json labels,issueType) ||
    fail "対象 Issue #$n の labels / issueType を読めなかった (上の gh のエラーを参照)" \
         "gh が issueType を知らない版なら (gh 2.94.0 から) gh を上げる。権限や通信の失敗なら、直してからこの check を再実行する"
  jq -e 'has("issueType")' <<<"$ijson" >/dev/null ||
    fail "対象 Issue #$n の応答に issueType が無い (Bug かどうかを判定できない)" \
         "gh を 2.94.0 以降に上げて、この check を再実行する"
  ilabels=$(jq -r '[.labels[].name] | join("\n")' <<<"$ijson")
  if [ "$(jq -r '.issueType.name // ""' <<<"$ijson")" = "Bug" ]; then
    bug_issues="$bug_issues #$n"
  fi
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
  section=$(jq -r '.body // ""' <<<"$pr_json" | body_section 確認方法)
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

# 4. Bug を閉じる PR の反証 (ADR-0040 決定 4)。
#
#    直近の fix PR 23 件は、原因の特定と再現テストはよくできていたが、兄弟の口を探さず、
#    同じ根のバグが後から 1 件ずつ出ていた。レビューコメントは 0 件で、棚卸し・プラン・
#    実装・検証を同じエージェントが担うので、**完了条件の範囲がそのまま調べる範囲の
#    上限になる** (#1659)。プランと完了条件を渡されない反証役の指摘と、それへの応え
#    (直した / 起票した / 当たらない+理由) を PR 本文に残させる。
#
#    **見るのは構造の有無だけである** — 「反証」を含む見出しの節があり、HTML コメントと
#    空白を除いて中身が残ること。指摘の質も応えの妥当性も見ない (3. と同じ形 —
#    ADR-0019 決定 1)。防いでいるのは反証役を起こし忘れることで、意図的な迂回ではない。
#
#    節の綴りは .github/pull_request_template.md の「## 反証」と揃える。境界の規則は 3. と
#    同じ (body_section)。
#
#    対象は閉じる Issue に Bug 型が 1 つでも含まれる PR だけ。Bug でない PR には問わない
#    (同じ PR でまとめて閉じる Task・Docs があっても、Bug があれば問う)。
#
#    採られた率 (指摘のうち「直した」「起票した」の割合) がほぼ 0 なら畳む (ADR-0040
#    決定 4)。数え直しは #1663
if [ -n "$bug_issues" ]; then
  refute=$(jq -r '.body // ""' <<<"$pr_json" | body_section 反証)
  # 見出しだけの節 (中身が空) と節そのものが無い場合を分けて名乗る。見出しの有無は
  # 本文の見出し行を直接見る — 切り出した中身が空でも見出しはあったかもしれない
  # **here-string で読む** (#1900)。pipefail の下で `… | grep -q` と書くと、grep が最初の行で
  # 抜けたときに書き手が SIGPIPE で止まり、長い本文ほど条件が裏返る
  body=$(jq -r '.body // ""' <<<"$pr_json")
  if ! grep -Eq '^#+[[:space:]].*反証' <<<"$body"; then
    fail "閉じる Bug (${bug_issues# }) の PR 本文に「反証」の節が無い (ADR-0040 決定 4)" \
         "$(missing_refute_message)"
  fi
  refute_text=$(strip_html_comments <<<"$refute")
  if ! grep -q '[^[:space:]]' <<<"$refute_text"; then
    fail "閉じる Bug (${bug_issues# }) の PR 本文の「反証」の節が空 (ADR-0040 決定 4)" \
         "$(missing_refute_message)"
  fi
  echo "review-gate: 反証の節を確認 (${bug_issues# })"
fi

# 5. 変更要求が残っていない
reviews=$(jq -r '[.latestReviews[]?.state] | join("\n")' <<<"$pr_json")
if grep -qx "CHANGES_REQUESTED" <<<"$reviews"; then
  fail "変更要求 (Changes requested) のレビューが未解消" \
       "指摘に対応して push し、レビュアーに変更要求を解いてもらう"
fi

# 6. AGENTS.md の増分 (#1668)。
#
#    AGENTS.md は毎セッション全文が読まれる固定費なので、増やす PR には本文に宣言の 1 行
#    (行全体で「AGENTS.md の増分: +N」) を求め、実測と突き合わせる。縮めた PR と触れて
#    いない PR は宣言なしで通る。**比べる相手は base の先端ではなく merge-base** — 先端と
#    比べると、後から入った他の PR の増減が自分の増分に混ざる。数え方と宣言の読み方は
#    check-agents-md-size.py の growth が持ち、ここは材料を取って渡すだけである (冒頭の
#    「1.」「数え方」がその理由)。
#
#    以前は字数の記録値を 1 行のファイルに置いていたが、AGENTS.md に触れる PR が同時に
#    2 本あるとその 1 行だけが衝突し、承認の取り直しを生んだ (#1668)。
#
#    no-issue の PR にも効かせる (上の 3. と違い、閉じる Issue の有無と関係が無い)。
#
#    **AGENTS.md に触れず、宣言らしき文字列も無ければ API を呼ばない。** 宣言の有無は
#    粗く見る — 文中で触れただけの行も呼ぶ側に倒すが、そのときは growth が「宣言なし・
#    増分 0」として緑を返すだけである。宣言の形の揺れを名指しするのは growth の側。
#
#    本文は \r を落とし、HTML コメントを除いてから渡す (テンプレートの案内はコメントに
#    書いてあり、そこの例を宣言と読まないため)。取得に失敗したら理由を名乗って落ちる —
#    読めないまま通すと、増分の検査が黙って外れる
agents_body=$(jq -r '.body // ""' <<<"$pr_json" | tr -d '\r' | strip_html_comments)
if grep -qx 'AGENTS.md' <<<"$pr_paths" ||
   grep -q 'AGENTS\.md の増分' <<<"$agents_body"; then
  base_ref=$(jq -r '.baseRefName // ""' <<<"$pr_json")
  head_oid=$(jq -r '.headRefOid // ""' <<<"$pr_json")
  [ -n "$base_ref" ] && [ -n "$head_oid" ] ||
    fail "PR の base / head を読めなかった (AGENTS.md の増分を比べられない)" \
         "gh pr view が baseRefName / headRefOid を返すか確かめて、この check を再実行する"
  merge_base=$(gh api "repos/$REPO/compare/${base_ref}...${head_oid}" --jq '.merge_base_commit.sha') ||
    fail "$base_ref と $head_oid の merge-base を引けなかった (上の gh のエラーを参照)" \
         "権限や通信の失敗なら、直してからこの check を再実行する"
  [[ "$merge_base" =~ ^[0-9a-f]{40}$ ]] ||
    fail "compare API が merge-base の SHA を返さなかった (読めた値: '$merge_base')" \
         "権限や通信の失敗なら、直してからこの check を再実行する"
  agents_dir=$(mktemp -d)
  trap 'rm -rf "$agents_dir"' EXIT
  for side in "base:$merge_base" "head:$head_oid"; do
    gh api -H 'Accept: application/vnd.github.raw' \
      "repos/$REPO/contents/AGENTS.md?ref=${side#*:}" >"$agents_dir/${side%%:*}" ||
      fail "AGENTS.md を ${side#*:} で読めなかった (上の gh のエラーを参照)" \
           "権限や通信の失敗なら、直してからこの check を再実行する"
  done
  if ! growth=$(python3 "$(dirname "${BASH_SOURCE[0]}")/check-agents-md-size.py" growth \
                  "$agents_dir/base" "$agents_dir/head" <<<"$agents_body" 2>&1); then
    fail "AGENTS.md の増分が PR 本文の宣言で説明されていない (#1668)" "$growth"
  fi
  echo "review-gate: $growth"
fi

echo "review-gate: ok"
