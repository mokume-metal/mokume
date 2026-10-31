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
#   orphan-load 前の job が残した負荷 (ppid=1 で CPU を使い続けるプロセス) が無い (#3095)
#
# **gpu-slot の記録は、専用機では job をまたいで残る。** 検査・計測を包む gpu-slot.py の置き場
# ($MOKUME_GPU_SLOT_DIR・既定は runner の ~/Library/Caches/mokume/gpu-slots) が runner のユーザーに
# 固定されているので、GPU の待ちが期限を越えた回が書いた記録 (scripts/gpu-slot.py の「## 期限切れの
# 記録」) は、手で消すまで次の job にも見える。残ったままだと、以後の検査は gpu-slot が起こさず 76 で
# 落ち続ける。それは PR の赤ではなく機械の状態なので、検査の前にここで名乗って、既存の発信
# (render-environment-report) で人に届ける。消すのは人 (GPU が答えることを確かめてから)。
#
# **orphan-load は、前の job が専用機に残した負荷が、後の job を黙って遅くするのを塞ぐ** (#3095)。
# 2026-10-19 に使い捨ての検査が立てた `yes` 10 本が、落ちた拍子に止められないまま ppid=1 に再親付けされ、
# 約 2 日 9 時間 CPU を使い続けた。その間、render の CPU の側は半分の速さになったが、どこにも赤は出なかった
# (#3010)。job のユーザーの ps から、ppid=1・%CPU が閾値超・経過時間が下限超のものを数える。
#
#   ・**経過時間の下限があるのは、一時の山を残りと取り違えないため。** macOS の ps の %CPU は直近の減衰平均なので、
#     閾値だけでは job 内の一時的な負荷や索引の山 (mdworker_shared など。専用機の表の GUI セッションは runner の
#     ユーザーで、その ppid=1 のプロセスは常に多数ある) を拾う
#   ・**出所で拾う** (#3631)。赤にするのは、実行ファイル (ps の comm) か作業ディレクトリ (lsof の cwd) が
#     job の置き場にあるものだけ。表の GUI セッションが runner のユーザーなので、OS の常駐 (写真の解析の
#     `mediaanalysisd` など) やログイン項目のアプリもユーザーの launchd の子として ppid=1 に見え、何日も CPU を
#     使い続けうる。それは前の job の残りではないので赤にせず、注意 (::warning) で名乗る。comm は親が決める
#     起動名 (argv[0]) で実行ファイルの置き場を保証しないので、「OS の置き場なら外す」形は採らない。#2959 の
#     `yes` (/usr/bin/yes) は作業ディレクトリが checkout なので拾う。job の置き場は次のとおり (前置きは区切りの
#     `/` まで見る。/System/Volumes/Data/ の firmlink の経路も同じ置き場に読む):
#
#       実行ファイル・作業ディレクトリの両方で見る
#         runner の _work      $GITHUB_WORKSPACE (`…/_work/<repo>/<repo>`) の _work と、同じホームの
#                              ~/actions-runner*/_work (専用機は runner 2 本・docs/render-runners.md)
#         */.build/*           SwiftPM がパッケージ直下に組んだもの
#         共有の組み立て置き場  $MOKUME_BUILD_DIR (既定 ~/Library/Caches/mokume/build・ADR-0037)
#       実行ファイルだけで見る (OS の常駐にも作業ディレクトリをここに置くものがある — privatecloudcomputed)
#         /private/tmp/・/tmp/・job のユーザーの一時の置き場 (getconf DARWIN_USER_TEMP_DIR)
#
#     作業ディレクトリを読む lsof が無い・runner の作業場所が分からない (job の中で $GITHUB_WORKSPACE が形に
#     合わない) は、黙って注意に回さず赤にする。ORPHAN_JOB_ROOTS (`:` 区切り) は検査のための差し替えで、
#     runner の _work の代わりに使う
#   ・**何も殺さない。** 名乗って止めるだけで、止めるのは人 (出所は lsof の cwd で引く。scripts/orphan-processes.sh が
#     見るのは .build・共有の組み立て置き場から起きたものだけ)
#   ・閾値 (ORPHAN_CPU_MIN・ORPHAN_ELAPSED_MIN) は専用機の平常の ps を読んで確定する (#3095)
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

# 前の job が残した負荷。ps の出力は `pid ppid %cpu etime comm` (comm は空白を含みうるので最後)。
# etime は `[[dd-]hh:]mm:ss`。名乗る項目は PID・名前 (パスの末尾)・%CPU・経過時間。
# **閾値は仮置き** — 専用機の平常の ps を読んで確定する (#3095)。環境変数で差し替えられるのは検査のため
ORPHAN_CPU_MIN=${ORPHAN_CPU_MIN:-50}
ORPHAN_ELAPSED_MIN=${ORPHAN_ELAPSED_MIN:-600}

# job の置き場 (冒頭の表)。前置きで持ち、照合は区切りの `/` まで見る
work_roots=()
if [ -n "${ORPHAN_JOB_ROOTS:-}" ]; then
  IFS=: read -r -a work_roots <<<"$ORPHAN_JOB_ROOTS"
else
  case "${GITHUB_WORKSPACE:-}" in
    */_work/*/*) work_roots+=("${GITHUB_WORKSPACE%%/_work/*}/_work") ;;
  esac
  for root in "$HOME"/actions-runner*/_work; do
    [ -d "$root" ] && work_roots+=("$root")
  done
