#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# Claude Code の PreToolUse フック: メンテナ名義で PR を作ろうとしたら差し戻す (#103)。
#
# ADR-0007 の不変条件 — 承認が要る PR の author は、その PR を承認できる集合の要素で
# あってはならない。破ると **誰も承認できない PR** ができ、author は後から変えられない
# ので close して作り直すしかない (#88)。しかもその詰みは PR 作成の瞬間には何も言わず、
# 承認を求める段階で初めて分かる。ここで止めれば作り直しが発生しない。
#
# **承認の要否は区別しない。** 判定にはルールセットのパス照合が要り、PR に載る変更を
# 作成前に確定するには git の状態まで読むことになる。PreToolUse の timeout は短く、
# 分岐を増やすほど壊れやすい。判定をローカルで完結させ、安全側に倒す (ADR-0007 決定 2 の
# 「例外を作らない」と同じ方向)。
# (ADR-0031 より前は、これに加えて対象 Issue の verify ラベルを API で引く必要があった。
#  ラベル由来の承認は畳まれたが、区別しない方針そのものは変わらない)
#
# **PR を作る口は 1 つではない。** gh 2.100.0 の `gh reference` から数え上げた (#719):
#
#   口                      | 作るか | 判定に載せるか
#   ------------------------|--------|--------------------------------------------------
#   gh pr create            | 作る   | 載せる
#   gh pr new               | 作る   | 載せる — **create の組み込みエイリアス**
#   gh pr revert            | 作る   | 載せる — revert PR。gh v2.83.0 (2025-11-04) で入った
#   gh agent-task create    | 作る   | 載せない — author が Copilot bot なので、承認できる
#                           |        |   集合の外に居る。不変条件を破りようがない
#   gh api POST …/pulls     | 作れる | 載せない — agent-comment-guard.sh が同じ理由で素通しと
#                           |        |   宣言している。任意の綴りで任意の API を叩けるので、
#                           |        |   ここで数え上げると必ず取りこぼす
#   gh alias / gh extension | 作れる | 載せない — 綴りが利用者の定義次第で、数え上げ不能
#
# **下の 3 つを載せないのは「安全だから」ではなく「この判定では捕まえられないから」である**
# (bot の 1 行だけは理由が違う)。捕まえられないものを捕まえたふりをすると、通ったことが
# 安全の証拠と読まれる。
#
# 素通しするもの:
#   - 上の表で「載せない」もの / PR を作らない口 (view/list/diff/checks …)
#   - --help / -h            → 使い方を尋ねているだけ
#   - --dry-run              → PR を作らず内容を出すだけ (gh pr create の旗)
#   - このリポジトリ以外宛て   → 規約の外
#   - 同じ行で gh-app-token.sh を **失敗が後段へ伝わる形で** 通し、かつ **export で
#     gh まで渡している**もの (実際の運用形)。発行の成功と export が gh の時点で必ず
#     済んでいることまで、bash の結合の順 (パイプと複合コマンドは && より強い) で見る (#1823)
#   - フック自身の環境の GH_TOKEN が installation token (ghs_) のとき
#   - 打つ人がこのリポジトリへの push 権限を持たないと確かめられたとき (外部の人)
#
# **外部の人は止めない** (#184)。承認者の集合の外に居る人の PR は、どの名義で作っても
# 誰かが承認できるので、不変条件は破れない。判定は `gh api repos/<このリポ>` の
# permissions.push を 1 回引くだけで、**false と読めたときだけ**通す。引けない・読めない
# ときはいままでどおり止める (メンテナが通り抜ける向きの誤りを作らない)。上の「判定を
# ローカルで完結させる」の例外はこの 1 回だけで、最後の差し戻しの直前にしか引かない。
#
# **token を発行しようとしているだけでは通さない。** 当初は「同じ行に gh-app-token.sh が
# あるか」だけを見ていたが、それでは発行の失敗を握り潰す形が通ってしまう (#122)。
#
#   export GH_TOKEN="$(…)" && gh pr create …
#
# は export 自身の終了コード (0) を返すため、発行に失敗しても && が切れず、空の
# GH_TOKEN で gh がメンテナの認証へフォールバックする。#120 はこれで詰んだ。
# set -e も救わない (同じ理由)。代入プレフィクス V="$(…)" gh … も同様。
#
# **発行できただけでも通さない。** 素の代入はそのシェルの変数を作るだけで、子プロセスの
# gh には渡らない。#279 はこれで詰んだ (#285) — 「失敗が伝わる形」は満たしていたので
# 素通しし、gh はメンテナの認証で走った。
#
# 危険な形は複数あって数え上げると取りこぼすので、**既知の安全な形だけを素通しする**
# (曖昧な --repo mokume を止める側に倒しているのと同じ方針)。
#
# ## 承認が要る PR は Draft で作らせない (#1621)
#
# 名義の判定を通った後で、もう 1 つだけ見る。**重要パスに触れる PR を `--draft` で作ると、
# ルールセットの required_reviewers が maintainers へのレビュー依頼を出さない。** 承認
# 待ちであることが GitHub のどこにも出ず、#1599・#1614・#1620 は依頼が空のまま止まった。
# Draft でなく作れば作成の瞬間に Team 宛ての依頼が出て、あとで Draft に落としても残る
# (#1234 の実測)。そこで Draft の作成を差し戻し、「作ってから `gh pr ready --undo`」を
# 案内する。依頼を自前で出す仕組みは足さない — GITHUB_TOKEN も App も Team へは依頼
# できず (scripts/rerequest-review.sh の冒頭)、宛先の User を書けば人が増えるたびに直す
# ことになる。
#
# **重要パスに触れない PR の `--draft` は通す。** 作ってから落とす形だと、その間だけ
# 描画の行列に入ってしまう (多くの描画 PR は重要パスに触れない)。ここだけは上の「承認の
# 要否は区別しない」の例外で、判定に手元の差分 (`git diff origin/<base>...<head>`) を
# 読む。**読めなければ差し戻す側に倒す** — 代償は `--draft` を外して打ち直すことだけで、
# 取りこぼしの代償 (依頼の無い承認待ち) より小さい。`gh pr revert` の中身は手元に無い
# ので、revert の `--draft` はいつも差し戻す。**手元の差分は cwd のものなので、gh が走る
# リポジトリが cwd と確かめられないときも読めないものとして扱う** — gh より前の cd などの
# 文で宛先を「決められない」と読んだとき (別の worktree へ cd した形を含む) と、-R /
# GH_REPO で名指しした宛先が cwd のリポジトリと違うとき (#1823 の反証 #6)。
#
# 名義の差し戻しと同時には出ない。判定は名義の素通しの直前に置いてあり、名義を直した
# 打ち直しで初めてこちらが当たる。
#
# 契約: stdin に PreToolUse の JSON。素通しは無出力 + 終了コード 0。
# 配線は .claude/settings.json、テストは scripts/tests/pr_identity_guard_test.py。
set -uo pipefail

