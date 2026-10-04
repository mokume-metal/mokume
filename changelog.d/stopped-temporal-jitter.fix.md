<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

細かさ (`pixelDensity`) を 1 より下げて `upscale: .temporal` を使うスケッチで、止まっている間 (`noLoop()` の後のキーやマウスのコールバック) に図形を置いて `get()` などで描き切らせると、その図形が既に描いてある絵からずれて出ていたのを直しました (細かさ 0.5 で最大 横 1.6・縦 1.2 出す画素ほど)。いまは同じ図形をフレームの中で描いたときと同じ位置に出ます。描き切らせずに次のフレームへ持ち越した図形と、`upscale: .spatial` のスケッチ、最初のフレームより前 (`setup()`) に描き切らせた絵は、これまでと変わりません。
