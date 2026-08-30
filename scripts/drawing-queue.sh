# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 描画 PR の**順番**の判定 (#467)。読み手が 2 つになったので、判定の実体をここへ
# 置く (ADR-0001 原則 9。パスの一覧を scripts/drawing-paths.sh に 1 つだけ置くのと
# 同じ理由で、順番の規則も 1 つに保つ):
#
#   - scripts/render-status.sh — 順番でない PR を CI で赤くする
#   - scripts/catch-up.sh      — 順番でないうちは打ち直しても無駄なので走らない (#457)
#
# 使い方:
#   . "$(dirname "${BASH_SOURCE[0]}")/drawing-queue.sh"
#   ahead=$(ahead_drawing_pr "$repo" "$number")
#
# 判定に要る touches_drawing は drawing-paths.sh が持つ。読み込む側が両方を source
# する (このファイルは source されるだけで、自分では読み込まない — 二重に読み込んで
# DRAWING_PATHS の上書きが効かなくなるのを避ける)。

# 描画 PR の順番 (#467)。
#
# 上の判定 (#435) は「手元で回した木と合流後の木が、描画に関わる範囲で同じ」ことを
# 要求する。裏を返すとこれは「手元で make ci-check を打ってから自分が merge される
# までの間に、描画に触れる変更が 1 つも入らないこと」の要求で、**描画 PR が 2 本
# 並走すると、片方が入るたびにもう片方が弾かれる**。追いついた頃にはまた動いており、
# 収束を保証するものが無かった (#456 は 3 回続けて弾かれ、#470 もその後に続いた)。
#
# 収束の条件は 2 つある — (1) 自分が main に追随していること と (2) 自分が merge
# されるまで他の描画 PR が入らないこと。(1) は自分で制御できるが (2) はできない。
# そこで **描画 PR に番号順の順番を作る**。GitHub の番号は単調増加なので「後から
# 自分より先頭が生まれる」ことがなく、先頭が merge されれば次に若い PR が先頭に
# なる。よって各描画 PR の打ち直しは **1 回**に収束する。
#
# **再評価の契機は足さない。** 打ち直しは必ず main を取り込んで push するので、
# pull_request の synchronize でこの判定がそのまま回り直す。
#
# **Draft は順番の外**に置く — merge を待っていないものが先頭に居座ると、後続が
# 動く理由の無い赤で止まる。先頭が停滞したときの逃がしもこれである (AGENTS.md)。
#
# 標準出力に返すもの:
#   <番号>  自分より先に居る描画 PR
#   (空)    自分が先頭
#   draft   自分が Draft (順番の外)
#   ?       判定できなかった
#
# **判定できないときは通す。** 防いでいるのは事故であって偽装ではない (冒頭の宣言)。
ahead_drawing_pr() {
  local repo=$1 number=$2 open n files self=''
  # draft の除外だけ API 側で済ませ、番号の順序は手元で見る (作り物の gh を通した
  # 検査が、順序の判定そのものを踏むようにするため)
  open=$(gh api "repos/$repo/pulls?state=open&per_page=100" --paginate \
    --jq '.[] | select(.draft | not) | .number' | sort -n) || { printf '?'; return 0; }

  # 自分が一覧に居なければ Draft である (同じ 1 回の応答から読む)
  for n in $open; do
    if [ "$n" = "$number" ]; then self=1; fi
  done
  [ -n "$self" ] || { printf 'draft'; return 0; }

  for n in $open; do
    [ "$n" -lt "$number" ] || continue
    if ! files=$(gh api "repos/$repo/pulls/$n/files" --paginate --jq '.[].filename'); then
      printf '?'
      return 0
    fi
    if printf '%s\n' "$files" | touches_drawing; then
      printf '%s' "$n"
      return 0
    fi
  done
  return 0
}