fi
if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ ${#work_roots[@]} -eq 0 ]; then
  problems+=("orphan-load: runner の作業場所が分からない (GITHUB_WORKSPACE が …/_work/<repo>/<repo> の形でない: '${GITHUB_WORKSPACE:-}')")
fi
build_root="${MOKUME_BUILD_DIR:-$HOME/Library/Caches/mokume/build}"
# 空の配列を "${a[@]}" で開くと、macOS の bash 3.2 は set -u で落ちる
shared_roots=(${work_roots[@]+"${work_roots[@]}"} "${build_root%/}")
temp_roots=(/private/tmp /tmp)
user_temp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)
if [ -n "$user_temp" ]; then
  temp_roots+=("${user_temp%/}")
  # /var は /private/var の別名。ps と lsof はどちらでも返しうるので両方を持つ
  case "$user_temp" in
    /var/*) temp_roots+=("/private${user_temp%/}") ;;
  esac
fi

# 置き場のどれかの下にあるか。$1 は見る置き場の種類 (exe = 実行ファイル・cwd = 作業ディレクトリ)
in_job_place() {
  local kind=$1 path=$2 root
  # データボリュームの firmlink (/System/Volumes/Data/Users/… は /Users/… と同じ所)
  path=${path#/System/Volumes/Data}
  case "$path" in */.build/*) return 0 ;; esac
  local roots=("${shared_roots[@]}")
  [ "$kind" = "exe" ] && roots+=("${temp_roots[@]}")
  for root in "${roots[@]}"; do
    [ -n "$root" ] || continue
    case "$path" in "${root%/}"/*) return 0 ;; esac
  done
  return 1
}

# 作業ディレクトリ。引けない (消えた・権限が無い) のは想定の範囲なので空を返す
cwd_of() {
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sed -n '1p' || true
}

if processes=$(ps -U "$job_user" -o pid=,ppid=,%cpu=,etime=,comm= 2>/dev/null); then
  heavy=$(printf '%s\n' "$processes" | awk -v cpu_min="$ORPHAN_CPU_MIN" -v elapsed_min="$ORPHAN_ELAPSED_MIN" '
    function seconds(etime,   days, rest, parts, n) {
      days = 0
      rest = etime
      if (index(etime, "-") > 0) {
        days = substr(etime, 1, index(etime, "-") - 1)
        rest = substr(etime, index(etime, "-") + 1)
      }
      n = split(rest, parts, ":")
      if (n == 3) return days * 86400 + parts[1] * 3600 + parts[2] * 60 + parts[3]
      if (n == 2) return days * 86400 + parts[1] * 60 + parts[2]
      return -1
    }
    $2 == 1 && $3 + 0 > cpu_min && seconds($4) > elapsed_min {
      name = $5
      for (i = 6; i <= NF; i++) name = name " " $i
      printf "%s\t%s\t%s\t%s\n", $1, $3, $4, name
    }')
  orphans="" others=""
  # 作業ディレクトリを読めないと、#2959 の形 (実行ファイルは /usr/bin・cwd が checkout) が黙って注意に落ちる
  if [ -n "$heavy" ] && ! command -v lsof >/dev/null 2>&1; then
    problems+=("orphan-load: プロセスの作業ディレクトリを読む lsof が無いので、前の job の残りか見分けられない")
  fi
  while IFS=$'\t' read -r pid cpu etime comm; do
    [ -n "$pid" ] || continue
    line="${comm##*/} (pid ${pid}, ${cpu}%, 経過 ${etime})"
    if { [ "${comm#/}" != "$comm" ] && in_job_place exe "$comm"; } || in_job_place cwd "$(cwd_of "$pid")"; then
      orphans+="${line}"$'\n'
    else
      others+="${line}"$'\n'
    fi
  done <<<"$heavy"
  orphans=${orphans%$'\n'}
  others=${others%$'\n'}
  if [ -n "$orphans" ]; then
    orphan_count=$(printf '%s\n' "$orphans" | wc -l | tr -d ' ')
    orphan_list=$(printf '%s\n' "$orphans" | sed -n '1,5p' | paste -sd '|' - | sed 's/|/, /g')
    orphan_more=""
    if [ "$orphan_count" -gt 5 ]; then orphan_more=" ほか $((orphan_count - 5)) 本"; fi
    problems+=("orphan-load: 前の job が残した負荷が ${orphan_count} 本ある (ppid=1 で CPU が ${ORPHAN_CPU_MIN}% 超・経過 $((ORPHAN_ELAPSED_MIN / 60)) 分超): ${orphan_list}${orphan_more}。何も止めていない。出所を確かめて人が止める")
  fi
  # job の置き場の外の重い負荷は、前の job の残りではないので赤にしない。検査を黙って遅くはするので名乗る
  if [ -n "$others" ]; then
    others_list=$(printf '%s\n' "$others" | sed -n '1,5p' | paste -sd '|' - | sed 's/|/, /g')
    others_count=$(printf '%s\n' "$others" | wc -l | tr -d ' ')
    others_more=""
    if [ "$others_count" -gt 5 ]; then others_more=" ほか $((others_count - 5)) 本"; fi
    notice="orphan-load: job の置き場の外のプロセスが CPU を使い続けている (前の job の残りではないので赤にしない。検査は遅くなりうる): ${others_list}${others_more}"
    echo "::warning title=専用機の環境::${notice}"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      printf -- '- 注意: %s\n' "$notice" >> "$GITHUB_STEP_SUMMARY"
    fi
  fi
else
  problems+=("orphan-load: job のユーザーのプロセスの一覧 (ps) を読めない")
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
      *"orphan-load:"*)
        printf '直し方 (orphan-load): 専用機の前で、名乗られた PID の出所 (lsof -a -p <PID> -d cwd の作業ディレクトリ・ps -o command= -p <PID>) を確かめ、人が止める。この前検査は何も止めない。残ったままだと、後の job が黙って遅くなる (#3010・#3095)。\n' ;;
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
