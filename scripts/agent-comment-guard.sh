#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# Claude Code の PreToolUse フック: 素の gh で Issue / PR にコメントしようとしたら
# 差し戻し、scripts/comment.sh へ誘導する (#18)。本文を書き換えようとしたら
# scripts/edit-body.sh へ誘導する (#2615)。
#
# 責務は「このリポジトリへの書き込みのうち、ラッパーを持つものはラッパーを通させる」で、
# 発言 (署名を付ける) と本文の書き換え (読んだ後の改訂を消さない) の 2 つがある。
# 本文の書き換えは新しいフックにせずここへ足した (#2615) — 読み方 (gh の呼び出しごとの
# 断片・他リポの扱い・--help・置換の中の呼び出し) がコメントとまったく同じで、別の
# フックにすると guard-lib の読み方を 2 回走らせ、同じ逃げ道を 2 か所で保つことになる。
#
# 署名を付けるのはラッパー (scripts/comment.sh) の仕事で、ここが見るのは「ラッパーを
# 通っているか」だけ。PreToolUse フックはツール入力を書き換えられない仕様なので、
# 通っていないものを deny で差し戻すのが決定論的に効かせられる唯一の形。
# ask ではなく deny なのは、ラッパーに変えればその場で続行できるから (人を呼ばない)。
#
# 判定はコメントを投稿するコマンドと、本文を書き換えるコマンドだけに絞る:
#   - gh issue comment / gh pr comment          → 差し戻す
#   - gh pr review で本文オプションが付くもの    → 差し戻す (--approve だけなら発言が無い)
#   - gh {issue,pr} {close,reopen} の --comment → 差し戻す (閉じ / 開き ながら発言する)
#   - gh {issue,pr} edit で本文オプションが付くもの → 差し戻す (scripts/edit-body.sh へ。#2615)
#   - gh {issue,pr} edit で本文以外だけ (--title・--add-label など) → 素通し
#   - gh {issue,pr} create・gh pr revert で、本文に署名が無いもの → 差し戻す (#3149)
#   - 他のリポジトリ宛て (-R other/repo)        → 素通し (このリポジトリの規約の外)
#   - それ以外 (view/list、gh api、--help)      → 素通し
#
# **サブコマンドを絞ってからオプションを見る。** 「-c が付いていたら発言」と短絡すると
# 読み取りまで止まる — gh の中で -c の意味は衝突している (#123):
#
#   gh pr view -c / gh issue view -c  → --comments (コメントを読む)
#   gh issue develop -c               → --checkout
#
# --comment は --comments の前方一致でもあるので、オプション側も後ろを区切りで留める。
#
# **口は数え上げてある (#708)。** 以前ここには「gh が発言を伴うサブコマンドを増やしたら
# ここに足す」と書いてあった。取りこぼしを後から足すほうが安いのは今も同じだが、数え上げ
# ないと決めた記述が残っている間は、掛かっているかを現物を読まずに疑える — #708 はそうして
# 起票された (診断は外れており、close / reopen は #127 が既に塞いでいた)。
#
# 数え上げは scripts/tests/comment_test.py の BODY_BEARING_SURFACES が持ち、そこの
# test_body_bearing_surfaces_are_enumerated が **gh の --help から導いた集合と照合する**。
# gh が口を増やせば赤くなるので、この一覧を人が見張らなくてよい。
#
# 署名の境界は「エージェントが新しく書く文か」の 1 本である (#3149)。以前は「スレッドへの
# 発言か」で、Issue / PR の本文は対象の外だった。その間、本文の署名は覚えていれば付く
# だけで、sub-issue の 11 件中 9 件・PR の本文 30 件すべてが無署名だった (#3149 の実測)。
# scripts/ready-queue.sh はその署名をエージェントの起票の唯一の手掛かりにしているので、
# 無署名の起票は人の起票に見えて在庫から漏れる。口ごとの扱い:
#
#   gh {issue,pr} create --body   → 新しい本文。署名が無ければ差し戻す。ラッパーは持たない —
#                                   作る口は gh の旗が多く (--fill・--template・--label …)、
#                                   包むと写しが要る。署名を足せばその場で続けられる
#   gh pr revert --body           → revert として作る PR の本文。create と同じ
#   gh {issue,pr} edit --body     → 既存本文の書き換え。発言ではないが、読んだ後の改訂を
#                                   黙って消すので scripts/edit-body.sh へ回す (#2615)。
#                                   署名は求めない — 人の本文をエージェントが直すこともあり、
#                                   署名を足すと出所の嘘になる (エージェントの本文なら、取得した
#                                   写しに署名が残っている)
#   gh pr merge --body            → マージコミットの本文。素通し (Assisted-by の trailer は別にある)
#   gh {issue,pr} view --comments → 読み取り。素通し
#
# 作る口の本文は scripts/gh_issue_body.py で取り出す (issue-evidence-guard.sh と同じ読み方)。
# 取り出せない形は、その呼び出しの断片に署名があれば通し、無ければ差し戻す — 「必ず付く」を
# 取って止める側へ倒す。逃げ道は署名を書いた --body-file の 1 つで足りる。例外は本文を標準
# 入力から読む `-F -` で、本文 (ヒアドキュメント・パイプの手前) は断片の外にあるので、
# コマンド文字列全体で見る。それ以外で全体を見ると、`echo '🤖 Assisted by'; gh pr create --fill`
# のように別のコマンドの語で通る (#1729 と同じ形。#3149 の反証)。
#
# 契約: stdin に PreToolUse の JSON。素通しは無出力 + 終了コード 0。
# 配線は .claude/settings.json、テストは scripts/tests/comment_test.py。
set -uo pipefail

