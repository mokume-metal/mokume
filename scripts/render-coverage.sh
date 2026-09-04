# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 手元の木から「覆い」を判定する (#819)。**git だけで決まるものをここに置く。**
#
# 読み手は 2 つで、以前は片方が**別プロセスを起こして**訊いていた:
#
#   scripts/render-status.sh — 報告を打つ (local / proxy)
#   scripts/catch-up.sh      — 報告先と、覆いがまだ効くかを訊く
#
# `catch-up.sh` は `render-status.sh target` と `render-status.sh coverage` を
# `bash` で起動していた。判定の実体が 1 つである点は正しかったが、そのために CLI に
# 2 つのモードが生えており、`render-status.sh` の口は 4 つになっていた。
#
# ## 境目は「gh の API が要るか」
#
# ここに置くのは**手元の git だけで決まるもの**である。残る側 (`render-status.sh`) は
# tree API・commit status・PR の一覧を引くので、認証が要る:
#
#   ここ                        tree_drawing_fingerprint / local_drawing_fingerprint /
#                               report_target / report_coverage
#   render-status.sh に残る     drawing_fingerprint (tree API) /
#                               covered_fingerprint (status を引く) / post /
#                               report_merge_group
#
# `catch-up.sh` が欲しいのは前者だけなので、この境目がそのまま共有の単位になる。
#
# **照合は drawing-paths.sh が持つ** (`drawing_files`)。このファイルは自分では
# 読み込まない — 二重に読み込んで DRAWING_PATHS の上書きが効かなくなるのを避けるため、
# 読み手が両方を source する (drawing-queue.sh と同じ形)。
#
# 使い方 (source する側):
#   . "$(dirname "${BASH_SOURCE[0]}")/drawing-paths.sh"
#   . "$(dirname "${BASH_SOURCE[0]}")/render-coverage.sh"
#   covers=$(local_drawing_fingerprint)
#   sha=$(report_target)
#   read -r verdict reason <<<"$(report_coverage)"
#
# テストは scripts/tests/render_status_test.py と scripts/tests/catch_up_test.py が、
# それぞれの読み手を通して行う。

# 手元にある木の同じ指紋。**綴りは drawing_fingerprint と一字一句同じでなければ
# ならない** — merge queue はこの値と合流後の木の指紋を突き合わせるので、どちらかの
# 書式が動くと全部の描画 PR が常時弾かれる。tree API が返すのと同じ「path sha」の
# 並びを作るために `--format` を使う (既定の出力はモードと型が混ざり、空白を含む
# パスを引用符で囲む)。
#
# 同じ commit で 2 経路が同じ 12 桁を返すことは実測してある (#612)。
#
# 引数は commit でも木そのものでもよい。`git merge-tree --write-tree` が書いた木を
# そのまま渡せることが要る (#830 の coverage は、queue がこれから組む木の指紋を
# **手元の git だけで**取る)
tree_drawing_fingerprint() {
  git ls-tree -r "$1" --format='%(path) %(objectname)' \
    | drawing_files coverage | sort | shasum -a 256 | cut -c1-12
}

local_drawing_fingerprint() { tree_drawing_fingerprint HEAD; }

