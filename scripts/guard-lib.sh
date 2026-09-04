# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# PreToolUse フックが共有する、payload の解き方・差し戻し方・Bash コマンド文字列の
# 読み方 (#128・#815)。
#
# agent-comment-guard.sh と pr-identity-guard.sh は「このコマンドは gh の
# どのサブコマンドを実行するか」を同じやり方で判定する。以前は両者が同一の正規表現を
# 複製して持ち、コマンド文字列**全体**を素朴に部分一致で見ていたため、2 方向に壊れていた。
#
#   見逃し: url=$(gh pr create --fill) / (gh …) / `gh …`
#           前置文字集合に ( とバッククォートが無く、コマンド置換の中を取りこぼす。
#           pr-identity-guard を素通りする以上、メンテナ名義の PR がそのまま作られた
#           (ADR-0007 の不変条件を守る機構に空いた穴)
#
#   誤検知: コミットメッセージや説明文でコマンド名に言及しただけで差し戻す。
#           回避策が「ファイルに逃がす」なので、guard を迂回する手癖がつく
#
# 前置文字集合を締める / 緩める方向は行き止まりだった。締めると代入プレフィクス
# (GH_TOKEN="$(…)" gh pr create。#122 で足した検出) が巻き添えで壊れ、緩めると地の文を拾う。
#
# **代わりに「先頭語が gh か」で判定する。** コマンドを断片に割り、各断片の先頭語を見る。
# 「gh がコマンドとして実行される位置にあるか」という本来見たかったものを直接表現する。
#
# **脅威モデルは変えない。** guard が止めるのは *うっかり* であって回避ではない。
# gh api は今も明示的に素通しで、その気になれば迂回できる。ヒアドキュメント本文を
# 判定から外すと bash <<EOF … EOF の中身が見えなくなるが、これは gh api と同じ水準の
# 抜けであって、新たに水準を下げるものではない。
#
# 取りこぼしとして許容するもの: sudo gh … / env X=1 gh … は先頭語が gh でないので
# 検出しない。このリポジトリで使う形ではない。
#
# 「宛先はこのリポジトリか」の判定も同じ理由でここに置く (#188)。両 guard が守るのは
# このリポジトリの規約であって、他リポジトリ宛ての操作は射程の外にある。
# pr-identity-guard.sh だけがこれを判定していたため、agent-comment-guard.sh は
# -R other/repo を付けたコメントまで差し戻していた — しかもラッパー (scripts/comment.sh)
# の投稿先は mokume 固定なので、**逃げ道がどこにも無い**状態だった。
#
# 使い方 (source する側):
#   . "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh" 2>/dev/null || exit 0
#   hook_payload            # HOOK_PAYLOAD / HOOK_CWD を置く。jq が無ければ素通し
#   hook_command            # HOOK_COMMAND を置く。コマンドを持たないツールなら素通し
#   is_help_request "$HOOK_COMMAND" && exit 0
#   is_gh_subcommand "$HOOK_COMMAND" 'pr[[:space:]]+create' || exit 0
#   targets_other_repo "$HOOK_COMMAND" "$HOOK_CWD" && exit 0
#   hook_deny "<理由>"
#
# テストは scripts/tests/guard_lib_test.py。

# --- フックの入口と出口 -------------------------------------------------------
#
# 3 本のフック (agent-comment-guard / pr-identity-guard / worktree-path-guard) は、
# 同じ前置きと同じ差し戻しの形を持つ。以前はそれぞれが写しを抱えていた (#815)。
#
# **写しのうち一番危ないのは差し戻しの JSON である。** 綴りは Claude Code 側の仕様
# (hookSpecificOutput.permissionDecision) に張り付いており、仕様が動いたときに直し漏れた
# 1 本は **「JSON を返さない = 素通し」**になる — ガードが黙って効かなくなる形である。
# #160 で実際に踏んだのがこれで (pr-identity-guard.sh が bash 3.2 のパースに失敗して
# JSON を返さなかった)、あのときは 1 本だったから気付けた。
#
# 3 本がここを通っているかは scripts/tests/guard_lib_test.py が構造で見る。

