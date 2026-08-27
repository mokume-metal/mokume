#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# リポジトリ内の定義を GitHub のルールセットへ適用する (ADR-0006 / #98)。
#
#   apply-rulesets.sh            差分を見せるだけ (既定)
#   apply-rulesets.sh --apply    実際に適用する
#
# **メンテナが打つ**。エージェントの GitHub App は Administration 権限を持たない
# ため通らない (ADR-0003 決定 1 — 与えると自分を縛るルールセットを外せてしまう)。
#
# 既定を dry-run にしているのは、これが main の保護を書き換える操作だから。
# 定義に無いルールセットの削除はしない (破壊的操作は人の手に残す)。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

REPO="${GITHUB_REPOSITORY:-mokume-metal/mokume}"
DEFS=.github/rulesets

apply=false
case "${1:-}" in
  --apply) apply=true ;;
  "") ;;
  *) echo "使い方: apply-rulesets.sh [--apply]" >&2; exit 2 ;;
esac

# 壊れた定義を GitHub へ送らない
python3 scripts/rulesets_lib.py shape "$DEFS"

live=$(mktemp -d)
trap 'rm -rf "$live"' EXIT

# name → id の対応。id は org ごとに変わるので定義ファイルには持たせず、毎回引く
declare -a names=() ids=()
while IFS=$'\t' read -r name id; do
  [ -n "$name" ] || continue
  names+=("$name")
  ids+=("$id")
  gh api "repos/$REPO/rulesets/$id" > "$live/$id.json"
done < <(gh api "repos/$REPO/rulesets" --jq '.[] | "\(.name)\t\(.id)"')

echo "== 定義と実設定の差分 =="
diff_status=0
python3 scripts/rulesets_lib.py diff "$DEFS" "$live" || diff_status=$?

if [ "$diff_status" -eq 0 ]; then
  echo "適用するものは無い (定義と実設定は一致している)"
  exit 0
fi

if ! $apply; then
  echo
  echo "上の差分を実設定へ反映するには --apply を付けて実行する:"
  echo "  bash scripts/apply-rulesets.sh --apply"
  exit 0
fi

echo
echo "== 適用 =="
for f in "$DEFS"/*.json; do
  name=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$f")
  id=""
  for i in "${!names[@]}"; do
    if [ "${names[$i]}" = "$name" ]; then
      id="${ids[$i]}"
      break
    fi
  done

  if [ -n "$id" ]; then
    gh api -X PUT "repos/$REPO/rulesets/$id" --input "$f" >/dev/null
    echo "更新: $name (id $id)"
  else
    gh api -X POST "repos/$REPO/rulesets" --input "$f" >/dev/null
    echo "作成: $name"
  fi
done

# 定義に無いルールセットが残っていても消さない。存在だけ知らせる
for name in "${names[@]:-}"; do
  [ -n "$name" ] || continue
  if [ ! -f "$DEFS/$name.json" ]; then
    echo "注意: 実設定の $name は定義に無い (このスクリプトは削除しない)" >&2
  fi
done

echo
echo "== 適用後の照合 =="
bash scripts/check-rulesets.sh
