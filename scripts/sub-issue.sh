#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# sub-issue を 1 コマンドで作る: 作成 + 親への紐づけ + 親の Issue Type 継承。
# gh CLI に sub-issue コマンドが無いための補い (ADR-0002 / #23)。
#
# 使い方:
#   sub-issue.sh <親番号> <タイトル> [--body-file F | --body TEXT] [--label L]... [--type T] [--with 名乗り]... [--blocked-by 前提]... [--test]
#   sub-issue.sh <親番号> --attach <番号>
#   sub-issue.sh <番号> --blocked-by <前提> [--blocked-by <前提>]...
#   --type   : 親から継ぐ型を上書きする (ADR-0004 の 5 型: Bug/Feature/Task/Design/Docs)
#   --test   : 使い捨て検証用。タイトルに test: を補い、verify: triaged を付け、
#              本文が無ければ検証用のテンプレートを入れる (確認後に close する前提)
#   --with   : 一緒に作った別のエージェント・モデルを署名に併記する (#3149)
#   --attach : 作らずに、既にある Issue を親の下へ繋ぐ (#1661)。型は継がない
#   --blocked-by : 前提の Issue を GitHub の依存関係 (blocked by) で繋ぐ (#3936)。何本でも並べられる。
#              タイトルの代わりに置くと、作らずに既にある Issue 同士を繋ぐ (先頭の番号は親ではなく、
#              待つ側の Issue)
#
# エージェントが実行したときは、作る Issue の本文の末尾にエージェントの署名を付ける (#3149。
# 署名の名前の決まり方は scripts/agent-signature.sh)。人の実行には付けない。
#
# ## --attach (#1661)
#
# 同じ根本原因のバグは、2 件目が見つかった時点で根本原因の Issue を親にしてまとめる (ADR-0040 決定 2)。まとめる
# 相手はたいてい**既に起票されている** — 作る手段しか無いと紐づけの REST を手で実行することに
# なり、実行されないまま同じ原因を持つ別の箇所が 1 件ずつ直されていった (#1659 の実測で、同じ根本原因の後発が 15 件)。
#
# 型を継がないのは、繋ぐ Issue の型は起票したときに既に決まっているからである。Bug の群を
# Design の親に繋いでも、子は Bug のままでよい (親が決めるのは根本原因の直し方で、子の仕事の
# 種類ではない)。
#
# **付け替えはしない。** 既に別の親を持つ Issue は、GitHub が紐づけを拒否する (replace_parent を
# 渡していないため)。そのときは失敗を報告して止まる — 黙って付け替えると、前の親が数えて
# いた群から子が消え、どちらの群が正しいかを誰も判断しないまま決まってしまう。
#
# 作った子を探すときは、検索に parent-issue:mokume-metal/mokume#<親番号> を使う。
#
# ## --blocked-by (#3936)
#
# 「印は前の段 (#N) の merge の後に付ける」と本文に書いただけの無印の段は、前の段が閉じても
# どこにも出てこず、2026-11-10 の棚卸し (#3933) で 11 本が 10 日間残っていた。前提を GitHub の
# 依存関係で繋いでおけば、`scripts/ready-queue.sh` が前提の閉じた無印の段を unblocked の行に出す。
# 前提を持つ段を作るときは、本文に書くのに加えてここで繋ぐ。
#
# 中は `gh issue edit <番号> --add-blocked-by <前提>` を前提ごとに 1 回打つだけである (gh 2.94.0 から)。
# 1 本ずつ打つのは、断られた前提を番号で名乗るため。**外す口は持たない** — 繋ぎ間違いは
# `gh issue edit <番号> --remove-blocked-by <前提>` で外す。
#
# **断られたら止まる。** 既に繋いである組 (`has already been taken`) と自分自身は GitHub が
# 断る (2026-11-10 に確かめた) ので、その出力をそのまま出して 1 で終える。作る口で断られたときは、Issue は作られて親にも
# 繋がっているので、作り直さずに繋ぐだけの口で残りを繋ぐ (番号は出力に出す)。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"
# 起票の署名 (#3149)
# shellcheck source=scripts/agent-signature.sh
. "$(dirname "${BASH_SOURCE[0]}")/agent-signature.sh"

USAGE='使い方: sub-issue.sh <親番号> <タイトル> [--body-file F | --body TEXT] [--label L]... [--type T] [--with 名乗り]... [--blocked-by 前提]... [--test]
        sub-issue.sh <親番号> --attach <番号>
        sub-issue.sh <番号> --blocked-by <前提> [--blocked-by <前提>]...'

