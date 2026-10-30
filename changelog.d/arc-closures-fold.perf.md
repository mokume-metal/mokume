<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`shader()` を効かせた間に大量に置く、輪郭の無い弧の `.chord` と `.open` の塗りが速くなりました。回転だけ違う弧を 10,000 個置く場面で、フレームの CPU 時間が 約 9〜12 ms → 約 2.6 ms です。形が同じ弧を 1 つの雛形にまとめて置くようになったためで、描く絵は変わりません。輪郭つきの弧と、貼る絵 (`texture()`) を効かせた `.chord` / `.open` は、これまでどおり置き場所ごとに組みます。
