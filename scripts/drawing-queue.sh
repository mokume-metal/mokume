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
# 判定に要る touches_drawing は drawing-paths.sh が持ち、変更ファイルの取り方は
# pr-files.sh が持つ (#793)。訊く問いは coverage の側で、
# 順番の理由 (下記) がそのまま覆いの判定だからである — 覆いを壊さない場所は、行列に
# 並ぶ理由も持たない (#497)。読み込む側が両方を source
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
#
# ## queue に居る描画 PR は番号より先に数える (#1266)
#
# 番号順だけで決めていた頃は、merge queue の並び (入れた順) と食い違うと互いを待って
# 止まった。queue の中で後ろに居る描画 PR は、前に居る描画 PR の変更が合流後の木に
# 入るので、**番号に関係なく覆いを満たせない**。2026-09-15 には queue の前に #1243 が
# 居る間、#1242 は番号順の先頭として打ち直しては弾かれ、#1243 は「#1242 を待て」と
# 言われていた — どちらも規約どおりに動いていて、どちらも進まなかった。
#
# そこで順番を 1 本にする — **queue に居る描画 PR が position の順に先、その外は
# 番号順**。queue の中の描画 PR は通るか弾かれて外へ出るかのどちらかで、外へ出れば
# 番号順に戻るので、上の収束の議論はそのまま効く。誰かを queue から外す手は要らない。
#
# **queue を読めなかったときは番号順だけで決める。** 「判定できない」へ倒すと CI の
# 順番待ちまで外れるので、以前の振る舞いを劣化時の姿として残す。
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

  # 自分が queue に居て前に描画 PR が居なければ、queue の外の番号は数えない — 数えると
  # 番号の若い外の PR を待ちながら、その PR は queue に居る自分に弾かれ続ける
  if n=$(queued_drawing_ahead "$repo" "$number") && [ -n "$n" ]; then
    [ "$n" = self ] || printf '%s' "$n"
    return 0
  fi

  for n in $open; do
    [ "$n" -lt "$number" ] || continue
    if ! files=$(pr_files "$repo" "$n"); then
      printf '?'
      return 0
    fi
    if printf '%s\n' "$files" | touches_drawing coverage; then
      printf '%s' "$n"
      return 0
    fi
  done
  return 0
}

# merge queue で自分より前に居る描画 PR のうち、先頭の番号 (#1266)。
#
# 自分が queue に居なければ queue 全体が前に居る。標準出力に返すもの:
#   <番号>  前に居る描画 PR
#   self    自分が queue に居て、前に描画 PR が居ない (queue の外は数えなくてよい)
#   (空)    自分は queue に居らず、queue に描画 PR も居ない
# 読めなかったときは 1 で終える (呼ぶ側が番号順へ落ちるか、名乗りを変えずに済ませる)。
#
# merge_group の判定 (render-status.sh) もこれを直に呼ぶ — 弾いた PR の前に描画 PR が
# 居れば、打ち直しても同じ理由でまた弾かれるので、名乗りを変える必要がある。
queued_drawing_ahead() {
  local repo=$1 number=$2 queued n files
  # GraphQL の $owner / $name はサーバ側の変数なので、展開させない
  # shellcheck disable=SC2016
  queued=$(gh api graphql -f owner="${repo%%/*}" -f name="${repo##*/}" \
    -f query='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){
      mergeQueue{entries(first:100){nodes{position pullRequest{number}}}}}}' \
    --jq '.data.repository.mergeQueue.entries.nodes // [] | sort_by(.position)[] | .pullRequest.number') \
    || return 1

  for n in $queued; do
    [ "$n" != "$number" ] || { printf 'self'; return 0; }
    files=$(pr_files "$repo" "$n") || return 1
    if printf '%s\n' "$files" | touches_drawing coverage; then
      printf '%s' "$n"
      return 0
    fi
  done
  return 0
}
