# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ルールセットの定義を読む道具が、「どの版の定義を読んでいるか」を名乗るための
# library (#311 / #425)。`source scripts/rulesets-freshness.sh` して使う。
#
# 照合も適用も、見ているのは **手元にチェックアウトされている定義** である。だから
# 古い版のツリーから打つと、照合は古い定義と古い実設定を突き合わせて緑になり (#311)、
# 適用は main の新しい定義を古い版で上書きする (#425)。しかも手元が古い可能性が最も
# 高いのは merge 直後、つまりこれらの道具を打ちたい瞬間である。
#
# **判定と、判定を受けてどうするかは分ける。** この library は名乗るところまでを持ち、
# 常に 0 で返る。止めるかどうかは呼び手が RULESET_TREE_FRESHNESS を見て決める —
# 照合は名乗るだけ、適用は stale のときだけ止める。同じ判定に別の重みを与えたいのは
# 読むのと書くのとで代償が違うからで、判定そのものを分ける理由は無い。
set -euo pipefail

# 呼び出し後の判定。呼び手はこれを見て、止めるかどうかを決める
#   same    手元の定義は main と同じ
#   stale   手元のツリーが古い (main の定義変更を HEAD が含んでいない)
#   editing 手元の定義が main にまだ入っていない (定義を編集中とみられる)
#   unknown 材料を引けず、どちらとも判定していない
RULESET_TREE_FRESHNESS=unknown

# 手元の定義が正典 (main) と同じかを名乗る (#311)。判定は 2 段で、片方だけだと誤検知する:
#
#   1. 中身  contents API の blob SHA と git hash-object を突き合わせ、違うかを決める
#   2. 向き  main で最後に定義を変えたコミットを HEAD が含むかで、古いか編集中かを分ける
#
# 段 2 だけでは、main が定義を触った後に切った作業ブランチや CI の shallow clone を
# 「古い」と誤って言う。段 1 が一致していればそこへ進まないので、そちらを先に置く。
#
# **この関数は赤にしない。** 定義を編集している最中の作業ブランチでは「手元だけが違う」
# のが正常な状態で、そこで止めると邪魔になる (#311 の打ち手案)。名乗るだけに留める。
report_tree_freshness() {
  local main_list="" main_names=" " differing="" name sha local_sha last f

  RULESET_TREE_FRESHNESS=unknown

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

  if [ -z "$differing" ]; then
    RULESET_TREE_FRESHNESS=same
    return 0
  fi

  last=$(gh api "repos/$REPO/commits?path=$DEFS&sha=main&per_page=1" \
      --jq '.[0].sha // empty' 2>/dev/null) || last=""

  {
    if [ -z "$last" ]; then
      echo "注意: 手元の定義は main と違うが、どちら向きの違いかは判定していない" \
        "(main の履歴を引けなかった)"
    elif git merge-base --is-ancestor "$last" HEAD 2>/dev/null; then
      RULESET_TREE_FRESHNESS=editing
      echo "注意: 手元の定義は main にまだ入っていない (定義を編集中とみられる)。"
      echo "      以下は手元の版についての結果である。"
    else
      RULESET_TREE_FRESHNESS=stale
      echo "注意: 手元のツリーは古い — main の定義変更 ${last:0:7} を含んでいない。"
      echo "      読んでいるのは手元の定義なので、実設定が最新の定義に追いついて"
      echo "      いるかは、これでは分からない (#311)。"
      echo "      最新の定義で見るには: git fetch origin main && git checkout origin/main"
    fi
    echo "      main と違う定義:$differing"
  } >&2
}
