# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# AI エージェントの署名を組む (#18・#3149)。source して使う。
#
# 署名は「どのエージェントが、どのモデルで」を、分かる範囲で名乗る:
#
#   <sub>🤖 Assisted by [Claude Code](https://claude.com/claude-code) (Opus 5.5)</sub>
#   <sub>🤖 Assisted by [Claude Code](…) (Opus 5.5, Haiku 5.5)</sub>   サブエージェントが別のモデル
#   <sub>🤖 Assisted by Grok CLI (grok-5)</sub>                                        環境変数で名乗る
#   <sub>🤖 Assisted by [Codex](https://developers.openai.com/codex) (GPT-6 Astra)</sub>
#   <sub>🤖 Assisted by [Claude Code](…) (Opus 5.5) and Codex (GPT-6 Astra)</sub>   --with で併記
#
# **分からない部分は書かない。** 推測で書いたモデル名は出所の嘘になる。Codex の
# config.toml の model は起動時の指定で上書きされうるので読まず、セッションの記録を読む (#3409)。
#
# 読み手は scripts/comment.sh (発言)・scripts/sub-issue.sh (起票)・
# scripts/agent-comment-guard.sh (署名の無い本文を差し戻すときに貼る 1 行を示す)。
#
# 名乗りの決まり方:
#
#   エージェント  MOKUME_AGENT_NAME (+ MOKUME_AGENT_URL) > Claude Code の env > Codex の痕跡 >
#                 AI_AGENT の道具名 (他の道具も立てる慣習の変数)。どれも無ければ「分からない」
#   モデル        MOKUME_AGENT_MODEL (カンマ区切りで複数) > Claude Code のセッションの記録に
#                 残る assistant の model / Codex のセッションの記録の最後の turn_context の model。**名乗るのはこの文を書いたモデルではなく、このセッションで
#                 使ったモデル**である (どの文をどのモデルが書いたかは記録から決められない)。
#                 先頭は主の記録の最新のモデル (/model で切り替えた後のもの)、続いて主の記録の残り、
#                 サブエージェントの記録にだけ現れるモデルの順
#   併記          --with に渡した名乗り (複数可)。連携は実行環境からは見えないので明示する

# 署名の検知キー。リンク先やモデルの名乗りが変わっても効き続けるよう、固定の語で見る。
# 絵文字まで含めるのは、署名の話をする本文や英文の引用 ("Assisted by") を署名と取り違えない
# ため (#3149 の反証)。scripts/agent-comment-guard.sh・scripts/ready-queue.sh・
# scripts/review-gate.sh もこの綴りを読む
SIGNATURE_KEY='🤖 Assisted by'

# 「どの AI が書いたか」を実行環境から判定する → "表示名\tURL" (URL は空でもよい)。
# 判定できなければ 1 を返して何も出さない (総称に落とすかは呼ぶ側が決める)。
#   $1 = strict なら、人もシェルの設定で立てる変数 (CODEX_HOME) だけでは判定しない。人も打つ
#        口 (scripts/sub-issue.sh) が人の起票に Codex の署名を付けないため (#3149 の反証)
detect_agent() {
  local is_claude strict=${1:-}
  if [ -n "${MOKUME_AGENT_NAME:-}" ]; then
    printf '%s\t%s' "$MOKUME_AGENT_NAME" "${MOKUME_AGENT_URL:-}"
    return 0
  fi
  # Claude Code: CLAUDECODE=1 を立てる。AI_AGENT にも識別子が入る
  case "${AI_AGENT:-}" in claude-code*) is_claude=true ;; *) is_claude=false ;; esac
  if [ "${CLAUDECODE:-}" = "1" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] || $is_claude; then
    printf 'Claude Code\thttps://claude.com/claude-code'
    return 0
  fi
  # Codex: 専用の名乗りがまだ無く (openai/codex#13416)、シェルに立てる CODEX_THREAD_ID と
  # サンドボックス実行の痕跡で見る。判定が緩いぶん、名乗りが増えたらここを差し替える。
  # 「OpenAI」は付けない (冗長。メンテナの指定。#3409)
  if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_SANDBOX:-}" ] ||
     [ -n "${CODEX_SANDBOX_NETWORK_DISABLED:-}" ] ||
     { [ "$strict" != strict ] && [ -n "${CODEX_HOME:-}" ]; }; then
    printf 'Codex\thttps://developers.openai.com/codex'
    return 0
  fi
  # 知らない道具でも AI_AGENT を立てていれば、その道具名 (版より前) を名乗る
  if [ -n "${AI_AGENT:-}" ]; then
    printf '%s\t' "${AI_AGENT%%_*}"
    return 0
  fi
  return 1
}

# モデルの ID を表示名へ畳む。claude-opus-5-5 → Opus 5.5、日付の接尾辞は落とす。
# 「Claude」を付けないのは、記録から読むのが Claude Code のときだけで、署名の頭の
# [Claude Code] と重なるため (メンテナの指定)。Claude 以外のエージェントが Claude の
# モデルを名乗るときは MOKUME_AGENT_MODEL に書いたとおりに出る (Claude Opus 5.5 など)。
# GPT は gpt-6-astra → GPT-6 Astra (Codex の models_cache.json の表示名は「GPT-6-Astra」
# 「GPT-6.1 Terra」と綴りが揺れるので使わない。#3409)。
# 形が読めない ID はそのまま返す (知らない形を作り替えると別のモデルを名乗りかねない)
model_display_name() { # $1=モデルの ID
  local id=${1%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}
  if [[ $id =~ ^claude-([a-z]+)-([0-9]+)(-([0-9]{1,2}))?$ ]]; then
    local family=${BASH_REMATCH[1]}
    printf '%s%s %s' "$(tr '[:lower:]' '[:upper:]' <<<"${family:0:1}")" "${family:1}" \
      "${BASH_REMATCH[2]}${BASH_REMATCH[4]:+.${BASH_REMATCH[4]}}"
  elif [[ $1 =~ ^gpt-([0-9]+(\.[0-9]+)?)-([a-z]+)$ ]]; then
    local name=${BASH_REMATCH[3]}
    printf 'GPT-%s %s%s' "${BASH_REMATCH[1]}" "$(tr '[:lower:]' '[:upper:]' <<<"${name:0:1}")" "${name:1}"
  else
    printf '%s' "$1"
  fi
}

