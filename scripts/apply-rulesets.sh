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
#
# **送るのは「手元にチェックアウトされている定義」である** (#425)。古い版のツリーから
# 打つと、main の新しい定義を古い版で上書きする — 誤った緑を読む #311 と入口は同じだが、
# こちらは保護そのものが古い形に戻り、実設定に履歴は無い。だから照合 (名乗るだけ) と違い、
# **手元が古いと判定できたときは --apply を止める**。逃げ道は用意しない。直し方は 1 行で、
# 既定が dry-run である以上、打ち直せば済むからである。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"
DEFS=.github/rulesets

# REPO / DEFS を読むので、代入の後に置く
# shellcheck source=scripts/rulesets-freshness.sh
source scripts/rulesets-freshness.sh

apply=false
case "${1:-}" in
  --apply) apply=true ;;
  "") ;;
  # usage は 64 (sysexits の EX_USAGE) で揃える (#820)
  *) echo "使い方: apply-rulesets.sh [--apply]" >&2; exit 64 ;;
esac

# 壊れた定義を GitHub へ送らない
python3 scripts/rulesets_lib.py shape "$DEFS"

# 差分より先に、これから送る定義がどの版かを言う (#425)。末尾の check-rulesets.sh では
# 遅い — 差分が空なら「適用するものは無い」でそこへ届かず、差分があれば書き込んだ後になる
report_tree_freshness

# 古いツリーからの適用だけは止める。編集中・判定できずは通す — 手元だけが違うのは定義を
# 編集している間の正常な状態で、止めれば押し通すための逃げ道が要る (#425)
if $apply && [ "$RULESET_TREE_FRESHNESS" = stale ]; then
  echo "NG: 手元のツリーが古いまま適用すると、main の定義を古い版で上書きする (#425)" >&2
  exit 1
fi

live=$(mktemp -d)
trap 'rm -rf "$live"' EXIT

# 実設定を引く。引き方は rulesets-freshness.sh が持つ (#820) —
# check-rulesets.sh と同じ 2 段 (一覧 → id ごとに GET) だったので畳んだ。
# **name→id の表は $live/index.tsv に置かれる** (連想配列で返せない理由はあちらの解説)
fetch_live_rulesets "$live" || true

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
  # 表から id を引く。**タブで区切って名前の完全一致を見る** — 名前に空白が入りうる
  id=$(awk -F'\t' -v want="$name" '$1 == want { print $2 }' "$live/index.tsv")

  if [ -n "$id" ]; then
    gh api -X PUT "repos/$REPO/rulesets/$id" --input "$f" >/dev/null
    echo "更新: $name (id $id)"
  else
    gh api -X POST "repos/$REPO/rulesets" --input "$f" >/dev/null
    echo "作成: $name"
  fi
done

# 定義に無いルールセットが残っていても消さない。存在だけ知らせる
while IFS=$'\t' read -r name _; do
  [ -n "$name" ] || continue
  if [ ! -f "$DEFS/$name.json" ]; then
    echo "注意: 実設定の $name は定義に無い (このスクリプトは削除しない)" >&2
  fi
done < "$live/index.tsv"

echo
echo "== 適用後の照合 =="
bash scripts/check-rulesets.sh
