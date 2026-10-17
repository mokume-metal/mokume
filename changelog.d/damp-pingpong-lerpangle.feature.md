<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

動きを書く純関数を 3 本足した。`damp(current, target, lambda, dt)` はフレームの長さに依らない硬さで目標へ寄り (`eyeX = damp(eyeX, mouseX, 6, deltaTime)`)、`x += (target - x) * 0.1` のようにフレームが落ちると遅れたり `frameRate` で硬さが変わったりしない。`pingpong(t, length)` は 0 から `length` まで上がって戻る三角波で、負の時刻でも巡る。`lerpAngle(a, b, amount)` は ±π をまたぐところでも 1 周回らず、最短の弧で角を混ぜる。

`damp` に `deltaTime` を渡すと、実時計の窓では実行ごとに同じ時刻の絵が揃わない (フレームの時計 — `mokume render` と設定の `clock: .frames` では揃う)。負の `lambda`・`dt` は動かさずに知らせ、数でない値は今の値を返す。
