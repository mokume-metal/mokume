#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 定期の「例の絵の前後の比較」の、区間の起点を引く (#2706・ADR-0019 決定 7)。
#
#   drift-base.sh
#
# **起点は、前回までに比べ終えた定期の run の head の SHA** である。render.yml の定期の run は
# 6 時間おきに main の先端を検査し、`scheduled-drift` の job が「起点 … 今の先端」の区間で
# 例の絵を描き比べる (scripts/scheduled-drift.sh)。比べ終えた最後の run を引けば、区間は
# 切れ目なく続く — main に入った変更が、render-pr が見送られた PR の分も含めてすべて
# どこかの区間に入る。
#
# **「比べ終えた」は `scheduled-drift` の job が success で終わったことである。** run 全体の
# 結論は見ない: debug か release が赤で終わった run でも、比べる job が success なら区間は
# 閉じており (定期の run の赤は debug の検査の話で、比べるのとは別の問い)、逆に run が緑でも
# 比べる job が落ちていれば区間は閉じていない。job が success になるのは、比べ終えたか、
# **比べないと決めて理由を要約に書いた**ときだけ (scheduled-drift.sh)。落ちた回の起点は
# 動かず、次の回の区間が伸びる。
#
# 出力 (`$GITHUB_OUTPUT`。無ければ標準出力):
#   base=<SHA>   起点。引けなければ空
#   reason=none  直近の定期の run に、比べ終えた回が 1 本も無い (初回・長く止まっていた後)
#   reason=api   GitHub の API を読めなかった (起点が分からない。比べる側は赤で止まる)
#   reason=      起点を引けた
#
# 読むのは `actions: read` だけで、書かない。専用機の job は secrets も token も持たないので
# (ADR-0019 決定 7)、API を読むこの手続きは GitHub ホストの門番の job が持つ
# (render-turn.sh と同じ置き場。.github/workflows/render.yml の scheduled-drift-turn)。
# 検査は scripts/tests/scheduled_drift_test.py。
set -euo pipefail

# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"
REPO="$(this_repo)"

# 比べる job の名前 (render.yml の job id と同じ。名前を付けない job の `name` は id になる)
readonly DRIFT_JOB="scheduled-drift"
# 遡る定期の run の数。6 時間おきなので 40 本は 10 日で、専用機が長く止まっていた後の
# 区間をここで諦める上限になる (越えたら reason=none で、起点を取り直す)
readonly LOOKBACK="${DRIFT_LOOKBACK:-40}"

emit() { # $1=base $2=reason
  local out="${GITHUB_OUTPUT:-/dev/stdout}"
  printf 'base=%s\n' "$1" >> "$out"
  printf 'reason=%s\n' "$2" >> "$out"
}

run_id="${GITHUB_RUN_ID:-0}"

# 新しい順の (run の ID, head の SHA)。完了した run だけを読む
if ! runs=$(gh api "repos/$REPO/actions/workflows/render.yml/runs?event=schedule&status=completed&per_page=$LOOKBACK" \
  --jq '.workflow_runs[] | [.id, .head_sha] | @tsv'); then
  echo "drift-base: 定期の run の一覧を読めなかった" >&2
  emit "" api
  exit 0
fi

while IFS=$'\t' read -r id sha; do
  [ -n "$id" ] || continue
  [ "$id" != "$run_id" ] || continue
  if ! conclusion=$(gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" \
    --jq "[.jobs[] | select(.name == \"$DRIFT_JOB\") | .conclusion][0] // \"\""); then
    echo "drift-base: run $id の job を読めなかった" >&2
    emit "" api
    exit 0
  fi
  if [ "$conclusion" = success ]; then
    echo "drift-base: 起点は run $id の $sha"
    emit "$sha" ""
    exit 0
  fi
done <<< "$runs"

echo "drift-base: 直近 $LOOKBACK 本の定期の run に、比べ終えた回が無い"
emit "" none
