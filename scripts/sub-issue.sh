#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# sub-issue を 1 コマンドで作る: 作成 + 親への紐づけ + 親の type: ラベル継承。
# gh CLI に sub-issue コマンドが無いための補い (ADR-0002 / #23)。
#
# 使い方:
#   sub-issue.sh <親番号> <タイトル> [--body-file F | --body TEXT] [--label L]... [--test]
#   --test : 使い捨て検証用。タイトルに test: を補い、verify: machine を付け、
#            本文が無ければ検証用の雛形を入れる (確認後に close する前提)
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-mokume-metal/mokume}"

PARENT="${1:?親 Issue 番号が必要}"; shift
TITLE="${1:?タイトルが必要}"; shift

BODY="" BODY_FILE="" IS_TEST=false
LABELS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --body-file) BODY_FILE="$2"; shift 2 ;;
    --body)      BODY="$2"; shift 2 ;;
    --label)     LABELS+=("$2"); shift 2 ;;
    --test)      IS_TEST=true; shift ;;
    *) echo "不明な引数: $1" >&2; exit 2 ;;
  esac
done

if $IS_TEST; then
  case "$TITLE" in test:*) ;; *) TITLE="test: $TITLE" ;; esac
  LABELS+=("verify: machine")
  if [ -z "$BODY" ] && [ -z "$BODY_FILE" ]; then
    BODY="#$PARENT の検証用の使い捨て Issue。確認が済んだら close する (merge しない試験 PR の紐づけ先)。"
  fi
fi

# 親の type: ラベルを継承 (明示指定があればそちらが優先)
parent_type=$(gh issue view "$PARENT" -R "$REPO" --json labels --jq '[.labels[].name | select(startswith("type: "))] | first // empty')
if [ -n "$parent_type" ] && ! printf '%s\n' "${LABELS[@]:-}" | grep -q "^type: "; then
  LABELS+=("$parent_type")
fi

args=(--title "$TITLE" -R "$REPO")
[ -n "$BODY_FILE" ] && args+=(--body-file "$BODY_FILE")
[ -n "$BODY" ] && args+=(--body "$BODY")
[ -z "$BODY_FILE" ] && [ -z "$BODY" ] && args+=(--body "")
for l in "${LABELS[@]:-}"; do [ -n "$l" ] && args+=(--label "$l"); done

url=$(gh issue create "${args[@]}")
num="${url##*/}"

child_id=$(gh api "repos/$REPO/issues/$num" --jq .id)
gh api -X POST "repos/$REPO/issues/$PARENT/sub_issues" -F sub_issue_id="$child_id" --jq .number >/dev/null

echo "sub-issue #$num を #$PARENT の下に作成した: $url"
