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
# 発言の境界は「スレッドへの発言か」の 1 本で、本文を伴っても次は署名の対象にしない:
#
#   gh {issue,pr} create --body   → Issue / PR の本文 (スレッドに並ぶ発言ではない)。素通し
#   gh {issue,pr} edit --body     → 既存本文の書き換え。発言ではないが、読んだ後の改訂を
#                                   黙って消すので scripts/edit-body.sh へ回す (#2615)
#   gh pr merge --body            → マージコミットの本文。素通し
#   gh pr revert --body           → revert として作る PR の本文。素通し
#   gh {issue,pr} view --comments → 読み取り。素通し
#
# create と merge・revert を素通しのままにするのは、上書きする既存の本文が無いからである。
#
# 契約: stdin に PreToolUse の JSON。素通しは無出力 + 終了コード 0。
# 配線は .claude/settings.json、テストは scripts/tests/comment_test.py。
set -uo pipefail

# payload の解き方・差し戻し方・コマンド文字列の読み方は guard-lib.sh と共有する
# (#128・#815)。読めなければ素通し — guard が壊れて Bash ツール全体が使えなくなるほうが
# 害が大きい (hook_payload の jq と同じ fail open の考え方)
# shellcheck source=scripts/guard-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh" 2>/dev/null || exit 0

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
in_substitution=0
while IFS=$'\t' read -r repo chdir place fragment; do
  kind=
  if is_comment_invocation "$fragment"; then
    kind=comment
  elif is_body_edit_invocation "$fragment"; then
    kind=edit
  fi
  [ -n "$kind" ] || continue
  # 使い方を尋ねているだけなら投稿ではない (判定は guard-lib.sh が持つ)
  is_help_request "$fragment" && continue
  # 他のリポジトリ宛てのコメントはこのリポジトリの規約の外 (#188)。あちらの署名の作法は
  # 別に決まっており、ラッパーの投稿先は mokume 固定なので、ここで止めると逃げ道が無くなる。
  # 判定は guard-lib.sh が持つ
  invocation_targets_other_repo "$fragment" "$repo" "$chdir" "$cwd" && continue
  if [ "$kind" = comment ]; then offending=1; else editing=1; fi
  [ "$place" = sub ] && in_substitution=1
done < <(gh_invocations "$command")

[ "$offending" = 1 ] || [ "$editing" = 1 ] || exit 0

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

if [ "$offending" = 0 ]; then
  hook_deny "$hint$(edit_reason)$(other_repo_hint 'gh issue edit <番号>')"
  exit 0
fi

also=
[ "$editing" = 1 ] && also=$'\n\n'"$(edit_reason)"

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
