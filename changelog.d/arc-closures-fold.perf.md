<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`shader()` や `texture()` を効かせた間に大量に置く弧 (`arc` の既定・`.chord`・`.open`) が速くなりました。回転だけ違う弧を 10,000 個置く場面で、フレームの CPU 時間が 輪郭あり 約 280 ms → 約 3 ms、輪郭なし 約 10〜14 ms → 約 2.6 ms です。形が同じ弧を 1 つの雛形にまとめて置くようになったためで、`.pie` と同じ扱いです。