# payload の解き方・差し戻し方・コマンド文字列の読み方は guard-lib.sh と共有する
# (#128・#815)。読めなければ素通し — guard が壊れて Bash ツール全体が使えなくなるほうが
# 害が大きい (hook_payload の jq と同じ fail open の考え方)
# shellcheck source=scripts/guard-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh" 2>/dev/null || exit 0
# 署名の検知キーと、差し戻しの文面に貼る 1 行の組み方 (#3149)
# shellcheck source=scripts/agent-signature.sh
. "$(dirname "${BASH_SOURCE[0]}")/agent-signature.sh" 2>/dev/null || exit 0

hook_payload
hook_command
command=$HOOK_COMMAND
cwd=$HOOK_CWD


# **判定は gh の呼び出しごとに、その断片だけを読む** (#1729 の反証)。以前はサブコマンドを
# 断片で見つけた後、旗・--help・-R・ラッパーをコマンド全体への部分一致で見ていたので、
# 同じ行の別のコマンドの語で本物の投稿が素通りした:
#
#   cat scripts/comment.sh && gh issue comment …   (ラッパーの名前があるだけ)
#   ls --help && gh issue comment …                (別のコマンドの --help)
#   git log -R x/y && gh issue comment …           (別のコマンドの -R)
#
# 逆に `gh pr view 3 --comments; gh pr close 3 && echo -c x` は、別のコマンドの -c で
# close を発言と取り違えた。ラッパー (scripts/comment.sh) は gh の呼び出しではないので、
# 素通しの特例は要らなくなった (内部で呼ぶ gh は別プロセスで、ここを通らない)。

# この gh の呼び出しは、スレッドへの発言か。旗は同じ断片の中からだけ読む
is_comment_invocation() { # $1=gh の断片
  gh_fragment_is "$1" '(issue|pr)[[:space:]]+comment' && return 0
  # レビューは本文を伴うときだけ。--approve / --request-changes だけなら発言が無い
  gh_fragment_is "$1" 'pr[[:space:]]+review' &&
    grep -qE '(^|[[:space:]])(-b|--body|-F|--body-file)([[:space:]]|=)' <<<"$1" &&
    return 0
  # close / reopen も本文を伴うときだけ。状態を変えるだけなら発言が無い。
  # 冒頭のとおり、-c の意味はサブコマンドによって違うのでここで絞ってから見る
  gh_fragment_is "$1" '(issue|pr)[[:space:]]+(close|reopen)' &&
    grep -qE '(^|[[:space:]])(-c|--comment)([[:space:]]|=)' <<<"$1" &&
    return 0
  return 1
}

