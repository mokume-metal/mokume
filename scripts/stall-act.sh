#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 止まった PR へ、表が定める対処を打つ (#961)。
#
#   stall-act.sh <stall-watch.sh の出力ファイル>
#
# 判定 (scripts/stall-watch.sh) と**スクリプトごと分けてある**。理由は
# report-ruleset-drift.sh を check-rulesets.sh から分けたのと同じで、手元で様子を見る
# ために判定を打っただけで auto-merge が掛かってしまうのを防ぐため。打つのはここだけで、
# 呼ぶのは .github/workflows/stall-watch.yml である。
#
# ## 打つのは 1 つの分類だけ
#
#   stale-checks         判定を固定している古い失敗ジョブを rerun する
#
# **打ち直すのはコードの検査の古い赤である。** 作法の検査 (タイトル・マージ判定・絵) の赤は
# 打ち直す対象ではなくなった — pr-gate (.github/workflows/pr-gate.yml) は直せば新しい run が
# 付け直し、ci.yml の ci-gate はもう作法を待たない (#2669)。かつて打ち直しの大半はこの作法の
# 赤だった (#1160・#2134)。残るのは、同じコミットに段を走らせる ci.yml の run が複数立つ場面
# (reopen・base の変更・閉じて作り直した PR) で、古い run の ci-check・ci-gate の赤が新しい緑と
# 並ぶときである。必須の判定がどちらを読むかは決まっていない (#2577) ので、打ち直しを残す。
# 本文の編集の run の緑 (段が skipped) は直った証拠ではないので、stall-watch.sh はそれを組に
# 数えない (masked-red と名乗る・#2669 の反証 4)。
#
# 本文の編集の run の ci-gate は、同じ SHA のコードの検査が走っている途中なら赤を返す (#2690)。
# 必須の判定は、検査の run の ci-gate が後から作られた緑を読むので merge は止まらない。赤は並んで
# 残るが、当番は新旧を run の id で決める (stall-watch.sh の normalize_checks) ので、id の大きい
# 本文の編集の run の赤を最新と読み、ここへは回さない。人が打ち直しても、同じ SHA を読み直す
# だけで害は無い。
#
# ## 作法のジョブを含む古い ci.yml の run は丸ごと打たない (#2669 の移行)
#
# #2669 より前の ci.yml の run は作法のジョブ (LEGACY_JOBS) を含み、その ci-gate はそれらを
# 待っていた。その pr-title を打つと古いタイトルを再生して赤を返し (#699)、その run の ci-gate を
# 打つと needs の赤で赤く走り直して最新の ci-gate になり、通っていた PR を塞ぐ。除外の名前に
# 足すだけでは ci-gate を外せないので、**その名前の check を 1 つでも含む run の失敗ジョブを
# まとめて飛ばす**。人へは stall-watch.sh が legacy-gate と名乗って返す。作法のジョブを含む run を
# head に持つ open な PR が無くなったら、この判定ごと消してよい。
#
# 名乗る (name) と黙る (quiet) の行には何もしない。**入力の 3 列目がその別**なので、
# ここで分類名を数え直さない — 判定は 1 箇所に保つ (ADR-0001 原則 9)。
#
# ## auto-merge は掛け直さない (#2614)
#
# 以前は auto-merge-dropped にも gh pr merge --auto --squash を打っていたが、**一度も
# 成功しなかった** (2026-10-13 に数えた直近 60 回で 0 回)。当番の GITHUB_TOKEN
# (contents: read) では enablePullRequestAutoMerge が `Resource not accessible by
# integration` (FORBIDDEN) で拒まれ、contents: write を足すと通る (probe の run
# 38541307087)。リポジトリへの書き込みを当番に渡すかは人の判断なので、権限は広げずに
# 掛け直しを消した。stall-watch.sh が名乗り、外れてから猶予を超えたら赤で人に返す。
# 掛け直すのは人である。
#
# ## gh の失敗の理由を捨てない (#2614)
#
# 失敗の行には gh の stderr を 1 行に畳んで添える。以前は 2>/dev/null で捨てていたので、
# 上の掛け直しが 60 回続けて落ちても理由がどこにも残らなかった。
#
# ## rerun はジョブ単位で打つ
#
# `gh run rerun <run-id> --failed` は**その run の失敗ジョブを全部**打ち直す。render.yml の
# run では、打ってはならない render-pr (下の除外の基準) まで巻き添えにする。
#
# だから**失敗ジョブを 1 つずつジョブの rerun の API で打ち、下の除外リストを飛ばす**。
# `gh run rerun --job` を使わないのは、拒まれたときに API の文面を捨てて
# 「job N cannot be rerun」としか言わないためである (#2614)。`gh api` は文面を
# 「gh: <message> (HTTP 403)」で返すので、下の 2 つを読み分けられる。
#
# ## 集約のジョブは最後に打つ (#1883)
#
# ジョブの rerun の API は、**打ったジョブと、それを needs で待つジョブ**を走らせ直す。ci-gate を
# 先に打つと、ci-gate だけが前の結論 (落ちた ci-check) を読んで同じ赤を返し、その run が走って
# いる間は ci-check の打ち直しが拒まれる。check run の並びが同じなら、次の回も同じ順で同じことが
# 起きる (2026-09-30 の #1883 では、上流の review-gate がそうして打ち直されなかった)。だから
# RERUN_LAST の名前は最後に回す。上流を打てば集約も一緒に走り直すので、そのときの集約の
# 打ち直しは「走り直している」で拒まれ、名乗って進む (下)。
#
# ## 拒まれても赤にしない 2 つ (#2614)
#
# 次の 2 つは打つ側の失敗ではなく、打つ対象がその回に居ないだけなので、名乗って 0 のまま進む
# (queue-sweep.sh が cancel の 409 を読み分けるのと同じ形)。文面は 2026-10-14 に実物で取った:
#
# - `The workflow run containing this job is already running` — 同じ run の別のジョブを
#   先に打つと run が走り出し、残りは拒まれる。後続のジョブなら一緒に走り直している。
#   そうでなければ、走り終わった後の次の回に打てる
# - `Only jobs from the current attempt can be re-run` — commit の check run の一覧には、
#   走り直す前の attempt のジョブも残る。それは打ち直せず、新しい attempt のジョブが同じ
#   一覧に居る
#
# それ以外の拒否 (権限など) は理由を添えて 1 で終える。
#
# ## 除外の基準は名前ではなく「何を読むジョブか」
#
# 除外が要るのは「**凍結されたイベントペイロードの可変な欄** (title / body / labels) を
# 読むジョブ」である。番号や sha は run の中で変わらないので、それだけを受け取る
# ジョブは rerun して安全である — 本文やタイトルは GH_TOKEN で都度取り直すからである。
#
# いま当てはまるジョブは無い (当てはまっていた ci.yml の pr-title は #2669 で消えた。pr-gate は
# タイトルも API から読む)。**同じ形のジョブが増えたらここへ足さないと同じ壊れ方をする**。
# 人手の対応にしないため、scripts/tests/stall_watch_test.py が PR の head に check を付ける
# ワークフローを読んで「可変欄を読むジョブが、このリストに載っているか」を見る (#801 と同じ形)。
#
# **もう 1 つの基準は「門番の後ろに居るジョブか」** (#2062)。render.yml の render-pr は、
# GitHub ホストの門番 (render-turn) を通ってから専用機に積まれる。ジョブ単位の rerun は
# 門番を走らせ直さないので、merge queue の render が専用機を待っている最中でも render-pr を
# 専用機へ直に積み、先頭の render と取り合わせる。render-pr は必須ではなく、rerun しなくても
# merge は止まらない。cancel された render-pr (queue-sweep が group のできた瞬間に退かせた
# もの・#2064、stall-watch の読み分け 9 で人が退かせたもの) が、
# 別の check の stale-checks の巻き添えで戻ってくるのも、これで止まる。
#
# **3 つ目の基準は「最新の run の結論が判定になるジョブか」** (#2668)。pr-gate
# (.github/workflows/pr-gate.yml) は直すと新しい run が付け直し、concurrency が走っている古い
# run を cancel する。head SHA に残る古い赤・cancelled は直す前の名残で、打ち直しても得るものが
# 無い。打てば同じ group で走っている新しい run を cancel しうる。stall-watch.sh の
# normalize_checks も古い pr-gate を stale-checks に数えない。
#
# 検査は scripts/tests/stall_watch_test.py。
set -euo pipefail

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"

