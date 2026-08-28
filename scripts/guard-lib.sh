# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# PreToolUse フックが共有する、Bash コマンド文字列の読み方 (#128)。
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
#   . "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh"
#   is_gh_subcommand "$command" 'pr[[:space:]]+create' && …
#   targets_other_repo "$command" && exit 0
#
# テストは scripts/tests/guard_lib_test.py。

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
targets_other_repo() { # $1=コマンド
  local this_repo target
  this_repo="${GITHUB_REPOSITORY:-mokume-metal/mokume}"
  # -R は複数書ける。gh は後勝ちなので tail -1 で最後の指定を採る
  target=$(printf '%s' "$1" |
    strip_heredoc_bodies |
    grep -oE '(^|[[:space:]])(-R|--repo)([[:space:]]|=)[^[:space:];&|]+' |
    tail -1 | grep -oE '[^[:space:]=]+$') || target=""
  [ -n "$target" ] || return 1
  case "$target" in */*) ;; *) return 1 ;; esac
  [ "$target" != "$this_repo" ]
}