# この gh の呼び出しは、既存の Issue / PR の本文の書き換えか (#2615)。タイトル・ラベル・
# 担当などだけを変える edit は本文に触れないので対象外。-b / -F は issue edit と pr edit の
# どちらでも --body / --body-file の短縮で、ほかの意味は無い
is_body_edit_invocation() { # $1=gh の断片
  gh_fragment_is "$1" '(issue|pr)[[:space:]]+edit' &&
    grep -qE '(^|[[:space:]])(-b|--body|-F|--body-file)([[:space:]]|=)' <<<"$1"
}


# この gh の呼び出しは、新しい本文を作るものか (#3149)。本文の旗の有無は問わない —
# 旗が無い create も、--fill やテンプレートで本文を作る
is_create_invocation() { # $1=gh の断片
  gh_fragment_is "$1" '(issue[[:space:]]+create|pr[[:space:]]+(create|revert))'
}

# 作る呼び出しの本文に署名があるか。取り出せなければ断片で、`-F -` ならコマンド文字列全体で
# 見る (冒頭の説明)。断片の引用の中の空白は \002 に伏せて届くので戻してから見る
create_is_signed() { # $1=断片 $2=chdir の列 $3=cwd
  local body
  if body=$(python3 "$(dirname "${BASH_SOURCE[0]}")/gh_issue_body.py" "$1" "$2" "$3"); then
    grep -qF "$SIGNATURE_KEY" <<<"$body"
  elif grep -qE '(^|[[:space:]])(-F|--body-file)([[:space:]]+|=)-([[:space:]]|$)' <<<"$1"; then
    grep -qF "$SIGNATURE_KEY" <<<"$command"
  else
    grep -qF "$SIGNATURE_KEY" <<<"${1//$'\002'/ }"
  fi
}


