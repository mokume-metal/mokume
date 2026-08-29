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
#
# **照合するのは「手元にチェックアウトされている定義」と実設定である** (#311)。
# だから古い版のツリーから打つと、古い定義と古い実設定が一致して緑になる —
# 適用したかを確かめるための道具が、適用していないことを緑で答える。しかも手元が
# 古い可能性が最も高いのは merge 直後、つまりこの道具を打ちたい瞬間である。
# 照合の前に、その結果がどの版についてのものかを名乗る (report_tree_freshness)。
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

# 手元の定義が正典 (main) と同じかを名乗る (#311)。判定は 2 段で、片方だけだと誤検知する:
#
#   1. 中身  contents API の blob SHA と git hash-object を突き合わせ、違うかを決める
#   2. 向き  main で最後に定義を変えたコミットを HEAD が含むかで、古いか編集中かを分ける
#
# 段 2 だけでは、main が定義を触った後に切った作業ブランチや CI の shallow clone を
# 「古い」と誤って言う。段 1 が一致していればそこへ進まないので、そちらを先に置く。
#
# **赤にはしない。** 定義を編集している最中の作業ブランチでは「手元だけが違う」のが
# 正常な状態で、そこで止めると邪魔になる (#311 の打ち手案)。名乗るだけに留める。
report_tree_freshness() {
  local main_list="" main_names=" " differing="" name sha local_sha last f

  if ! main_list=$(gh api "repos/$REPO/contents/$DEFS?ref=main" \
      --jq '.[] | select(.type == "file") | "\(.name)\t\(.sha)"' 2>/dev/null); then
    echo "注意: main の定義を引けず、手元のツリーが正典と同じかは確かめていない" >&2
    return 0
  fi

  while IFS=$'\t' read -r name sha; do
    [ -n "$name" ] || continue
    main_names="$main_names$name "
    local_sha=""
    [ ! -f "$DEFS/$name" ] || local_sha=$(git hash-object "$DEFS/$name")
    [ "$local_sha" = "$sha" ] || differing="$differing $name"
  done <<< "$main_list"

  # main に無いのに手元にあるものも「違い」— 定義を足している最中がこれにあたる
  for f in "$DEFS"/*.json; do
    name=$(basename "$f")
    case "$main_names" in *" $name "*) ;; *) differing="$differing $name" ;; esac
  done

  [ -n "$differing" ] || return 0

  last=$(gh api "repos/$REPO/commits?path=$DEFS&sha=main&per_page=1" \
      --jq '.[0].sha // empty' 2>/dev/null) || last=""

  {
    if [ -z "$last" ]; then
      echo "注意: 手元の定義は main と違うが、どちら向きの違いかは判定していない" \
        "(main の履歴を引けなかった)"
    elif git merge-base --is-ancestor "$last" HEAD 2>/dev/null; then
      echo "注意: 手元の定義は main にまだ入っていない (定義を編集中とみられる)。"
      echo "      下の照合は手元の版についての結果である。"
    else
      echo "注意: 手元のツリーは古い — main の定義変更 ${last:0:7} を含んでいない。"
      echo "      下の照合は古い定義と実設定を突き合わせるので、一致と出ても"
      echo "      「実設定が最新の定義に追いついている」ことは意味しない (#311)。"
      echo "      最新の定義で見るには: git fetch origin main && git checkout origin/main"
    fi
    echo "      main と違う定義:$differing"
  } >&2
}

# 形が壊れていれば実設定を見るまでもない
python3 scripts/rulesets_lib.py shape "$DEFS"
# set -e の下では `[ ... ] && exit 0` が偽になった時点でスクリプトごと終わる。
# 条件分岐で書く
if [ "$mode" = shape ]; then
  exit 0
fi

# 結果より先に、その結果がどの版についてのものかを言う (#311)
report_tree_freshness

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
