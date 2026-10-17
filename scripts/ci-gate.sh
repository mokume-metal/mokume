#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# ci.yml の必須チェック ci-gate の判定。呼ぶのは ci.yml の ci-gate だけである。
#
#   RESULTS=<toJSON(needs)> EVENT_NAME=<github.event_name> bash scripts/ci-gate.sh
#
# ## 赤にするもの
#
# - needs の failure と cancelled (どの event でも)
# - pull_request の run の skipped (#2690・#2718。下の段落)
# - EVENT_NAME が無い・知らない event (下の段落の最後)
#
# merge_group では skipped を通す。いまは merge_group で skipped になる段が無い。
#
# ## pull_request の run の skipped を赤にする理由 (#2690・#2718)
#
# ci.yml は本文・タイトル・base の編集 (edited) では起きない (#2718)。pull_request の run はどれも
# コードを走らせる run (opened・synchronize・reopened) で、段を走らせる 2 つ (ci-check・ci-static) は
# `if:` を持たずに必ず走る。skipped が来たら、`if:` か on: が変わった印である。**素通しにしない** —
# 通すと、検査していない run の緑の ci-gate が必須を満たす (#2690 が塞いだ穴)。ci-gate を skipped に
# しても塞がらない (skipped の必須チェックは通過と扱われる)。
#
# **同じ head SHA の検査の結論を待って読む形 (#2690) には戻さない** (#2718)。本文の編集の run の
# ci-gate が、同じ SHA の検査の終わりを最長 90 分待つ形だった。編集のたびに待つ ci-gate が 1 本ずつ
# 重なって ubuntu の runner の枠を削り、待った末の赤は、検査を打ち直して緑にしても必須を塞ぎ続けた
# (#2717・#2727)。編集で run を立てないことで、待つ理由ごと消した。
#
# EVENT_NAME が無い・知らない event を赤にするのは、開く側に倒れると、渡し忘れひとつで素通しに
# 戻るためである。
#
# ## 代償: PR の時点の ci-gate は、その SHA を最後に走らせた run の結論である (#2718)
#
# - **base を付け替えても、PR の時点では検査し直さない。** 前の base で走った run の ci-gate が
#   必須を満たし続ける。#1712 で保った「新しい base との合流後の木を、PR の時点で下限 OS
#   (ADR-0009 の macOS 26) で検査する」保証は手放した。合流後の木は merge_group の render (新しい
#   OS) と ci-check の examples 等が見て、下限 OS の release は release.yml の release-check が版の
#   前に見る。main が進むたびに既に起きている欠け (#1985) と同じ形である
# - reopen では、新しい run の ci-gate が検査の終わるまで作られない。その間は前の run の緑の
#   ci-gate で必須が満たされうる (下の規則の「確かめていないこと」)。合流後の木を見るのは、上と
#   同じく merge_group である
#
# ## 必須の判定が読む check run (#2577)
#
# **必須チェックの規則の置き場はここ 1 か所である** (ci.yml・stall-act.sh・stall-watch.sh・
# pr-gate.yml はここを指す)。観測からの推定で、GitHub の文書では確かめていない:
#
# > 必須の判定は、**ワークフローごとに、作成順で最新の check suite (run) に載った、その名前の
# > check run** を読む。古い suite の赤・cancelled は読まない。同じ run の打ち直しは同じ suite に
# > 載るので、打ち直した結論がその suite の結論になる。
#
# 作成順は check suite の id の順で読む。どの観測でも作成時刻と食い違わず、Actions の run の id も
# 同じ順に並んでいた (#2696・#2703・#2707・#2710・#2712 の CI と PR gate の run)。**concurrency の
# group に入る順とは違いうる** — #2712 では新しい run が先に group に入り、後から入った古い run に
# cancel された (pr-gate はその後 concurrency を外した・#2716)。
#
# この規則で説明できる観測 (run と suite の id は #2577 の本文):
#
#   #2543          古い suite の赤い pr-title・ci-gate を残したまま merge された
#   #2688          新しい suite の緑の ci-gate が、走っている古い suite を待たずに必須を満たした
#   #2696          新しい suite (本文の編集の run) の赤い ci-gate が、古い suite の緑で上書きされず
#                  11 時間 BLOCKED。打ち直して CLEAN
#   #2717          古い suite の検査を打ち直して緑にしても、その suite の ci-gate が走り直すだけで、
#                  新しい suite (本文の編集の run) の赤い ci-gate は残った
#   #2712          作成と同時のラベルで同じ秒に立った pr-gate のうち、新しい suite のほうが cancelled
#                  で BLOCKED。打ち直して CLEAN (#2716)
#   #2710 ほか     cancelled の pr-gate が古い suite のほうで、止まらずに merge された (#2707・#2703 も)
#
# **確かめていないこと (#2692)**: 最新の suite にその名前がまだ無いとき、前の suite の結論で必須が
# 満たされるか。#279 (API で上書きした check run が最初の suite に居続けた回) は「待ち」と記録して
# いるが、ci-gate で測った記録は無い。満たされるとしても上の代償の reopen の形で、合流後の木は
# merge_group が見るので、測らずに置く (#2692 は測らずに閉じた・#2718)。

set -euo pipefail

: "${RESULTS:?toJSON(needs) を渡す}"
: "${EVENT_NAME:?github.event_name を渡す}"

echo "$RESULTS"
# パイプにしない (#2609)。pipefail の下では、grep -q が一致して先に抜けたときに
# 書き終えていない printf が SIGPIPE で落ち、if が偽 (= 落ちていない) と読む
if grep -Eq '"result": *"(failure|cancelled)"' <<<"$RESULTS"; then
  echo "必須ジョブが落ちている" >&2
  exit 1
fi

case "$EVENT_NAME" in
  merge_group) exit 0 ;;
  pull_request) ;;
  *) echo "知らない event: $EVENT_NAME (ci.yml の on: と合わせる)" >&2; exit 1 ;;
esac

skipped=$(jq -r 'to_entries[] | select(.value.result == "skipped") | .key' <<<"$RESULTS")
[ -n "$skipped" ] || exit 0

while read -r name; do
  echo "$name: この run では skipped — pull_request の run では段を走らせるジョブは必ず走る (ci.yml の on: と if: を見る・#2690・#2718)" >&2
done <<<"$skipped"
exit 1
