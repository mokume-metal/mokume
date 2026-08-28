#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 着手時に立てたプランを GitHub (PR / Issue のコメント) に残させるフック (#35)。
# AGENTS.md 「進め方」3 の担保 — capture で投稿を指示し、guard で未投稿を差し戻す。
#
# 設計の要点:
#   1. 置き場は GitHub のコメント (リポジトリにはコミットしない)
#   2. 持ち出す前に落とす。秘密は落とさず投稿ごと止める
#   3. 投稿はフックが行わず scripts/comment.sh を打たせる (人間の目を一度通す)
#
# 契約 (詳細は各関数の頭):
#   capture   stdin に PostToolUse (ExitPlanMode) の JSON。記録し指示を stderr へ (exit 2)
#   guard     stdin に Stop の JSON。未投稿が残っていれば差し戻す (exit 2)
#   sanitize  stdin の本文からパス類を落として stdout へ
#   scan      stdin の本文から BLOCK / WARN 行を stdout へ
#
# 環境変数: MOKUME_PLAN_RECORD=0 / MOKUME_PLAN_RECORD_DEBUG=1 / GITHUB_REPOSITORY
# 配線は .claude/settings.json、テストは scripts/tests/plan_record_test.py。

set -uo pipefail

REPO="${GITHUB_REPOSITORY:-mokume-metal/mokume}"

# 投稿済み判定の目印。個人環境の同種フック (plan-record: <id>) と混ざらないよう
# 接頭辞を分ける — 両方が動いていても互いの記録を「投稿済み」と誤読しない
readonly MARKER='mokume-plan-record'

# 何もせず終わる経路の理由を見せる。既定は無言 (通常運転で喋ると邪魔になる)。
# 仕組みが黙って効かなくなったときの切り分け用で、MOKUME_PLAN_RECORD_DEBUG=1 を
# 付けて同じ payload を流し直せば理由が出る
debug() { [ "${MOKUME_PLAN_RECORD_DEBUG:-0}" = "0" ] || printf 'plan-record: %s\n' "$1" >&2; }

# 一時的に止めたいときの逃げ道
if [ "${MOKUME_PLAN_RECORD:-1}" = "0" ]; then
  debug 'MOKUME_PLAN_RECORD=0 で無効化されている'
  exit 0
fi

MAX_NAGS=3      # guard が差し戻す回数の上限。超えたら諦めて人間の判断へ返す
STALE_DAYS=14   # 投稿先が現れないまま放置された記録を捨てるまでの日数

# --- サニタイズ -------------------------------------------------------------
# 機械的に落とせるのは「場所」だけ。判断の要るもの (メールアドレス、1Password の
# 参照) は scan で警告に回し、消すかどうかは本文を読めるエージェントと人間に委ねる。

sanitize() { # $@ = 畳むディレクトリ (短い順に効かせたいので渡した順に処理)
  local script='' prefix

  # リポジトリの絶対パスはリポジトリ相対に畳む。worktree で作業していると
  # /Users/foo/Repos/mokume/.claude/worktrees/wt-a1b2/scripts/comment.sh のような
  # パスが本文に載るが、他人にとっては scripts/comment.sh 以外に意味が無い。
  #
  # 同じ場所を指すのに表記が違うことがある (macOS の /tmp と /private/tmp) ので
  # 複数受け取る。git が返すのは実パス、本文に載るのはエージェントが見ている論理パスで、
  # 片方だけを消すともう片方が生のまま残る
  for prefix in "$@"; do
    [ -n "$prefix" ] || continue
    prefix=$(escape_for_sed "$prefix")
    script="$script s|$prefix/||g; s|$prefix|.|g;"
  done

  # 残った絶対パスからホームディレクトリを畳む。$HOME だけでなく他人のホームも
  # 対象にする (プランには他の開発者のパスが引用として混ざりうる)。
  # 区切りは # — ここは選択 (|) を使うので、区切りに | は選べない
  sed -E "$script"'
    s#/(Users|home)/[^/[:space:]"'"'"'`)]+#~#g
  '
}

escape_for_sed() { # ERE のパターンとして特別扱いされる文字を殺す (区切りの | を含む)
  printf '%s' "$1" | sed 's/[][\.*^$|/(){}+?]/\\&/g'
}