# 差し戻しの文言は関数に切り出す。`hook_deny "$(cat <<'EOF' … EOF)"` と書くと macOS の
# bash 3.2 が壊れる — $( … ) の中の here-document の本文まで閉じ括弧の探索対象に
# するため、本文に $( が現れるとネストを誤認して no closing ')' になる。ここの文言は
# 案内として GH_TOKEN="$(…)" を含むので、正しく書くほど壊れるという噛み合わせだった
# (#160)。関数にすると here-document が $( … ) の外へ出るので誤解されない。

unsafe_token_form_message() {
  cat <<'EOF'
token の発行が失敗しても後段が走る形になっています。この形では詰みが起きます。

  export GH_TOKEN="$(…)" && gh pr create …
  ^^^^^^ export 自身の終了コード (0) が返るため、発行に失敗しても && が切れません。
         空の GH_TOKEN で gh がメンテナの認証へフォールバックし、**誰も承認できない
         PR** ができます (ADR-0007 / #88。実際に #120 がこれで詰みました)。

次の形にしてください。代入は右辺の終了コードをそのまま返すので && が正しく切れます:

  GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && gh pr create …

同じ理由で通らない形が他にもあります:

  - set -e を足しても救われません (export の終了コードが 0 のため)
  - 代入プレフィクス GH_TOKEN="$(…)" gh pr create … も、発行の失敗が伝わりません
  - 発行から gh までを ;・改行・& で区切った形や、|| を挟んだ形 (発行の直前の || を
    含む) も、発行の失敗が gh まで伝わりません。発行から gh までを && で繋いでください
    (#1823)。パイプの中で発行・export しても、外の gh には渡りません
  - $( … ) の中で gh-app-token.sh の後ろに || true・| tr・; true などを置くと、発行が
    失敗しても置換は 0 を返します。置換の中は gh-app-token.sh だけにしてください
EOF
}

token_not_exported_message() {
  cat <<'EOF'
token は発行できていますが、**gh へ渡っていません**。素の代入はそのシェルの変数を作る
だけで、子プロセスには継がれません。

  GH_TOKEN="$(bash scripts/gh-app-token.sh)" && git push -u origin HEAD && gh pr create …
                                                                          ^^ ここはメンテナの認証で走る

この形は「発行に失敗したら && が切れる」という条件は満たしているので気付きにくく、
できあがるのは **誰も承認できない PR** です (ADR-0007 / #88)。しかもその詰みは、
**閉じて作り直しても解けません** — 閉じたほうの run が残した失敗の判定が同じコミットに
付いたままになり、作り直した PR まで巻き添えにします (#285)。

export を挟んでください。代入・export・gh を && で繋ぐと、発行の失敗も伝わります:

  GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && gh pr create …
EOF
}

identity_required_message() { # $1=実際に打たれた口 (例: gh pr create)
  cat <<EOF
**このリポジトリ宛ての** PR は GitHub App の identity で作成してください。素の gh
(メンテナ名義) で作ると、**誰も承認できない PR** になります — GitHub は自分の PR を
自分で承認できず、author は後から変えられないので close して作り直すしかありません
(ADR-0007 / #88)。

  GH_TOKEN="\$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && $1 …

代入から始めるのが要点です。export を先頭に付けると終了コードが 0 に化けて、token の
発行に失敗しても後段が走ってしまいます (#122)。

\`MOKUME_APP_PRIVATE_KEY_CMD\` が未設定でも「鍵が無い」と即断しないでください。手元の
秘密管理には「自動化から読んでよい秘密の一覧」があるのが普通なので、まずその一覧を
引いて、このリポジトリの App の鍵が載っていないかを見ます。参照名が分かればその環境
変数は 1 行で組めます (在処そのものを読む必要はありません)。

一覧にも無ければ PR を作らず、鍵の渡し方を人に尋ねてください。

このリポジトリへの push 権限を持たない外部の人は、この差し戻しに当たりません (自分の
名義で PR を作ってよい)。当たったなら、gh の認証 (\`gh auth status\`) を確かめて打ち直して
ください — 権限を読めなかったときは止める側に倒しています。

承認が要らない PR でもここでは経路を分けません。承認の要否はルールセットのパスで
決まりますが、作成前にそれを確定するより一律で App identity にするほうが安全です
(ADR-0007 決定 2)。
EOF
}

draft_created_message() { # $1=実際に打たれた口  $2=差分を読めなかった理由 (読めたなら空)  $3=cwd なら cwd の読み違い
  if [ -n "${2:-}" ]; then
    cat <<EOF
**Draft で作ろうとしている PR が重要パスに触れているかを確かめられませんでした** ($2)。
触れているものとして扱っています。

EOF
  fi
  cat <<EOF
**承認が要る PR を Draft で作ると、maintainers へのレビュー依頼が出ません** (#1621)。
ルールセットの required_reviewers は、重要パス (docs/decisions/・.github/・.claude/ など)
に触れる PR に 1 承認を課しますが、Draft で作られた PR には依頼を出しません。承認待ちで
あることが GitHub のどこにも出ないまま止まります (#1599・#1614・#1620)。

Draft に置きたいなら、Draft でなく作ってから落としてください。依頼は作成の瞬間に出て、
Draft に落としても残ります (#1234):

  $1 …            (--draft / -d を外す)
  gh pr ready --undo <番号>

重要パスに触れない PR の --draft は差し戻しません。
EOF
  if [ "${3:-}" = cwd ]; then
    cat <<'EOF'
触れていないと分かっているなら、PR を作るリポジトリの checkout を cwd にしてから
(cd は別の呼び出しで打つ)、cd・GIT_DIR などの変数・GH_REPO の文を挟まずに打ち直して
ください (cwd の差分が読めれば判定できます)。
EOF
  elif [ -n "${2:-}" ]; then
    cat <<'EOF'
触れていないと分かっているなら、手元にある枝を --head / --base で指し直して打ち直して
ください (差分が読めれば判定できます)。
EOF
  fi
}

# payload の解き方・差し戻し方・コマンド文字列の読み方は guard-lib.sh と共有する
# (#128・#815)。読めなければ素通し — guard が壊れて Bash ツール全体が使えなくなるほうが
# 害が大きい (hook_payload の jq と同じ fail open の考え方)
# shellcheck source=scripts/guard-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh" 2>/dev/null || exit 0
# 「承認が要るパスに触れているか」— 正本はルールセットで、写しは持たない (#1621 の判定)
# shellcheck source=scripts/protected-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/protected-paths.sh" 2>/dev/null || exit 0

# PR を作る口 (冒頭の表の「載せる」3 つ)。**判定と、打たれた口の取り出しが同じ綴りを
# 読む** — 割れると「差し戻したのに、名乗る口が空」が起きる
PR_CREATING_PORTS='pr[[:space:]]+(create|new|revert)'

# 内容を出すだけで PR を作らない。`gh pr create --dry-run` の旗で、他の 2 つの口は
# 持たない (持たない口に付ければ gh 自身が弾く)。旗は呼び出しの断片からだけ読む —
# 同じ行の別のコマンドの --dry-run (echo --dry-run など) は PR 作成の旗ではない
is_dry_run() { # $1=gh の断片
  printf '%s\n' "$1" | grep -qE '(^|[[:space:]])--dry-run([[:space:]]|$)'
}

# 旗の値。`--head x` / `--head=x` / `-H x` の形を読み、引用符を落とす。後勝ち (gh と同じ)
flag_value() { # $1=断片  $2=旗の正規表現 (例 '--head|-H')
  printf '%s' "$1" |
    grep -oE "(^|[[:space:]])($2)(=|[[:space:]]+)[^[:space:]]+" |
    tail -1 |
    sed -E "s/^[[:space:]]*($2)(=|[[:space:]]+)//; s/^[\"']//; s/[\"']\$//"
}

# 重要パスに触れる PR を Draft で作ろうとしていたら差し戻す (冒頭の「Draft で作らせない」)。
# 名義の素通しの直前で呼ぶ。Draft でなければ何もしない。旗は判定中の呼び出し ($fragment)
# からだけ読む — 同じ行の別のコマンドの `-d` を拾わないため
deny_if_protected_draft() {
  local base head files
  printf '%s\n' "$fragment" | grep -qE '(^|[[:space:]])(--draft|-d)(=|[[:space:]]|$)' || return 0

  # revert の中身は、戻す PR の差分であって手元には無い (port は末尾に空白を持ちうる)
  case "$port" in "gh pr revert"*)
    hook_deny "$(draft_created_message "$port" "revert の中身は手元の差分に無い")"
    ;;
  esac

  # 読むのは cwd の差分なので、宛先が cwd のリポジトリと確かめられるときだけ読む (#1823 の
  # 反証 #6)。cd などの文で宛先を「決められない」と読んだとき (chdir) や、-R / GH_REPO で
  # 別の checkout から名指ししたときの cwd の差分は、その PR の差分とは限らない
  [ "$chdir" = 1 ] &&
    hook_deny "$(draft_created_message "$port" "gh より前の文や前置で、gh が走るリポジトリが cwd から変わりうる" cwd)"
  [ "$(repo_of_dir "$cwd" 2>/dev/null)" = "$(this_repo)" ] ||
    hook_deny "$(draft_created_message "$port" "cwd のリポジトリが PR の宛先と同じと確かめられない" cwd)"

  base=$(flag_value "$fragment" '--base|-B')
  base=${base:-main}
  head=$(flag_value "$fragment" '--head|-H')
  head=${head##*:} # <user>:<branch> の形
  head=${head:-HEAD}
  # --head の枝が手元に無ければ、push 済みの枝を見る
  git -C "$cwd" rev-parse -q --verify "$head^{commit}" >/dev/null 2>&1 || head="origin/$head"

  files=$(git -C "$cwd" diff --name-only "origin/$base...$head" 2>/dev/null) ||
    hook_deny "$(draft_created_message "$port" "origin/$base...$head の差分を読めなかった")"

  printf '%s\n' "$files" | touches_protected_path || return 0
  hook_deny "$(draft_created_message "$port")"
}

# gh に渡る GH_TOKEN が、installation token と確かめられない (#1729)。$1=口 $2=どうなっているか
prefix_token_message() {
  cat <<EOF
$1 に渡る GH_TOKEN が、gh の前置か同じ行の文で$2。installation token (ghs_) でない
認証で gh が走ると、**誰も承認できない PR** になります (ADR-0007 / #88)。

前置で渡すなら、同じ行で発行した token を、失敗が後段へ伝わる形で渡してください:

  t="\$(bash scripts/gh-app-token.sh)" && GH_TOKEN="\$t" $1 …

export で渡す形でも構いません:

  GH_TOKEN="\$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && $1 …
EOF
}

# 承認者の外に居る人 (push 権限の無い外部の人) か。どの名義で作っても承認できる
# (冒頭の「外部の人は止めない」・#184)。確かめられたときだけ真で、引けない・読めない
# ときは偽 (止める側へ倒す)
is_outside_collaborator() {
  local push
  push=$(gh api "repos/$(this_repo)" --jq '.permissions.push' 2>/dev/null </dev/null) || push=""
  [ "$push" = false ]
}

# 1 つの PR 作成の呼び出しを判定する。通れば戻り、止めるなら差し戻して終わる。
#   $1 = gh_invocations の GH_TOKEN の列 (gh に渡る token の見立て)
#
# **見立ては、その gh の前置と、gh より前に置いた文だけから決まる** (#1729 の反証)。
# 字句読み (guard-lib.sh の gh_invocations) が文を順に読み、発行・export・unset・再代入と
# 前置を追う。以前はコマンド全体への部分一致で、gh の**後ろ**に書いた発行と export
# (`gh pr create --fill; GH_TOKEN="$(…)" && export GH_TOKEN`) まで「渡した」と読み、
# 前置 (`env -u GH_TOKEN gh`) は捨てていた。
#
# 安全な発行は素の代入から始める。代入は右辺のコマンド置換の終了コードをそのまま返すので、
# 続く && が正しく切れる (#122):
#
#   GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && gh pr create …
#
# export を先頭に付けると (`export GH_TOKEN="$(…)"`) 終了コードが export のもの (0) に
# 化けるため、発行に失敗しても && が切れず、空の GH_TOKEN で gh がメンテナの認証へ
# フォールバックする。#120 はこれで詰んだ。代入プレフィクス `GH_TOKEN="$(…)" gh …` も同じ。
# 見立ては unsafe になる。
#
# **発行できただけでは足りない。** 素の代入はそのシェルの変数を作るだけで、子プロセスの
# gh には渡らない。
#
#   GH_TOKEN="$(bash scripts/gh-app-token.sh)" && git push -u origin HEAD && gh pr create …
#
# は「発行の失敗が伝わる形」を満たしていながら、gh はメンテナの認証で走る。#279 はこれで
# 詰んだ (#285)。
# 見立ては unexported になる。
#
#   見立て        gh に渡るもの                         判定
#   installation  ghs_… か、同じ行で安全に発行した値    通す
#   inherit       打つシェルの GH_TOKEN                 フックの環境が ghs_ なら通す
#   unsafe        発行の失敗が伝わらない                止める (unsafe_token_form_message)
#                 (発行から gh までが && で繋がっていない形・置換の中で失敗を
#                 握り潰した形を含む・#1823)
#   unexported    何も渡らない (export していない)     止める (token_not_exported_message)
#   removed       何も渡らない (env -u / env -i / unset) 止める (prefix_token_message)
#   other・unknown 確かめられない値                     止める (prefix_token_message)
#
# 止める側のうち removed・other・unknown と、inherit の差し戻しは、push 権限の無い外部の
# 人なら通す (どの名義でも承認できる)。unsafe・unexported は token を使おうとしている形
# なので、何がまずいかを名指しして止める (汎用の差し戻しだと「使っているのに止められた」と
# 読めて直し方が分からない)。
judge_invocation() { # $1=GH_TOKEN の見立て
  case "$1" in
    installation)
      deny_if_protected_draft
      return 0
      ;;
    inherit)
      # 常設している環境 (GH_TOKEN に installation token を置いてある) も常道
      case "${GH_TOKEN:-}" in ghs_*)
        deny_if_protected_draft
        return 0
        ;;
      esac
      is_outside_collaborator && return 0
      hook_deny "$(identity_required_message "$port")$(other_repo_hint "$port")"
      ;;
    unsafe) hook_deny "$(unsafe_token_form_message)" ;;
    unexported) hook_deny "$(token_not_exported_message)" ;;
    removed)
      is_outside_collaborator && return 0
      hook_deny "$(prefix_token_message "$port" "消されています (env -u GH_TOKEN / env -i / unset GH_TOKEN)")"
      ;;
    unknown)
      is_outside_collaborator && return 0
      hook_deny "$(prefix_token_message "$port" "読めない形で変えられています (+= など)")"
      ;;
    *)
      is_outside_collaborator && return 0
      hook_deny "$(prefix_token_message "$port" "installation token と確かめられない値になっています (空・個人の token・同じ行で発行していない変数)")"
      ;;
  esac
}

hook_payload
hook_command
command=$HOOK_COMMAND
cwd=$HOOK_CWD

# **PR を作る口は 1 つではない** (冒頭の表)。create の別綴り (new) と revert も見る。
# 呼び出しごとに、その断片と前置だけを読む (#1729 の反証) — --help・--dry-run・-R は同じ行の
# 別のコマンドのものを拾わない (echo --dry-run && gh pr create … を素通しにしていた)。
# 呼び出しは fd 3 から読む — 判定の中で走る gh api / git に標準入力を食わせない
while IFS=$'\t' read -r token repo chdir _place fragment <&3; do
  gh_fragment_is "$fragment" "$PR_CREATING_PORTS" || continue

  # 実際に打たれた口。差し戻しの文言がこれを名乗る — 打っていない綴りで直し方を示すと、
  # 読み手が自分の行と突き合わせられない
  port="gh $(printf '%s\n' "$fragment" |
    grep -oE "$PR_CREATING_PORTS" |
    head -1 |
    tr -s '[:space:]' ' ')"

  # 使い方を尋ねているだけなら作成ではない (判定は guard-lib.sh が持つ)
  is_help_request "$fragment" && continue

  # 内容を出すだけで PR を作らない (gh pr create の旗)
  is_dry_run "$fragment" && continue

  # 他のリポジトリ宛ての PR はこのリポジトリの規約の外。判定は guard-lib.sh が持つ
  # (agent-comment-guard.sh と共有する。#188)
  invocation_targets_other_repo "$fragment" "$repo" "$chdir" "$cwd" && continue

  judge_invocation "$token"
done 3< <(gh_invocations "$command")
exit 0