REPO="$(this_repo)"

# rerun を打ってはならないジョブ。**readonly にしない** — 検査が差し替えて回すため
RERUN_EXCLUDED=${RERUN_EXCLUDED:-"render-pr pr-gate"}

# 最後に打つジョブ (needs で他を待つ集約)。理由は冒頭の「集約のジョブは最後に打つ」
RERUN_LAST=${RERUN_LAST:-"ci-gate"}

# 作法のジョブの名前。この名前の check を含む run を古い run と読み、丸ごと打たない。
# scripts/stall-watch.sh の LEGACY_JOBS と同じに保つ (検査が見る)
readonly LEGACY_JOBS="pr-title review-gate drawing-evidence"

LOG="${1:?stall-watch.sh の出力ファイルが必要}"
[ -f "$LOG" ] || {
  echo "判定の出力ファイルが無い: $LOG" >&2
  exit 66
}

failed=0

# gh の stderr の受け皿。標準出力を値として受ける呼び出しでも理由を拾えるように、
# ファイルへ逃がしてから読む
errfile=$(mktemp)
trap 'rm -f "$errfile"' EXIT

say() { printf '%s\n' "$*"; }

# 直前の gh の stderr を 1 行に畳む。空なら空と言う (黙ると「理由なし」と読めない)
reason() {
  local text
  text=$(tr '\n' ' ' <"$errfile" | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//')
  printf '%s' "${text:-gh は理由を出さなかった}"
}

excluded() { # $1=ジョブ名
  case " $RERUN_EXCLUDED " in *" $1 "*) return 0 ;; esac
  return 1
}

