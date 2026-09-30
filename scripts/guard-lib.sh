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
#   - 同じコマンドの中で**文として**宛先を変える形 (cd・pushd・popd・GH_REPO や GIT_DIR を
#     変える文) の**値**。値は追わず、あれば宛先を「決められない」として止める側へ倒す
#     (#1823。invocation_targets_other_repo の説明)。GH_TOKEN を文として変える形 (発行・
#     export・unset・再代入) は読む (#1729)
#   - GH_TOKEN を変える文のうち、サブシェル・$( … ) の中のもの (外へは効かないので読まない)
#     と、パイプラインの片側・declare -x / typeset -x / readonly のもの
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
#   while IFS=$'\t' read -r token repo chdir place fragment; do   # gh の呼び出しごと
#     gh_fragment_is "$fragment" 'pr[[:space:]]+create' || continue
#     is_help_request "$fragment" && continue
#     invocation_targets_other_repo "$fragment" "$repo" "$chdir" "$HOOK_CWD" && continue
#     hook_deny "<理由>"
#   done < <(gh_invocations "$HOOK_COMMAND")
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

# このコマンドの中で**実行される gh の呼び出し**を 1 行ずつ出す (#128・#1729)。
#   $1 = コマンド文字列
#
# 行は tab 区切りの 5 列で、判定に要るものを呼び出しごとに持つ:
#
#   1. GH_TOKEN   その gh に渡る token の見立て。前置 (GH_TOKEN= / env -u / env -i) と、
#                 **gh より前に置いた**文 (発行・export・unset・再代入) から決める:
#                   installation  installation token (ghs_… か、同じ行で安全に発行した値)
#                   inherit       打つシェルから継ぐ (同じ行では触っていない)
#                   unsafe        発行の失敗が後段へ伝わらない形で入れた
#                                 (export X="$(…)" / 前置 GH_TOKEN="$(…)" / 発行・export・gh が
#                                 1 つの && の並びにない、またはその並びの gh より前に || がある
#                                 — #1823。直書きの ghs_ は発行が失敗しえないので並びを問わない)
#                   unexported    安全に発行したが export していない (gh へ渡らない)
#                   removed       消した (env -u GH_TOKEN / env -i / unset GH_TOKEN)
#                   other         確かめられない値 (空・個人の token・発行していない変数)
#                   unknown       読めない形で変えた (+= など)
#   2. GH_REPO    前置の値。`=` は継ぐ・`-` は消した・`+<値>` は前置の値・`?` は読めない
#                 (前置が無く、gh より前の文で GH_REPO を代入・export・unset したときも `?`)
#   3. chdir      宛先を cwd から決められないなら 1。env -C と、gh より前の文としての
#                 cd・pushd・popd と、GIT_DIR (前置・文) (#1823)
#   4. 置き場     top か sub ($( … ) やバッククォートの中で実行される)
#   5. 呼び出し   `gh …` から始まる断片。引用の中の空白・改行は \002 に伏せてある
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
# **ヒアドキュメントも同じ字句読みの中で読む** (#1729 の 2 回目の反証)。以前は行単位の
# 前段が引用も注釈も見ずに `<<WORD` を探したので、`git commit -m "fix <<EOF parse"` や
# `# note <<EOF` の後ろの行がすべて判定から消えた。いまは引用の外の `<<` (<<- を含み、
# <<< を除く) だけを開きとして区切り語を覚え、次の改行から区切り語の行までを落とす。
# 区切り語の行は前後の空白を許す (以前の前段と同じ寛容さ)。
#
# 断片ごとに、**実行される語の手前の前置を落とす**。落とすのは
#
#   予約語       ! { do then else elif if while until time (-p) coproc、function <名前>
#   リダイレクト 2>/dev/null・>out・<in・&>log …
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
# **時間は長さに比例させる** (#1729 の 2 回目の反証)。1 文字ずつ文字列を継ぎ足すと長さの
# 2 乗かかり、480KB の二重引用の本文で 16 秒を越えた (フックの timeout は 10 秒で、越えると
# 判定が出ない)。入力は 1 度に配列へ割り、普通の文字の並びはまとめて写す。語は 1 つ 4096
# バイトまでしか持たない — 長い本文の中身は判定に要らない。断片は語の配列として持ち、
# 出すときに半分ずつ繋ぐ。
#
# awk は **LC_ALL=C でバイト単位に読ませる**。字句の区切りはすべて ASCII で、macOS の awk は
# UTF-8 の既定のまま日本語の本文を 1 文字ずつ切ると `towc: multibyte conversion failure` で
# 止まる (止まると呼び出しが 1 つも出ず、ガードが素通しになる)。
#
# 取りこぼしとして許容するものは、冒頭の「取りこぼしとして許容するもの」にまとめてある。
gh_invocations() { # $1=コマンド
  printf '%s\n' "$1" |
    LC_ALL=C awk -v q="'" '
      function addw(s) { if (length(cw[depth]) < WCAP) cw[depth] = cw[depth] s }
      function mask(s) { gsub(/[ \t\n]/, M, s); return s }
      function run(i, j,   len) { len = j - i; if (len > WCAP) len = WCAP; return substr(src, i, len) }
      # 入れ子は、宛先を変えた印 (DC・DR) を親から継ぐ。閉じれば捨てるので外へは効かない
      function push(t) {
        depth++; ftype[depth] = t; finq[depth] = 0; cw[depth] = ""; nw[depth] = 0; fiss[depth] = 0
        DC[depth] = DC[depth - 1]; DR[depth] = DR[depth - 1]
      }
      function endword() { if (cw[depth] != "") { nw[depth]++; W[depth, nw[depth]] = cw[depth]; cw[depth] = "" } }
      function joinw(d, lo, hi,   mid) {
        if (lo == hi) return W[d, lo]
        mid = int((lo + hi) / 2)
        return joinw(d, lo, mid) " " joinw(d, mid + 1, hi)
      }
      function flush(sep,   f, k) {
        endword()
        if (nw[depth] == 0) { if (depth == 0) chain(sep, 1); return }
        f = joinw(depth, 1, nw[depth])
        for (k = 1; k <= nw[depth]; k++) delete W[depth, k]
        nw[depth] = 0
        if (index(f, "scripts/gh-app-token.sh")) fiss[depth] = 1
        emit(f, sep)
        if (depth == 0) chain(sep, 0)
      }
      # 入れ子の外の and-or の並び。LID は並びの番号で、&& 以外の区切り (; 改行 & | …) で
      # 進む。|| を見たら、その並びの残りに印 (OR) を付ける — 前の段が成功すると後ろが
      # 飛ばされ、その先の && へ進む。空の断片の区切りは、&& / || の後の改行 (継続) と ( を
      # 数えない。empty = 区切りの前に語が無かった
      function chain(sep, empty) {
        if (sep == "&&") { LOP = sep; return }
        if (sep == "||") { OR = 1; LOP = sep; return }
        if (empty && (sep == "(" || (sep == "\n" && LOP != ""))) return
        LID++; OR = 0; LOP = ""
      }
      # 発行した値 (SL がその並びの番号) が、いまの並びで && だけを通って届くか。
      # 直書きの ghs_ (SL = -1) は発行が失敗しえないので、並びを問わない
      function reaches(name) {
        if (SL[name] == -1) return 1
        return SL[name] == LID && !OR
      }
      # $( … ) / バッククォートを閉じる。発行の置換は印 (X) を持つ語として親へ返す
      function popsub(   iss) {
        flush(")"); iss = fiss[depth]; depth--
        addw(iss ? "$(" X ")" : "$()")
      }
      function backtick() { if (ftype[depth] == "bt") popsub(); else push("bt") }
      # << の後ろの区切り語を読んで覚える。戻り値は区切り語の最後の位置
      function heredoc(i,   j, d, ch) {
        j = i + 2
        if (C[j] == "-") j++
        while (C[j] == " " || C[j] == "\t") j++
        d = ""
        while (j <= n) {
          ch = C[j]
          if (ch == q) { j++; while (j <= n && C[j] != q) { d = d C[j]; j++ }; j++; continue }
          if (ch == "\"") {
            j++
            while (j <= n && C[j] != "\"") { if (C[j] == "\\") j++; d = d C[j]; j++ }
            j++; continue
          }
          if (ch == "\\") { d = d C[j + 1]; j += 2; continue }
          if (ch ~ /[ \t\n;&|()<>]/) break
          d = d ch; j++
        }
        if (d != "") { nh++; HD[nh] = d }
        return j - 1
      }
      # 改行 (位置 i) の後ろの本文を、覚えた区切り語の順に落とす。戻り値は最後の改行の位置
      function bodies(i,   k, a, e, t) {
        for (k = 1; k <= nh; k++) {
          while (i < n) {
            a = i + 1; e = a
            while (e <= n && C[e] != "\n") e++
            t = substr(src, a, e - a); sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
            i = e
            if (t == HD[k]) break
          }
        }
        nh = 0
        return (i > n) ? n : i
      }
      function word1(s) { return match(s, /^[^ ]+/) ? substr(s, 1, RLENGTH) : "" }
      function rest1(s) { s = substr(s, length(word1(s)) + 1); sub(/^ +/, "", s); return s }
      function unquote(w) { gsub(QRE, "", w); gsub(M, " ", w); return w }
      # $NAME / ${NAME} なら NAME を返す
      function varref(v) {
        if (v ~ /^\$[A-Za-z_][A-Za-z0-9_]*$/) return substr(v, 2)
        if (v ~ /^\$\{[A-Za-z_][A-Za-z0-9_]*\}$/) return substr(v, 3, length(v) - 3)
        return ""
      }
      # 文としての代入。sep はその文を終えた区切り (&& なら発行の失敗が後段へ伝わる)
      function setvar(name, val, plus, sep,   v, r) {
        if (plus) { SV[name] = "unknown"; return }
        v = unquote(val)
        if (v == "$(" X ")") {
          if (sep == "&&") { SV[name] = "issued"; SL[name] = LID } else SV[name] = "unsafe"
          return
        }
        r = varref(v)
        if (r != "") {
          if (r == name) return
          if (r in SV) { SV[name] = SV[r]; if (r in SL) SL[name] = SL[r] } else SV[name] = "other"
          return
        }
        if (v ~ /^ghs_/) { SV[name] = "issued"; SL[name] = -1 } else SV[name] = "other"
      }
      # 文として代入・export・unset した名前が、gh の宛先に効くなら印を立てる (#1823)
      function destvar(name) {
        if (name == "GH_REPO") DR[depth] = 1
        if (name == "GIT_DIR") DC[depth] = 1
      }
      function shellstate(   s) {
        if (!("GH_TOKEN" in SV)) return "inherit"
        s = SV["GH_TOKEN"]
        if (s != "issued") return s
        if (!gx) return "unexported"
        # 発行・export・gh が 1 つの && の並びにあるときだけ (#1823)
        if (!reaches("GH_TOKEN")) return "unsafe"
        return (SL["GH_TOKEN"] == -1 || GXL == LID) ? "installation" : "unsafe"
      }
      function verdict(tok,   v, r, s) {
        if (tok == "-") return "removed"
        if (tok == "?") return "unknown"
        if (tok == "=") return shellstate()
        v = unquote(substr(tok, 2))
        if (v == "$(" X ")") return "unsafe"
        if (v ~ /^ghs_/) return "installation"
        r = varref(v)
        if (r != "") {
          if (r in SV) {
            s = SV[r]
            if (s == "issued") return reaches(r) ? "installation" : "unsafe"
            return (s == "removed") ? "other" : s
          }
          if (r == "GH_TOKEN") return "inherit"
        }
        return "other"
      }
      # 前置を落とし、先頭が gh なら 5 列の行を出す。gh でなく入れ子の外なら、文として
      # GH_TOKEN に効くもの (代入・export・unset) を覚える
      function emit(f, sep,   w, name, val, plus, bare, o, t, L, v, tok, repo, chd, na, k, a, r) {
        tok = "="; repo = "="; chd = 0; na = 0
        while (1) {
          w = word1(f)
          if (w == "") break
          if (w ~ /^(!|\{|do|then|else|elif|if|while|until|time|coproc)$/) {
            f = rest1(f)
            if (w == "time" && word1(f) == "-p") f = rest1(f)
            continue
          }
          if (w == "function") { f = rest1(rest1(f)); continue }
          if (w ~ /^[0-9]*(<<<|<>|>>|>\||&>>|&>|<&|>&|<|>)/) {
            bare = (w ~ /^[0-9]*(<<<|<>|>>|>\||&>>|&>|<&|>&|<|>)$/)
            f = rest1(f)
            if (bare) f = rest1(f)
            continue
          }
          if (w ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/) {
            name = w; sub(/[[+=].*/, "", name)
            val = w; sub(/^[^=]*=/, "", val)
            plus = (w ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+=/)
            na++; AN[na] = name; AV[na] = val; AP[na] = plus
            if (name == "GH_TOKEN") tok = plus ? "?" : "+" val
            if (name == "GH_REPO") repo = plus ? "?" : "+" val
            if (name == "GIT_DIR") chd = 1
            f = rest1(f)
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
            na = 0
            continue
          }
          break
        }
        if (f == "") {
          for (k = 1; k <= na; k++) destvar(AN[k])
          if (depth == 0) for (k = 1; k <= na; k++) setvar(AN[k], AV[k], AP[k], sep)
          return
        }
        w = word1(f)
        if (unquote(w) ~ /^(.*\/)?gh$/) {
          if (DC[depth]) chd = 1
          if (DR[depth] && repo == "=") repo = "?"
          print verdict(tok) "\t" repo "\t" chd "\t" ((depth > 0) ? "sub" : "top") "\tgh" substr(f, length(w) + 1)
          return
        }
        # 宛先を変える文は、入れ子の中でも覚える (その入れ子の中の gh に効く・#1823)
        w = unquote(w)
        if (w ~ /^(cd|pushd|popd)$/) DC[depth] = 1
        if (w ~ /^(export|unset|declare|typeset|readonly|local)$/) {
          r = rest1(f)
          while ((a = word1(r)) != "") {
            r = rest1(r)
            if (a ~ /^-/) continue
            name = unquote(a); sub(/=.*/, "", name); destvar(name)
          }
        }
        if (depth != 0) return
        if (w == "export") {
          r = rest1(f)
          while ((a = word1(r)) != "") {
            r = rest1(r)
            if (a ~ /^-/) continue
            name = a; sub(/=.*/, "", name)
            if (a ~ /=/) { val = a; sub(/^[^=]*=/, "", val); setvar(name, val, 0, "export") }
            if (name == "GH_TOKEN") { gx = 1; GXL = LID }
          }
        } else if (w == "unset") {
          r = rest1(f)
          while ((a = word1(r)) != "") {
            r = rest1(r)
            if (a ~ /^-/) continue
            if (a == "GH_TOKEN") { SV[a] = "removed"; gx = 0 } else delete SV[a]
          }
        }
      }
      BEGIN {
        RS = "\001"
        M = "\002"; X = "\003"; WCAP = 4096
        QRE = "[\"\\\\" q "]"; QCH = "[\"" q "]"
        s = " \t\n;&|()<>\"\\$`" q
        for (k = 1; k <= length(s); k++) SPU[substr(s, k, 1)] = 1
        s = "\"\\$`"
        for (k = 1; k <= length(s); k++) SPD[substr(s, k, 1)] = 1
        depth = 0; ftype[0] = "top"; cw[0] = ""; nw[0] = 0; fiss[0] = 0; nh = 0; gx = 0
        DC[0] = 0; DR[0] = 0; LID = 1; OR = 0; LOP = ""; GXL = 0
      }
      { src = $0 }
      END {
        sub(/\n$/, "", src)
        n = split(src, C, "")
        for (i = 1; i <= n; i++) {
          c = C[i]; nx = (i < n) ? C[i + 1] : ""
          if (c == "\\") {
            if (nx != "\n") addw(c mask(nx))
            i++; continue
          }
          if (finq[depth]) {
            if (c == "\"") { finq[depth] = 0; addw(c); continue }
            if (c == "$" && nx == "(") { push("sub"); i++; continue }
            if (c == "`") { backtick(); continue }
            j = i; while (j <= n && !(C[j] in SPD)) j++
            if (j == i) { addw(c); continue }
            addw(mask(run(i, j))); i = j - 1; continue
          }
          if (c == q || (c == "$" && nx == q)) {
            j = (c == "$") ? i + 2 : i + 1
            while (j <= n && C[j] != q) {
              if (c == "$" && C[j] == "\\") j++
              j++
            }
            addw(mask(run(i, j + 1))); i = j; continue
          }
          if (c == "\"") { finq[depth] = 1; addw(c); continue }
          if (c == "#" && cw[depth] == "") {
            while (i < n && C[i + 1] != "\n") i++
            continue
          }
          if (c == "$" && nx == "(") { push("sub"); i++; continue }
          if (c == "(") {
            if (cw[depth] ~ /[<>]$/) { push("sub"); continue }
            flush("("); push("paren"); continue
          }
          if (c == ")") {
            if (ftype[depth] == "sub") { popsub(); continue }
            if (ftype[depth] == "paren") { flush(")"); depth--; continue }
            flush(")"); continue
          }
          if (c == "`") { backtick(); continue }
          if (c == "<" && nx == "<") {
            if (i + 2 <= n && C[i + 2] == "<") { addw("<<<"); i += 2; continue }
            i = heredoc(i); continue
          }
          if (c == "&" && nx == "&") { flush("&&"); i++; continue }
          if (c == "|" && nx == "|") { flush("||"); i++; continue }
          if ((c == "&" && (nx == ">" || cw[depth] ~ /[<>]$/)) || (c == "|" && cw[depth] ~ />$/)) {
            addw(c); continue
          }
          if (c == ";" || c == "&" || c == "|") { flush(c); continue }
          if (c == "\n") { flush(c); if (nh > 0) i = bodies(i); continue }
          if (c == " " || c == "\t") { endword(); continue }
          j = i; while (j <= n && !(C[j] in SPU)) j++
          if (j == i) { addw(c); continue }
          addw(run(i, j)); i = j - 1
        }
        while (depth > 0) {
          if (ftype[depth] == "sub" || ftype[depth] == "bt") popsub()
          else { flush(""); depth-- }
        }
        flush("")
      }
    '
}

# 断片 (gh_invocations の 5 列目) は、gh の <サブコマンド> の呼び出しか。
#   $1 = 断片
#   $2 = サブコマンドの正規表現 (例 'pr[[:space:]]+create'、'(issue|pr)[[:space:]]+comment')
#
# gh とサブコマンドの間にはグローバルオプション (-R owner/repo など) が入りうるので、
# その間は緩く見る。ただし**同じ断片の中**に限る (gh issue … と pr review … のような
# 離れた語を繋げない)。
gh_fragment_is() { # $1=断片 $2=サブコマンド正規表現
  printf '%s\n' "$1" | grep -qE "^gh([[:space:]]+[^[:space:]]+)*[[:space:]]+$2([[:space:]]|$)"
}

# 1 つの gh の呼び出しの宛先は、このリポジトリの**外**か。
#   $1 = 断片  $2 = GH_REPO の列  $3 = chdir の列  $4 = cwd
#   (列の意味は gh_invocations)
#
# 基準は GITHUB_REPOSITORY (既定 mokume-metal/mokume)。
#
# 判定は gh の宛先解決と同じ順に見る。**読むのはその呼び出しの断片と前置、打つシェルから
# 継ぐ環境だけ**で、同じ行の別のコマンドの -R (git log -R x/y など) は宛先ではない
# (#1729 の反証):
#
#   1. -R / --repo が付いていれば、それが宛先 (複数書けて後勝ち)
#   2. 前置の GH_REPO= があれば、それが宛先。前置が無ければ、打つシェルから継ぐ GH_REPO
#      (フックの環境に在れば。GH_TOKEN を継ぐのと同じ扱い・#1729 の 2 回目の反証)
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
# **同じコマンドの中の cd と、文としての export GH_REPO= は、値を追わずに「決められない」と
# 読む** (#1823)。コマンド文字列からその値を読むのは推測になる (変数展開・引用・複数の cd・
# サブシェル・順序)。以前は追わないまま cwd と継いだ GH_REPO で決めていたので、別のリポジトリの
# cwd から `cd <mokume> && gh …`・`export GH_REPO=mokume-metal/mokume && gh …` が素通しし、
# mokume の cwd で継いだ他リポの GH_REPO を `unset GH_REPO` で消した形も素通しした。
#
# 印は gh_invocations が gh より前の文から立てる (2 列目の `?` と 3 列目の 1)。立てるのは、
# cwd を変える文 (cd・pushd・popd)・GIT_DIR (gh は GIT_DIR のリポジトリを今いるリポジトリと
# して読む)・GH_REPO を変える文 (代入・export・export -n・declare / typeset・unset) である。
# `( … )` と `$( … )` の中の gh には外の文も効き、中の文は外の gh に効かない
# (x=$(cd <dir> && pwd) && gh … は cwd のまま読む)。逃げ道は -R の明示と前置の GH_REPO= で、
# この 2 つは印より勝つ (gh の宛先の順と同じ)。差し戻しの文面は -R を案内する。
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
      '=') target=${GH_REPO:-} ;;
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
読みます。同じコマンドの中で gh より前に cd・pushd・popd・GIT_DIR や、GH_REPO を変える文
(export GH_REPO=・unset GH_REPO など) があれば、その先は追わずに宛先を決められないものとして
止めます — 判定を推測に寄せないためです。cd 先のリポジトリ宛てなら -R を付けてください。
git 管理外・origin が無い・owner を省いた --repo も同じく止める側です。
EOF
}