# usage は 64 (sysexits の EX_USAGE) で揃える (#820)。**使い方も出す** —
# 終了コードだけ揃えても、読む人はその場で直せない
usage_error() { # $1=何が悪かったか
  printf '%s\n%s\n' "$1" "$USAGE" >&2
  exit 64
}

# 子を親の下へ繋ぐ。作る口と --attach の口が同じ REST を通る。
#
# **set -e に頼らない。** `if ! link_to_parent …` の形で呼ぶと、関数の中では set -e が
# 効かない — id を引けなかったまま、空の id で紐づけへ進んでしまう
link_to_parent() { # $1=子の番号
  local child_id out
  child_id=$(gh api "repos/$REPO/issues/$1" --jq .id) || return 1
  # 断られた理由 (errors) は応答の本文 (stdout) にしか無いので、捨てずに名乗る (#2075)
  if ! out=$(gh api -X POST "repos/$REPO/issues/$PARENT/sub_issues" \
    -F sub_issue_id="$child_id" 2>&1); then
    printf '%s\n' "$out" >&2
    return 1
  fi
}

# 前提を blocked by で繋ぐ。作る口と繋ぐだけの口が同じ gh を通る (冒頭の「--blocked-by」)。
# 断られた前提で止まり、どれが繋がっていないかを名乗る
link_blockers() { # $1=待つ側の番号 $2...=前提の番号
  local issue=$1 b
  shift
  for b in "$@"; do
    if ! gh issue edit "$issue" -R "$REPO" --add-blocked-by "$b" >/dev/null; then
      echo "#$issue を前提 #$b に繋げなかった (理由は上の gh の出力)。" >&2
      return 1
    fi
  done
}

# 前提の番号は、打つ前に形を見る。作る口では、作った後に断られると Issue だけが残る
blocker_number() { # $1=前提の番号
  case "$1" in '' | *[!0-9]*) usage_error "--blocked-by には前提の Issue の番号が要る: '$1'" ;; esac
}

PARENT="${1:?親 Issue 番号が必要}"; shift
# 位置引数の親番号とタイトルは、値として読んで起票まで進む。`-` で始まるのは慣習の `--help` などの
# 選択肢の綴りで、そのまま題や親にすると「--help」という題の Issue が立つ (#3047)。
# 選択肢の値 (`--body` の箇条書き `- …` など) は正当に `-` で始まりうるので、ここでは見ない
case "$PARENT" in -*) usage_error "親番号は - で始まる値を読まない: $PARENT" ;; esac

# 既に在る Issue を繋ぐ口 (冒頭の「--attach」)。作成と型の継承は通らない
if [ "${1:-}" = --attach ]; then
  CHILD="${2:-}"
  case "$CHILD" in '' | *[!0-9]*) usage_error "--attach には繋ぐ Issue の番号が要る: '$CHILD'" ;; esac
  [ $# -eq 2 ] || usage_error "--attach は他の引数と併せない: ${*:3}"
  if ! link_to_parent "$CHILD"; then
    {
      echo "#$CHILD を #$PARENT の下に繋げなかった (理由は上の gh の出力)。"
      echo "既に別の親を持つなら付け替えはしない — どちらの群に属するかを決めてから、"
      echo "前の親から外すか、この親を諦める。"
    } >&2
    exit 1
  fi
  echo "#$CHILD を #$PARENT の下に繋いだ"
  exit 0
fi

# 既に在る Issue 同士を前提で繋ぐ口 (冒頭の「--blocked-by」)。作成は通らず、先頭の番号は待つ側
if [ "${1:-}" = --blocked-by ]; then
  ISSUE=$PARENT
  case "$ISSUE" in *[!0-9]*) usage_error "--blocked-by で繋ぐ Issue の番号が要る: '$ISSUE'" ;; esac
  BLOCKERS=()
  while [ $# -gt 0 ]; do
    [ "$1" = --blocked-by ] || usage_error "--blocked-by で繋ぐだけのときは他の引数と併せない: $1"
    blocker_number "${2:-}"
    BLOCKERS+=("$2"); shift 2
  done
  link_blockers "$ISSUE" "${BLOCKERS[@]}" || exit 1
  echo "#$ISSUE を前提 $(printf '#%s ' "${BLOCKERS[@]}")に繋いだ (blocked by)"
  exit 0
fi

TITLE="${1:?タイトルが必要}"; shift
case "$TITLE" in -*) usage_error "タイトルは - で始まる値を読まない: $TITLE" ;; esac