# 止めた呼び出しが、別のコマンドの引数の中の $( … ) かバッククォートで実行されるものだった
# ときに、差し戻しの頭に添える (#1729 の 2 回目の反証)。
#
#   bash scripts/comment.sh issue 1 --body "see `gh issue comment` docs"
#
# は、二重引用の中のバッククォートを bash が実行するので、判定そのものは正しい。ただ打った
# 側は本文で名前に触れただけのつもりで、「scripts/comment.sh から投稿して」だけでは直し方が
# 分からない (既にラッパーを使っている)。関数に切り出すのは、本文に $( とバッククォートを
# 含むため (bash 3.2 の #160 と同じ理由)
substitution_hint() {
  cat <<'EOF'
止めたのは、引数の中で**実行される** gh の呼び出しです。二重引用の中でも $( … ) と
バッククォートは実行されます。本文でコマンド名に触れるだけなら、単一引用で包むか
(--body '… `gh issue comment` …')、\` で逃がすか、--body-file に書いてください。

EOF
}

offending=0
editing=0
unsigned=0
in_substitution=0
while IFS=$'\t' read -r repo chdir place fragment; do
  kind=
  if is_comment_invocation "$fragment"; then
    kind=comment
  elif is_body_edit_invocation "$fragment"; then
    kind=edit
  elif is_create_invocation "$fragment"; then
    kind=create
  fi
  [ -n "$kind" ] || continue
  # 使い方を尋ねているだけなら投稿ではない (判定は guard-lib.sh が持つ)
  is_help_request "$fragment" && continue
  # 他のリポジトリ宛てのコメントはこのリポジトリの規約の外 (#188)。あちらの署名の作法は
  # 別に決まっており、ラッパーの投稿先は mokume 固定なので、ここで止めると逃げ道が無くなる。
  # 判定は guard-lib.sh が持つ
  invocation_targets_other_repo "$fragment" "$repo" "$chdir" "$cwd" && continue
  case $kind in
    comment) offending=1 ;;
    edit) editing=1 ;;
    create)
      create_is_signed "$fragment" "$chdir" "$cwd" && continue
      unsigned=1 ;;
  esac
  [ "$place" = sub ] && in_substitution=1
done < <(gh_invocations "$command")

[ "$offending" = 1 ] || [ "$editing" = 1 ] || [ "$unsigned" = 1 ] || exit 0

hint=
[ "$in_substitution" = 1 ] && hint="$(substitution_hint)"$'\n\n'

# 本文の書き換えの案内 (#2615)。コメントと同じコマンドに並んだら両方を出す
edit_reason() {
  cat <<'EOF'
このリポジトリの Issue / PR の本文は scripts/edit-body.sh で書き換えてください。

素の gh issue edit / gh pr edit は、読んだ後に人や別のエージェントが本文を書き換えて
いても、その改訂を黙って消します (#2615)。ラッパーは取得した版を土台に控え、書き込む
直前に本文が変わっていれば、誰がいつ変えたかと差分を示して止まります。

  bash scripts/edit-body.sh issue <番号> --fetch <ファイル>      # 本文を書き出し、土台を控える
  (<ファイル> を直す)
  bash scripts/edit-body.sh issue <番号> --body-file <ファイル>  # 変わっていなければ書き込む

PR の本文なら issue を pr に替えます。タイトル・ラベルなど本文以外の変更は、本文の
オプション (--body / --body-file) を外せば素の gh のままで続けられます。
EOF
}

# 署名の無い本文の案内 (#3149)。貼る 1 行はこのセッションの名乗りで組む (モデルも名乗る)
unsigned_reason() {
  local sig model
  # Claude Code 以外 (Codex など) は、payload がモデルを名乗っていればそれを使う。Claude Code は
  # 記録 (transcript_path) から、サブエージェントのモデルまで拾う
  model=$(hook_field '.model // empty')
  case "$(detect_agent)" in
    "Claude Code"*) ;;
    *) [ -z "$model" ] || MOKUME_AGENT_MODEL=${MOKUME_AGENT_MODEL:-$model} ;;
  esac
  sig=$(agent_signature --generic --transcript "$(hook_field '.transcript_path // empty')")
  cat <<EOF
このリポジトリに新しく作る Issue / PR の本文には、エージェントの署名が要ります。

署名は発言の出どころを後から辿る手掛かりで、scripts/ready-queue.sh がエージェントの起票を
見分ける唯一の手掛かりでもあります (無いと人の起票に見えます。#3149)。本文の末尾に次の
2 行を足してから、同じコマンドで出し直してください:

---
$sig

別のエージェント・モデルと一緒に作ったなら、括弧の後ろに「 and <名乗り> (<モデル>)」と
併記してください。本文を \$(cat …) で組むと中身を読めないので、署名を書いたファイルを
--body-file に渡してください。sub-issue は scripts/sub-issue.sh が署名を自動で付けます。
EOF
}

# 先頭に出す案内と、並んだ他の案内を組む。コメント > 本文の書き換え > 署名の順に重い
reasons=()
[ "$editing" = 1 ] && reasons+=("$(edit_reason)$(other_repo_hint 'gh issue edit <番号>')")
[ "$unsigned" = 1 ] && reasons+=("$(unsigned_reason)$(other_repo_hint 'gh issue create')")

if [ "$offending" = 0 ]; then
  first=${reasons[0]}
  rest=
  [ "${#reasons[@]}" -gt 1 ] && rest=$'\n\n'"${reasons[1]}"
  hook_deny "$hint$first$rest"
  exit 0
fi

also=
for r in ${reasons[@]+"${reasons[@]}"}; do also="$also"$'\n\n'"$r"; done

hook_deny "$hint$(cat <<'EOF'
このリポジトリの Issue / PR へのコメントは scripts/comment.sh から投稿してください。

同じ Issue には人間も複数のエージェントも書き込みます。どの AI が書いたかを本文の
署名で判別できる必要があり、ラッパーがそれを実行環境から判定して自動で付けます
(規約を覚えていることに依存させない)。

  bash scripts/comment.sh issue <番号> --body-file <ファイル>
  bash scripts/comment.sh pr    <番号> --body "<本文>"

投稿前に本文を確かめたいときは --dry-run を付けてください。
gh pr review で本文を添える場合も、本文はこのラッパーで投稿し、レビュー自体は
--approve / --request-changes だけで送ってください。

close / reopen に --comment を添える場合は 2 手に分けます。発言を先に投稿してから、
状態の変更は発言なしで実行してください (説明してから閉じる、という読み順になります):

  bash scripts/comment.sh pr <番号> --body "<本文>"
  gh pr close <番号>
EOF
)$also$(other_repo_hint 'gh issue comment <番号>')"
