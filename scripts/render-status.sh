#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 描画の検査が走ったことを local-render として commit status に報告する (#304)。
#
# CI はこの世代のコマンド構造を持たない GPU の上で動くので、絵を作る検査を 1 本も
# 走らせられない (#180・ADR-0019 決定 7 で恒久の決定)。走らせられるのは手元だけで、
# 走らせたかどうかを GitHub が知る経路がこれまで無かった — 打ち忘れた PR が緑で
# 通っていた。
#
# そこで **報告する主体を Actions ではなく手元の実行**にする。check run ではなく
# commit status を選ぶのは #282 と同じ理由 (suite に縛られず、同じ context の最新が
# 常に勝つ)。
#
# ## 使い方
#
#   bash scripts/render-status.sh local   # make ci-check の最後。全検査が通ったときだけ打つ
#   bash scripts/render-status.sh proxy   # CI から。打たなくてよい場合の代理報告だけ
#   bash scripts/render-status.sh target  # 報告先の commit を出すだけ (catch-up が push の要否を訊く)
#
# ## 何を防いでいるか
#
# 防いでいるのは**打ち忘れ**であって、意図的な偽装ではない。status の 1 行は手でも
# 打てる。偽装はまだ起きていないので、いまは対象にしない (ADR-0008 決定 1)。
#
# どちらのモードも**失敗しない** — 報告しない理由を述べて 0 で終える。報告が無い
# ことは GitHub 側で「必須チェックの待ち」として現れるので、ここで赤くする必要が無い。
#
# 例外は merge queue の判定 (#435) で、そこでは **status を failure で打つ**。待たせて
# 済ませられないためである — 打たずに待たせると queue は check_response_timeout_minutes
# (60 分) を空費してから諦め、しかも理由がどこにも残らない。スクリプト自身は 0 で終える
# (赤くするのは Actions の run ではなく local-render という報告の側である)。
#
# その failure は **queue のコミットと、覆えていない PR の head の両方**に打つ (#462)。
# queue のコミットだけに打っていた頃は、gh pr checks にもタイムラインにも現れず、
# 弾かれたことに気付く経路が人間しか無かった。**head へ打つのは failure だけ**である。
set -euo pipefail

# 「描画に触れているか」の判定は #306 と共有する (照合の実体は 1 つ)。**訊く問いは
# coverage の側**である — 手元の実行の覆いが壊れるか、で、絵の証跡を要求するかとは
# 答えが違う場所がある (#497)
# shellcheck source=scripts/drawing-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/drawing-paths.sh"
# 描画 PR の順番の判定も catch-up.sh と共有する (#457)
# shellcheck source=scripts/drawing-queue.sh
. "$(dirname "${BASH_SOURCE[0]}")/drawing-queue.sh"
# 報告の context の綴りも catch-up.sh と共有する。**打つ側と探す側で割れると、覆いが
# 永久に見つからない** — 割れ方は render-context.sh の冒頭が持つ (#785)
# shellcheck source=scripts/render-context.sh
. "$(dirname "${BASH_SOURCE[0]}")/render-context.sh"

# scene-ledger の suite 名。**この名前が走って通ったこと**を、GPU のある機械で
# 全検査が回った証拠として使う (SceneLedgerTests.swift の @Suite 名と一致させる)。
readonly LEDGER_SUITE='代表シーンの台帳'

TEST_LOG=${RENDER_TEST_LOG:-.build/test-log.txt}
LEDGER=${RENDER_LEDGER:-Tests/MokumeCoreTests/scene-ledger.txt}

say() { echo "$RENDER_CONTEXT: $*"; }
give_up() { say "報告しない — $1"; exit 0; }