last() { # $1=ジョブ名
  case " $RERUN_LAST " in *" $1 "*) return 0 ;; esac
  return 1
}

# 1 つのジョブを打つ。打てたら 0、打たなかった・拒まれたら 1 (failed は自分で立てる)
rerun_job() { # $1=PR 番号 $2=ジョブ名 $3=ジョブの id
  local n=$1 name=$2 id=$3
  if excluded "$name"; then
    say "#$n: $name は rerun しない (凍結されたペイロードを読む #699・門番の後ろに居る #2062・最新の run が判定 #2668 のどれか)"
    return 1
  fi
  if gh api "repos/$REPO/actions/jobs/$id/rerun" -X POST --silent 2>"$errfile"; then
    say "#$n: $name を rerun した"
    return 0
  fi
  case "$(reason)" in
    *"is already running"*)
      say "#$n: $name は同じ run が走り直している (後続なら一緒に走り直す) — 残れば次の回に回す" ;;
    *"Only jobs from the current attempt"*)
      say "#$n: $name は古い attempt のジョブで打ち直せない — 新しい attempt の側を見る" ;;
    *)
      say "#$n: $name を rerun できなかった: $(reason)" >&2
      failed=1
      ;;
  esac
  return 1
}

rerun_stale_jobs() { # $1=PR 番号
  local n=$1 sha runs name id run concl pass legacy=" " failing="" acted=0
  sha=$(gh pr view "$n" --repo "$REPO" --json headRefOid --jq '.headRefOid' 2>"$errfile") || {
    say "#$n: head の commit を読めなかった: $(reason)" >&2
    failed=1
    return 0
  }
  # check run の id は、Actions のジョブ id そのものである。古い run を見分けるため、失敗して
  # いないものも含めて「id 結論 run 名前」で全部引く (名前は空白を含みうるので最後に置く)。
  # --paginate の --jq はページごとに当たるので、run の束ね方はここではなく下の bash で行う
  runs=$(gh api "repos/$REPO/commits/$sha/check-runs" --paginate \
    --jq '.check_runs[] | "\(.id) \(.conclusion // "-") \((.details_url // "")
          | (capture("/actions/runs/(?<r>[0-9]+)").r // "0")) \(.name)"' 2>"$errfile") || {
    say "#$n: check run の一覧を読めなかった: $(reason)" >&2
    failed=1
    return 0
  }
  while read -r id concl run name; do
    [ -n "${name:-}" ] || continue
    case " $LEGACY_JOBS " in *" $name "*) [ "$run" = 0 ] || legacy="$legacy$run " ;; esac
  done <<<"$runs"
  while read -r id concl run name; do
    [ -n "${name:-}" ] || continue
    case "$concl" in failure | cancelled | timed_out | startup_failure) ;; *) continue ;; esac
    case "$legacy" in
      *" $run "*)
        say "#$n: $name は作法のジョブを含む古い ci.yml の run ($run) に居るので rerun しない (古いイベントを再生し、ci-gate は needs の赤で赤く返す・#2669)"
        continue
        ;;
    esac
    failing+="$name $id"$'\n'
  done <<<"$runs"
  # 集約 (RERUN_LAST) を後ろへ回す 2 周。理由は冒頭の「集約のジョブは最後に打つ」
  for pass in first last; do
    while read -r name id; do
      [ -n "${id:-}" ] || continue
      if last "$name"; then [ "$pass" = last ] || continue; else [ "$pass" = first ] || continue; fi
      if rerun_job "$n" "$name" "$id"; then acted=1; fi
    done <<<"$failing"
  done
  [ "$acted" -eq 1 ] || say "#$n: 打てる失敗ジョブが無かった"
}

while read -r number kind action _rest; do
  [ -n "${number:-}" ] || continue
  [ "${action:-}" = act ] || continue
  case "$kind" in
    stale-checks) rerun_stale_jobs "$number" ;;
    *) say "打ち方を知らない分類: $kind (#$number)" >&2; failed=1 ;;
  esac
done <"$LOG"

exit "$failed"
