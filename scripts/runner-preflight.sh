#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 専用機の job の最初に、検査を走らせられる環境かを数秒で確かめる (#2588)。
#
#   runner-preflight.sh
#
# 専用機の表の GUI セッションが runner から別のユーザーへ替わると、runner からは画面が
# 0 枚に見える (#2507)。そのまま `make ci-check` を走らせると、約 14 分かけて窓の検査が
# 19 件落ちてから赤になる。merge queue はそれを PR の赤と見分けられず、先頭の PR を
# 1 本ずつ弾き続けた (2026-10-12 に 14 回)。原因が分かったのは翌朝だった。
#
# ここは**検査の範囲を変えない**。検査の前に、環境が壊れていれば落ちて名乗るだけで、
# 通れば続く `make` がこれまでどおり全部を走らせる。
#
# ## 見るもの
#
#   console  /dev/console の持ち主 (表の GUI セッション) が job のユーザーと同じ — #2507 の根
#   screens  job のユーザーから見える画面が 1 枚以上 (NSScreen.screens)
#   metal    Metal の既定のデバイスが取れる (MTLCreateSystemDefaultDevice)
#
# 当たったものは全部名乗る (1 つ目で止めない)。直す人が専用機の前に立つのは 1 回で済ませたい。
# 画面と Metal は osascript (JXA) で読む。手元の実測で 0.1 秒で、swift のスクリプトのように
# 組み立てを待たない。**読めない (osascript が落ちる・数でない) も赤にする。** 黙って通すと
# 14 分の赤に戻る。
#
# ## 出力
#
# 当たれば `::error::` を 1 条件 1 行で出し、$GITHUB_STEP_SUMMARY があれば直し方を添えて書き、
# $GITHUB_OUTPUT があれば `reason=<1 行の要約>` を書いて 1 で終える。render.yml は reason を
# job の出力へ上げ、GitHub ホストの render-environment-report が発信に使う
# (scripts/report-runner-environment.sh)。当たらなければ 1 行出して 0 で終える。
#
# 呼び出しは .github/workflows/render.yml の専用機の 4 job、検査は
# scripts/tests/runner_preflight_test.py。
set -uo pipefail

job_user=$(id -un)
problems=()

console_user=$(stat -f %Su /dev/console 2>/dev/null || true)
if [ -z "$console_user" ]; then
  problems+=("console: /dev/console の持ち主を読めない")
elif [ "$console_user" != "$job_user" ]; then
  problems+=("console: 表の GUI セッションが ${console_user} で、job のユーザー (${job_user}) ではない")
fi

screens=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSScreen.screens.count' 2>/dev/null || true)
case "$screens" in
  '' | *[!0-9]*) problems+=("screens: job のユーザーから画面の枚数を読めない (${screens:-出力なし})") ;;
  0) problems+=("screens: job のユーザーから見える画面が 0 枚") ;;
esac

metal=$(osascript -l JavaScript -e 'ObjC.import("Metal"); var d = $.MTLCreateSystemDefaultDevice(); d.isNil() ? "" : ObjC.unwrap(d.name)' 2>/dev/null || true)
if [ -z "$metal" ]; then
  problems+=("metal: Metal の既定のデバイスが取れない")
fi

if [ ${#problems[@]} -eq 0 ]; then
  echo "runner-preflight: 検査を走らせられる (表のセッション ${console_user}・画面 ${screens} 枚・${metal})"
  exit 0
fi

for p in "${problems[@]}"; do
  echo "::error title=専用機の環境::$p"
done

reason=""
for p in "${problems[@]}"; do
  reason="${reason:+$reason / }$p"
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '## 専用機の環境が検査を走らせられない状態で、検査の前に止めた (#2588)\n\n'
    for p in "${problems[@]}"; do
      printf -- '- %s\n' "$p"
    done
    printf '\nPR の中身による赤ではない。直し方: 専用機の前で、表の GUI セッションを runner のユーザーに戻す (#2507)。\n'
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'reason=%s\n' "$reason" >> "$GITHUB_OUTPUT"
fi

exit 1
