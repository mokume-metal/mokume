#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# merge queue から弾かれた描画 PR を、1 手で queue へ戻す (#457)。
#
# 描画のパスに触れる PR は、queue で待つ間に別の描画 PR が main へ入ると
# `local-render` が failure に転んで弾かれる。手元で実際に回した木が、queue の見る
# 合流後の木を覆えなくなるためで、機構としては正しい (#435 が塞いだ事故を事前に
# 止めている)。
#
# 困るのは**復旧に手数がある**ことである。1 手でも抜けると PR は全チェック緑・
# mergeStateStatus は CLEAN のまま止まり、外から見て異常に見えない。赤を見張る
# 仕掛けは何も言わない。**#533 では当時の 5 手のうち 4 手までやって最後が抜けた** —
# AGENTS.md に正しく書かれている手順を読み落として、である。
#
#   1. git merge origin/main
#   2. make ci-check          # 覆い直した報告は、この中の render-status が打つ
#   3. gh pr merge --auto --squash  # 弾かれた拍子に外れた auto-merge を掛け直す
#
# **取り込みは手元だけで済ませ、push しない** (#612)。push するとルールセットの
# dismiss_stale_reviews_on_push が承認を落とすので、承認が要る描画 PR は他の PR が
# 入るたびに押し直しになっていた。覆いの判定に要るのは「どの木を回したか」だけで、
# それは local-render の covers= が運ぶ (scripts/render-status.sh)。
#
# 例外は**衝突を解いた合流**で、そのときだけ push する — 解いた中身は remote に
# 無いので、queue も同じ木を作れない。中身が本当に変わるので、承認のやり直しは正しい。
#
# ## 使い方
#
#   bash scripts/catch-up.sh        # = make catch-up
#
# ## 終了コード
#
#   0  queue へ戻した
#   3  打つ意味が無い (描画に触れない / 先に描画 PR が居る / Draft)。**待つのが正解**
#   1  途中で止まった (衝突・検査の失敗・報告が付かない)。直してから打ち直す
#
# 3 を 1 と分けるのは、「待て」と「壊れている」を取り違えないためである。
# **入口の `make catch-up` は 3 を成功に均す** (#786) — 終了コードを読まない人にとって
# 「待て」は正常な結果で、赤で返すと取り違えを入口で作り直してしまうためである。
# 区別が要る呼び手のために、契約そのものはここで 0 / 1 / 3 のまま保つ。
# (review-gate.sh も承認待ちを 20 で分けていた。ADR-0031 がラベル由来の承認を畳んで
#  待つ状態そのものが無くなり、あちらの終了コードは 0・1 に戻っている — #618。
#  分ける理由がここでは生きているのは、待ちが**人の承認ではなく他の PR の merge**
#  だからである)
#
# ## やらないこと
#
# **弾かれた後の自動復旧そのもの。** 合流後の木を覆い直すには手元で実際に絵を回す
# 必要があり、CI にはできない (#180・ADR-0019 決定 7)。この道具がやるのは「人が
# 打ち直すと決めた後」を取りこぼさないところまでである。
set -euo pipefail

# 「描画に触れているか」の判定 (照合の実体は 1 つ)
# shellcheck source=scripts/drawing-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/drawing-paths.sh"
# 変更ファイルの取り方 (#793)。drawing-queue.sh も使うが、あちらは自分で読み込まない
# ので読み手が source する (drawing-paths.sh とまったく同じ形)
# shellcheck source=scripts/pr-files.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-files.sh"
# 描画 PR の順番の判定 (render-status.sh と共有する)
# shellcheck source=scripts/drawing-queue.sh
. "$(dirname "${BASH_SOURCE[0]}")/drawing-queue.sh"
# 報告の context の綴り。**探す側だけが直書きだと、打つ側の改名に付いていけない** (#785)
# shellcheck source=scripts/render-context.sh
. "$(dirname "${BASH_SOURCE[0]}")/render-context.sh"

readonly SKIPPED=3

say() { echo "catch-up: $*"; }

