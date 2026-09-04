#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# Issue / PR へのコメントを、AI エージェントの署名を自動で付けて投稿する (#18)。
#
# 同じ Issue には人間も複数のエージェントも書き込む。署名が無いと、後から読む人
# (と、記憶がリセットされた次のセッション) が発言の出どころを判別できない。
# GitHub App 経由で投稿するエージェントはプラットフォームが出所を描いてくれるが、
# ローカルの gh CLI = 本人のトークンで投稿する経路にはその表示が出ない。
#
# 署名を「規約として書いておく」のではなく、ここで機械的に付ける。エージェントが
# 規約を覚えていることに依存しない (AGENTS.md は読まれない前提で設計する)。
#
# 使い方:
#   scripts/comment.sh {issue|pr} <番号> (--body TEXT | --body-file FILE) [--dry-run]
#     --dry-run : gh を呼ばず、最終的なコマンドと本文を stdout に出す
#
# 環境変数:
#   MOKUME_AGENT_NAME  署名に出す名前を明示する (自動検出より優先)
#   MOKUME_AGENT_URL   その名前に張るリンク (省略可)
#   GITHUB_REPOSITORY  投稿先リポジトリ (既定 mokume-metal/mokume)
#
# 人間が直接 gh を使う分にはこのラッパーは不要 (署名の意味が無い)。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"

# 署名の検知キー。リンク先や絵文字が変わっても効き続けるよう、固定の語で見る。
# scripts/agent-comment-guard.sh と .github の検査もこの文字列を共有する
readonly SIGNATURE_KEY='Assisted by'

usage() {
  cat >&2 <<'EOF'
使い方: scripts/comment.sh {issue|pr} <番号> (--body TEXT | --body-file FILE) [--dry-run]

例:
  scripts/comment.sh issue 42 --body-file /tmp/plan.md
  scripts/comment.sh pr 7 --body "CI が緑になったので確認しました"
EOF
  exit 64
}

# --- エージェントの検出 -----------------------------------------------------
# 「どの AI が書いたか」を実行環境から判定する。検出できなくても投稿は止めない
# — 止めるとこのラッパー自体が使われなくなり、署名の無い素の gh に戻ってしまう。
# 総称の署名で投稿し、名乗り方を stderr で案内する。

detect_agent() { # → "表示名\tURL" (URL は空でもよい)
  local is_claude
  if [ -n "${MOKUME_AGENT_NAME:-}" ]; then
    printf '%s\t%s' "$MOKUME_AGENT_NAME" "${MOKUME_AGENT_URL:-}"
    return
  fi
  # Claude Code: CLAUDECODE=1 を立てる。AI_AGENT にも識別子が入る
  case "${AI_AGENT:-}" in claude-code*) is_claude=true ;; *) is_claude=false ;; esac
  if [ "${CLAUDECODE:-}" = "1" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] || $is_claude; then
    printf 'Claude Code\thttps://claude.com/claude-code'
    return
  fi
  # OpenAI Codex: 専用の名乗りがまだ無く (openai/codex#13416)、サンドボックス実行の
  # 痕跡で見るしかない。判定が緩いぶん、名乗りが増えたらここを差し替える
  if [ -n "${CODEX_SANDBOX:-}" ] || [ -n "${CODEX_SANDBOX_NETWORK_DISABLED:-}" ] ||
     [ -n "${CODEX_HOME:-}" ]; then
    printf 'OpenAI Codex\thttps://developers.openai.com/codex'
    return
  fi
  printf 'an AI agent\t'
}

signature() { # $1=表示名 $2=URL
  if [ -n "$2" ]; then
    printf '<sub>🤖 %s [%s](%s)</sub>' "$SIGNATURE_KEY" "$1" "$2"
  else
    printf '<sub>🤖 %s %s</sub>' "$SIGNATURE_KEY" "$1"
  fi
}

# --- 引数 -------------------------------------------------------------------

[ $# -ge 2 ] || usage
KIND="$1"; NUMBER="$2"; shift 2
case "$KIND" in issue | pr) ;; *) echo "種別は issue か pr: $KIND" >&2; usage ;; esac
case "$NUMBER" in '' | *[!0-9]*) echo "番号が数値でない: $NUMBER" >&2; usage ;; esac

BODY='' BODY_FILE='' DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --body) BODY="${2:?--body に本文が必要}"; shift 2 ;;
    --body-file | -F) BODY_FILE="${2:?--body-file にパスが必要}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "不明な引数: $1" >&2; usage ;;
  esac
done

if [ -n "$BODY_FILE" ]; then
  [ -f "$BODY_FILE" ] || { echo "本文のファイルが無い: $BODY_FILE" >&2; exit 66; }
  BODY=$(cat "$BODY_FILE")
fi
[ -n "$BODY" ] || { echo "本文が空" >&2; usage ;}

# --- 署名の付与 -------------------------------------------------------------

agent=$(detect_agent)
name=${agent%%$'\t'*}
url=${agent#*$'\t'}

if printf '%s' "$BODY" | grep -qF "$SIGNATURE_KEY"; then
  # 既に署名がある本文には足さない (plan-record のように署名込みで用意される経路がある)
  final="$BODY"
else
  final="$BODY

---
$(signature "$name" "$url")"
fi

if [ "$name" = "an AI agent" ]; then
  cat >&2 <<EOF
どの AI エージェントから投稿されているか判定できませんでした。総称の署名で投稿します。

名乗らせるには MOKUME_AGENT_NAME を設定してください (リンクを付けるなら MOKUME_AGENT_URL も):

  MOKUME_AGENT_NAME="<エージェント名>" scripts/comment.sh $KIND $NUMBER ...
EOF
fi

# --- 投稿 -------------------------------------------------------------------
# 本文は一時ファイル経由で渡す。--body に直接渡すと、長い本文や引用符・バッククォートを
# 含む本文がシェルの引数として壊れる

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$final" > "$tmp"

if $DRY_RUN; then
  echo "gh $KIND comment $NUMBER -R $REPO -F <本文>"
  echo "--- 本文 ---"
  cat "$tmp"
  exit 0
fi

gh "$KIND" comment "$NUMBER" -R "$REPO" -F "$tmp"
