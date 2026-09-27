#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# sub-issue を 1 コマンドで作る: 作成 + 親への紐づけ + 親の Issue Type 継承。
# gh CLI に sub-issue コマンドが無いための補い (ADR-0002 / #23)。
#
# 使い方:
#   sub-issue.sh <親番号> <タイトル> [--body-file F | --body TEXT] [--label L]... [--type T] [--test]
#   sub-issue.sh <親番号> --attach <番号>
#   --type   : 親から継ぐ型を上書きする (ADR-0004 の 5 型: Bug/Feature/Task/Design/Docs)
#   --test   : 使い捨て検証用。タイトルに test: を補い、verify: triaged を付け、
#              本文が無ければ検証用の雛形を入れる (確認後に close する前提)
#   --attach : 作らずに、既に在る Issue を親の下へ繋ぐ (#1661)。型は継がない
#
# ## --attach (#1661)
#
# 同じ根のバグは、2 件目が見つかった時点で根を親にして束ねる (ADR-0040 決定 2)。束ねる
# 相手はたいてい**既に起票されている** — 作る口しか無いと紐づけの REST を手で打つことに
# なり、打たれないまま兄弟が 1 件ずつ直されていった (#1659 の実測で、同じ根の後発が 15 件)。
#
# 型を継がないのは、繋ぐ Issue の型は起票したときに既に決まっているからである。Bug の群を
# Design の親に繋いでも、子は Bug のままでよい (親が決めるのは根の直し方で、子の仕事の
# 種類ではない)。
#
# **付け替えはしない。** 既に別の親を持つ Issue は、GitHub が紐づけを断る (replace_parent を
# 渡していないため)。そのときは失敗を名乗って止まる — 黙って付け替えると、前の親が数えて
# いた群から子が消え、どちらの群が正しいかを誰も判断しないまま決まってしまう。
#
# 作った子を探すときは、検索に parent-issue:mokume-metal/mokume#<親番号> を使う。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"

USAGE='使い方: sub-issue.sh <親番号> <タイトル> [--body-file F | --body TEXT] [--label L]... [--type T] [--test]
        sub-issue.sh <親番号> --attach <番号>'

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
  local child_id
  child_id=$(gh api "repos/$REPO/issues/$1" --jq .id) || return 1
  gh api -X POST "repos/$REPO/issues/$PARENT/sub_issues" -F sub_issue_id="$child_id" \
    --jq .number >/dev/null
}

PARENT="${1:?親 Issue 番号が必要}"; shift

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

TITLE="${1:?タイトルが必要}"; shift

BODY="" BODY_FILE="" TYPE="" IS_TEST=false
LABELS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --body-file) BODY_FILE="$2"; shift 2 ;;
    --body)      BODY="$2"; shift 2 ;;
    --label)     LABELS+=("$2"); shift 2 ;;
    --type)      TYPE="$2"; shift 2 ;;
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

args=(--title "$TITLE" -R "$REPO")
[ -n "$TYPE" ] && args+=(--type "$TYPE")
[ -n "$BODY_FILE" ] && args+=(--body-file "$BODY_FILE")
[ -n "$BODY" ] && args+=(--body "$BODY")
[ -z "$BODY_FILE" ] && [ -z "$BODY" ] && args+=(--body "")
for l in "${LABELS[@]:-}"; do [ -n "$l" ] && args+=(--label "$l"); done

url=$(gh issue create "${args[@]}")
num="${url##*/}"

link_to_parent "$num"

echo "sub-issue #$num を #$PARENT の下に作成した: $url"