stop() {
  echo "catch-up: 止まった — $1" >&2
  [ $# -lt 2 ] || echo "次にすること: $2" >&2
  exit 1
}

skip() {
  say "打つ意味が無い — $1"
  exit "$SKIPPED"
}

# --- 1. 打てる状態か -------------------------------------------------------

command -v gh >/dev/null 2>&1 || stop "gh が無い" "brew install gh"
gh auth status >/dev/null 2>&1 || stop "gh が認証されていない" "gh auth login"

# **本人の認証でなければ commit status を打てない。** App の installation token を
# 掴んだシェルから打つと、`gh api /statuses` が 403 で弾かれる。render-status.sh は
# 報告できなくても失敗しない設計 (最頻の理由が「まだ push していない」で、それは
# 作業の途中というだけ) なので、気付かないまま先へ進んでしまう — #533 で踏んだ。
# /user は installation token では通らないので、ここで安く分けられる。
gh api user --jq '.login' >/dev/null 2>&1 || stop \
  "いまの認証では $RENDER_CONTEXT を打てない (App の installation token を掴んでいる)" \
  "GH_TOKEN を外して打ち直す — 手元の報告は本人の認証でしか付かない"

git rev-parse --git-dir >/dev/null 2>&1 || stop "git リポジトリの中で打つ"
# 汚れた木で make ci-check を回しても、報告は HEAD に付いて中身と食い違う
[ -z "$(git status --porcelain)" ] || stop "作業ツリーが汚れている" \
  "commit するか片付けてから打ち直す"

# --- 2. 打つ意味があるか ---------------------------------------------------

info=$(gh pr view --json number,state,isDraft --jq '"\(.number) \(.state) \(.isDraft)"') \
  || stop "この枝に PR が無い" "先に PR を作る"
read -r number state draft <<<"$info"

[ "$state" = OPEN ] || skip "PR #$number が OPEN でない ($state)"
[ "$draft" != true ] || skip "PR #$number は Draft — 順番の外なので queue へ入れられない"

repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner') \
  || stop "対象リポジトリを読めなかった"

# 描画に触れない PR は合流後の木を動かさないので、BEHIND のまま merge できる。
# 取り込みは queue がこれからやることの前借りにしかならない (AGENTS.md)
pr_files "$repo" "$number" | touches_drawing coverage \
  || skip "PR #$number は台帳の絵を動かさない — main を取り込む必要が無い"

# 描画 PR は番号順に 1 本ずつ。順番でないうちに打ち直しても、先頭が入った時点で
# また覆えなくなる (AGENTS.md「描画に影響する変更」の表の 2 行目)。make ci-check は
# 数分かかるので、ここで断るのと断らないのとでその数分が変わる
ahead=$(ahead_drawing_pr "$repo" "$number")
case "$ahead" in
  '?') say "先に居る描画 PR を読めなかった (順番は見ていない — そのまま進む)" ;;
  draft) skip "PR #$number は Draft — 順番の外" ;;
  '') say "PR #$number が描画の先頭" ;;
  *) skip "先に #$ahead が居る — いま打ち直しても、#$ahead が入った時点でまた覆えなくなる" ;;
esac

# --- 3. 合流後の姿を覆い直す -----------------------------------------------

git fetch -q origin || stop "origin を引けなかった"

if git merge-base --is-ancestor origin/main HEAD; then
  say "main は取り込み済み"
else
  say "main を取り込む"
  # **衝突しても中止しない。** git merge --abort で畳むと、解くべき中身が消えて
  # 「何が衝突したのか」を見る機会まで失われる。木は git status が持っている
  git merge --no-edit origin/main \
    || stop "main の取り込みで衝突した" "衝突を解いて commit してから打ち直す"
fi

say "make ci-check を回す (絵の検査を含むので数分かかる)"
make ci-check || stop "make ci-check が通らなかった" "上の出力の失敗を直してから打ち直す"

# **素直な取り込みなら push しない** (#612)。push するとルールセットの
# dismiss_stale_reviews_on_push が承認を落とし、承認が要る描画 PR は他の PR が
# 入るたびに押し直しになる。判定に要るのは「どの木を回したか」だけで、それは
# local-render の covers= が運ぶので、head を動かす必要が無い。
#
# **push の要否をここで判定し直さない。** 報告先を決めるのと同じ問いなので、
# render-status へ訊く (ADR-0001 原則 9)。HEAD が返るのは「push しないと誰も
# 見られない木」— 衝突を解いた合流がこれに当たる
sha=$(bash "$(dirname "${BASH_SOURCE[0]}")/render-status.sh" target)
if [ "$sha" = "$(git rev-parse '@{u}')" ]; then
  say "手元の木は queue が組む木と同じ — push しない (承認は落ちない・#612)"
else
  say "手元の木は queue が組む木と違う (衝突を解いてある) — push する"
  say "承認済みなら押し直しが要る — 入る中身が変わるため"
  git push || stop "push できなかった"
  # ci-check の最後の報告は、その時点で commit が remote に無いので届かなかった。
  # 同じ記録から打ち直す
  make render-status
fi

# --- 4. 報告が実際に付いたことを確かめる -----------------------------------

# **確かめてから戻す。** render-status は報告できなくても 0 で終えるので、確かめずに
# 進むと弾かれた状態のまま queue へ入り、同じことをもう一度繰り返すことになる
#
# 綴りは打つ側と同じ出どころから取る (#785)。gh api に --arg は無いので、フィルタへ
# シェルが展開する (render-status.sh の covered_fingerprint と同じ形)
reported=$(gh api "repos/$repo/commits/$sha/statuses" \
  --jq "map(select(.context == \"$RENDER_CONTEXT\")) | first | .state // \"無い\"") \
  || stop "$RENDER_CONTEXT の状態を読めなかった"
[ "$reported" = success ] || stop \
  "$RENDER_CONTEXT が $reported のまま — このまま戻しても弾かれる" \
  "make render-status の出力に、報告できなかった理由が出ている"

# --- 5. queue へ戻す -------------------------------------------------------

gh pr merge "$number" --auto --squash || stop "queue へ戻せなかった"

# **確認は isInMergeQueue で行う。** queue に載った後は autoMergeRequest が null に
# なるのが正常で、そこだけ見ると「外れたまま」に読める (#457 で実際に取り違えた)
# GraphQL の $owner / $number はサーバ側の変数なので、展開させない
# shellcheck disable=SC2016
entry=$(gh api graphql \
  -f owner="${repo%%/*}" -f name="${repo##*/}" -F number="$number" \
  -f query='query($owner:String!,$name:String!,$number:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$number){ isInMergeQueue mergeQueueEntry{ position state } }}}' \
  --jq '.data.repository.pullRequest
        | "isInMergeQueue=\(.isInMergeQueue) position=\(.mergeQueueEntry.position // "-") state=\(.mergeQueueEntry.state // "-")"') \
  || entry='(読めなかった)'

say "PR #$number を queue へ戻した — $entry"
say "autoMergeRequest が null になるのは正常 (queue に載った後は queue が持つ)"
