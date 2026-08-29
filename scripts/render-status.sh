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
set -euo pipefail

# 「描画に触れているか」の判定は #306 と共有する (照合の実体は 1 つ)
# shellcheck source=scripts/drawing-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/drawing-paths.sh"

readonly CONTEXT=local-render
# scene-ledger の suite 名。**この名前が走って通ったこと**を、GPU のある機械で
# 全検査が回った証拠として使う (SceneLedgerTests.swift の @Suite 名と一致させる)。
readonly LEDGER_SUITE='代表シーンの台帳'

TEST_LOG=${RENDER_TEST_LOG:-.build/test-log.txt}
LEDGER=${RENDER_LEDGER:-Tests/MokumeCoreTests/scene-ledger.txt}

say() { echo "$CONTEXT: $*"; }
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
    -f state="$state" -f context="$CONTEXT" -f description="$description" --silent; then
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
  printf '%s\n' "$tree" | drawing_files | sort | shasum -a 256 | cut -c1-12
}

# merge queue の SHA への報告 (#435)。
#
# ここが #432 の落ちた隙間である。CI は絵を回せず (ADR-0019 決定 7)、手元の実行は
# **合流前の枝**でしか回らない。以前はその隙間を無条件の success で埋めていたので、
# 描画 PR が 2 本並走すると、後から入ったほうが merge されてから main を赤くした。
#
# 絵を回す機械を増やす代わりに、**手元の報告が合流後の姿を覆っているか**を見る。
# 覆っていなければ local-render を failure にして queue から外す。守られるのは
# 「main の絵に関わるファイルは、常に誰かが手元で実際に回して確かめた組み合わせの
# ままである」という不変条件で、描画に触れない PR はその組み合わせを動かさないので
# 対象外にしてよい (BEHIND のまま merge できる従来の運用がそのまま残る)。
#
# **判定できないときは通す。** 防いでいるのは事故であって偽装ではない (冒頭の宣言)
# ので、queue を止めるより名乗って通すほうを取る。何を見ていないかは必ず述べる。
report_merge_group() {
  local repo=$1 merged=$2 head_ref=$3
  local numbers number head files fp_head checked=0
  local fp_merged=''

  # queue の枝は gh-readonly-queue/<base>/pr-<番号>-<base sha>。まとめて積まれた
  # ときに備えて pr-<番号> は全件拾う (1 本でも覆えていなければ通さない)
  numbers=$(printf '%s\n' "$head_ref" | grep -oE 'pr-[0-9]+' | cut -d- -f2 || true)
  if [ -z "$numbers" ]; then
    say "queue の枝から PR 番号を読めなかった ($head_ref)"
    post "$repo" "$merged" success "merge queue (覆いは見ていない)"
    return
  fi

  for number in $numbers; do
    if ! files=$(gh api "repos/$repo/pulls/$number/files" --paginate --jq '.[].filename'); then
      say "#$number の変更ファイルを読めなかった"
      post "$repo" "$merged" success "merge queue (覆いは見ていない)"
      return
    fi
    # 読み飛ばすときも名乗る (#441)。止めなかった回のログが「見た上で通した」のか
    # 「見る対象が無かった」のかを分けて読めるようにするため
    if ! printf '%s\n' "$files" | touches_drawing; then
      say "#$number は描画に触れない (覆いを見る対象ではない)"
      continue
    fi

    # 合流後の木は、見る対象が現れて初めて引く。描画 PR が 1 本も無い回に
    # 「木を読めなかった」という無関係な名乗りが出ないため (#441)
    if [ -z "$fp_merged" ] && ! fp_merged=$(drawing_fingerprint "$repo" "$merged"); then
      say "合流後の木を読めなかった (指紋を取れない)"
      post "$repo" "$merged" success "merge queue (覆いは見ていない)"
      return
    fi

    if ! head=$(gh api "repos/$repo/pulls/$number" --jq '.head.sha') ||
      ! fp_head=$(drawing_fingerprint "$repo" "$head"); then
      say "#$number の head の木を読めなかった (指紋を取れない)"
      post "$repo" "$merged" success "merge queue (覆いは見ていない)"
      return
    fi

    if [ "$fp_head" != "$fp_merged" ]; then
      say "#$number の手元の実行は合流後の姿を覆っていない (head=$fp_head 合流後=$fp_merged)"
      say "main を取り込んで手元で make ci-check を打ち直すと、この報告が付き直す"
      post "$repo" "$merged" failure \
        "#$number の手元の実行が合流後の姿を覆っていない — main を取り込んで打ち直す"
      return
    fi
    say "#$number は覆えている (描画に関わるファイル $fp_head)"
    checked=$((checked + 1))
  done

  # 見る対象が無かった回を「覆っている」と名乗らない (#441)
  if [ "$checked" -eq 0 ]; then
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
    post "$repo" "$(git rev-parse HEAD)" success \
      "手元で全検査が通った skipped=$skipped ledger=$ledger_digest"
    ;;

  proxy)
    # CI からの代理報告。**描画に触れている PR には打たない** — 打たないことが
    # そのまま「手元の報告待ち」になる。pending を打たないのは順序の危険を避ける
    # ためで、手元の報告が CI より先に届くことがあるから (後から pending を打つと
    # 成立した報告を打ち消す)。
    : "${GITHUB_REPOSITORY:?}" "${GITHUB_EVENT_NAME:?}"
    if [ "$GITHUB_EVENT_NAME" = "merge_group" ]; then
      report_merge_group "$GITHUB_REPOSITORY" "${MERGE_GROUP_SHA:?}" "${MERGE_GROUP_HEAD_REF:-}"
      exit 0
    fi

    if gh api "repos/$GITHUB_REPOSITORY/pulls/${PR_NUMBER:?}/files" --paginate \
      --jq '.[].filename' | touches_drawing; then
      say "描画に触れている PR — 手元の報告を待つ (報告しない)"
      exit 0
    fi
    post "$GITHUB_REPOSITORY" "${PR_HEAD_SHA:?}" success "描画に触れていない"
    ;;

  *)
    echo "使い方: $0 local|proxy" >&2
    exit 2
    ;;
esac
