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
# **承認の要否は区別しない。** 承認が要るかを作成前に判定するにはルールセットのパス
# 照合と、本文の Closes #N から対象 Issue の verify ラベルを引く必要がある。PreToolUse
# の timeout は短く、API 依存の判定は遅く壊れやすい。判定をローカルで完結させ、安全側に
# 倒す (ADR-0007 決定 2 の「例外を作らない」と同じ方向)。
#
# 素通しするもの:
#   - gh pr create 以外 (view/list/diff/checks …)
#   - --help / -h            → 使い方を尋ねているだけ
#   - このリポジトリ以外宛て   → 規約の外
#   - 同じ行で gh-app-token.sh を **失敗が後段へ伝わる形で** 通し、かつ **export で
#     gh まで渡している**もの (実際の運用形)
#   - フック自身の環境の GH_TOKEN が installation token (ghs_) のとき
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
# 契約: stdin に PreToolUse の JSON。素通しは無出力 + 終了コード 0。
# 配線は .claude/settings.json、テストは scripts/tests/pr_identity_guard_test.py。
set -uo pipefail

deny() { # $1=理由
  jq -n --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# 差し戻しの文言は関数に切り出す。`deny "$(cat <<'EOF' … EOF)"` と書くと macOS の
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

identity_required_message() {
  cat <<'EOF'
PR は GitHub App の identity で作成してください。素の gh (メンテナ名義) で作ると、
**誰も承認できない PR** になります — GitHub は自分の PR を自分で承認できず、author は
後から変えられないので close して作り直すしかありません (ADR-0007 / #88)。

  GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && gh pr create …

代入から始めるのが要点です。export を先頭に付けると終了コードが 0 に化けて、token の
発行に失敗しても後段が走ってしまいます (#122)。

`MOKUME_APP_PRIVATE_KEY_CMD` が未設定でも「鍵が無い」と即断しないでください。手元の
秘密管理には「自動化から読んでよい秘密の一覧」があるのが普通なので、まずその一覧を
引いて、このリポジトリの App の鍵が載っていないかを見ます。参照名が分かればその環境
変数は 1 行で組めます (在処そのものを読む必要はありません)。

一覧にも無ければ PR を作らず、鍵の渡し方を人に尋ねてください。

承認が要らない PR でもここでは経路を分けません。承認の要否はルールセットのパスと
対象 Issue の verify ラベルで決まり、作成前に確定できないためです。
EOF
}

# コマンド文字列の読み方は agent-comment-guard.sh と共有する (#128)。
# 読めなければ素通し — guard が壊れて Bash ツール全体が使えなくなるほうが害が大きい
# (下の jq と同じ fail open の考え方)
# shellcheck source=scripts/guard-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh" 2>/dev/null || exit 0

payload=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
command=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null) || exit 0
[ -n "$command" ] || exit 0

is_gh_subcommand "$command" 'pr[[:space:]]+create' || exit 0

# 使い方を尋ねているだけなら作成ではない
printf '%s' "$command" | grep -qE '(^|[[:space:]])(-h|--help)([[:space:]]|$)' && exit 0

# 他のリポジトリ宛ての PR はこのリポジトリの規約の外。判定は guard-lib.sh が持つ
# (agent-comment-guard.sh と共有する。#188)
targets_other_repo "$command" && exit 0

# 同じ行で installation token を発行しているなら、それが常道の形 — ただし **発行の失敗が
# 後段へ伝わる形** に限る (冒頭の解説と #122)。
#
# 安全な形は素の代入から始める。代入は右辺のコマンド置換の終了コードをそのまま返すので、
# 続く && が正しく切れる:
#
#   GH_TOKEN="$(bash scripts/gh-app-token.sh)" && export GH_TOKEN && gh pr create …
#
# export を先頭に付けると終了コードが export のもの (0) に化けるため、この式は
# 「区切りの直後に来る素の GH_TOKEN= 代入」であることを要求する。export の直後は行頭にも
# 区切りにも当たらないので落ちる。
readonly SAFE_TOKEN_FORM='(^|&&|;|\|)[[:space:]]*GH_TOKEN=("|'"'"')?\$\([^)]*scripts/gh-app-token\.sh[^)]*\)("|'"'"')?[[:space:]]*&&'

# **発行できただけでは足りない。** 素の代入はそのシェルの変数を作るだけで、子プロセスの
# gh には渡らない。つまり
#
#   GH_TOKEN="$(bash scripts/gh-app-token.sh)" && git push -u origin HEAD && gh pr create …
#
# は「発行の失敗が伝わる形」を満たしていながら、gh はメンテナの認証で走る。#279 はこれで
# 詰んだ (#285) — 上の SAFE_TOKEN_FORM だけを見ていたので素通しし、**誰も承認できない
# PR** ができた。渡っていることまで確かめるため、区切りの直後に来る export を要求する。
readonly EXPORT_FORM='(^|&&|;|\|)[[:space:]]*export[[:space:]]+GH_TOKEN([[:space:]]|&|;|\||$)'

if printf '%s' "$command" | grep -qE '[^[:space:];&|`)]*scripts/gh-app-token\.sh'; then
  if printf '%s' "$command" | grep -qE "$SAFE_TOKEN_FORM"; then
    printf '%s' "$command" | grep -qE "$EXPORT_FORM" && exit 0

    # 発行の形は正しいが、gh へ渡っていない
    deny "$(token_not_exported_message)"
  fi

  # token を発行しようとはしている。汎用の差し戻しだと「使っているのに止められた」と
  # 読めて直し方が分からないので、何がまずいかを名指しする
  deny "$(unsafe_token_form_message)"
fi

# 常設している環境 (GH_TOKEN に installation token を置いてある) も常道。
# 判定は token 発行の形より **後**。危険な形は env の token を空文字で上書きするので、
# ここが先に通ると握り潰しを見逃す
case "${GH_TOKEN:-}" in ghs_*) exit 0 ;; esac

deny "$(identity_required_message)"
