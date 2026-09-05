#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 窓を出して走らせているスケッチへ、観測と入力の要求を続けて置き、すべてに応答が返るか
# 数える。フレーム番号が進み続けていることも同時に見る。
#
# #221 の受け入れ条件そのもの。区画のファイルを直に叩くので、道具 (窓口・見張り) を
# 挟まずに面だけを測る — 面の能力が窓口の実装に閉じ込められていないことは ADR-0018
# 決定 1 の前提でもある。
#
# **画面と GPU が要るので `make ci-check` には入れない** (#180)。手元で確かめる手順を
# 毎回組み直さずに済ませるために置いてある。
#
# 使い方:
#   scripts/check-observation-roundtrip.sh [回数] [1 回あたりの待ちの上限 (秒)]
#   scripts/check-observation-roundtrip.sh --minimized [回数] [待ちの上限]
#   scripts/check-observation-roundtrip.sh --display-asleep [回数] [待ちの上限]
#
# --minimized は #223 の受け入れ条件。窓を畳んでも面が応答し続けることを見る。
#
# --display-asleep は #874 の受け入れ条件。**打つと画面が実際に消える** — 他の条件と
# 違って、測っている間じゅう打った人の画面が暗いままになる (終わると戻る)。ディスプレイ
# のスリープは自プロセスからは作れないので `pmset displaysleepnow` で作り、復帰は
# `caffeinate -u` で行う。測る側は --allow-display-sleep で断りを外して走らせる —
# 断ったまま測ると「スリープを作れなかったのに緑」という嘘が出る。
set -euo pipefail

# **自分の隣を基準にする。** `$0` は source されると呼び出し側を指し、cwd にも依存する
# (#820)。`BASH_SOURCE` はこのファイル自身の場所で、`pwd -P` が symlink も解く
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPO="$(pwd)"

MINIMIZED=0
DISPLAY_ASLEEP=0
if [ "${1:-}" = "--minimized" ]; then
  MINIMIZED=1
  shift
elif [ "${1:-}" = "--display-asleep" ]; then
  DISPLAY_ASLEEP=1
  shift
fi

ROUNDS="${1:-100}"
DEADLINE="${2:-1.5}"

WORK="$(mktemp -d)"
SKETCH_PID=""
cleanup() {
  [ -n "$SKETCH_PID" ] && kill "$SKETCH_PID" 2>/dev/null
  # **画面を戻してから終わる。** 途中で落ちても暗いままにしない
  [ "$DISPLAY_ASLEEP" = 1 ] && caffeinate -u -t 1 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

if [ "$DISPLAY_ASLEEP" = 1 ]; then
  # **測る側の断りを外す。** 外さないと `pmset displaysleepnow` を打っても
  # すぐ戻ってしまい、測っていないのに緑になる (#874)
  echo "== 測るための窓を出す (この後に画面を消す) =="
  swift build >/dev/null
  FACETS="$WORK"
  mkdir -p "$FACETS/.mokume/observe" "$FACETS/.mokume/input"
  MOKUME_WORK_DIR="$FACETS" ./.build/debug/frame-rate-probe \
    --seconds "$((ROUNDS * 2 + 60))" --allow-display-sleep >/dev/null &
  SKETCH_PID=$!
  sleep 6
  echo "== 画面を消す (測り終わるまで暗いまま) =="
  pmset displaysleepnow
  sleep 3
elif [ "$MINIMIZED" = 1 ]; then
  # **測る側に自分で畳ませる。** よそのプロセスの窓を osascript から畳むには
  # アクセシビリティの許可が要り、許可の無い環境では「面が応答しなかった」と
  # 「窓を畳めなかった」を区別できない (#223)
  echo "== 測るための窓を出す (3 秒後に自分で畳む) =="
  swift build >/dev/null
  FACETS="$WORK"
  mkdir -p "$FACETS/.mokume/observe" "$FACETS/.mokume/input"
  MOKUME_WORK_DIR="$FACETS" ./.build/debug/frame-rate-probe \
    --seconds "$((ROUNDS * 2 + 60))" --minimize-after 3 >/dev/null &
  SKETCH_PID=$!
  sleep 6
else
  # **いま手元にあるライブラリを測る。** ひな形が既定で指すのは公開済みの版なので、
  # --local でこの作業ツリーへ向け直す
  echo "== ひな形のスケッチを作る =="
  swift run mokume-cli new roundtrip --path "$WORK" --local "$REPO" >/dev/null

  SKETCH="$WORK/roundtrip"
  echo "== 作って走らせる (窓が出る) =="
  (cd "$SKETCH" && swift build >/dev/null)
  FACETS="$SKETCH"
  mkdir -p "$FACETS/.mokume/observe" "$FACETS/.mokume/input"
  (cd "$SKETCH" && exec ./.build/debug/roundtrip) &
  SKETCH_PID=$!
  sleep 3
fi

echo "== 観測と入力の要求を $ROUNDS 回続けて置く =="
# 置き方・待ち方は ADR-0018 決定 3 の規約で、実装は scripts/observe_lib.py の 1 つだけ。
# 数える側も .py へ出してある — 埋まったままでは lint も unittest も見ず、この手順は
# 画面と GPU が要るので make ci-check にも入っていない (#817)
python3 scripts/observation_roundtrip.py "$FACETS/.mokume" "$ROUNDS" "$DEADLINE"
