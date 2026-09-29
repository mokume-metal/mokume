<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

同じフレームで先に図形を置いてから `createShape { }` の中で `background()` や `get()` を呼ぶと、`Range requires lowerBound <= upperBound` でプロセスごと落ちていたのを直しました。組み立ての中では、塗り直し (`background()`) と画素の読み書き (`get()`・`set()`・`pixels`・`loadPixels()`) は 1 度注意して何もしません。`get()` は透明を返します。先に何も置いていなくても、組み立ての中で画素を読むと組み立てた図形がフレームへ描かれて形から抜けていましたが、それも起きなくなりました。

組み立ての中で、同じフレームに置いた描き場所 (`createGraphics`) を描き換えたときと、`noiseSeed()`・`noiseDetail()` で揺らぎの設定を書き換えたときも同じように落ちていました。こちらは落ちずに空の形を返し、1 度注意します。どちらも組み立ての前か後で行ってください。
