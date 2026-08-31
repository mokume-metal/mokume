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
#   4. 着手の瞬間に、完了条件がまだ妥当かを問う (ADR-0031 決定 4 — recheck_missing)
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

# --- stdin ------------------------------------------------------------------
# **期限を持たせる。** 4 つの口はどれも呼び手が本文を即座に渡す前提で、手で打つと
# 永遠に待つ。**固まるのは EOF が来ない stdin** である — 空を渡した場合 (< /dev/null)
# は昔から返っていたので、端末やパイプが開いたまま打たれたときだけ無言で止まっていた
# (実際に 40 分放置された・#636)。AGENTS.md の「固まりうる待ちには、待つ側が期限を
# 持たせて越えたら殺す」がそのまま当たる。
#
# 5 秒にする根拠は、呼び手 (フック) が payload を即座に書くこと — 遅い機械でも届かない。
readonly STDIN_DEADLINE=5

read_stdin() { # → stdin の全体 (何も来なければ空)
  local line body=''
  while IFS= read -r -t "$STDIN_DEADLINE" line; do
    body+="$line"$'\n'
  done
  # 最後の行が改行で終わらないとき、read は変数へ入れて非 0 を返す。ここで拾わないと
  # 1 行落ちる
  [ -n "$line" ] && body+="$line"
  printf '%s' "$body"
}

explain_stdin() { # $1=口 $2=渡すもの。**その場で直せるところまで書く**
  {
    printf '%s は stdin から %s を読みます。%s 秒待って何も来ませんでした。\n\n' \
      "$1" "$2" "$STDIN_DEADLINE"
    printf 'capture と guard はフック (.claude/settings.json) が呼ぶ口で、手で打つものでは\n'
    printf 'ありません。sanitize と scan は本文を渡して使います:\n\n'
    printf '    bash scripts/%s %s < <ファイル>\n' "$(basename "$0")" "$1"
  } >&2
}

