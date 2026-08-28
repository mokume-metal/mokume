#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# フレームレートを前面・背面の 2 条件で測る。
#
# ADR-0012 決定 5 は「アプリが前面でない状態でも描画のフレームレートが落ちない」ことを
# 機能要件として固定している。ここはその要件を確かめる手順で、**測ってから判断する**
# (ADR-0008 決定 1)。
#
# **1 つのプロセスで 1 つの条件だけを測る。** 同じプロセスで前面 → 背面と続けて測ると、
# 前の条件が残した状態 (確保済みの資源・温まったキャッシュ) が次の数字に混ざる。
#
# 画面が要る。ヘッドレスの実行環境では走らない。
set -euo pipefail

cd "$(dirname "$0")/.."

SECONDS_TO_MEASURE="${1:-7}"

echo "== 前面 =="
swift run frame-rate-probe --seconds "$SECONDS_TO_MEASURE"

echo
echo "== 背面 =="
# 起動してから別のアプリを前面に出し、測る側を背面へ回す
swift run frame-rate-probe --seconds "$SECONDS_TO_MEASURE" &
probe_pid=$!
sleep 3
osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 || true
wait "$probe_pid"
