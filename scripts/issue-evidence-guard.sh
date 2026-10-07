#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# Claude Code の PreToolUse フック: エージェントが gh issue create / edit で出す本文が、
# 描画のファイルを名指ししているのに絵も宣言も持たなければ差し戻す (#2195)。
#
# PR には drawing-evidence の門があり、描画に触れた PR の絵はほぼ欠けない。Issue には
# 門が無く、見た目・動きの Issue 20 件のうち 19 件に絵が無かった (#2195 の実測)。
# エージェントは --body-file で起票するのでテンプレートの促しも通らない。抜けたときに
# 気付ける最初の場所が、起票のコマンドそのものである。
#
# **判定はしない。** 本文を取り出して scripts/check-drawing-evidence.sh --issue-body に
# 渡すだけで、「描画の Issue か」「絵か宣言があるか」の照合は PR の門と同じ 1 つを使う。
# deny なのは、絵を貼るか宣言の 1 行を足せばその場で続けられるため (人を呼ばない)。
#
# 本文の取り出し方:
#
#   --body-file / -F <パス>   ファイルを読む。相対パスは cwd から。宛先を cwd から決め
#                             られない呼び出し (cd の後など)・`-`・読めないパスは素通し
#   --body / -b <本文>        断片の中の語から取り出す (scripts/gh_issue_body.py)。引用の中の空白・改行は guard-lib が
#                             伏せた形 (\002) で届くので、空白に戻して読む。改行は戻らない
#                             ので、宣言の照合は行頭に限っていない (check-drawing-evidence)。
#                             語は 4096 バイトで切られるので、それより長い本文は素通し
#
# **取りこぼしは許容する** (agent-comment-guard と同じ水準)。止めるのはうっかりで、
# 回避ではない。$(cat …) で組んだ本文・scripts/sub-issue.sh などのスクリプト経由の起票・
# gh api は見えない。人の Web 入力は対象外 (入力欄へ落とせば絵が付く)。
#
# 契約: stdin に PreToolUse の JSON。素通しは無出力 + 終了コード 0。
# 配線は .claude/settings.json、テストは scripts/tests/issue_evidence_guard_test.py。
set -uo pipefail

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source=scripts/guard-lib.sh
. "$here/guard-lib.sh" 2>/dev/null || exit 0

hook_payload
hook_command
command=$HOOK_COMMAND
cwd=$HOOK_CWD

# 断片から本文を取り出して標準出力へ。取り出せなければ 1 を返す (素通し)。
#   $1 = 断片  $2 = chdir の列  $3 = cwd
body_of() {
  python3 "$here/gh_issue_body.py" "$1" "$2" "$3"
}

reasons=
while IFS=$'\t' read -r repo chdir _place fragment; do
  gh_fragment_is "$fragment" 'issue[[:space:]]+(create|edit)' || continue
  is_help_request "$fragment" && continue
  invocation_targets_other_repo "$fragment" "$repo" "$chdir" "$cwd" && continue
  file=$(mktemp)
  if body_of "$fragment" "$chdir" "$cwd" > "$file"; then
    if ! out=$(bash "$here/check-drawing-evidence.sh" --issue-body "$file" 2>&1 >/dev/null); then
      reasons=$out
    fi
  fi
  rm -f "$file"
done < <(gh_invocations "$command")

[ -n "$reasons" ] || exit 0
hook_deny "$reasons"
