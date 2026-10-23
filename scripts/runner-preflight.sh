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
#   gpu-slot GPU の待ちの期限切れの記録 (wait-expired.json) が無い (#2235)
#
# **gpu-slot の記録は、専用機では job をまたいで残る。** 検査・計測を包む gpu-slot.py の置き場
# ($MOKUME_GPU_SLOT_DIR・既定は runner の ~/Library/Caches/mokume/gpu-slots) が runner のユーザーに
# 固定されているので、GPU の待ちが期限を越えた回が書いた記録 (scripts/gpu-slot.py の「## 期限切れの
# 記録」) は、手で消すまで次の job にも見える。残ったままだと、以後の検査は gpu-slot が起こさず 76 で
# 落ち続ける。それは PR の赤ではなく機械の状態なので、検査の前にここで名乗って、既存の発信
# (render-environment-report) で人に届ける。消すのは人 (GPU が答えることを確かめてから)。
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

slot_dir=${MOKUME_GPU_SLOT_DIR:-$HOME/Library/Caches/mokume/gpu-slots}
expiry_record="$slot_dir/wait-expired.json"
if [ -e "$expiry_record" ] || [ -L "$expiry_record" ]; then
  problems+=("gpu-slot: GPU の待ちが期限を越えた記録が残っている (${expiry_record})。人が GPU の答えを確かめて消すまで、検査は gpu-slot が起こさず 76 で止まる")
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
    printf '\nPR の中身による赤ではない。\n'
    case "$reason" in
      *"console:"* | *"screens:"* | *"metal:"*)
        printf '直し方 (console・screens・metal): 専用機の前で、表の GUI セッションを runner のユーザーに戻す (#2507)。\n' ;;
    esac
    case "$reason" in
      *"gpu-slot:"*)
        printf '直し方 (gpu-slot): 専用機の前で、画面が固まっていない・前の検査プロセスが残っていない (bash scripts/orphan-processes.sh)・GPU が答える、を確かめてから、記録のファイル (%s) を人が削除する。確かめる前に消すと、答えない GPU に新しい発行口を作って機械ごと止まりうる。中身には、期限を越えた待ちと起動元がある (scripts/gpu-slot.py の「## 期限切れの記録」・#2235)。\n' "$expiry_record" ;;
    esac
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'reason=%s\n' "$reason" >> "$GITHUB_OUTPUT"
fi

exit 1
