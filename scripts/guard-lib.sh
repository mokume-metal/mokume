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
# **代わりに「gh がコマンドとして実行される位置にあるか」で判定する。** コマンドを字句として
# 読んで断片に割り、各断片の前置 (予約語・リダイレクト・代入・env) を落とした先頭語を見る
# (gh_invocations)。周辺の判定 (旗・--help・宛先・token) も、その呼び出しの断片と前置だけを
# 読む — コマンド全体への部分一致だと、同じ行の別のコマンドの語で外れる (#1729 の反証)。
#
# **脅威モデルは変えない。** guard が止めるのは *うっかり* であって回避ではない。
# gh api は今も明示的に素通しで、その気になれば迂回できる。ヒアドキュメント本文を
# 判定から外すと bash <<EOF … EOF の中身が見えなくなるが、これは gh api と同じ水準の
# 抜けであって、新たに水準を下げるものではない。
#
# `PATH=/x:$PATH gh …`・`for …; do gh …`・`/opt/homebrew/bin/gh …`・`"gh" …`・`gh \⏎ …`
# も gh が実行される位置にある (#1729)。以前は `env X=1 gh …` をここで取りこぼしとして
# 許容していたが、前置の代入と同じ形なので拾う。予約語・リダイレクト・代入・env の形は
# 有限なので数え上げて落とす。
#
# 取りこぼしとして許容するもの:
#
#   - **別のコマンドを起動するコマンド**の後ろの gh (sudo / command / exec / builtin /
#     nohup / nice / xargs … gh)、`bash -c "gh …"`・eval・source、alias とシェル関数。
#     起動する側の語は利用者が増やせるので、数え上げは必ず取りこぼす (gh api を素通しに
#     しているのと同じ水準)
#   - 実行時に決まる語 (`$GH …`・`$(which gh) …`)。値を読むのは推測になる
#   - 同じコマンドの中で**文として**環境を変える形 (cd・export GH_REPO=・unset GH_TOKEN・
#     GH_TOKEN の再代入)。扱いは #1823 で決める
#
# このリポジトリで使う形ではない。
#
# 「宛先はこのリポジトリか」の判定も同じ理由でここに置く (#188)。両 guard が守るのは
# このリポジトリの規約であって、他リポジトリ宛ての操作は射程の外にある。
# pr-identity-guard.sh だけがこれを判定していたため、agent-comment-guard.sh は
# -R other/repo を付けたコメントまで差し戻していた — しかもラッパー (scripts/comment.sh)
# の投稿先は mokume 固定なので、**逃げ道がどこにも無い**状態だった。
#
# 「どのリポジトリか」の解き方は scripts/repo-slug.sh が持つ (#818)。フックに限った話では
# ないので、フックが共有する読み方・返し方の置き場であるここには置かない。
#
# 使い方 (source する側):
#   . "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh" 2>/dev/null || exit 0
#   hook_payload            # HOOK_PAYLOAD / HOOK_CWD を置く。jq が無ければ素通し
#   hook_command            # HOOK_COMMAND を置く。コマンドを持たないツールなら素通し
#   while IFS=$'\t' read -r token repo chdir fragment; do   # gh の呼び出しごと
#     gh_fragment_is "$fragment" 'pr[[:space:]]+create' || continue
#     is_help_request "$fragment" && continue
#     invocation_targets_other_repo "$fragment" "$repo" "$chdir" "$HOOK_CWD" && continue
#     hook_deny "<理由>"
#   done < <(gh_invocations "$HOOK_COMMAND")
#
# コマンド全体を 1 回で問う口 (is_gh_subcommand・targets_other_repo) も残してある。
#
# テストは scripts/tests/guard_lib_test.py。

# 「どのリポジトリか」の解き方を借りる (#818)。**source は || return 1** —
# 読めなければ、この先の判定ができないまま進むのではなく、source した側の
# `|| exit 0` (fail open) を発火させる
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh" 2>/dev/null || return 1

