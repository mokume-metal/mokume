# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ワイヤフォーマットの正典 (Schemas/*.schema.json) と、その代表例
# (Schemas/examples/) が食い違っていないかを見る (ADR-0018 決定 4)。
#
# 例の名前は <スキーマ名>.json か <スキーマ名>-<変種>.json とする。
# 対応が曖昧になる名前 (2 つのスキーマに掛かる) はここで落とす — 検査が
# 「どちらで検証したか」を推測し始めると、通っていることの意味が薄れる。
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEMA_DIR=Schemas
EXAMPLE_DIR=Schemas/examples

if ! command -v check-jsonschema >/dev/null 2>&1; then
  echo "check-jsonschema が見つからない: pipx install check-jsonschema" >&2
  exit 1
fi

status=0
pairs=$(mktemp)
trap 'rm -f "$pairs"' EXIT

for schema in "$SCHEMA_DIR"/*.schema.json; do
  [ -e "$schema" ] || continue
  base=$(basename "$schema" .schema.json)
  found=0
  for example in "$EXAMPLE_DIR/$base".json "$EXAMPLE_DIR/$base"-*.json; do
    [ -e "$example" ] || continue
    found=1
    printf '%s\t%s\n' "$example" "$schema" >> "$pairs"
    if check-jsonschema --schemafile "$schema" "$example" >/dev/null; then
      echo "ok: $example ← $(basename "$schema")"
    else
      # 失敗の詳細をもう一度出す (上は静かに走らせている)
      check-jsonschema --schemafile "$schema" "$example" || true
      status=1
    fi
  done
  if [ "$found" -eq 0 ]; then
    echo "例が 1 つも無いスキーマ: $schema" >&2
    echo "  $EXAMPLE_DIR/$base.json を置く (正典だけあって代表例が無い状態を許さない)" >&2
    status=1
  fi
done

# 孤児 (どのスキーマにも掛からない例) と、曖昧 (複数に掛かる例) を見る
for example in "$EXAMPLE_DIR"/*.json; do
  [ -e "$example" ] || continue
  hits=$(awk -F'\t' -v e="$example" '$1 == e' "$pairs" | wc -l | tr -d ' ')
  if [ "$hits" -eq 0 ]; then
    echo "どのスキーマにも掛からない例: $example" >&2
    echo "  <スキーマ名>.json か <スキーマ名>-<変種>.json に直す" >&2
    status=1
  elif [ "$hits" -gt 1 ]; then
    echo "複数のスキーマに掛かる例: $example" >&2
    awk -F'\t' -v e="$example" '$1 == e { print "  " $2 }' "$pairs" >&2
    status=1
  fi
done

exit "$status"
