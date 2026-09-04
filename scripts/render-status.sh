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
#   bash scripts/render-status.sh local     # make ci-check の最後。全検査が通ったときだけ打つ
#   bash scripts/render-status.sh proxy     # CI から。打たなくてよい場合の代理報告だけ
#   bash scripts/render-status.sh coverage  # 手元の覆いがいまの origin/main にまだ効くか (#830)
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
# 「どのリポジトリか」の解き方 (#818)。ここには `git@github.com:` と `https://github.com/`
# の 2 形だけを落とす劣化版があり、ssh:// 形や ssh alias の origin を解けなかった —
# 空を返さないので逃がしにも掛からず、報告が黙って届かなかった
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
# 手元の木から覆いを判定する部分 (#819)。**git だけで決まるもの**はあちらが持ち、
# catch-up.sh も同じものを source する (以前はあちらが別プロセスでここへ訊いていた)
# shellcheck source=scripts/render-coverage.sh
. "$(dirname "${BASH_SOURCE[0]}")/render-coverage.sh"
# 変更ファイルの取り方 (#793)。drawing-queue.sh も使うが、あちらは自分で読み込まない
# ので読み手が source する (drawing-paths.sh とまったく同じ形)
# shellcheck source=scripts/pr-files.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-files.sh"
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
# 1 PR ぶんの「見る対象か」の判定。
#   0 = 台帳の絵を動かす / 1 = 動かさない / 2 = 読めなかった
#
# **合流後の木を引く前にこれを訊く** (#441)。描画 PR が 1 本も無い回に「木を読めなかった」
# という無関係な名乗りを出さないため、木の取得は見る対象が現れて初めて行う。
pr_touches_drawing() { # $1=repo $2=PR 番号
  local files
  files=$(pr_files "$1" "$2") || return 2
  printf '%s\n' "$files" | touches_drawing coverage
}

# 1 PR ぶんの覆いの判定。判定の結果を stdout へ 1 行で返す。
# 出力はタブ区切りの 3 欄 `<判定>\t<内訳>\t<head>`:
#   covered   <出どころ>=<指紋>   —      覆えている
#   rejected  <出どころ>=<指紋>   <head> 覆えていない (呼ぶ側が弾く)
#   blind     <理由>              —      判定できなかった
#
# **空白ではなくタブで区切る。** 理由の文には空白が入るので、空白区切りにすると
# 「blind head を読めなかった」が 3 語に割れて名乗りが壊れる
#
# **弾いた PR の head へ failure を打つのは呼ぶ側**である。ここは判定だけを返す —
# 打つかどうかは queue 全体を見てから決まる (#462)。
pr_coverage() { # $1=repo $2=PR 番号 $3=合流後の指紋
  local repo=$1 number=$2 fp_merged=$3 head covered fp_head source
  if ! head=$(gh api "repos/$repo/pulls/$number" --jq '.head.sha'); then
    printf 'blind\thead を読めなかった\t-\n'
    return
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
    printf 'blind\thead の木を読めなかった (指紋を取れない)\t-\n'
    return
  fi
  if [ "$fp_head" != "$fp_merged" ]; then
    printf 'rejected\t%s=%s\t%s\n' "$source" "$fp_head" "$head"
    return
  fi
  printf 'covered\t%s=%s\t-\n' "$source" "$fp_head"
}