BODY="" BODY_FILE="" TYPE="" IS_TEST=false
LABELS=() WITH=() BLOCKERS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --body-file) BODY_FILE="$2"; shift 2 ;;
    --body)      BODY="$2"; shift 2 ;;
    --label)     LABELS+=("$2"); shift 2 ;;
    --type)      TYPE="$2"; shift 2 ;;
    --with)      WITH+=(--with "$2"); shift 2 ;;
    --blocked-by) blocker_number "${2:-}"; BLOCKERS+=("$2"); shift 2 ;;
    --test)      IS_TEST=true; shift ;;
    *)           usage_error "不明な引数: $1" ;;
  esac
done

if $IS_TEST; then
  case "$TITLE" in test:*) ;; *) TITLE="test: $TITLE" ;; esac
  LABELS+=("verify: triaged")
  if [ -z "$BODY" ] && [ -z "$BODY_FILE" ]; then
    BODY="#$PARENT の検証用の使い捨て Issue。確認が済んだら close する (merge しない試験 PR の紐づけ先)。"
  fi
fi

# 親の Issue Type を継承 (--type の明示指定があればそちらが優先。ADR-0004)。
# 型はツリーの中で引き継がれるのが既定 — 子が別の仕事なら --type で上書きする
if [ -z "$TYPE" ]; then
  TYPE=$(gh issue view "$PARENT" -R "$REPO" --json issueType --jq '.issueType.name // empty')
fi

# エージェントの起票なら本文の末尾に署名を付ける (#3149)。ここで作る Issue は中の gh を
# 通るので、素の gh issue create を見る agent-comment-guard.sh には見えない。署名は
# scripts/ready-queue.sh がエージェントの起票を見分ける唯一の手掛かりでもある。
# **人の実行には付けない** — エージェントと判定できなければ署名しない (総称に落とさない)
[ -n "$BODY_FILE" ] && [ -n "$BODY" ] && usage_error "--body と --body-file は併せない"
if [ -n "$BODY_FILE" ]; then
  # 読めるかは cat に任せる (`<(…)` のようなファイルでないものも、`-` の標準入力も読む)
  BODY=$(cat "$BODY_FILE") || { echo "本文のファイルを読めない: $BODY_FILE" >&2; exit 66; }
fi
# エージェントの起票なら、作る前に本文を絵の照合に通す (#3376)。素の gh issue create は
# scripts/issue-evidence-guard.sh が見るが、ここを通る起票はそれに見えず、見た目のバグが
# 絵も宣言も無いまま作られていた (#2655・#2647)。人の実行には掛けない (署名と同じ判定)
if detect_agent strict >/dev/null; then
  body_tmp=$(mktemp)
  printf '%s\n' "$BODY" > "$body_tmp"
  if ! out=$(bash "$(dirname "${BASH_SOURCE[0]}")/check-drawing-evidence.sh" --issue-body "$body_tmp" 2>&1 >/dev/null); then
    rm -f "$body_tmp"
    printf '%s\n' "$out" >&2
    exit 1
  fi
  rm -f "$body_tmp"
fi

# --generic を渡さない = 判定できなければ署名しない
if ! grep -qF "$SIGNATURE_KEY" <<<"$BODY" &&
   sig=$(agent_signature ${WITH[@]+"${WITH[@]}"}); then
  BODY="${BODY:+$BODY

}---
$sig"
fi

args=(--title "$TITLE" -R "$REPO" --body "$BODY")
[ -n "$TYPE" ] && args+=(--type "$TYPE")
for l in "${LABELS[@]:-}"; do [ -n "$l" ] && args+=(--label "$l"); done

url=$(gh issue create "${args[@]}")
num="${url##*/}"

link_to_parent "$num"

echo "sub-issue #$num を #$PARENT の下に作成した: $url"

# 前提を繋ぐ (冒頭の「--blocked-by」)。作った後なので、断られても Issue は残る — 番号を名乗って
# 繋ぐだけの口へ渡す
if [ ${#BLOCKERS[@]} -gt 0 ]; then
  if ! link_blockers "$num" "${BLOCKERS[@]}"; then
    echo "#$num は作って #$PARENT の下に繋いである。作り直さず、残りの前提は次で繋ぐ:" >&2
    echo "  bash scripts/sub-issue.sh $num --blocked-by <前提>" >&2
    exit 1
  fi
  echo "#$num を前提 $(printf '#%s ' "${BLOCKERS[@]}")に繋いだ (blocked by)"
fi