# 差し戻して終わる。**フックの出口はここだけ。**
#   $1 = 理由 (差し戻しの文面。そのまま読み手に出る)
#
# 終了コードは 0 — deny は JSON で伝える。非 0 で終えると Claude Code は「フックが
# 壊れた」と読み、判定として扱わない。
hook_deny() { # $1=理由
  jq -n --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# stdin の payload を読み、HOOK_PAYLOAD と HOOK_CWD を置く。
#
# **jq が無ければ素通しで終わる** (fail open)。ガードが壊れて Bash ツール全体が使えなく
# なるほうが害が大きい。
#
# HOOK_CWD はフックが受け取ったカレントディレクトリで、payload に無ければ $PWD へ倒す。
# `-R` が無いときの gh の宛先はカレントのリポジトリなので、それを真似るのに要る (#611)。
#
# **サブシェルの中から呼ばない。** 素通しを exit で表すので、$( … ) の中では効かない。
hook_payload() {
  HOOK_PAYLOAD=$(cat)
  command -v jq >/dev/null 2>&1 || exit 0
  HOOK_CWD=$(printf '%s' "$HOOK_PAYLOAD" | jq -r '.cwd // ""' 2>/dev/null)
  [ -n "$HOOK_CWD" ] || HOOK_CWD=$PWD
}

# payload の 1 項目を stdout へ。読めなければ空を返す (理由は呼び出し側が決める)。
#   $1 = jq のフィルタ
hook_field() { # $1=jq のフィルタ
  printf '%s' "${HOOK_PAYLOAD:-}" | jq -r "$1" 2>/dev/null || printf ''
}

# Bash ツールが実行しようとしているコマンド文字列を HOOK_COMMAND へ。
# **コマンドを持たないツール (Edit / Write など) では素通しで終わる。**
hook_command() {
  HOOK_COMMAND=$(hook_field '.tool_input.command // ""')
  [ -n "$HOOK_COMMAND" ] || exit 0
}

# 使い方を尋ねているだけか。投稿でも作成でもないので、3 本とも素通しの判定に使う。
is_help_request() { # $1=コマンド
  printf '%s' "$1" | grep -qE '(^|[[:space:]])(-h|--help)([[:space:]]|$)'
}

# ヒアドキュメントの本文を落とす (stdin → stdout)。
#
# 本文はデータであってコマンドではない。コミットメッセージ・PR 本文・Issue 本文は
# ここに載るので、コマンド名への言及を実行と取り違えないために外す。
# ヒアドキュメントを**開いた行そのものは残す** — そこは実際のコマンドなので。
# <<WORD / <<'WORD' / <<"WORD" / <<-WORD に対応し、<<< (ヒアストリング) は誤認しない。
strip_heredoc_bodies() {
  awk '
    function delim_of(line,   m) {
      if (match(line, /<<-?[[:space:]]*"[^"]+"/)) {
        m = substr(line, RSTART, RLENGTH); gsub(/^<<-?[[:space:]]*"|"$/, "", m); return m
      }
      if (match(line, /<<-?[[:space:]]*'"'"'[^'"'"']+'"'"'/)) {
        m = substr(line, RSTART, RLENGTH); gsub(/^<<-?[[:space:]]*'"'"'|'"'"'$/, "", m); return m
      }
      if (match(line, /<<-?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*/)) {
        m = substr(line, RSTART, RLENGTH); gsub(/^<<-?[[:space:]]*/, "", m); return m
      }
      return ""
    }
    {
      if (in_doc) {
        t = $0; sub(/^[[:space:]]+/, "", t)   # <<- は終端行の字下げを許す
        if (t == delim) in_doc = 0
        next                                   # 本文も終端行も落とす
      }
      # <<< (ヒアストリング) は本文を持たない。潰してから区切り語を探す —
      # そうしないと <<< '"'"'x'"'"' の後ろ 2 文字が <<'"'"'x'"'"' に見えて、
      # 以降の行を本文として丸ごと落としてしまう
      probe = $0
      gsub(/<<</, "\001\001\001", probe)
      d = delim_of(probe)
      if (d != "") { delim = d; in_doc = 1 }
      print
    }
  '
}

# コマンドを断片に割り、先頭の空白とクォートを落とす (stdin → stdout)。
#
# 割るのはシェルの演算子 — && || ; & | ( ) バッククォート、および改行 (行は awk / grep が
# もともと分けている)。( と ) で割ることで $( … ) の中身が独立した断片になり、
# コマンド置換の中の gh が先頭語として現れる。
#
# 先頭のクォートを落とすのは、GH_TOKEN="$(…)" gh pr create のような代入プレフィクスで
# 断片が `" gh pr create` の形になるため。
# 先頭の除去を **別の sed に分ける**のが要点。分割で挿入した改行は同じ sed の中では
# まだパターン空間の途中にあり、^ は最初の行にしか効かない。パイプで渡して初めて
# 各断片が独立した行として扱われる。
split_into_fragments() {
  sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/[;&|()`]/\n/g' |
    sed -e 's/^[[:space:]"'"'"']*//'
}

# このコマンドは gh の <サブコマンド> を実行するか。
#   $1 = コマンド文字列
#   $2 = サブコマンドの正規表現 (例 'pr[[:space:]]+create'、'(issue|pr)[[:space:]]+comment')
#
# gh とサブコマンドの間にはグローバルオプション (-R owner/repo など) が入りうるので、
# その間は緩く見る。ただし**同じ断片の中**に限る — 以前は断片の概念が無く、
# 離れた語まで繋げて拾っていた (gh issue … と pr review … のような地の文が該当した)。
is_gh_subcommand() { # $1=コマンド $2=サブコマンド正規表現
  printf '%s' "$1" |
    strip_heredoc_bodies |
    split_into_fragments |
    grep -qE "^gh([[:space:]]+[^[:space:]]+)*[[:space:]]+$2([[:space:]]|$)"
}

# このコマンドの宛先は、このリポジトリの**外**か。
#   $1 = コマンド文字列
#
# 基準は GITHUB_REPOSITORY (既定 mokume-metal/mokume)。
#
# -R / --repo が付いていて、それが owner/repo 形式かつ基準と違うときだけ真。
# したがって次はすべて偽 = 「このリポジトリ宛て」として guard の判定が続く:
#
#   -R が無い            … 既定の宛先はカレントのリポジトリ
#   -R mokume-metal/mokume … 明示された自リポ
#   --repo mokume        … owner を省いた指定。自リポか判定できないので、
#                           曖昧なものは止める側に倒す
#
# **ヒアドキュメント本文は先に落とす。** そこに現れる --repo x/y は投稿する文章であって
# 宛先ではない。落とさないと、本文にそう書くだけで guard を素通りできてしまう
# (is_gh_subcommand が地の文を拾わないために本文を落としているのと同じ理由)。
# ディレクトリの origin から owner/repo を取り出す (stdout)。解けなければ非 0。
#
# `-R` が無いとき gh が宛先にするのはカレントディレクトリのリポジトリなので、同じことを
# ここで近似する。`gh repo set-default` による上書きは見ない — ずれたときは「解けなかった」
# ではなく「別の宛先」と読む可能性があるが、その形は origin と既定が食い違うリポジトリに
# 限られ、このリポジトリでは起きない。
repo_of_dir() { # $1=ディレクトリ
  local url slug
  [ -n "${1:-}" ] || return 1
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  # scheme://host/ と user@host: の 2 形を落とし、末尾の .git と / を落とす
  slug=$(printf '%s' "$url" |
    sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://[^/]+/##; s#^[^/@]+@[^:/]+:##; s#\.git$##; s#/$##')
  # owner/repo ちょうど 2 段でなければ解けなかったものとして扱う (ローカルパスの
  # remote などが該当する)。曖昧なものを宛先として採らない
  case "$slug" in
    */*/*) return 1 ;;
    */*) printf '%s\n' "$slug" ;;
    *) return 1 ;;
  esac
}

# このコマンドの宛先は、このリポジトリの**外**か。
#   $1 = コマンド文字列
#   $2 = カレントディレクトリ (省略時は $PWD)。フックは payload の .cwd を渡す
#
# 基準は GITHUB_REPOSITORY (既定 mokume-metal/mokume)。
#
# 判定は gh の宛先解決と同じ順に見る:
#
#   1. -R / --repo が付いていれば、それが宛先 (複数書けて後勝ち)
#   2. 付いていなければ、カレントディレクトリのリポジトリ
#
# **2 を見ずに「このリポジトリ宛て」と決めていたのが #611 だった。** 別のリポジトリの
# ディレクトリから打った操作まで差し戻し、しかも差し戻しの文面は「誰も承認できない PR に
# なる」と、そのリポジトリでは成り立たないことを断定していた。フックが受け取る payload の
# cwd はシェルが実際に居るディレクトリなので (設定ファイルの読まれ方とは別)、これは
# 判定できる。
#
# 次はすべて偽 = 「このリポジトリ宛て」として guard の判定が続く:
#
#   -R mokume-metal/mokume … 明示された自リポ
#   --repo mokume          … owner を省いた指定。自リポか判定できないので、
#                            曖昧なものは止める側に倒す
#   cwd が git 管理外 / origin が無い / owner/repo に解けない
#                          … 宛先を決められない。同じく止める側
#
# **同じコマンドの中の cd は追わない。** `cd <dir> && gh …` は横断作業で頻出だが、
# コマンド文字列から cd 先を読むのは推測になる (変数展開・引用・複数の cd・サブシェル)。
# 推測を permissive な向きに置くと、このリポジトリ宛ての操作を取りこぼしうる。曖昧なら
# 止める側に倒すというこの guard の方針をここでも通し、逃げ道は -R の明示に一本化する
# (差し戻しの文面がそう案内する)。
#
# **ヒアドキュメント本文は先に落とす。** そこに現れる --repo x/y は投稿する文章であって
# 宛先ではない。落とさないと、本文にそう書くだけで guard を素通りできてしまう
# (is_gh_subcommand が地の文を拾わないために本文を落としているのと同じ理由)。
targets_other_repo() { # $1=コマンド  $2=cwd (省略可)
  local this_repo target cwd
  this_repo="${GITHUB_REPOSITORY:-mokume-metal/mokume}"
  cwd=${2:-}
  [ -n "$cwd" ] || cwd=$PWD
  # -R は複数書ける。gh は後勝ちなので tail -1 で最後の指定を採る
  target=$(printf '%s' "$1" |
    strip_heredoc_bodies |
    grep -oE '(^|[[:space:]])(-R|--repo)([[:space:]]|=)[^[:space:];&|]+' |
    tail -1 | grep -oE '[^[:space:]=]+$') || target=""
  if [ -n "$target" ]; then
    case "$target" in */*) ;; *) return 1 ;; esac
    [ "$target" != "$this_repo" ]
    return
  fi
  target=$(repo_of_dir "$cwd") || return 1
  [ "$target" != "$this_repo" ]
}

# 宛先がこのリポジトリでないときの逃げ道を案内する (stdout)。
#
# **文面は 2 つの guard で共有する。** 同じ逃げ道を書き分けると片方だけ古くなり、
# しかも読む側は「こちらの guard には逃げ道が無い」と受け取る。差し戻しは読まれる
# 前提の文章なので、判定と同じ重さで一本化しておく (#611)。
other_repo_hint() { # $1=そのコマンドの例 (例: "gh pr view" のような gh の呼び出し)
  cat <<EOF

宛先がこのリポジトリでないなら、-R owner/repo を付けてください。

  $1 -R owner/repo …

-R が無いときの宛先は、**フックが受け取ったカレントディレクトリ**のリポジトリとして
読みます。同じコマンドの中の cd は追いません — 判定を推測に寄せないためです。つまり
cd 先のリポジトリ宛てのつもりでも、シェルがまだこのリポジトリに居るなら止まります。
git 管理外・origin が無い・owner を省いた --repo も同じく止める側です。
EOF
}
