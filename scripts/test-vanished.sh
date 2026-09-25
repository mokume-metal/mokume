#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# `make test` の `swift test` が非 0 で終わった回に、**検査のプロセスが要約を残さずに
# 消えた回かどうか**を記録から見分け、そうなら名乗って、その回の材料を残す (#1526)。
#
# 本体の検査のプロセス (`swiftpm-testing-helper`) が、要約も記録も残さずに消えた回が
# 3 度あった。そのとき出ていたのは `✘ ci-check は [2/27] test で止まった` だけで、
# 上の出力に失敗 (`✘`) は 1 件も無く、`make catch-up` の「上の出力の失敗を直して」も
# 当たらない。しかも打ち直すと `tee` が `.build/test-log.txt` を切り詰め、`rm -f` が
# 記録を消すので、**原因 (#1527) を調べる材料が 1 つも残らなかった**。
#
# ## 何を見て、何を見ないか
#
# **判定は記録 (xunit XML) だけで行う。console は読まない** (#1056)。console の要約
# (`Test run with …`) は全件が緑の回でも落ちるので、「要約が無い」を印にすると緑の回
# でも名乗ってしまう。記録は `read-test-record.py --failures` で読み、消えた回を 3 つの
# 形で名乗る:
#
#   missing      記録が無い (1 度目)
#   unreadable   在るが読めない (3 度目。本物の helper を kill -9 した回もこれだった)
#   failures 0   読めるが失敗を 1 件も持たない (2 度目のように、消えた後も別の検査が
#                走り切って記録を閉じた回)
#
# 記録に失敗が 1 件以上あれば普通の赤なので、何も言わずに抜ける。
#
# **原因は調べない** (それは #1527)。ここが持つのは名乗りと、その回の材料を打ち直しで
# 消えない置き場へ残すことだけである。
#
# ## 材料
#
# `.build/test-vanished/<時刻>/` に置く。記録と同じ派生物の置き場で、worktree を片付け
# れば一緒に消えてよい。**どこへも送らない** — Issue へ貼るかどうかは人が決める。
#
#   summary.txt      いつ・swift test の終了コード・記録の形
#   test-log.txt     その回の .build/test-log.txt
#   record.xml       在れば記録 (途中までのものも)
#   jetsam.txt       段の始まりからのカーネルの memorystatus の行 (jetsam の有無)
#   memory.txt       メモリの状態 (空きの割合・swap)・load average
#   processes.txt    同じ機械で動いている swift / helper のプロセス (常駐の大きさ付き)
#   reports.txt      2 つの DiagnosticReports に、段の始まりより後にできた報告の名前
#
# メモリの状態に `memory_pressure` は使わない。あれは圧迫を**掛ける**道具である
# (`man memory_pressure`)。読むだけなら `sysctl` と `vm_stat` で足りる。
#
# 採れなかった項目 (権限が無い・道具が無い・期限を越えた) は、採れなかったと名乗って
# 続ける。**終了コードは常に 0** — test 段の終了コードは呼ぶ側 (Makefile) が
# `swift test` のものを返す。ここで落ちて段の意味を変えない。
#
# ## 使い方
#
#   bash scripts/test-vanished.sh <swift test の終了コード> <記録> <ログ> <段の始まりの印>
#
# 呼び口は Makefile の test 段の失敗の経路の 1 つだけである。
#
# 環境変数: MOKUME_DIAGNOSTIC_REPORTS  報告の置き場を : 区切りで差し替える (検査用)
# テストは scripts/tests/test_vanished_test.py。

set -uo pipefail

usage() {
  echo "使い方: bash scripts/test-vanished.sh <swift test の終了コード> <記録> <ログ> <段の始まりの印>" >&2
  exit 64
}

[ "$#" -eq 4 ] || usage
case "$1" in '' | *[!0-9]*) usage ;; esac

# リポジトリの owner/repo。**literal は scripts/repo-slug.sh の 1 箇所だけ** (#818)
# shellcheck source=scripts/repo-slug.sh
. "$(dirname "${BASH_SOURCE[0]}")/repo-slug.sh"

readonly CODE=$1 RECORD=$2 LOG=$3 STAMP=$4
readonly CAUSE_ISSUE='#1527'
CAUSE_URL="https://github.com/$(this_repo)/issues/1527"
readonly CAUSE_URL
# log show は統合ログの量次第で長引く。手元で 15 分ぶんが 2 秒だった
readonly LOG_DEADLINE=60
REPORT_DIRS=${MOKUME_DIAGNOSTIC_REPORTS:-$HOME/Library/Logs/DiagnosticReports:/Library/Logs/DiagnosticReports}

verdict="$(python3 "$(dirname "${BASH_SOURCE[0]}")/read-test-record.py" --failures "$RECORD")"
case "$verdict" in
  missing) form="記録が無い" ;;
  unreadable) form="記録が読めない — 途中で切れているか壊れている" ;;
  "failures 0") form="記録は在るが、失敗を 1 件も持たない" ;;
  *) exit 0 ;; # 記録に失敗がある — 普通の赤