logical_root() { # $1=フックが渡してきた cwd → その表記のままのリポジトリルート
  # git は実パスを返すので、シンボリックリンクを経由していると本文中の表記と
  # 食い違う (macOS の /tmp は /private/tmp)。cwd からルートまでの深さぶん
  # 遡って、エージェントが見ているのと同じ表記のルートを作る
  local dir="${1:-}" depth i
  [ -n "$dir" ] || return 0
  depth=$(git rev-parse --show-prefix 2>/dev/null | tr -cd '/' | wc -c | tr -d ' ')
  for ((i = 0; i < depth; i++)); do
    dir=$(dirname "$dir")
  done
  printf '%s' "$dir"
}

# --- 検査 -------------------------------------------------------------------
# BLOCK: 見つかったら投稿用ファイルを作らない (秘密情報)
# WARN : 投稿は止めないがエージェントに読ませて判断させる (個人情報・環境固有)

scan() {
  local body
  body=$(cat)

  emit BLOCK 'GitHub のトークン' "$body" 'gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,}'
  emit BLOCK 'API キー' "$body" 'sk-ant-[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9]{32,}'
  emit BLOCK 'AWS のアクセスキー' "$body" 'AKIA[0-9A-Z]{16}'
  emit BLOCK 'Slack のトークン' "$body" 'xox[baprs]-[A-Za-z0-9-]{10,}'
  emit BLOCK '秘密鍵' "$body" '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  # 値が実体を持つものだけ。$VAR / <your-token> / **** のような伏せ字は対象外。
  # 値は ASCII の英数記号に限る — 日本語を許すと「token は環境変数で渡す」のような
  # 説明文まで秘密情報として拾ってしまい、投稿を止める判断が信用できなくなる
  emit BLOCK '秘密情報らしき代入' "$body" \
    '(password|passwd|secret|token|api[_-]?key|access[_-]?key)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+=_-]{8,}'

  # noreply は GitHub が公開用に配るアドレスなので、伏せる意味が無い
  emit WARN 'メールアドレス' "$body" \
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' 'noreply'
  emit WARN '1Password の参照 (vault の構造が漏れる)' "$body" 'op://[^[:space:]]+'
  emit WARN '畳めなかった絶対パス' "$body" '/(Users|home)/[A-Za-z0-9._-]+'
  emit WARN 'ローカルのポート番号' "$body" 'localhost:[0-9]+|127\.0\.0\.1:[0-9]+'
}

emit() { # $1=種別 $2=説明 $3=本文 $4=検出パターン $5=除外パターン(省略可)
  local kind="$1" label="$2" body="$3" pattern="$4" exclude="${5:-}" hits
  # 大文字小文字は区別しない。GITHUB_TOKEN= のような書き方を取りこぼすため。
  # 検出漏れより過検出のほうが安全 — BLOCK は行番号を示すだけ、WARN は判断を委ねる
  hits=$(printf '%s' "$body" | grep -inE "$pattern" 2>/dev/null) || return 0
  [ -n "$exclude" ] && hits=$(printf '%s' "$hits" | grep -viE "$exclude")
  [ -n "$hits" ] || return 0
  # 中身は出さない。秘密情報を hook の出力へ再掲したら守った意味が無いため、
  # 場所 (行番号) だけを伝えて本文へ誘導する
  printf '%s\t%s\t行 %s\n' "$kind" "$label" \
    "$(printf '%s' "$hits" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')"
}

# --- 投稿先の解決 -----------------------------------------------------------
# 優先順は「今そこにある器」から。PR があればそこ、無ければプランが閉じようと
# している Issue、それも無ければブランチ名の数字列。どれも無ければ空を返す。
#
# PR はマージ後も投稿先のまま扱う。open だけを見ると、マージした瞬間に投稿済みの
# プランを見失い、Closes で名乗った Issue (たいてい閉じている) へ催促が回る。
# 除くのは放棄された CLOSED だけ。
#
# gh には必ず -R を渡す。リポジトリを cwd から推定させると、直前に別ディレクトリへ
# 移動していただけで別リポジトリの同じ番号へプランが飛ぶ (実際に起きた)。