# 対象リポジトリを origin から導く (owner/repo)。
resolve_repo() {
  local url
  url=$(git config --get remote.origin.url || true)
  [ -n "$url" ] || return 1
  url=${url%.git}
  url=${url#git@github.com:}
  url=${url#https://github.com/}
  printf '%s' "$url"
}

# 報告できなくても**失敗しない**。いちばん多い理由は「まだ push していない」で、
# それは作業の途中というだけである (remote に無い commit へは status を打てない)。
# push のあとに make render-status をもう一度打てば、同じ記録から報告し直せる。
post() {
  local repo=$1 sha=$2 state=$3 description=$4
  if gh api -X POST "repos/$repo/statuses/$sha" \
    -f state="$state" -f context="$RENDER_CONTEXT" -f description="$description" --silent; then
    say "報告: $sha → $state ($description)"
  else
    say "報告できなかった — この commit がまだ remote に無いか、権限が無い"
    say "push してから make render-status を打つと、同じ記録から報告し直せる"
  fi
}

# 木の「描画に関わるファイルの中身」の指紋 (#435)。
#
# 画素ではなくファイルの中身 (path と blob の並び) を畳む。GPU が要らず、判定に
# 要るのは「手元が回した木と合流後の木が、絵に効く範囲で同じか」だけだからである。
#
# 木が truncated なら 2 を返す (この規模の木では起きないが、黙って通さないため)。
drawing_fingerprint() {
  local repo=$1 sha=$2 tree
  tree=$(gh api "repos/$repo/git/trees/$sha?recursive=1" \
    --jq 'if .truncated then "!truncated"
          else (.tree[] | select(.type == "blob") | "\(.path) \(.sha)") end') || return 1
  case "$tree" in '!truncated'*) return 2 ;; esac
  printf '%s\n' "$tree" | drawing_files coverage | sort | shasum -a 256 | cut -c1-12
}

# 手元の木の同じ指紋。**綴りは drawing_fingerprint と一字一句同じでなければならない**
# — merge queue はこの値と合流後の木の指紋を突き合わせるので、どちらかの書式が動くと
# 全部の描画 PR が常時弾かれる。tree API が返すのと同じ「path sha」の並びを作るために
# `--format` を使う (既定の出力はモードと型が混ざり、空白を含むパスを引用符で囲む)。
#
# 同じ commit で 2 経路が同じ 12 桁を返すことは実測してある (#612)。
local_drawing_fingerprint() {
  git ls-tree -r HEAD --format='%(path) %(objectname)' \
    | drawing_files coverage | sort | shasum -a 256 | cut -c1-12
}

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
# 条件は「**手元の木が、queue がこれから組む木と同じ**」である。同じなら、報告先を
# push 済み head にしても報告とその中身は食い違わない — covers= が名乗るのは手元が
# 実際に回した木で、それは queue が組む木そのものだからである。
#
# 違えば HEAD を返す。その木は remote に無いので、今までどおり「まだ push して
# いない」として報告が付かない。
report_target() {
  local head upstream automatic
  head=$(git rev-parse HEAD)
  upstream=$(git rev-parse --verify --quiet '@{u}' 2>/dev/null) || upstream=''
  if [ -z "$upstream" ] || [ "$upstream" = "$head" ]; then
    printf '%s' "$head"
    return 0
  fi
  # **queue がこれから作る木と、手元の木が同じか**を直接見る。commit の数え方では
  # 決まらない — 取り込みは main の commit を丸ごと連れてくるので、「合流だけか」を
  # 履歴の形から判定しようとすると main の commit を数えてしまう (実測)。
  #
  # 木が同じなら、手元が回したのは queue がこれから組む木そのものである。違うなら
  # queue は同じ木を作れない — 衝突を解いた合流がこれに当たり、解いた中身は remote に
  # 無いので push しない限り誰も再現できない (押し直しが要るのは正しい)。
  if ! automatic=$(git merge-tree --write-tree "$upstream" origin/main 2>/dev/null) ||
    [ "$automatic" != "$(git rev-parse "$head^{tree}")" ]; then
    printf '%s' "$head"
    return 0
  fi
  printf '%s' "$upstream"
}

# 手元の実行が「どの木を回したか」を、報告そのものから読む (#612)。
#
# 覆いの判定は本来「手元が回した木 == 合流後の木」であり、**PR の head の木では
# ない**。両者が同じだったのは、覆い直しに push を要求していたからにすぎない。
# push を要求すると承認が落ちる (dismiss_stale_reviews_on_push) ので、回した木の
# ほうを報告に載せてもらい、ここではそれを読む。
#
# 読むのは**最新の success** である。弾かれた後に打ち直した報告が最新になるので、
# 途中の failure を挟んでも最後に成立した覆いが残る。名乗っていなければ空を返し、
# 呼ぶ側が今までどおり head の木で判定する。
covered_fingerprint() {
  local repo=$1 head=$2 description
  # **綴りは打つ側と同じ出どころから取る** (#785)。gh api に --arg は無いので、
  # フィルタへシェルが展開する (gh-app-token.sh / report-ruleset-drift.sh と同じ形)
  description=$(gh api "repos/$repo/commits/$head/statuses" \
    --jq "map(select(.context == \"$RENDER_CONTEXT\" and .state == \"success\"))
          | first | .description // \"\"") || return 1
  printf '%s' "$description" | sed -n 's/.*covers=\([0-9a-f][0-9a-f]*\).*/\1/p'
}

# merge queue の SHA への報告 (#435)。
#
# ここが #432 の落ちた隙間である。CI は絵を回せず (ADR-0019 決定 7)、手元の実行は
# **合流前の枝**でしか回らない。以前はその隙間を無条件の success で埋めていたので、
# 描画 PR が 2 本並走すると、後から入ったほうが merge されてから main を赤くした。
#
# 絵を回す機械を増やす代わりに、**手元の報告が合流後の姿を覆っているか**を見る。
# 覆っていなければ local-render を failure にして queue から外し、同じ failure を
# **その PR の head にも打って gh pr checks を赤くする** (#462)。守られるのは
# 「main の絵に関わるファイルは、常に誰かが手元で実際に回して確かめた組み合わせの
# ままである」という不変条件で、描画に触れない PR はその組み合わせを動かさないので
# 対象外にしてよい (BEHIND のまま merge できる従来の運用がそのまま残る)。
#
# **判定できないときは通す。** 防いでいるのは事故であって偽装ではない (冒頭の宣言)
# ので、queue を止めるより名乗って通すほうを取る。何を見ていないかは必ず述べる。
report_merge_group() {
  local repo=$1 merged=$2 head_ref=$3
  local numbers number head files fp_head covered source checked=0 blind=''
  local fp_merged='' rejected=''

  # queue の枝は gh-readonly-queue/<base>/pr-<番号>-<base sha>。まとめて積まれた
  # ときに備えて pr-<番号> は全件拾う (1 本でも覆えていなければ通さない)
  numbers=$(printf '%s\n' "$head_ref" | grep -oE 'pr-[0-9]+' | cut -d- -f2 || true)
  if [ -z "$numbers" ]; then
    say "queue の枝から PR 番号を読めなかった ($head_ref)"
    post "$repo" "$merged" success "merge queue (覆いは見ていない)"
    return
  fi

  # **覆えていない PR を見つけても、そこで切り上げない** (#462)。queue はまとめて
  # 積む (max_entries_to_build: 5) ので、1 本目で return すると 2 本目以降の作者に
  # とっては何も変わらない — 自分の PR は緑のまま、理由もどこにも出ないまま弾かれる。
  # 判定は rejected に畳んで、queue への報告はループの後に 1 回だけ打つ。
  #
  # 読めなくなったら見るのをやめる (blind)。ただし**既に決まった failure は
  # 上書きしない** — 「読めなければ名乗って通す」は判定できなかったときの逃がしで
  # あって、判定できた failure を取り消す口ではない。
  for number in $numbers; do
    if ! files=$(gh api "repos/$repo/pulls/$number/files" --paginate --jq '.[].filename'); then
      say "#$number の変更ファイルを読めなかった"
      blind=1
      break
    fi
    # 読み飛ばすときも名乗る (#441)。止めなかった回のログが「見た上で通した」のか
    # 「見る対象が無かった」のかを分けて読めるようにするため
    if ! printf '%s\n' "$files" | touches_drawing coverage; then
      say "#$number は台帳の絵を動かさない (覆いを見る対象ではない)"
      continue
    fi

    # 合流後の木は、見る対象が現れて初めて引く。描画 PR が 1 本も無い回に
    # 「木を読めなかった」という無関係な名乗りが出ないため (#441)
    if [ -z "$fp_merged" ] && ! fp_merged=$(drawing_fingerprint "$repo" "$merged"); then
      say "合流後の木を読めなかった (指紋を取れない)"
      blind=1
      break
    fi

    if ! head=$(gh api "repos/$repo/pulls/$number" --jq '.head.sha'); then
      say "#$number の head を読めなかった"
      blind=1
      break
    fi

    # **手元が回した木の指紋を、報告そのものから読む** (#612)。名乗っていない報告
    # (古いもの・手で打った status) は今までどおり head の木で判定する
    covered=$(covered_fingerprint "$repo" "$head") || covered=''
    if [ -n "$covered" ]; then
      fp_head=$covered
      source='手元の報告'
    elif fp_head=$(drawing_fingerprint "$repo" "$head"); then
      source='head の木'
    else
      say "#$number の head の木を読めなかった (指紋を取れない)"
      blind=1
      break
    fi

    if [ "$fp_head" != "$fp_merged" ]; then
      say "#$number の手元の実行は合流後の姿を覆っていない ($source=$fp_head 合流後=$fp_merged)"
      say "main を取り込んで手元で make ci-check を打ち直すと、この報告が付き直す"
      # **PR の head にも打つ** (#462)。queue のコミットに付けた failure は
      # gh pr checks にもタイムラインにも現れないので、弾かれたことに気付く経路が
      # 人間しか無かった。ここが赤くなれば、見届けの仕組みがそのまま拾う。
      #
      # **CI がここへ打つのは failure だけである。** success は手元の実行しか
      # 打たない (#304) — その不変条件を、報告先を広げるついでに崩さない。
      post "$repo" "$head" failure \
        "merge queue で弾かれた — main を取り込んで make ci-check を打ち直す"
      rejected="$rejected #$number"
      continue
    fi
    say "#$number は覆えている ($source=$fp_head)"
    checked=$((checked + 1))
  done

  if [ -n "$rejected" ]; then
    post "$repo" "$merged" failure \
      "${rejected# } の手元の実行が合流後の姿を覆っていない — main を取り込んで打ち直す"
  elif [ -n "$blind" ]; then
    post "$repo" "$merged" success "merge queue (覆いは見ていない)"
  # 見る対象が無かった回を「覆っている」と名乗らない (#441)
  elif [ "$checked" -eq 0 ]; then
    post "$repo" "$merged" success "merge queue (描画に触れる PR は無い)"
  else
    post "$repo" "$merged" success "merge queue ($checked 本の描画 PR が合流後の姿を覆っている)"
  fi
}

mode=${1:-}
case "$mode" in
  local)
    # 1. 走らせたものと HEAD が指すものが同じでなければ、報告に意味が無い
    [ -z "$(git status --porcelain)" ] || give_up "作業ツリーが汚れている"

    # 2. テストの記録が要る (make の test ターゲットが残す)
    [ -f "$TEST_LOG" ] || give_up "テストの記録が無い ($TEST_LOG)"

    # 3. **台帳の suite が通っていること**を、絵の検査が実際に回った証拠にする。
    #    スキップの数を数えるのではなく、走ってほしいものが走ったかを見る —
    #    出力の書式が変わったときに、黙って通る側へ倒れないため
    grep -q "Suite \"$LEDGER_SUITE\".*passed" "$TEST_LOG" \
      || give_up "「${LEDGER_SUITE}」が通っていない (この世代の GPU が無い機械の実行)"

    # 4. 報告先と資格情報。CI からここへ来ても、認証が無いのでここで止まる
    command -v gh >/dev/null 2>&1 || give_up "gh が無い"
    gh auth status >/dev/null 2>&1 || give_up "gh が認証されていない"
    repo=$(resolve_repo) || give_up "origin が無い"

    skipped=$(grep -c 'skipped:' "$TEST_LOG" || true)
    ledger_digest=$(grep -vE '^[[:space:]]*(#|$)' "$LEDGER" | shasum -a 256 | cut -c1-8)
    covers=$(local_drawing_fingerprint)
    target=$(report_target)
    # 報告先が HEAD でないのは「取り込みだけ」の木のときで、そこは黙って通さない
    [ "$target" = "$(git rev-parse HEAD)" ] \
      || say "報告先は push 済みの head ($target) — 手元は main を取り込んだ木で、その指紋を covers= が運ぶ"
    post "$repo" "$target" success \
      "手元で全検査が通った skipped=$skipped ledger=$ledger_digest covers=$covers"
    ;;

  proxy)
    # CI からの代理報告。**台帳の絵を動かしうる PR には打たない** — 打たないことが
    # そのまま「手元の報告待ち」になる。pending を打たないのは順序の危険を避ける
    # ためで、手元の報告が CI より先に届くことがあるから (後から pending を打つと
    # 成立した報告を打ち消す)。
    : "${GITHUB_REPOSITORY:?}" "${GITHUB_EVENT_NAME:?}"
    if [ "$GITHUB_EVENT_NAME" = "merge_group" ]; then
      report_merge_group "$GITHUB_REPOSITORY" "${MERGE_GROUP_SHA:?}" "${MERGE_GROUP_HEAD_REF:-}"
      exit 0
    fi

    if gh api "repos/$GITHUB_REPOSITORY/pulls/${PR_NUMBER:?}/files" --paginate \
      --jq '.[].filename' | touches_drawing coverage; then
      # 描画 PR は番号順に 1 本ずつ merge する (#467)。順番でなければここで赤くする
      # — queue で弾かれるのを待つと、待ち時間も手元の打ち直しも無駄になる
      ahead=$(ahead_drawing_pr "$GITHUB_REPOSITORY" "$PR_NUMBER")
      case "$ahead" in
        '?') say "先に居る描画 PR を読めなかった (順番は見ていない)" ;;
        draft) say "Draft の描画 PR — 順番の外" ;;
        '') say "この PR が描画の先頭" ;;
        *)
          say "先に #$ahead が居る — 描画 PR は番号順に 1 本ずつ merge する"
          post "$GITHUB_REPOSITORY" "${PR_HEAD_SHA:?}" failure \
            "#$ahead の merge を待つ (描画 PR は番号順に 1 本ずつ)"
          exit 0
          ;;
      esac
      say "台帳の絵を動かしうる PR — 手元の報告を待つ (報告しない)"
      exit 0
    fi
    post "$GITHUB_REPOSITORY" "${PR_HEAD_SHA:?}" success "手元の実行の覆いを壊さない"
    ;;

  target)
    # 報告先を出すだけ。**push の要否の判定を 2 か所に書かない**ため、catch-up は
    # ここへ訊く (ADR-0001 原則 9)。HEAD が返れば「push しないと誰も見られない木」
    report_target
    echo
    ;;

  *)
    echo "使い方: $0 local|proxy|target" >&2
    exit 2
    ;;
esac