sanitize() { # $@ = 畳むディレクトリ (短い順に効かせたいので渡した順に処理)
  local script='' prefix body
  body=$(read_stdin)
  # **パイプの途中で使われるので止めない** (capture が 2 段で通す)。名乗って空を返す
  if [ -z "$body" ]; then
    explain_stdin sanitize 'プランの本文'
    return 0
  fi

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
  printf '%s' "$body" | sed -E "$script"'
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
  body=$(read_stdin)
  # sanitize と同じ理由で止めない (capture が 2 段で通す)
  if [ -z "$body" ]; then
    explain_stdin scan 'プランの本文'
    return 0
  fi

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

# 投稿済みかを、複数の投稿先で見る (#631)。
#
# guard が resolve_target を引き直すだけでは足りない。AGENTS.md 「進め方」は
# 「プランを Issue へ → PR を作る」の順を求めるので、**規約どおりに進めると
# guard の時点で解決が Issue から PR へ移っている** — 引き直した先 (PR) にプランは
# 無く、投稿済みなのに差し戻していた。
#
# 見るのは 2 つだけに絞る (capture が指示した先と、いまの解決先)。「Issue にも PR にも
# 無いこと」で判定すると、PR ができた後に取ったプランを Issue へ投稿しても黙ってしまい、
# 「PR を出した後なら PR 側へ」(AGENTS.md 「進め方」4) が効かなくなる。
#
# 配列は使わない (/bin/bash は 3.2 で、set -u 下の空配列展開が落ちる)。パイプでは
# なくヒアストリングで回す — パイプにするとサブシェルになり return が呼び手へ届かない。

posted_anywhere() { # $1=記録 ID $2=候補 (1 行 1 件・空行は飛ばす) → 載っていれば 0
  local id="$1" candidate kind number seen=''

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    # 同じ先を 2 度問い合わせない (capture の指示といまの解決が同じことは普通にある)
    case "$seen" in *"|$candidate|"*) continue ;; esac
    seen="$seen|$candidate|"
    kind=${candidate%% *} number=${candidate##* }
    posted "$kind" "$number" "$id" && return 0
  done <<< "$2"

  return 1
}

# 他のセッションが同じ Issue に既に着手していないかを見る (#642)。
#
# 二重着手は実際に起きた — 2 つのセッションが同じ Issue に着手し、両方が実装を書いて
# 片方が破棄された。見落とされたのは status: in progress ラベルで、**読むのは人の目だけ**
# だったので、見落としても何も起きなかった。
#
# **止めない。名乗るだけである。** 実例では、重複を知った側は知った時点で自分から畳んだ
# ので、要ったのは知らせることだった。加えて「他人が着手済み」という差し戻しは
# **プランの書き直しでは解けない** — 自分で解けない差し戻しには押し通す口が要り、
# それは「読まずに押し通す」癖を生む (#631 で見たのと同じ構造)。
#
# 見るのは**別のセッションが載せたプランの目印だけ**である。
#
# status: in progress ラベルは信号にならない。ラベルを付けるのは着手するセッション自身
# なので、規約どおり動くと capture の時点で必ず自分が付けたラベルが在る。しかも付け主は
# 判定できない — エージェントは同じ認証で操作するので、Issue events の actor が同じに
# なる。毎回名乗る注意は意味を失うので、区別できない信号は採らない。
#
# **代償は既知である。** 他のセッションが着手してラベルを付け、まだプランを投稿していない
# 窓 (数分) では何も見えない。埋めるには区別できないラベルを毎回名乗ることになり、
# 割に合わない。実例 (#637) では A の投稿から B の着手まで 19 分あったので、目印で届く。

concurrent_marks() { # $1=Issue 番号 $2=自分の記録 ID の接頭辞 → 跡を 1 行 1 件で stdout へ
  local number="$1" prefix="$2" json others count url

  json=$(gh issue view "$number" -R "$REPO" --json comments 2>/dev/null) || return 0
  [ -n "$json" ] || return 0

  # 自分のセッションが載せたプランは除く。同じセッションで 2 度プランを取ったときに
  # 自分を指して「二重着手かもしれない」と言わないため
  others=$(printf '%s' "$json" | jq -r --arg m "$MARKER: " --arg p "$prefix-" '
    [ .comments[]? | select(.body | contains($m)) | select(.body | contains($m + $p) | not) ]
    | "\(length)\t\(.[0].url // "")"' 2>/dev/null) || return 0

  count=${others%%	*}
  url=${others#*	}
  case "$count" in
    ''|0|*[!0-9]*) return 0 ;;
  esac

  printf '別のセッションのプランが %s 件載っている' "$count"
  [ -z "$url" ] || printf ' (%s)' "$url"
  printf '\n'
}

# 記録の付帯情報。capture と guard の両方が書くので 1 箇所に持たせる — 催促のたびに
# 書き戻すため、片方で target 行を落とすと 2 回目の Stop から効かなくなる。
write_meta() { # $1=経路 $2=ブランチ $3=記録 ID $4=催促した回数 $5=capture が指示した先 (空可)
  {
    printf 'branch=%s\nid=%s\nnags=%s\n' "$2" "$3" "$4"
    [ -z "$5" ] || printf 'target=%s\n' "$5"
  } > "$1"
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

# --- 着手時の再チェック -----------------------------------------------------
# **トリアージ済みのラベルは、付いた時点の判断しか表さない** (ADR-0031 決定 4)。
# 直近 100 Issue のうち 11 件で着手時に完了条件が動いており、#457 は起票時の 3 条件が
# 着手前に既に満たされていた (別の PR が解消済みだった)。#448 は対象が 4 つではなく
# 2 つだった。再チェックは実務では既に行われているのに、それを促すものが何も無かった。
#
# **見るのは構造の有無だけで、判定が正しいかは見ない** — scripts/review-gate.sh の
# 対応表や scripts/check-drawing-evidence.sh の絵と同じ形である (ADR-0019 決定 1)。
# 防いでいるのは書き忘れであって、意図的な迂回ではない。
#
# 現況の語彙は**広く取る**。狭いと正しく再チェックしたプランまで差し戻され、
# MOKUME_PLAN_RECORD=0 で外す癖がついて機構ごと形骸化する (drawing-evidence の
# has_evidence が広く取っているのと同じ理由)。
recheck_missing() { # stdin=プラン本文。足りないものを 1 行 1 件で stdout へ
  local body
  # **内部からパイプで呼ばれるだけ**なので案内は出さない。読み方だけ揃える
  body=$(read_stdin)
  grep -qE '#[0-9]+' <<<"$body" || echo '対象 Issue の番号 (#N)'
  grep -qE 'まだ有効|なお有効|依然|既に満たされ|すでに満たされ|満たされている|残っている|差し替え|書き換え|更新し|変わっていない|変わって|ずれて|古くなって|現況|再チェック|突き合わせ' \
    <<<"$body" || echo '完了条件の現況 (まだ有効 / 既に満たされている / 差し替えが要る)'
}

capture() {
  local payload plan cwd session root branch dir id file body findings blocks warns target recheck marks

  payload=$(read_stdin)
  if [ -z "$payload" ]; then
    explain_stdin capture 'PostToolUse (ExitPlanMode) の JSON'
    exit 64
  fi
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

  recheck=$(printf '%s' "$body" | recheck_missing)
  if [ -n "$recheck" ]; then
    # 記録は作らない。プランを直して ExitPlanMode を通し直させる
    cat >&2 <<EOF
着手プランに、完了条件の再チェックが見当たりません (ADR-0031 決定 4)。足りないのは:

$(printf '%s' "$recheck" | sed 's/^/  - /')

**トリアージ済みのラベルは、付いた時点の判断しか表しません。** 着手する前に Issue 本文の
完了条件を現行のコードと突き合わせ、各条件が「まだ有効」「既に満たされている」「差し替えが
要る」のどれかをプランに書いてください。ずれていれば Issue 本文のほうを先に更新します。

  #457 — 起票時の 3 条件は、着手時点で既に別の PR が解消していた
  #448 — 載せ替える対象は 4 つではなく 2 つだった

**見ているのは書いてあることだけで、判定が正しいかは見ていません。** 記録は作っていないので、
プランを直してもう一度 ExitPlanMode を通してください。
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

  # 他のセッションが同じ Issue に既に着手していないかを見る (#642)。着手直後は PR が
  # まだ無いので投稿先は Issue になり、二重着手が問題になるのもその時点である
  marks=''
  case "$target" in
    'issue '*) marks=$(concurrent_marks "${target#issue }" "${id%-*}") ;;
  esac

  # 指示した先を記録に残す。guard は解決を引き直すが、規約どおりに進めると解決は
  # Issue から PR へ移るので、引き直しだけでは投稿済みを見落とす (#631)
  write_meta "$dir/$id.meta" "$branch" "$id" 0 "$target"

  {
    echo "プランを GitHub 用に整えました: $file"
    echo "(絶対パスとホームディレクトリは畳んであります。署名は投稿時に自動で付きます)"
    echo
    if [ -n "$marks" ]; then
      echo "注意: この Issue には既に他のセッションの着手の跡があります。二重着手かもしれません:"
      printf '%s\n' "$marks" | sed 's/^/  - /'
      echo
      echo "先にそれを読み、同じ仕事なら畳んでください。**この注意は着手を止めません** —"
      echo "並行が正しいこともあるので、判断はあなたに委ねます。"
      echo
    fi
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
  local payload cwd dir branch meta id file nags captured target kind number pending='' round=0

  payload=$(read_stdin)
  if [ -z "$payload" ]; then
    explain_stdin guard 'Stop の JSON'
    exit 64
  fi
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

    captured=$(sed -n 's/^target=//p' "$meta")
    target=$(resolve_target "$branch" "$(cat "$file")")

    # 投稿済みかは、capture が指示した先と、いまの解決先の両方で見る。順序は
    # 「捕捉した先」が先 — 規約どおりに進めたセッションはそちらに載っている (#631)。
    #
    # target 行を持たない記録 (この仕組みが入る前のもの) では captured が空になり、
    # 従来どおりいまの解決だけで判定される
    if posted_anywhere "$id" "$captured
$target"; then
      rm -f "$meta" "$file"
      continue
    fi

    # 投稿先がまだ無いものは急かさない (PR を立てる前に終えるセッションもある)
    [ -n "$target" ] || continue

    # shellcheck disable=SC2086
    set -- $target
    kind="$1" number="$2"

    if [ "$nags" -ge "$MAX_NAGS" ]; then
      rm -f "$meta" "$file"
      continue
    fi
    write_meta "$meta" "$branch" "$id" "$((nags + 1))" "$captured"
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
  *)
    {
      echo "usage: $(basename "$0") {capture|guard|sanitize [root]|scan}"
      echo "  4 つの口はすべて stdin から読む (フックが渡す JSON か、プランの本文)。"
      echo "  手で打つと $STDIN_DEADLINE 秒待って、何を渡すべきかを言って終わる。"
    } >&2
    exit 64
    ;;
esac
