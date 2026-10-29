#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 定期の run で、前回の区間の起点から今の main までの例の絵の画素のずれを読む (#2706)。
# 専用機の job `scheduled-drift` が走らせる。
#
#   scheduled-drift.sh      (起点は環境変数 DRIFT_BASE / DRIFT_BASE_REASON で受ける)
#
# **塞ぐのは「render-pr が名指しした絵のずれが、merge の後に誰の手元にも残らない」である。**
# render-pr の名指しは PR の上の警告で、止めない (scripts/example-shots.py 冒頭「指紋が見て
# いない範囲」)。merge queue が専用機を待つ間は render-pr ごと見送られるので名指しが出ない
# こともあり、#2705 では 13 枚が 11 日残って、無関係の作業で偶然見つかった。ここは PR を
# 見ずに、**main の区間の差** — 前回の定期の run が比べ終えた SHA (scripts/drift-base.sh) から
# 今の main まで — を、同じ専用機・同じ OS で描き比べる。区間に入った変更は、render-pr が
# 見送られた PR の分も含めてすべて読む。merge されなかった PR の分は入らない。
#
# ## 描くか
#
#   - 起点が無い (初回・長く止まった後) — 区間が分からないので描かない。**その旨を run の
#     要約へ書き**、job は success で終わる (この回が次の起点になる)
#   - 起点が今の main と同じ — 区間が空
#   - 区間に描画のパスへ触れた変更が無い — 描かない。判定は render-pr と同じ
#     scripts/drawing-paths.sh の 1 つを読む
#   - それ以外 — `example-shots.py --drift <起点> --drift-record <記録>`
#
# **job が success で終わるのは、比べ終えたか、比べないと決めて要約に書いたときだけ。**
# API を読めなかった回 (reason=api) と、起点を受け取れなかった回 (reason が空で base も空) は
# 区間を閉じられないので赤で終わり、次の回の区間が伸びる (起点は success の job から引く)。
# 起点の commit が remote から消えた回は、取れる起点が無いのと同じなので、書いて success で終える
# (赤のまま残すと、起点が動かず毎回落ちる)。取得の失敗 (起点は在る) は赤で、区間を伸ばす。
#
# ## 記録
#
# `.build/scheduled-drift/` (DRIFT_RECORD) に `summary.md`・`drifts.tsv` (変わった絵 1 本 1 行・
# 無ければ空)・`range.txt` (起点と今の SHA) を置く。専用機の job は書き込みの token を持たない
# (ADR-0019 決定 7) ので、artifact で GitHub ホストの `scheduled-report` へ渡し、そちらが
# scripts/report-example-drift.sh で起票する。変わった絵の本数は `$GITHUB_OUTPUT` の
# `drift-count` へ出す (起票の job の `if:` が読む)。
#
# 検査は scripts/tests/scheduled_drift_test.py。
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/drawing-paths.sh
. "$here/drawing-paths.sh"

RECORD="${DRIFT_RECORD:-.build/scheduled-drift}"
BASE="${DRIFT_BASE:-}"
REASON="${DRIFT_BASE_REASON:-}"
# 検査は偽のスクリプトへ向ける
EXAMPLE_SHOTS="${EXAMPLE_SHOTS:-$here/example-shots.py}"

rm -rf "$RECORD"
mkdir -p "$RECORD"
: > "$RECORD/drifts.tsv"

head_sha=$(git rev-parse HEAD)
printf '%s %s\n' "${BASE:-none}" "$head_sha" > "$RECORD/range.txt"

emit_count() { # $1=本数
  printf 'drift-count=%s\n' "$1" >> "${GITHUB_OUTPUT:-/dev/null}"
}

# 比べないと決めた回の理由を、run の要約と記録へ書く
say() { # $1=本文
  local text
  text=$(printf '## 例の絵の前後の比較 (定期)\n\n%s\n' "$1")
  printf '%s\n' "$text" > "$RECORD/summary.md"
  printf '%s\n' "$text" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  echo "$1"
}

if [ -z "$BASE" ]; then
  case "$REASON" in
    none)
      say "前回までに比べ終えた定期の run が見つからない (初回か、長く止まっていた後)。区間が分からないので、**例の絵は比べない**。この回が次の区間の起点になる。"
      emit_count 0
      exit 0
      ;;
    api)
      say "前回の定期の run を GitHub の API から読めなかった。区間が分からないので、**例の絵は比べない**。この job は赤で終わり、次の回の区間は今回の分を含めて伸びる。"
      emit_count 0
      exit 1
      ;;
    *)
      say "区間の起点を、前の job (scheduled-drift-turn) から受け取れなかった。**例の絵は比べない**。この job は赤で終わり、次の回の区間は今回の分を含めて伸びる。"
      emit_count 0
      exit 1
      ;;
  esac
fi

if [ "$BASE" = "$head_sha" ]; then
  say "起点 \`$BASE\` が今の main と同じで、区間が空。**例の絵は比べない**。"
  emit_count 0
  exit 0
fi

# 起点の commit を取り寄せる (checkout は浅い)。**取得の失敗と、起点が本当に消えたことを分ける。**
# 起点が remote から消えた (到達できない) ときだけ、取れる起点が無いのと同じなので書いて success で
# 終え、区間を捨てる (赤のままだと、起点が動かず毎回落ちる)。ネットワークや認証の失敗は、起点は在る
# のに取れなかっただけなので赤で終え、次の回の区間を伸ばす (success にすると、この区間の名指しが
# 黙って消える)
if ! git cat-file -e "$BASE^{commit}" 2>/dev/null; then
  if ! fetch_err=$(git fetch --no-tags --depth=1 origin "$BASE" 2>&1); then
    case "$fetch_err" in
      *"not our ref"* | *"couldn't find remote ref"* | *"unadvertised object"* | *"no such remote ref"*)
        say "起点 \`$BASE\` の commit が remote に無い (main から消えて、到達できない)。**例の絵は比べない**。この回が次の区間の起点になる。"
        emit_count 0
        exit 0
        ;;
      *)
        say "起点 \`$BASE\` の commit を取り寄せられなかった (取得の失敗: ${fetch_err//$'\n'/ })。起点は在るので区間は捨てず、**例の絵は比べない**。この job は赤で終わり、次の回の区間は今回の分を含めて伸びる。"
        emit_count 0
        exit 1
        ;;
    esac
  fi
fi

files=$(git diff --name-only "$BASE" "$head_sha")
if ! touches_drawing <<< "$files"; then
  say "区間 \`${BASE:0:8}..${head_sha:0:8}\` に描画のパス (\`scripts/drawing-paths.txt\`) へ触れた変更が無いので、**例の絵は比べない**。"
  emit_count 0
  exit 0
fi

python3 "$EXAMPLE_SHOTS" --drift "$BASE" --drift-record "$RECORD"

count=$(grep -c '' "$RECORD/drifts.tsv" || true)
emit_count "${count:-0}"
