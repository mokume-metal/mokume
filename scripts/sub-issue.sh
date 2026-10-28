#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# sub-issue を 1 コマンドで作る: 作成 + 親への紐づけ + 親の Issue Type 継承。
# gh CLI に sub-issue コマンドが無いための補い (ADR-0002 / #23)。
#
# 使い方:
#   sub-issue.sh <親番号> <タイトル> [--body-file F | --body TEXT] [--label L]... [--type T] [--with 名乗り]... [--test]
#   sub-issue.sh <親番号> --attach <番号>
#   --type   : 親から継ぐ型を上書きする (ADR-0004 の 5 型: Bug/Feature/Task/Design/Docs)
#   --test   : 使い捨て検証用。タイトルに test: を補い、verify: triaged を付け、
#              本文が無ければ検証用の雛形を入れる (確認後に close する前提)
#   --with   : 一緒に作った別のエージェント・モデルを署名に併記する (#3149)
#   --attach : 作らずに、既に在る Issue を親の下へ繋ぐ (#1661)。型は継がない
#
# エージェントが実行したときは、作る Issue の本文の末尾にエージェントの署名を付ける (#3149。
# 名乗りの決まり方は scripts/agent-signature.sh)。人の実行には付けない。
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
# 起票の署名 (#3149)
# shellcheck source=scripts/agent-signature.sh
. "$(dirname "${BASH_SOURCE[0]}")/agent-signature.sh"

USAGE='使い方: sub-issue.sh <親番号> <タイトル> [--body-file F | --body TEXT] [--label L]... [--type T] [--with 名乗り]... [--test]
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
  local child_id out
  child_id=$(gh api "repos/$REPO/issues/$1" --jq .id) || return 1
  # 断られた理由 (errors) は応答の本文 (stdout) にしか無いので、捨てずに名乗る (#2075)
  if ! out=$(gh api -X POST "repos/$REPO/issues/$PARENT/sub_issues" \
    -F sub_issue_id="$child_id" 2>&1); then
    printf '%s\n' "$out" >&2
    return 1
  fi
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

TITLE="${1:?タイトルが必要}"; shift
case "$TITLE" in -*) usage_error "タイトルは - で始まる値を読まない: $TITLE" ;; esac

BODY="" BODY_FILE="" TYPE="" IS_TEST=false
LABELS=() WITH=()
while [ $# -gt 0 ]; do
  case "$1" in
    --body-file) BODY_FILE="$2"; shift 2 ;;
    --body)      BODY="$2"; shift 2 ;;
    --label)     LABELS+=("$2"); shift 2 ;;
    --type)      TYPE="$2"; shift 2 ;;
    --with)      WITH+=(--with "$2"); shift 2 ;;
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