resolve_target() { # $1=ブランチ $2=本文 → "pr 123" / "issue 45" / ""
  local branch="$1" body="$2" number

  number=$(gh pr view "$branch" -R "$REPO" --json number,state \
    -q 'select(.state != "CLOSED") | .number' 2>/dev/null)
  if [ -n "$number" ]; then
    printf 'pr %s' "$number"
    return 0
  fi

  # Closes #12 / Refs #12 のように、プランが自分で名乗っている Issue
  number=$(printf '%s' "$body" |
    grep -ioE '(closes|fixes|resolves|refs|ref|issue)[[:space:]]*#[0-9]+' |
    grep -oE '[0-9]+' | head -1)
  # 名乗りが無ければブランチ名の数字列 (issues-123 / fix/123-foo)。ただし採るのは
  # 区切りに接した数字だけにする。Claude Code が切るブランチ名の末尾 hex
  # (claude/<説明>-c936e5 → 936) や worktree の自動生成名に紛れる断片
  # (cse_0127aTN6... → 127) を番号と読むと、無関係な Issue へプランが飛ぶ。
  # 番号が実在することは、そこが投稿先として正しいことを意味しない
  [ -n "$number" ] || number=$(printf '%s' "$branch" |
    sed -E 's#^(claude/.*)-[0-9a-f]{6}$#\1#' |
    grep -oE '(^|[^0-9A-Za-z])[0-9]{1,6}([^0-9A-Za-z]|$)' |
    grep -oE '[0-9]+' | head -1)
  [ -n "$number" ] || return 0

  # 実在して open かを確かめる。ブランチ名の数字はハッシュの断片でもありうる
  gh issue view "$number" -R "$REPO" --json number -q .number >/dev/null 2>&1 || return 0
  printf 'issue %s' "$number"
}

posted() { # $1=種別 $2=番号 $3=記録 ID — GitHub 側にこの記録が既にあるか
  local kind="$1" number="$2" id="$3"
  gh "$kind" view "$number" -R "$REPO" --json comments -q '.comments[].body' 2>/dev/null |
    grep -qF "$MARKER: $id"
}

