#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ブランチ保護のルールセットが、リポジトリ内の定義どおりかを検査する (ADR-0006 / #98)。
#
#   check-rulesets.sh --shape   定義ファイルの形だけを見る (token 不要。make ci-check から)
#   check-rulesets.sh           定義と GitHub 側の実設定を照合する (gh の認証が要る)
#   check-rulesets.sh --without-bypass-actors
#                               bypass_actors を読めない認証で残りを照合する (CI 用)
#
# 二段に分けているのは、ルールセットの状態が PR の内容と独立に変わるため。
# PR ごとに実設定を照合しても意味が薄く、fork からの PR には token も渡らない。
# 実設定との照合は定期実行 (.github/workflows/ruleset-drift.yml) と手元で回す。
#
# bypass_actors は ruleset への write access がある認証にしか返らない (#99 で実測)。
# CI の GITHUB_TOKEN では読めないので、そこだけは --without-bypass-actors で
# 「見ていない」と名乗った上で残りを照合する。メンテナが手元で引数なしに打つと、
# 読めなければ赤になる厳格な照合になる。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

REPO="${GITHUB_REPOSITORY:-mokume-metal/mokume}"
DEFS=.github/rulesets

mode=live
diff_flags=()
case "${1:-}" in
  --shape) mode=shape ;;
  --without-bypass-actors) diff_flags+=("--without-bypass-actors") ;;
  "") ;;
  *) echo "使い方: check-rulesets.sh [--shape | --without-bypass-actors]" >&2; exit 2 ;;
esac

# 形が壊れていれば実設定を見るまでもない
python3 scripts/rulesets_lib.py shape "$DEFS"
# set -e の下では `[ ... ] && exit 0` が偽になった時点でスクリプトごと終わる。
# 条件分岐で書く
if [ "$mode" = shape ]; then
  exit 0
fi

# 実設定を 1 本ずつ引く。一覧の応答には rules も bypass_actors も含まれないため、
# id を取ってから個別に GET する必要がある。
live=$(mktemp -d)
trap 'rm -rf "$live"' EXIT

ids=$(gh api "repos/$REPO/rulesets" --jq '.[].id')
if [ -z "$ids" ]; then
  echo "NG: $REPO にルールセットが 1 つも無い (定義はあるが未適用)" >&2
  exit 1
fi
for id in $ids; do
  gh api "repos/$REPO/rulesets/$id" > "$live/$id.json"
done

python3 scripts/rulesets_lib.py diff "$DEFS" "$live" "${diff_flags[@]+"${diff_flags[@]}"}"