# queue へ 1 回だけ打つ。**優先順は rejected > blind > 見る対象なし > 覆えている。**
#
# 弾いた PR が 1 本でもあれば failure である。「読めなかった」で上書きしない —
# 読めなければ名乗って通すのは判定できなかったときの逃がしで、判定できた failure を
# 取り消す口ではない。
post_queue_verdict() { # $1=repo $2=合流後の sha $3=弾いた PR $4=読めなかったか $5=覆えていた本数
  local repo=$1 merged=$2 rejected=$3 blind=$4 checked=$5
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

# merge queue へ 1 回だけ報告する。合流後の木を、積まれた PR ぜんぶと突き合わせる。
#
# **覆えていない PR を見つけても、そこで切り上げない** (#462)。queue はまとめて積む
# (max_entries_to_build: 5) ので、1 本目で return すると 2 本目以降の作者にとっては
# 何も変わらない — 自分の PR は緑のまま、理由もどこにも出ないまま弾かれる。判定は
# rejected に畳んで、queue への報告はループの後に 1 回だけ打つ。
#
# **読み飛ばすときも名乗る** (#441)。止めなかった回のログが「見た上で通した」のか
# 「見る対象が無かった」のかを分けて読めるようにするため。
#
# 読めなくなったら見るのをやめる (blind)。
#
# **弾いた PR の head にも打つ** (#462)。queue のコミットに付けた failure は
# gh pr checks にもタイムラインにも現れないので、弾かれたことに気付く経路が人間しか
# 無かった。head が赤くなれば、見届けの仕組みがそのまま拾う。**CI がここへ打つのは
# failure だけである** — success は手元の実行しか打たない (#304)。
report_merge_group() {
  local repo=$1 merged=$2 head_ref=$3
  local numbers number touches line verdict detail head
  local checked=0 blind='' fp_merged='' rejected=''

  # queue の枝は gh-readonly-queue/<base>/pr-<番号>-<base sha>。まとめて積まれた
  # ときに備えて pr-<番号> は全件拾う (1 本でも覆えていなければ通さない)
  numbers=$(printf '%s\n' "$head_ref" | grep -oE 'pr-[0-9]+' | cut -d- -f2 || true)
  if [ -z "$numbers" ]; then
    say "queue の枝から PR 番号を読めなかった ($head_ref)"
    post "$repo" "$merged" success "merge queue (覆いは見ていない)"
    return
  fi

  for number in $numbers; do
    # **`$?` を素で見ない。** set -e の下では非 0 を返した時点で script が落ちる
    touches=0
    pr_touches_drawing "$repo" "$number" || touches=$?
    case $touches in
      2) say "#$number の変更ファイルを読めなかった"; blind=1; break ;;
      1) say "#$number は台帳の絵を動かさない (覆いを見る対象ではない)"; continue ;;
    esac

    if [ -z "$fp_merged" ] && ! fp_merged=$(drawing_fingerprint "$repo" "$merged"); then
      say "合流後の木を読めなかった (指紋を取れない)"
      blind=1
      break
    fi

    # **判定を先に受け取ってから読む。** `IFS=$'\t' read … <<<"$(pr_coverage …)"` と
    # 1 文で書くと、前置きの IFS が**同じコマンドの中のコマンド置換にも効く** —
    # drawing_files の `for tag in $rest` が空白で分割されなくなり、`evidence-only` の
    # 印が読めずに覆いの判定が別の問い (evidence) の答えを返していた (#819 で実測)
    line=$(pr_coverage "$repo" "$number" "$fp_merged")
    IFS=$'\t' read -r verdict detail head <<<"$line"
    case $verdict in
      blind)
        say "#$number の $detail"
        blind=1
        break
        ;;
      rejected)
        say "#$number の手元の実行は合流後の姿を覆っていない ($detail 合流後=$fp_merged)"
        say "main を取り込んで手元で make ci-check を打ち直すと、この報告が付き直す"
        post "$repo" "$head" failure \
          "merge queue で弾かれた — main を取り込んで make ci-check を打ち直す"
        rejected="$rejected #$number"
        ;;
      *)
        say "#$number は覆えている ($detail)"
        checked=$((checked + 1))
        ;;
    esac
  done

  post_queue_verdict "$repo" "$merged" "$rejected" "$blind" "$checked"
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
    # **解けなければ名乗って諦める。** 劣化版はごみを宛先にして黙って失敗していた
    repo=$(repo_of_dir "$PWD") || give_up "origin から owner/repo を解けない"

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

    if pr_files "$GITHUB_REPOSITORY" "${PR_NUMBER:?}" | touches_drawing coverage; then
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

  *)
    # **口は「打つ」2 つだけである** (#819)。以前は catch-up が別プロセスで訊くための
    # target / coverage があったが、判定は scripts/render-coverage.sh に移り、
    # あちらは source して直に呼ぶ
    echo "使い方: $0 local|proxy" >&2
    exit 2
    ;;
esac