# 報告先の commit (#612)。
#
# 既定は HEAD。ただし**手元が「push 済みの head に main を取り込んだだけ」の木**なら、
# その push 済み head へ報告する。
#
# 覆い直しのために push すると、ルールセットの dismiss_stale_reviews_on_push が
# **承認を落とす**。承認が要る描画 PR は、他の PR が入るたびにこれを繰り返すことに
# なっていた (#612)。判定に要るのは「どの木を回したか」だけで、それは description の
# covers= が運ぶので、**head を動かす必要が無い**。
#
# 条件は「**手元の木が、push 済み head から機械的に作り直せるか**」である。作り直せる
# なら remote に無い中身は 1 バイトも無いので、報告先を push 済み head にしても報告と
# その中身は食い違わない。
#
# 作り直せなければ HEAD を返す。その木は remote に無いので、今までどおり「まだ push
# していない」として報告が付かない — 衝突を解いた合流と、手元だけの commit がこれに
# 当たる (どちらも push が要り、承認の押し直しも正しい)。
#
# **比べる相手は「手元が取り込んだ main」で、いま origin/main が指すものではない**
# (#830)。origin/main は ref にすぎず、同じリポジトリを共有する別の worktree が
# fetch しただけで先へ動く。動いた相手と比べていた頃は、`make ci-check` の 9 分間に
# 別の PR が main へ入るだけで素直な取り込みまで「衝突を解いてある」と誤診し、解いた
# 中身が 1 バイトも無い合流を push して承認を落としていた (#612 がそのまま戻る)。
report_target() {
  local head upstream taken automatic
  head=$(git rev-parse HEAD)
  upstream=$(git rev-parse --verify --quiet '@{u}' 2>/dev/null) || upstream=''
  if [ -z "$upstream" ] || [ "$upstream" = "$head" ]; then
    printf '%s' "$head"
    return 0
  fi
  # 手元が取り込んだ main を、控えではなく履歴から取り直す。**main は fast-forward で
  # しか進まない**ので、HEAD に入っているいちばん新しい main の commit は merge-base
  # そのもので、origin/main が先へ動いてもこの値は動かない。
  #
  # 合流の第 2 親 (HEAD^2) では 1 段の合流しか見られない — catch-up は 2 回打たれる
  # ことがあり、そのとき第 1 親は push 済み head ではなく前回の合流 commit になる。
  if ! taken=$(git merge-base HEAD origin/main 2>/dev/null) || [ -z "$taken" ]; then
    printf '%s' "$head"
    return 0
  fi
  # commit の数え方では決まらない — 取り込みは main の commit を丸ごと連れてくるので、
  # 「合流だけか」を履歴の形から判定しようとすると main の commit を数えてしまう
  # (実測)。木そのものを突き合わせる。
  if ! automatic=$(git merge-tree --write-tree "$upstream" "$taken" 2>/dev/null) ||
    [ "$automatic" != "$(git rev-parse "$head^{tree}")" ]; then
    printf '%s' "$head"
    return 0
  fi
  printf '%s' "$upstream"
}

# 手元の実行の覆いが、いまの origin/main で組まれる合流後の姿にまだ効くか (#830)。
#
# push の要否から origin/main を切り離すと (report_target)、**覆いが古くなるかは別の
# 問いとして残る** — queue が組むのは動いた後の origin/main との合流だからである。
# 見ているのは描画に関わるファイルの中身だけなので、動いた main がそこを触っていな
# ければ手元の実行はまだ合流後の姿を覆っている。
#
# 判定は**手元の git だけで付く**。`git merge-tree --write-tree` は組んだ木を手元の
# object DB へ書くので、その木の指紋を tree_drawing_fingerprint がそのまま読める。
#
# 名乗りは 1 行目の 1 語で、fresh / stale / conflict / unknown。**判定できないときは
# 通す** (冒頭の宣言と同じ向き) ので、読めなかった側は unknown で名乗る。
report_coverage() {
  local head base queue_tree
  head=$(git rev-parse HEAD)
  # 覆いが載る先 = 報告先。push した後なら @{u} は HEAD に追いついている
  base=$(git rev-parse --verify --quiet '@{u}' 2>/dev/null) || base=$head
  if ! git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    echo "unknown origin/main を読めない (覆いが古くなるかは見ていない)"
    return 0
  fi
  if git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    echo "fresh main は手元が取り込んだままで動いていない"
    return 0
  fi
  # 衝突していれば queue は合流後の木を作れない。覆いの話ではないので、そちらを先に
  # 名乗る (取り込んで解いて push する、が正しい次の一手になる)
  if ! queue_tree=$(git merge-tree --write-tree "$base" origin/main 2>/dev/null); then
    echo "conflict 動いた main と衝突している"
    return 0
  fi
  if [ "$(tree_drawing_fingerprint "$queue_tree")" = "$(tree_drawing_fingerprint HEAD)" ]; then
    echo "fresh 動いた main は描画に関わるファイルを動かしていない"
  else
    echo "stale 動いた main が描画に関わるファイルを動かした"
  fi
}