record_dir() {
  local common
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  # --git-common-dir は相対パス (.git) を返すことがあるので絶対化しておく。
  # .git の中なのでコミットされず、worktree からでも共通の一箇所を指す
  case "$common" in
    /*) ;;
    *) common="$(pwd)/$common" ;;
  esac
  printf '%s/%ss' "$common" "$MARKER"
}

# --- プラン本文の取り出し ---------------------------------------------------
# 本文の置き場は Claude Code のバージョンで動く:
#   以前 — モデルが ExitPlanMode の引数として本文を渡していた (.tool_input.plan)
#   現在 — モデルは引数を取らず本文はファイルに書かれる。フックへは
#          .tool_response.plan / .tool_response.filePath として返り、
#          .tool_input は {"_targetMode":"auto"} だけになる
# 1 箇所に賭けるとこの変化で黙って壊れるので、ありうる場所を順に見て最初に
# 見つかった本文を使い、本文が直接来ていなければファイルから読む。

plan_body() { # $1=payload → プラン本文 (見つからなければ空)
  local payload="$1" body file
  body=$(printf '%s' "$payload" | jq -r '
    first((
      .tool_input.plan?, .tool_input.content?, .tool_input.text?, .tool_response.plan?
    ) | select(type == "string" and . != ""))' 2>/dev/null)
  if [ -z "$body" ]; then
    file=$(printf '%s' "$payload" | jq -r '
      first((
        .tool_response.filePath?, .tool_response.planFilePath?, .tool_input.planFilePath?
      ) | select(type == "string" and . != ""))' 2>/dev/null)
    [ -n "$file" ] && [ -f "$file" ] && body=$(cat "$file")
  fi
  printf '%s' "$body"
}

payload_keys() { # $1=payload $2=キー名 → そのオブジェクトのキー一覧
  # 値は出さない。プランにも tool_response にも秘密情報が混ざりうるので、
  # 次に直す人の手がかりになるキー名だけを見せる
  printf '%s' "$1" | jq -r --arg k "$2" '
    .[$k] | if type == "object" then (keys | join(",")) else "(\(type))" end' 2>/dev/null ||
    printf '(不明)'
}

post_command() { # $1=種別 $2=番号 $3=記録ファイル → 提示する投稿コマンド
  # 素の gh ではなくラッパー経由 (#18)。署名の付与はそちらに任せる
  printf 'bash scripts/comment.sh %s %s --body-file "%s"' "$1" "$2" "$3"
}

# --- capture ----------------------------------------------------------------

capture() {
  local payload plan cwd session root branch dir id file body findings blocks warns target

  payload=$(cat)
  if ! command -v jq >/dev/null 2>&1; then
    debug 'jq が無い'
    exit 0
  fi

  plan=$(plan_body "$payload")
  if [ -z "$plan" ]; then
    # ExitPlanMode が通った以上プランは必ず存在するので、本文が取れないこと自体が異常。
    # ここだけは黙って諦めない — 無言で終わると guard も黙り、「プランを GitHub に
    # 残す」仕組みが誰にも気付かれないまま無効化される
    cat >&2 <<EOF
ExitPlanMode は通りましたが、プラン本文を取り出せませんでした。GitHub 用の記録は作れていません。

プランは手元に残っているので、対象の PR / Issue へ scripts/comment.sh で投稿してください。
そのうえで、フックが受け取る形が変わっていないか scripts/plan-record.sh の plan_body() を確かめてください。

  受け取ったキー: tool_input=$(payload_keys "$payload" tool_input) / tool_response=$(payload_keys "$payload" tool_response)
EOF
    exit 2
  fi

  cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""')
  session=$(printf '%s' "$payload" | jq -r '.session_id // "nosession"')
  [ -n "$cwd" ] && cd "$cwd" 2>/dev/null

  # git リポジトリの外で立てたプランには投稿先が無い。黙って通す
  if ! root=$(git rev-parse --show-toplevel 2>/dev/null); then
    debug "git リポジトリの外 (cwd=$cwd)"
    exit 0
  fi
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || { debug 'HEAD を解決できない'; exit 0; }
  dir=$(record_dir) || { debug 'record_dir を解決できない'; exit 0; }

  body=$(printf '%s' "$plan" | sanitize "$root" "$(logical_root "$cwd")")
  findings=$(printf '%s' "$body" | scan)
  blocks=$(printf '%s' "$findings" | grep '^BLOCK' | cut -f2,3)
  warns=$(printf '%s' "$findings" | grep '^WARN' | cut -f2,3)

  if [ -n "$blocks" ]; then
    # 保存もしない。秘密情報を含むファイルを .git の中に置き去りにしないため
    cat >&2 <<EOF
プランに秘密情報らしき文字列があるため、GitHub 用の記録を作りませんでした。

$(printf '%s' "$blocks" | sed 's/^/  - /')

その値を本文から外して (環境変数名や参照だけにして) からプランを立て直してください。
本文は出力していません。行番号を頼りに手元のプランを確認してください。
EOF
    exit 2
  fi

  mkdir -p "$dir" 2>/dev/null || { debug "記録の置き場を作れない ($dir)"; exit 0; }
  id="${session%%-*}-$(date +%s)"
  file="$dir/$id.md"

  {
    printf '<!-- %s: %s -->\n' "$MARKER" "$id"
    printf '## 着手時のプラン\n\n'
    printf '%s\n' "$body"
    printf '\n---\n\n'
    printf 'このプランは着手時点の判断です。実装の過程で変わった場合は、'
    printf 'このコメントに返信する形で差分を残してください。\n'
    # 署名はここで焼き込まない。どのエージェントから投稿されるかは実行環境で決まるので、
    # scripts/comment.sh が投稿時に判定して付ける (#18)
  } > "$file"

  target=$(resolve_target "$branch" "$body")
  printf 'branch=%s\nid=%s\nnags=0\n' "$branch" "$id" > "$dir/$id.meta"

  {
    echo "プランを GitHub 用に整えました: $file"
    echo "(絶対パスとホームディレクトリは畳んであります。署名は投稿時に自動で付きます)"
    echo
    if [ -n "$target" ]; then
      # shellcheck disable=SC2086
      set -- $target
      echo "次のコマンドで投稿してください:"
      echo
      echo "  $(post_command "$1" "$2" "$file")"
    else
      echo "投稿先の PR / Issue がまだありません。対象の Issue か、PR を立てたらそこへ:"
      echo
      echo "  $(post_command issue '<番号>' "$file")"
      echo
      echo "(このセッションを終えようとしたときに、まだ投稿されていなければ差し戻します)"
    fi
    echo
    echo "投稿の前に本文を読み、他の開発者が読む前提で次を確かめてください。"
    echo "気になる箇所は $file を直接編集してから投稿して構いません (--dry-run で確認できます)。"
    echo "  - 自分の環境でだけ成り立つ手順 (個人の設定、ローカルのポート、手元のディレクトリ構成)"
    echo "  - 他の開発者には不要な個人情報 (メールアドレス、社内 URL、1Password の参照)"
    echo "  - 未公開の計画や、まだ相談していない他人の名前"
    if [ -n "$warns" ]; then
      echo
      echo "次の箇所は自動では判断できませんでした。残すかどうか本文を見て決めてください:"
      printf '%s\n' "$warns" | sed 's/^/  - /'
    fi
  } >&2
  exit 2
}

# --- guard ------------------------------------------------------------------

guard() {
  local payload cwd dir branch meta id file nags target kind number pending='' round=0

  payload=$(cat)
  command -v jq >/dev/null 2>&1 || { debug 'jq が無い'; exit 0; }
  command -v gh >/dev/null 2>&1 || { debug 'gh が無い'; exit 0; }

  cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""')
  [ -n "$cwd" ] || { debug 'payload に cwd が無い'; exit 0; }
  cd "$cwd" 2>/dev/null || { debug "cwd へ移動できない ($cwd)"; exit 0; }
  dir=$(record_dir) || { debug 'git リポジトリの外'; exit 0; }
  [ -d "$dir" ] || { debug "未投稿の記録が無い ($dir)"; exit 0; }

  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || { debug 'HEAD を解決できない'; exit 0; }

  for meta in "$dir"/*.meta; do
    [ -f "$meta" ] || continue

    # 投稿先が現れないまま放置された記録は捨てる (毎セッション蒸し返さない)
    if [ -n "$(find "$meta" -mtime +$STALE_DAYS 2>/dev/null)" ]; then
      rm -f "$meta" "${meta%.meta}.md"
      continue
    fi

    # 見るのは今のブランチのものだけ。他ブランチの分はそのブランチに戻ったときに
    [ "$(sed -n 's/^branch=//p' "$meta")" = "$branch" ] || continue

    id=$(sed -n 's/^id=//p' "$meta")
    nags=$(sed -n 's/^nags=//p' "$meta")
    nags=${nags:-0}
    file="${meta%.meta}.md"
    [ -f "$file" ] || { rm -f "$meta"; continue; }

    target=$(resolve_target "$branch" "$(cat "$file")")
    # 投稿先がまだ無いものは急かさない (PR を立てる前に終えるセッションもある)
    [ -n "$target" ] || continue

    # shellcheck disable=SC2086
    set -- $target
    kind="$1" number="$2"

    if posted "$kind" "$number" "$id"; then
      rm -f "$meta" "$file"
      continue
    fi

    if [ "$nags" -ge "$MAX_NAGS" ]; then
      rm -f "$meta" "$file"
      continue
    fi
    printf 'branch=%s\nid=%s\nnags=%s\n' "$branch" "$id" "$((nags + 1))" > "$meta"
    # 表示する回数は最も催促の進んだ記録に合わせる (複数あっても数字が後戻りしない)
    [ "$((nags + 1))" -gt "$round" ] && round=$((nags + 1))
    pending="$pending  $(post_command "$kind" "$number" "$file")
"
  done

  [ -n "$pending" ] || exit 0

  cat >&2 <<EOF
着手時のプランがまだ GitHub に残っていません ($round/$MAX_NAGS 回目)。終了せず投稿してください。

$pending
記憶がリセットされた次のセッションは、この PR / Issue を読むだけで再開できる必要があります。
実装の途中で方針が変わっているなら、変わった点を本文に追記してから投稿してください。

上の投稿先が違うと思うなら、ブランチ名から推定した番号かもしれません。正しい PR /
Issue へ投稿したうえで、--body-file に出ている記録ファイルを消せばこの差し戻しは止まります。

投稿しない判断をした場合 (プランが実装と食い違って役に立たない等) は、そのまま終えて
構いません ($MAX_NAGS 回で自動的に黙ります)。
EOF
  exit 2
}

case "${1:-}" in
  capture)  capture ;;
  guard)    guard ;;
  sanitize) sanitize "${2:-}" ;;
  scan)     scan ;;
  *) echo "usage: $(basename "$0") {capture|guard|sanitize [root]|scan}" >&2; exit 64 ;;
esac
