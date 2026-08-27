#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 新規 Issue のトリアージ下書き (#78)。起票時には何も要求せず、分類は機械が
# 下書きする (ADR-0002 決定 1)。「何の仕事か」は Issue Type で表す (ADR-0004)。
#
#   triage.sh <Issue 番号> <タイトル>
#
# 判断は二つ:
#   1. 型が既に付いていれば触らない — テンプレートや sub-issue.sh の明示指定は
#      タイトルからの推定より確かなので、後から上書きしない
#   2. タイトルの Conventional Commits prefix から型を推定する。推定できなければ
#      無分類のままにする (推定できないものを機械が埋めない — ADR-0004 決定 5)
#
# ラベルは付けない。トリアージが済んだかは verify: の有無が表す (ADR-0002 決定 1)。
# かつては status: needs-triage も付けていたが、verify: の不在の写しでしかなく、
# 付与に失敗した Issue が未トリアージの検索から漏れて危険側に倒れたため廃止した
# (#156)。付けない側に倒れれば、取りこぼしはそのまま「着手できない」になる。
#
# 呼び出しは .github/workflows/triage.yml、検査は scripts/tests/triage_test.py。
# ロジックを YAML に埋めないのは、issues イベントの workflow が既定ブランチの
# ものしか走らず、ブランチ上で確かめられないため (#66 で確認した性質)。
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-mokume-metal/mokume}"

NUM="${1:?Issue 番号が必要}"
TITLE="${2:?タイトルが必要}"

current_type=$(gh issue view "$NUM" -R "$REPO" --json issueType --jq '.issueType.name // empty')
if [ -n "$current_type" ]; then
  echo "triage: 型は既に $current_type — 上書きしない"
  exit 0
fi

case "$TITLE" in
  "fix:"*|"fix("*)       type="Bug" ;;
  "feat:"*|"feat("*)     type="Feature" ;;
  "docs:"*|"docs("*)     type="Docs" ;;
  "design:"*|"design("*) type="Design" ;;
  "chore:"*|"chore("*|"ci:"*|"ci("*|"build:"*|"build("*|\
  "refactor:"*|"refactor("*|"test:"*|"test("*|"perf:"*|"perf("*) type="Task" ;;
  *) type="" ;;
esac

if [ -z "$type" ]; then
  echo "triage: タイトルから型を推定できなかった — トリアージで人が決める"
  exit 0
fi

# 失敗を握り潰さない。org の型と ADR-0004 の表がずれたら、ここが最初に鳴る
if ! gh issue edit "$NUM" -R "$REPO" --type "$type" >/dev/null; then
  echo "triage: 型 \"$type\" を付けられなかった" >&2
  echo "次にすること: org の Issue Type に \"$type\" があるか確かめる (正典は ADR-0004 決定 2 の 5 型)。無ければメンテナが Settings > Planning > Issue types で作る" >&2
  exit 1
fi
echo "triage: 型 $type を付けた"
