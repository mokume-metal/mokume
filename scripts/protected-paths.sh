# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 「この変更は承認が要るパスに触れているか」の判定 (#584)。
#
# 一覧そのものは .github/rulesets/main-protection.json の required_reviewers が持ち、
# **それを読む照合はここ 1 つ**に保つ (ADR-0001 原則 9)。
#
# 読み手は scripts/review-gate.sh の「承認が要る PR か」の判定 1 つである。かつては
# scripts/request-review.sh も読んでいて、ラベル由来のレビュー要求が同じ人へ 2 通目を
# 投げないための条件判定に使っていた (#583 / #584)。ADR-0031 がラベル由来の承認ごと
# 畳んだので、そちらは消えた (#618) — 分けた形そのものは今も正しく、読み手が 1 つに
# 戻っただけである。
#
# 読むのは API ではなくリポジトリ内の定義ファイルなので、追加の権限も呼び出しも要らない。
# drawing-paths.sh / guard-lib.sh と同じ形で source する。
#
# 使い方 (source する側):
#   . "$(dirname "${BASH_SOURCE[0]}")/protected-paths.sh"
#   jq -r '.files[]?.path // empty' <<<"$pr_json" | touches_protected_path && …
#
# テストは scripts/tests/review_gate_test.py が読み手を通して行う
# (RULESET_FILE を差し替えて走らせる)。

# 承認が要るパスの正本。テストは別のファイルを指す
RULESET_FILE="${RULESET_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/rulesets/main-protection.json}"

# ルールセットが 1 承認を課しているパスのパターン。**写しを持たず正本を読む**
required_patterns() {
  [ -f "$RULESET_FILE" ] || return 0
  jq -r '
    .rules[]? | select(.type == "pull_request")
    | .parameters.required_reviewers[]? | .file_patterns[]?
  ' "$RULESET_FILE"
}

# 1 パターンが 1 ファイルに当たるか。ルールセットの file_patterns は gitignore 形式で、
# このリポジトリが使うのは末尾 `/**` (ディレクトリ配下すべて) だけである。他の形が
# 増えたらここを見る — 特に否定 (`!`) は無視すると過剰に一致し、承認の要らない PR を
# 「誰も承認できない」と誤って差し戻す
pattern_match() { # $1=パターン $2=ファイルパス
  local pattern=$1 path=$2
  if [[ $pattern == */\*\* ]]; then
    [[ $path == "${pattern%/\*\*}"/* ]]
  else
    [[ $path == $pattern ]]
  fi
}

# 標準入力のファイル群 (1 行 1 件) のどれかがルールセットの対象に当たるか
touches_protected_path() {
  local paths pattern path
  paths=$(cat)
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      pattern_match "$pattern" "$path" && return 0
    done <<<"$paths"
  done < <(required_patterns)
  return 1
}