# --- フックの入口と出口 -------------------------------------------------------
#
# 2 本のフック (agent-comment-guard / pr-identity-guard) は、
# 同じ前置きと同じ差し戻しの形を持つ。以前はそれぞれが写しを抱えていた (#815)。
#
# **写しのうち一番危ないのは差し戻しの JSON である。** 綴りは Claude Code 側の仕様
# (hookSpecificOutput.permissionDecision) に張り付いており、仕様が動いたときに直し漏れた
# 1 本は **「JSON を返さない = 素通し」**になる — ガードが黙って効かなくなる形である。
# #160 で実際に踏んだのがこれで (pr-identity-guard.sh が bash 3.2 のパースに失敗して
# JSON を返さなかった)、あのときは 1 本だったから気付けた。
#
# 2 本がここを通っているかは scripts/tests/guard_lib_test.py が構造で見る。

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

# 使い方を尋ねているだけか。投稿でも作成でもないので、2 本とも素通しの判定に使う。
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

# このコマンドの中で**実行される gh の呼び出し**を 1 行ずつ出す (#128・#1729)。
#   $1 = コマンド文字列
#
# 行は tab 区切りの 4 列で、判定に要るものを呼び出しごとに持つ:
#
#   1. GH_TOKEN   その gh に渡る値。`=` は打つシェルから継ぐ・`-` は消した (env -u / -i)・
#                 `+<値>` は前置で渡した値 (引用はそのまま)・`?` は読めない (+= など)
#   2. GH_REPO    同じ形。宛先の判定が読む
#   3. chdir      env -C で別のディレクトリから走らせるなら 1 (宛先を cwd から決められない)
#   4. 呼び出し   `gh …` から始まる断片。引用の中の空白・改行は \002 に伏せてある
#
# **実行位置は、字句を読んで決める** (#1729 の反証)。以前は演算子の文字で素朴に割り、
# 断片の先頭語が gh かを見ていたので、2 方向に外れていた:
#
#   見逃し  for …; do gh … / if …; then gh … / { gh …; } / ! gh … (割った後の先頭が予約語)、
#           2>/dev/null gh …・A+=x gh …・A=x\ y gh …・env -P /x gh … (落とさない前置)、
#           gh \⏎ issue comment … (行継続)、\gh・"gh"・'/x y/gh' (引用した gh)
#   誤検知  git commit -m "note; X=1 gh issue comment 1" (引用の中まで ; で割った)
#
# 字句は次のとおり読む。引用 ('…'・$'…'・"…") の中では割らず、"…" の中でも $( … ) と
# バッククォートは入れ子のコマンドとして読む。\⏎ は行継続として消す。語の頭の # から
# 行末は注釈。割るのは && || ; & | 改行 ( ) — ただし >&2・&>・2>&1・>| はリダイレクトの
# 一部として割らない。( … ) と $( … )・<( … )・バッククォートの中身は、それぞれ独立した断片になる。
#
# 断片ごとに、**実行される語の手前の前置を落とす**。落とすのは
#
#   予約語       ! { do then else elif if while until time (-p)
#   リダイレクト 2>/dev/null・>out・<in・&>log・<<EOF …
#   代入         NAME=値・NAME+=値・NAME[i]=値 (値の引用・\ の逃がしを含む)。GH_TOKEN と
#                GH_REPO は値を 1・2 列に写す
#   env          パス付きも。旗は macOS の env(1) の -0 -i -v -C 値 -P 値 -S 値 -u 値 と、
#                -・--、GNU の --unset= / --chdir= / --split-string= / --ignore-environment。
#                -S の値はそのままコマンドとして読み直す
#
# で、これらはどの順に並んでもよい。残った先頭語から引用と \ を外したものが gh か <何か>/gh
# なら gh の呼び出しとして出す。**前置を落とすのは断片の先頭だけ**なので、別のコマンドの
# 引数に現れる gh (echo PATH=x gh … / ls /x/gh …) は拾わない。
#
# **ヒアドキュメント本文は先に落とす** (strip_heredoc_bodies)。
#
# 取りこぼしとして許容するものは、冒頭の「取りこぼしとして許容するもの」にまとめてある。
#
# awk は **LC_ALL=C でバイト単位に読ませる**。字句の区切りはすべて ASCII で、macOS の awk は
# UTF-8 の既定のまま日本語の本文を 1 文字ずつ切ると `towc: multibyte conversion failure` で
# 止まる (止まると呼び出しが 1 つも出ず、ガードが素通しになる)。
gh_invocations() { # $1=コマンド
  printf '%s\n' "$1" |
    strip_heredoc_bodies |
    LC_ALL=C awk -v q="'" '
      function app(s) { fbuf[depth] = fbuf[depth] s }
      function mask(s) { gsub(/[ \t\n]/, M, s); return s }
      function push(t) { depth++; ftype[depth] = t; fbuf[depth] = ""; finq[depth] = 0 }
      function flush(   f) {
        f = fbuf[depth]; fbuf[depth] = ""
        sub(/^ +/, "", f); sub(/ +$/, "", f)
        if (f != "") emit(f)
      }
      function backtick() {
        if (ftype[depth] == "bt") { flush(); depth--; app("`") } else { app("`"); push("bt") }
      }
      function word1(s) { return match(s, /^[^ ]+/) ? substr(s, 1, RLENGTH) : "" }
      function rest1(s) { s = substr(s, length(word1(s)) + 1); sub(/^ +/, "", s); return s }
      function unquote(w) { gsub(QRE, "", w); gsub(M, " ", w); return w }
      # 前置を落とし、先頭が gh なら 4 列の行を出す
      function emit(f,   w, r, name, val, plus, bare, o, t, L, v, tok, repo, chd) {
        tok = "="; repo = "="; chd = 0
        while (1) {
          w = word1(f)
          if (w == "") return
          if (w ~ /^(!|\{|do|then|else|elif|if|while|until|time)$/) {
            f = rest1(f)
            if (w == "time" && word1(f) == "-p") f = rest1(f)
            continue
          }
          if (w ~ /^[0-9]*(<<<|<<-?|<>|>>|>\||&>>|&>|<&|>&|<|>)/) {
            bare = (w ~ /^[0-9]*(<<<|<<-?|<>|>>|>\||&>>|&>|<&|>&|<|>)$/)
            f = rest1(f)
            if (bare) f = rest1(f)
            continue
          }
          if (w ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/) {
            r = rest1(f)
            if (r == "") return
            name = w; sub(/[[+=].*/, "", name)
            val = w; sub(/^[^=]*=/, "", val)
            plus = (w ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+=/)
            if (name == "GH_TOKEN") tok = plus ? "?" : "+" val
            if (name == "GH_REPO") repo = plus ? "?" : "+" val
            f = r
            continue
          }
          if (unquote(w) ~ /^(.*\/)?env$/) {
            f = rest1(f)
            while (1) {
              o = word1(f)
              if (o == "--") { f = rest1(f); break }
              if (o !~ /^-/) break
              f = rest1(f)
              if (o == "-" || o == "--ignore-environment") { tok = "-"; repo = "-"; continue }
              if (o ~ /^--(unset|chdir|split-string)/) {
                L = (o ~ /^--unset/) ? "u" : (o ~ /^--chdir/) ? "C" : "S"
                v = o
                if (!sub(/^--[a-z-]+=/, "", v)) v = ""
              } else if (o ~ /^--/) {
                continue
              } else {
                t = substr(o, 2)
                while (t ~ /^[0iv]/) {
                  if (substr(t, 1, 1) == "i") { tok = "-"; repo = "-" }
                  t = substr(t, 2)
                }
                if (t == "") continue
                L = substr(t, 1, 1); v = substr(t, 2)
                if (L !~ /^[uCPS]$/) continue
              }
              if (v == "") { v = word1(f); f = rest1(f) }
              if (L == "u") {
                v = unquote(v)
                if (v == "GH_TOKEN") tok = "-"
                if (v == "GH_REPO") repo = "-"
              }
              if (L == "C") chd = 1
              if (L == "S") {
                gsub(M, " ", v); sub("^" QCH, "", v); sub(QCH "$", "", v)
                f = v " " f; sub(/^ +/, "", f)
              }
            }
            continue
          }
          if (unquote(w) ~ /^(.*\/)?gh$/) print tok "\t" repo "\t" chd "\tgh" substr(f, length(w) + 1)
          return
        }
      }
      BEGIN { M = "\002"; QRE = "[\"\\\\" q "]"; QCH = "[\"" q "]"; depth = 0; ftype[0] = "top" }
      { src = (NR > 1) ? src "\n" $0 : $0 }
      END {
        n = length(src)
        for (i = 1; i <= n; i++) {
          c = substr(src, i, 1); nx = substr(src, i + 1, 1)
          if (c == "\\") {
            if (nx != "\n") app(c mask(nx))
            i++; continue
          }
          if (finq[depth]) {
            if (c == "\"") { finq[depth] = 0; app(c); continue }
            if (c == "$" && nx == "(") { app("$("); push("sub"); i++; continue }
            if (c == "`") { backtick(); continue }
            app(mask(c)); continue
          }
          if (c == q || (c == "$" && nx == q)) {
            j = (c == "$") ? i + 2 : i + 1
            while (j <= n && substr(src, j, 1) != q) {
              if (c == "$" && substr(src, j, 1) == "\\") j++
              j++
            }
            app(mask(substr(src, i, j - i + 1))); i = j; continue
          }
          if (c == "\"") { finq[depth] = 1; app(c); continue }
          if (c == "#" && (fbuf[depth] == "" || fbuf[depth] ~ / $/)) {
            while (i < n && substr(src, i + 1, 1) != "\n") i++
            continue
          }
          if (c == "$" && nx == "(") { app("$("); push("sub"); i++; continue }
          if (c == "(") {
            if (fbuf[depth] ~ /[<>]$/) { app(c); push("sub"); continue }
            flush(); push("paren"); continue
          }
          if (c == ")") {
            if (ftype[depth] == "sub") { flush(); depth--; app(c); continue }
            if (ftype[depth] == "paren") { flush(); depth--; continue }
            flush(); continue
          }
          if (c == "`") { backtick(); continue }
          if ((c == "&" && (nx == ">" || fbuf[depth] ~ /[<>]$/)) || (c == "|" && fbuf[depth] ~ />$/)) {
            app(c); continue
          }
          if (c == ";" || c == "&" || c == "|" || c == "\n") { flush(); continue }
          if (c == " " || c == "\t") {
            if (fbuf[depth] != "" && fbuf[depth] !~ / $/) app(" ")
            continue
          }
          app(c)
        }
        while (depth > 0) { flush(); depth-- }
        flush()
      }
    '
}

# 断片 (gh_invocations の 4 列目) は、gh の <サブコマンド> の呼び出しか。
#   $1 = 断片
#   $2 = サブコマンドの正規表現 (例 'pr[[:space:]]+create'、'(issue|pr)[[:space:]]+comment')
#
# gh とサブコマンドの間にはグローバルオプション (-R owner/repo など) が入りうるので、
# その間は緩く見る。ただし**同じ断片の中**に限る (gh issue … と pr review … のような
# 離れた語を繋げない)。
gh_fragment_is() { # $1=断片 $2=サブコマンド正規表現
  printf '%s\n' "$1" | grep -qE "^gh([[:space:]]+[^[:space:]]+)*[[:space:]]+$2([[:space:]]|$)"
}

# このコマンドは gh の <サブコマンド> を実行するか。
#   $1 = コマンド文字列  $2 = サブコマンドの正規表現
is_gh_subcommand() { # $1=コマンド $2=サブコマンド正規表現
  local tok repo chd fragment
  while IFS=$'\t' read -r tok repo chd fragment; do
    gh_fragment_is "$fragment" "$2" && return 0
  done < <(gh_invocations "$1")
  return 1
}

# 1 つの gh の呼び出しの宛先は、このリポジトリの**外**か。
#   $1 = 断片  $2 = GH_REPO の列  $3 = chdir の列  $4 = cwd
#   (列の意味は gh_invocations)
#
# 基準は GITHUB_REPOSITORY (既定 mokume-metal/mokume)。
#
# 判定は gh の宛先解決と同じ順に見る。**読むのはその呼び出しの断片と前置だけ**で、同じ行の
# 別のコマンドの -R (git log -R x/y など) は宛先ではない (#1729 の反証):
#
#   1. -R / --repo が付いていれば、それが宛先 (複数書けて後勝ち)
#   2. 前置の GH_REPO= があれば、それが宛先 (#1729)
#   3. どちらも無ければ、カレントディレクトリのリポジトリ
#
# **3 を見ずに「このリポジトリ宛て」と決めていたのが #611 だった。** 別のリポジトリの
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
#   GH_REPO=$X / GH_REPO+= … 値を読めない。同じく止める側
#   env -C <dir>           … cwd から宛先を決められない。同じく止める側
#   cwd が git 管理外 / origin が無い / owner/repo に解けない
#                          … 宛先を決められない。同じく止める側
#
# **前置の GH_REPO= は読む** (#1729)。その gh にだけ渡る値で、推測にならない。読まずに
# いると、別のリポジトリの cwd から `GH_REPO=mokume-metal/mokume gh …` を打った形を
# 素通しにしていた (止める側へ片方向にしか倒れていなかった)。
#
# **同じコマンドの中の cd と、文としての export GH_REPO= は追わない。** コマンド文字列から
# その値を読むのは推測になる (変数展開・引用・複数の cd・サブシェル・順序)。追わないことが
# 素通しの向きに倒れる形 (別のリポジトリの cwd から `cd <mokume> && gh …`) が残っており、
# 扱いは #1823 で決める。逃げ道は -R の明示に一本化する (差し戻しの文面がそう案内する)。
invocation_targets_other_repo() { # $1=断片 $2=GH_REPO $3=chdir $4=cwd
  local base target
  base="$(this_repo)"
  # -R は複数書ける。gh は後勝ちなので tail -1 で最後の指定を採る
  target=$(printf '%s\n' "$1" |
    grep -oE '(^|[[:space:]])(-R|--repo)([[:space:]]|=)[^[:space:]]+' |
    tail -1 | grep -oE '[^[:space:]=]+$' | tr -d "\"'") || target=""
  if [ -z "$target" ]; then
    case "$2" in
      +*) target=$(printf '%s' "${2#+}" | tr -d "\"'") ;;
      '?') return 1 ;;
    esac
    case "$target" in *'$'* | *'`'*) return 1 ;; esac
  fi
  if [ -n "$target" ]; then
    case "$target" in */*) ;; *) return 1 ;; esac
    [ "$target" != "$base" ]
    return
  fi
  [ "$3" = 1 ] && return 1
  target=$(repo_of_dir "$4") || return 1
  [ "$target" != "$base" ]
}

# このコマンドの gh の呼び出しが、**どれも**このリポジトリの外宛てか。
#   $1 = コマンド文字列
#   $2 = カレントディレクトリ (省略時は $PWD)。フックは payload の .cwd を渡す
#
# gh の呼び出しが 1 つも無ければ偽 (このリポジトリ宛てとして扱う)。フックは呼び出しごとに
# invocation_targets_other_repo を使う。これはコマンド全体を 1 回で問う口である。
targets_other_repo() { # $1=コマンド  $2=cwd (省略可)
  local cwd tok repo chd fragment any=0
  cwd=${2:-}
  [ -n "$cwd" ] || cwd=$PWD
  while IFS=$'\t' read -r tok repo chd fragment; do
    any=1
    invocation_targets_other_repo "$fragment" "$repo" "$chd" "$cwd" || return 1
  done < <(gh_invocations "$1")
  [ "$any" = 1 ]
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
