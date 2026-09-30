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
#   - **別のコマンドを起動するコマンド**の後ろの gh (sudo / exec / nohup / nice / xargs …
#     gh)、`bash -c "gh …"`・eval・source、alias とシェル関数。起動する側の語は利用者が
#     増やせるので、数え上げは必ず取りこぼす (gh api を素通しにしているのと同じ水準)。
#     bash の builtin / command は増やせない語なので、その後ろも文として読む (#1823 の反証 #1。
#     command -v / -V は引くだけなので読まない)
#   - 実行時に決まる語 (`$GH …`・`$(which gh) …`)。値を読むのは推測になる
#   - 同じコマンドの中で**文として**宛先を変える形 (cd・chdir・pushd・popd・GH_REPO や、git が
#     リポジトリを探し remote を読むのに効く変数を変える文・for / select のループ変数) の**値**。
#     値は追わず、あれば宛先を「決められない」として止める側へ倒す (#1823。
#     invocation_targets_other_repo の説明)。GH_TOKEN を文として変える形 (発行・export・unset・
#     再代入・名前で書く builtin) は読む (#1729・#1823)。ループの本体では、gh の後ろの文も
#     次の周の gh に効くものとして読む
#   - 宛先に効きうるが、上の名前と文に当たらないもの (source・eval・trap・シェル関数・
#     `git remote set-url`・`gh repo set-default`・HOME / XDG_CONFIG_HOME の前置 …)。
#     列挙を「宛先に効かないと分かっている文」の側へ裏返すかは #1880 で決める
#   - GH_TOKEN を変える文のうち、サブシェル・$( … )・パイプラインの要素の中のもの (外へは
#     効かないので読まない。中の発行・export も外の gh へは運ばない) と、パラメータ展開の
#     中の代入 (`: ${GH_TOKEN:=…}` — 発行した値があれば何も変えない)
#   - 同じコマンドの中で cd した先が、同じ別のリポジトリの中であること
#     (`cd <other>/sub; gh …` も止まる。値を追わない設計の代償で、逃げ道は -R・#1823)
#
# ガードは bash の文法で読む。Bash ツールのシェルが zsh でも、zsh だけの cd の綴り (chdir) は
# 止める側に読む
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
#                                 (export X="$(…)" / 前置 GH_TOKEN="$(…)" / 発行の成功と export
#                                 が、その gh の段で必ず済んでいるとは言えない — #1823。読み方は
#                                 下の「並びの枠」。置換の中の発行は、置換の終了コードが
#                                 gh-app-token.sh の成否を伝えるときだけ発行と読む (|| true・
#                                 | tr・; true の後ろでは伝わらない)。直書きの ghs_ は発行が
#                                 失敗しえないので成否を問わない)
#                   unexported    安全に発行したが export していない (gh へ渡らない)
#                   removed       消した (env -u GH_TOKEN / env -i / unset GH_TOKEN)
#                   other         確かめられない値 (空・個人の token・発行していない変数)
#                   unknown       読めない形で変えた (+= など)
#   2. GH_REPO    前置の値。`=` は継ぐ・`-` は消した・`+<値>` は前置の値・`?` は読めない
#                 (前置が無く、gh より前の文で GH_REPO を代入・export・unset・read・
#                 printf -v … したときも `?`)
#   3. chdir      宛先を cwd から決められないなら 1。env -C と、gh より前の文としての
#                 cd・chdir・pushd・popd と、git がリポジトリを探し remote を読むのに効く変数
#                 (GITV・前置・文)。ループの本体で gh の後ろに置いたものも (#1823)
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
#                (文の頭の予約語と builtin・command (-p) は、並びの枠を読む structure が落とす。
#                command -v / -V は引くだけなので落とさない)
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
      # 入れ子は、宛先を変えた印 (DC・DR) を親から継ぐ。閉じれば捨てるので外へは効かない。
      # 並びの枠も 1 つ開く。( … ) は親の段の要素になり、$( … ) は語の中で走る
      function push(t,   e) {
        if (t == "paren") { FPEND[fd] = 1; FWANT[fd] = 0 }
        e = FE[fd]
        depth++; ftype[depth] = t; finq[depth] = 0; cw[depth] = ""; nw[depth] = 0; fiss[depth] = 0
        DC[depth] = DC[depth - 1]; DR[depth] = DR[depth - 1]
        fd++; FK[fd] = t; FDEP[fd] = depth; FE0[fd] = e; newlist(e)
        if (t != "paren") { nsub++; FSK[fd] = "S" nsub }
      }
      # --- 並びの枠 (#1823 の反証 #7・#8・#10) ---
      #
      # gh の時点で「必ず済んでいる」事実を、bash の文法の結合の順に運ぶ。事実は空白区切りの
      # 集合で持つ: I<n> は n 番目の発行の代入が成功した、X<n> は GH_TOKEN を export した
      # (n は unset・export -n で進む世代)、S<n> は n 番目の置換の中で gh-app-token.sh が
      # 成功した。
      #
      # 枠は並びの入れ物で、入れ子の外 (top)・( … )・$( … )・バッククォート・{ … }・
      # if / while / until / for … の 1 つずつにある。枠の中で持つのは:
      #   FG  いまの並びの頭で必ず済んでいる事実 (; と改行の後ろの並びへ運ぶ)
      #   FE  いま読んでいる段 (パイプライン) に入るとき必ず済んでいる事実
      #   FZ / FN  直前の段までを終えて、終了コードが 0 / 0 以外のとき必ず済んでいる事実
      # 段を終えると、&& の後ろの段は FZ から、|| の後ろの段は FN から入る。段が飛ばされても
      # 終了コードは前のまま残るので、FZ・FN はその場合との積を取る。
      #
      # パイプライン (a | b) は && より強く結合する 1 つの段で、要素はどれも子で走るので、
      # 中で立てた事実は外へ出さない。! は段の成否を裏返すので、成功の事実を捨てる。
      # 複合コマンド ({ … }・if …) も 1 つの段で、中は入口の事実 (FE0) から読む。{ … } は
      # 今のシェルで走り、終了コードは最後に走った並びのものなので、その並びの事実を外の段へ
      # 運ぶ (反証 2-6)。if とループの中で立てた事実は外へ出さない (止める側)。if の条件で
      # 立てた事実も本体へ運ばない — 本体が条件の成功のときだけ走ることは読まない (#1823 の
      # D の 19 を止める側に置く)
      function sunion(a, b,   n, t, k) {
        n = split(b, t, " ")
        for (k = 1; k <= n; k++) if (!index(a, " " t[k] " ")) a = a t[k] " "
        return a
      }
      function sinter(a, b,   n, t, k, r) {
        r = " "; n = split(a, t, " ")
        for (k = 1; k <= n; k++) if (index(b, " " t[k] " ")) r = r t[k] " "
        return r
      }
      function has(a, k) { return index(a, " " k " ") > 0 }
      function newlist(g) {
        FG[fd] = g; FE[fd] = g; FST[fd] = 0; FOP[fd] = ""; FLAST[fd] = 0
        FPEND[fd] = 0; FWANT[fd] = 0; FPIPE[fd] = 0; FNEG[fd] = 0; FPS[fd] = " "; FPA[fd] = " "
      }
      # 段を終える。FPS / FPA はその段で、成功したとき / 走ったときに必ず済む事実
      function finpipe(   s, a, e) {
        if (!FPEND[fd]) return
        s = FPS[fd]; a = FPA[fd]
        if (FPIPE[fd]) { s = " "; a = " " }
        if (FNEG[fd]) s = a
        e = FE[fd]
        if (!FST[fd]) { FZ[fd] = sunion(e, s); FN[fd] = sunion(e, a) }
        else if (FOP[fd] == "&&") { FN[fd] = sinter(sunion(e, a), FN[fd]); FZ[fd] = sunion(e, s) }
        else { FZ[fd] = sinter(sunion(e, s), FZ[fd]); FN[fd] = sunion(e, a) }
        FST[fd] = 1; FPEND[fd] = 0; FWANT[fd] = 0; FPIPE[fd] = 0; FNEG[fd] = 0; FPS[fd] = " "; FPA[fd] = " "
      }
      # 並びを終える。& で終えた並びは子で走るので、後ろへ何も運ばない
      # 並びを終える。& で終えた並びは子で走るので、後ろへ何も運ばない。終えた並びの FZ は
      # FLZ に残す — 枠の終了コードは最後に走った並びのもので、`{ a && b; }` の ; の後ろは空
      function endlist(bg,   z, g) {
        finpipe()
        if (bg) { g = FG[fd]; z = g }
        else if (FST[fd]) { z = FZ[fd]; g = sinter(FZ[fd], FN[fd]) }
        else { g = FG[fd]; z = FLAST[fd] ? FLZ[fd] : g }
        newlist(g); FLZ[fd] = z; FLAST[fd] = 1
      }
      # 枠の終了コードが 0 のときに必ず済んでいる事実
      function lastz() { return FST[fd] ? FZ[fd] : FLAST[fd] ? FLZ[fd] : FG[fd] }
      function andor(op) {
        finpipe()
        if (!FST[fd]) return
        FOP[fd] = op; FE[fd] = (op == "&&") ? FZ[fd] : FN[fd]
      }
      # 複合コマンドの枠を開く。loop はループ (while / until / for / select) で、本体の gh の
      # 行を閉じるまで溜める — 本体の中で gh の後ろに置いた文も、次の周の gh に効く (反証 2-3)
      function openf(k, loop,   e) {
        FPEND[fd] = 1; FWANT[fd] = 0; e = FE[fd]
        fd++; FK[fd] = k; FDEP[fd] = depth; FE0[fd] = e; newlist(e); FLOOP[fd] = loop
        if (loop) { LOOPN++; FB0[fd] = NB + 1; FDC0[fd] = DCC[depth]; FDR0[fd] = DRC[depth]; FTK0[fd] = TKC }
      }
      function closef(k) {
        if (fd == 0 || FK[fd] != k || FDEP[fd] != depth) return
        popcmp()
      }
      # 複合コマンドの枠を閉じる。{ … } の終了コードは最後の文のものなので、成功したとき・
      # 走ったときに済む事実を外の段へ運ぶ (反証 2-6)。if とループの事実は運ばない (止める側)。
      # ループを閉じるときは、本体で宛先・token を変える文があれば、本体の gh の行すべてに
      # その印を付ける
      function popcmp(   s, a, k, d, g) {
        finpipe()
        s = lastz(); a = FST[fd] ? sinter(FZ[fd], FN[fd]) : FG[fd]
        if (FLOOP[fd]) {
          d = FDEP[fd]
          for (k = FB0[fd]; k <= NB; k++) {
            if (DCC[d] > FDC0[fd]) RC[k] = 1
            if (DRC[d] > FDR0[fd] && RR[k] == "=") RR[k] = "?"
            if (TKC > FTK0[fd] && RT[k]) RV[k] = "unknown"
          }
          LOOPN--
        }
        g = (FK[fd] == "grp"); fd--
        if (g) { FPS[fd] = sunion(FPS[fd], s); FPA[fd] = sunion(FPA[fd], a) }
        if (!LOOPN) rows()
      }
      # 入れ子を閉じる前に、その深さで閉じ忘れた複合コマンドの枠を閉じる
      function dropto() {
        while (fd > 0 && FDEP[fd] == depth && (FK[fd] == "grp" || FK[fd] == "cmp")) popcmp()
        finpipe()
      }
      # gh の行。ループの中では、ループを閉じるまで溜める。inh は token を打つシェルの状態から
      # 見立てたか (前置で渡した token は、ループの中の文で変わらない)
      function row(v, r, c, p, f, inh) {
        NB++; RV[NB] = v; RR[NB] = r; RC[NB] = c; RP[NB] = p; RF[NB] = f; RT[NB] = inh
        if (!LOOPN) rows()
      }
      function rows(   k) {
        for (k = 1; k <= NB; k++) print RV[k] "\t" RR[k] "\t" RC[k] "\t" RP[k] "\t" RF[k]
        NB = 0
      }
      # 宛先を変える文の印。数 (DCC・DRC) はループの本体で立ったかを見るのに使う
      function markc() { DC[depth] = 1; DCC[depth]++ }
      function markr() { DR[depth] = 1; DRC[depth]++ }
      # for / select のループ変数は、名前で書く文として読む (反証 2-1)
      function loopvar(name) {
        if (name !~ /^[A-Za-z_][A-Za-z0-9_]*$/) return
        destvar(name)
        if (depth == 0 && name == "GH_TOKEN") { SV[name] = "unknown"; TKC++ }
      }
      # 文の先頭の予約語と、枠を開け閉めする語を読み、残りを返す。builtin / command の後ろも
      # 文として読む (反証 #1)。command -v / -V は引くだけで実行しない
      function structure(f,   w, o) {
        while ((w = word1(f)) != "") {
          if (w == "{") { openf("grp"); f = rest1(f); continue }
          if (w == "if") { openf("cmp", 0); f = rest1(f); continue }
          if (w ~ /^(while|until)$/) { openf("cmp", 1); f = rest1(f); continue }
          if (w ~ /^(for|select)$/) { openf("cmp", 1); loopvar(word1(rest1(f))); return "" }
          if (w ~ /^(then|do|else|elif)$/) {
            if (FK[fd] == "cmp" && FDEP[fd] == depth) { finpipe(); newlist(FE0[fd]) } else endlist(0)
            f = rest1(f); continue
          }
          if (w == "}") { closef("grp"); f = rest1(f); continue }
          if (w ~ /^(fi|done)$/) { closef("cmp"); f = rest1(f); continue }
          if (w == "!") { FNEG[fd] = 1; f = rest1(f); continue }
          if (w == "coproc") { FPIPE[fd] = 1; f = rest1(f); continue }
          if (w == "time") { f = rest1(f); if (word1(f) == "-p") f = rest1(f); continue }
          if (w == "function") { f = rest1(rest1(f)); continue }
          if (w == "builtin") { f = rest1(f); continue }
          if (w == "command") {
            o = rest1(f)
            while (word1(o) ~ /^-/) { if (word1(o) ~ /[vV]/) return f; o = rest1(o) }
            f = o; continue
          }
          break
        }
        return f
      }
      function endword() { if (cw[depth] != "") { nw[depth]++; W[depth, nw[depth]] = cw[depth]; cw[depth] = "" } }
      function joinw(d, lo, hi,   mid) {
        if (lo == hi) return W[d, lo]
        mid = int((lo + hi) / 2)
        return joinw(d, lo, mid) " " joinw(d, mid + 1, hi)
      }
      # 断片 (単純コマンド 1 つ) を読み、区切り (sep) に従って段・並びを進める。
      # sep の "close" は入れ子を閉じる ) で、段を終えるだけにする (並びの終わりは
      # 閉じた側が決める)。空の断片は、段の途中でなければ読み飛ばす — && / || / | の後ろの
      # 改行 (継続) と、; の後ろの ; など
      function flush(sep,   f, k, iss) {
        endword()
        if (nw[depth] > 0) {
          f = joinw(depth, 1, nw[depth])
          for (k = 1; k <= nw[depth]; k++) delete W[depth, k]
          nw[depth] = 0
          iss = index(f, "scripts/gh-app-token.sh")
          if (iss) fiss[depth] = 1
          f = structure(f)
          if (f != "") {
            ES = " "; EA = " "
            emit(f)
            if (iss && (FK[fd] == "sub" || FK[fd] == "bt")) ES = sunion(ES, FSK[fd])
            FPEND[fd] = 1; FWANT[fd] = 0; FPS[fd] = sunion(FPS[fd], ES); FPA[fd] = sunion(FPA[fd], EA)
          }
        } else if (!FPEND[fd] || (FWANT[fd] && sep == "\n")) return
        if (sep == "&&" || sep == "||") andor(sep)
        else if (sep == "|") { FPIPE[fd] = 1; FWANT[fd] = 1 }
        else if (sep == ";" || sep == "\n" || sep == ")") endlist(0)
        else if (sep == "&") endlist(1)
        else if (sep == "close" || sep == "") finpipe()
      }
      # $( … ) / バッククォートを閉じる。置換の終了コードが gh-app-token.sh の成功を
      # 意味するとき (最後の並びが 0 で終わるなら S が済んでいる) だけ、発行の印 (X) を持つ
      # 語として親へ返す。綴りはあるが失敗が置換の外へ伝わらない形 (|| true・| tr・; true) は
      # 別の印 (Y) で、見立ては unsafe になる (反証 #5)
      function popsub(   iss, ok) {
        flush("close"); dropto()
        ok = has(lastz(), FSK[fd]); iss = fiss[depth]
        fd--; depth--
        addw(ok ? "$(" X ")" : iss ? "$(" Y ")" : "$()")
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
      # 文としての代入。ctx は "export" (export X=… の形) か "stmt"。発行した値は、
      # 成功の事実 (I<n>) を SK に持つ。gh の段でその事実が済んでいるかは FE で見る。
      # 直書きの ghs_ は発行が失敗しえないので、事実を求めない (SK が空)
      function setvar(name, val, plus, ctx,   v, r) {
        if (name == "GH_TOKEN") TKC++
        if (plus) { SV[name] = "unknown"; return }
        v = unquote(val)
        if (v == "$(" X ")") {
          if (ctx == "export") { SV[name] = "unsafe"; return }
          ni++; SV[name] = "issued"; SK[name] = "I" ni; ES = sunion(ES, "I" ni)
          return
        }
        if (v == "$(" Y ")") { SV[name] = "unsafe"; return }
        r = varref(v)
        if (r != "") {
          if (r == name) return
          if (r in SV) { SV[name] = SV[r]; SK[name] = SK[r] } else SV[name] = "other"
          return
        }
        if (v ~ /^ghs_/) { SV[name] = "issued"; SK[name] = "" } else SV[name] = "other"
      }
      # 発行した値 (name) が、いまの段で成功したと確かめられるか
      function landed(name) { return SK[name] == "" || has(FE[fd], SK[name]) }
      # 文として代入・export・unset した名前が、gh の宛先に効くなら印を立てる (#1823)。
      # git の変数は、git がリポジトリを探し remote を読むのに効くものだけ (GITV・反証 #2 と
      # 2-5。GIT_PAGER・GIT_TERMINAL_PROMPT などは宛先に効かない)
      function destvar(name) {
        if (name == "GH_REPO") markr()
        if (name ~ GITV) markc()
      }
      function shellstate(   s) {
        if (!("GH_TOKEN" in SV)) return "inherit"
        s = SV["GH_TOKEN"]
        if (s != "issued") return s
        if (!gx) return "unexported"
        # 発行の成功と export が、この gh の段で必ず済んでいるときだけ (#1823)
        if (!landed("GH_TOKEN") || !has(FE[fd], "X" xg)) return "unsafe"
        return "installation"
      }
      function verdict(tok,   v, r, s) {
        if (tok == "-") return "removed"
        if (tok == "?") return "unknown"
        if (tok == "=") return shellstate()
        v = unquote(substr(tok, 2))
        if (v == "$(" X ")" || v == "$(" Y ")") return "unsafe"
        if (v ~ /^ghs_/) return "installation"
        r = varref(v)
        if (r != "") {
          if (r in SV) {
            s = SV[r]
            if (s == "issued") return landed(r) ? "installation" : "unsafe"
            return (s == "removed") ? "other" : s
          }
          if (r == "GH_TOKEN") return "inherit"
        }
        return "other"
      }
      # 前置を落とし、先頭が gh なら 5 列の行を出す。gh でなく入れ子の外なら、文として
      # GH_TOKEN に効くもの (代入・export・unset) を覚え、その段で済む事実を ES (成功したとき)
      # と EA (走ったとき) に足す
      function emit(f,   w, name, val, plus, bare, o, t, L, v, tok, repo, chd, na, k, a, r, xn, xf) {
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
            if (name ~ GITV) chd = 1
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
          if (depth == 0) for (k = 1; k <= na; k++) setvar(AN[k], AV[k], AP[k], "stmt")
          return
        }
        w = word1(f)
        if (unquote(w) ~ /^(.*\/)?gh$/) {
          if (DC[depth]) chd = 1
          if (DR[depth] && repo == "=") repo = "?"
          row(verdict(tok), repo, chd, (depth > 0) ? "sub" : "top", "gh" substr(f, length(w) + 1), tok == "=")
          return
        }
        # 宛先を変える文は、入れ子の中でも覚える (その入れ子の中の gh に効く・#1823)。
        # 名前を引数に取って変数へ書く builtin (read・printf -v・mapfile …) も同じ (反証 #3)。
        # chdir は zsh の builtin で、Bash ツールが zsh で走る環境では cd と同じに効く
        w = unquote(w)
        if (w ~ /^(cd|chdir|pushd|popd)$/) markc()
        if (w ~ /^(export|unset|declare|typeset|readonly|local|read|printf|mapfile|readarray|getopts|let|wait)$/) {
          r = rest1(f)
          while ((a = word1(r)) != "") {
            r = rest1(r)
            if (a ~ /^-/) continue
            name = unquote(a); sub(/[=[].*/, "", name); destvar(name)
            # token の側も、名前で GH_TOKEN に書く文は読めない書き換えとして読む (反証 2-4)。
            # export と unset は下で読む
            if (depth == 0 && name == "GH_TOKEN" && w !~ /^(export|unset)$/) { SV[name] = "unknown"; TKC++ }
          }
        }
        if (depth != 0) return
        # GH_TOKEN を消す・export を外す文は、GH_REPO の側と同じく先頭語の後ろまで読む
        # (反証 #4)。export -n は export を外し、export -f は関数の名前なので読まない
        if (w == "export") {
          r = rest1(f); xn = 0; xf = 0
          while ((a = word1(r)) != "") {
            r = rest1(r)
            if (a ~ /^-/) { if (a ~ /^-[^-]*n/) xn = 1; if (a ~ /^-[^-]*f/) xf = 1; continue }
            if (xf) continue
            name = unquote(a); sub(/=.*/, "", name)
            if (a ~ /=/) { val = a; sub(/^[^=]*=/, "", val); setvar(name, val, 0, "export") }
            if (name != "GH_TOKEN") continue
            if (xn) { gx = 0; xg++; TKC++ } else { gx = 1; ES = sunion(ES, "X" xg); EA = sunion(EA, "X" xg) }
          }
        } else if (w == "unset") {
          r = rest1(f)
          while ((a = word1(r)) != "") {
            r = rest1(r)
            if (a ~ /^-/) continue
            a = unquote(a)
            if (a == "GH_TOKEN") { SV[a] = "removed"; gx = 0; xg++; TKC++ } else delete SV[a]
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
        DC[0] = 0; DR[0] = 0; Y = "\004"; ni = 0; xg = 0; nsub = 0; ES = " "; EA = " "
        fd = 0; FK[0] = "top"; FDEP[0] = 0; newlist(" "); NB = 0; LOOPN = 0; TKC = 0
        # git がリポジトリを探し remote を読むのに効く変数 (git(1) の「The Git Repository」の
        # うちリポジトリの在処と探し方を決めるものと、設定を差し替える GIT_CONFIG の族。
        # remote.*.url と url.*.insteadOf は設定から読まれる・反証 2-5)
        GITV = "^GIT_(DIR|COMMON_DIR|WORK_TREE|NAMESPACE|CEILING_DIRECTORIES|DISCOVERY_ACROSS_FILESYSTEM|CONFIG.*)$"
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
            if (ftype[depth] == "paren") { flush("close"); dropto(); fd--; depth--; continue }
            flush(")"); continue
          }
          if (c == "`") { backtick(); continue }
          if (c == "<" && nx == "<") {
            if (i + 2 <= n && C[i + 2] == "<") { addw("<<<"); i += 2; continue }
            i = heredoc(i); continue
          }
          if (c == "&" && nx == "&") { flush("&&"); i++; continue }
          if (c == "|" && nx == "|") { flush("||"); i++; continue }
          # |& は 2>&1 | と同じパイプ (& で割ると、段を裏で走らせたと読む)
          if (c == "|" && nx == "&") { flush("|"); i++; continue }
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
          else { flush("close"); dropto(); fd--; depth-- }
        }
        flush("")
        # 閉じ忘れた複合コマンドも閉じてから、溜めた行を出す
        while (fd > 0) popcmp()
        rows()
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
#   -R "$O/$R"             … 同じく値を読めない (#1823 の反証 2-2)
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
# cwd を変える文 (cd・chdir・pushd・popd)・git がリポジトリを探し remote を読むのに効く変数
# (gh は git に remote を尋ねるので、GIT_DIR・GIT_COMMON_DIR・GIT_WORK_TREE・GIT_CONFIG の族 …
# で宛先が変わる。GIT_PAGER・GIT_TERMINAL_PROMPT のように効かないものは読まない — 一覧は
# gh_invocations の GITV)・GH_REPO を変える文 (代入・export・export -n・declare / typeset・
# unset・read・printf -v・mapfile・for / select のループ変数 …) である。文の先頭の builtin /
# command は落として読む。ループの本体では、gh の後ろに置いた文も次の周の gh に効くので、
# 本体の gh すべてに印を付ける。
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
  fi
  # 値が実行時に決まる (-R "$O/$R"・-R "${REPO:-…}"・前置の GH_REPO="$X") なら読めない。
  # -R も前置と同じく止める側 (反証 2-2)。置換は字句読みで $( … ) の語に置き換わっている
  case "$target" in *'$'* | *'`'*) return 1 ;; esac
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
読みます。同じコマンドの中で gh より前に cd・pushd・popd・git のリポジトリを指す変数 (GIT_DIR など) や、
GH_REPO を変える文 (export GH_REPO=・unset GH_REPO など) があれば、その先は追わずに宛先を決められないものとして
止めます — 判定を推測に寄せないためです。cd 先のリポジトリ宛てなら -R を付けてください。
git 管理外・origin が無い・owner を省いた --repo も同じく止める側です。
EOF
}