# Claude Code のセッションの記録を探す → パス。CLAUDE_CODE_SESSION_ID の記録は
# ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<起動した場所>/<ID>.jsonl に置かれる
claude_transcript() {
  local id=${CLAUDE_CODE_SESSION_ID:-} f
  [ -n "$id" ] || return 1
  for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$id".jsonl; do
    [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# 記録から、使ったモデルを多い順に 1 行ずつ。読むのは各行の message.model だけで、ツールの
# 結果や本文に映った "model" の字面は拾わない。grep で assistant の行に絞るのは速さのため
# (長いセッションの記録は MB 単位になり、フックの持ち時間は 10 秒)
transcript_models() { # $1=記録のパス…
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    grep -E '"type": ?"assistant"' "$f" | jq -r '.message.model // empty' 2>/dev/null
  done | grep -vxF '<synthetic>' | sort | uniq -c | sort -rn | awk '{print $2}'
}

# 記録の最後の assistant の行のモデル (いま主が使っているモデル)
latest_model() { # $1=記録のパス
  [ -f "$1" ] || return 0
  grep -E '"type": ?"assistant"' "$1" | jq -r '.message.model // empty' 2>/dev/null |
    grep -vxF '<synthetic>' | tail -n 1
}

# Codex のセッションの記録から、いま使っているモデルの ID (分からなければ空)。記録は
# ${CODEX_HOME:-~/.codex}/sessions/YYYY/MM/DD/rollout-<時刻>-<CODEX_THREAD_ID>.jsonl に置かれ、
# 手番ごとの turn_context 行がその時点の model を持つ。最後の行を読むので、途中で切り替えた
# 後のモデルを名乗る。grep で turn_context の行に絞るのは速さのため (transcript_models と同じ)
codex_model() {
  local id=${CODEX_THREAD_ID:-} f
  [ -n "$id" ] || return 0
  for f in "${CODEX_HOME:-$HOME/.codex}"/sessions/*/*/*/rollout-*-"$id".jsonl; do
    [ -f "$f" ] || continue
    grep -E '"type": ?"turn_context"' "$f" | jq -r '.payload.model // empty' 2>/dev/null | tail -n 1
    return 0
  done
}

# 使ったモデルの名乗り → "Opus 5.5, Haiku 5.5" (分からなければ空)。
#   $1 = エージェントの表示名  $2 = Claude Code の記録のパス (省略時は env から探す)
agent_models() {
  local agent=$1 transcript=${2:-} line out=
  if [ -n "${MOKUME_AGENT_MODEL:-}" ]; then
    printf '%s' "$MOKUME_AGENT_MODEL"
    return
  fi
  if [ "$agent" = Codex ]; then
    line=$(codex_model)
    [ -z "$line" ] || model_display_name "$line"
    return 0
  fi
  [ "$agent" = "Claude Code" ] || return 0
  [ -n "$transcript" ] || transcript=$(claude_transcript) || return 0
  # 主の記録の最新のモデル → 主の記録の残り → サブエージェントの記録にだけ現れるモデル
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line=$(model_display_name "$line")
    case ", $out, " in *", $line, "*) continue ;; esac
    out=${out:+$out, }$line
  done < <(latest_model "$transcript"
           transcript_models "$transcript"
           transcript_models "${transcript%.jsonl}"/subagents/*.jsonl)
  printf '%s' "$out"
}

# 1 人分の名乗り → "[Claude Code](url) (Opus 5.5)"
agent_credit() { # $1=表示名 $2=URL $3=モデル
  if [ -n "$2" ]; then printf '[%s](%s)' "$1" "$2"; else printf '%s' "$1"; fi
  [ -z "$3" ] || printf ' (%s)' "$3"
}

# 署名の 1 行。
#   agent_signature [--generic] [--transcript <パス>] [--with <名乗り>]...
#   --generic : エージェントを判定できなくても総称 (an AI agent) で署名する。付けなければ
#               判定できないときに 1 を返して何も出さない (人の実行に署名を付けない口のため)
agent_signature() {
  local generic=false transcript='' agent name url credits
  local -a with=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --generic) generic=true; shift ;;
      --transcript) transcript=$2; shift 2 ;;
      --with) with+=("$2"); shift 2 ;;
      *) return 64 ;;
    esac
  done
  local strict=strict
  $generic && strict=
  if agent=$(detect_agent "$strict"); then
    name=${agent%%$'\t'*}
    url=${agent#*$'\t'}
  elif $generic; then
    name='an AI agent' url=
  else
    return 1
  fi
  credits=$(agent_credit "$name" "$url" "$(agent_models "$name" "$transcript")")
  local w
  for w in ${with[@]+"${with[@]}"}; do credits="$credits and $w"; done
  printf '<sub>%s %s</sub>' "$SIGNATURE_KEY" "$credits"
}