esac

# 期限を越えたら殺す。見張りは sleep を子に持つので、自分が止められたら sleep も畳む
# (残すと出力を握らないまでも、期限の秒数だけプロセスが残る)。collect が引数として呼ぶ
# shellcheck disable=SC2329
with_deadline() {
  local secs=$1 pid watch rc
  shift
  "$@" &
  pid=$!
  (
    trap 'kill "$s" 2>/dev/null; exit 0' TERM
    sleep "$secs" &
    s=$!
    wait "$s"
    kill "$pid" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  watch=$!
  wait "$pid"
  rc=$?
  kill "$watch" 2>/dev/null
  wait "$watch" 2>/dev/null
  return "$rc"
}

missed=()
# 1 項目を採る。失敗しても続け、何が採れなかったかを覚えておく
collect() {
  local label=$1 out=$2 rc
  shift 2
  # 材料に書く見出しは、打ち直せる形の本体だけにする (期限の包みは読み手に要らない)
  local shown=("$@")
  [ "$1" = with_deadline ] && shown=("${@:3}")
  {
    printf '$'
    printf ' %q' "${shown[@]}"
    printf '\n'
    "$@" 2>&1
  } >>"$out"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    missed+=("$label (終了コード $rc)")
    printf '(採れなかった: 終了コード %d)\n' "$rc" >>"$out"
  fi
  printf '\n' >>"$out"
}

base=.build/test-vanished
dir="$base/$(date '+%Y%m%d-%H%M%S')"
n=1
candidate=$dir
mkdir -p "$base"
until mkdir "$candidate" 2>/dev/null; do
  n=$((n + 1))
  candidate="$dir-$n"
  [ "$n" -gt 50 ] && { echo "材料の置き場を作れなかった ($base)" >&2; exit 0; }
done
dir=$candidate

started=
if [ -e "$STAMP" ]; then
  started="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$STAMP")"
fi

{
  echo "終わった時刻: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "段の始まり: ${started:-不明 ($STAMP が無い)}"
  echo "swift test の終了コード: $CODE"
  echo "記録の形: $form ($RECORD)"
  echo "原因を調べる Issue: $CAUSE_URL"
} >"$dir/summary.txt"

if [ -e "$LOG" ]; then
  cp "$LOG" "$dir/test-log.txt"
else
  missed+=("ログ ($LOG が無い)")
fi
[ -s "$RECORD" ] && cp "$RECORD" "$dir/record.xml"

if [ -n "$started" ]; then
  collect "カーネルの memorystatus の行 (log show)" "$dir/jetsam.txt" \
    with_deadline "$LOG_DEADLINE" log show --start "$started" \
    --predicate 'process == "kernel" AND eventMessage CONTAINS "memorystatus"'
else
  missed+=("カーネルの memorystatus の行 (段の始まりが分からない)")
fi

collect "sysctl" "$dir/memory.txt" \
  sysctl kern.memorystatus_level vm.memory_pressure vm.swapusage vm.loadavg
collect "vm_stat" "$dir/memory.txt" vm_stat
collect "uptime" "$dir/memory.txt" uptime

# swift を名に含む行だけ残す。見出しの行も残す (列の意味が要る)。collect が引数として呼ぶ
# shellcheck disable=SC2329
swift_processes() {
  ps -axo pid,ppid,rss,etime,command | awk -v me="$$" 'NR == 1 || (/swift/ && $1 != me && $2 != me)'
}
collect "ps" "$dir/processes.txt" swift_processes

IFS=: read -r -a report_dirs <<<"$REPORT_DIRS"
for d in "${report_dirs[@]}"; do
  {
    printf '$ find %s -newer %s\n' "$d" "$STAMP"
    if [ ! -d "$d" ] || [ ! -r "$d" ]; then
      echo "(採れなかった: 読めない)"
      missed+=("報告の名前 ($d が読めない)")
    elif [ ! -e "$STAMP" ]; then
      echo "(採れなかった: 段の始まりが分からない)"
      missed+=("報告の名前 ($d · 段の始まりが分からない)")
    else
      find "$d" -maxdepth 2 -type f -newer "$STAMP" -print 2>&1 | sed 's|.*/||' | sort
    fi
    echo
  } >>"$dir/reports.txt"
done

echo
echo "✘ 検査の失敗ではなく、検査のプロセスが要約を残さずに終わった (swift test の終了コード $CODE)"
echo "   $form ($RECORD)。どの検査が落ちたかは記録からは分からない"
echo "   材料を $dir/ に残した (打ち直しても消えない):"
for f in "$dir"/*; do printf '     %s\n' "${f##*/}"; done
if [ "${#missed[@]}" -gt 0 ]; then
  echo "   採れなかったもの:"
  printf '     %s\n' "${missed[@]}"
fi
echo "   原因は $CAUSE_ISSUE で調べている ($CAUSE_URL)。材料を貼るかどうかは人が決める"
echo "   (ここからはどこへも送らない)。直すものが上の出力に無ければ、打ち直してよい"
exit 0
