<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`fill` / `stroke` / `tint` / `background` と `color(…)` に渡した不透明度が、0–255 に締まるようになりました。これまでは範囲の外の値がそのまま成分に掛かり、`fill(255, -100)` の矩形は下地を黒く抜き、`fill(255, 400)` の矩形は白を越える明るさで重なっていました (画面では白に見えても、上から重ねて暗くすると差が出ていました)。いまは -100 は 0 と、400 は 255 と同じ色になります。`alpha(color(0, 0, 0, 400))` も 255 を返します。

0–1 で書く `.display(red:green:blue:alpha:)` と `LinearRGBA(straightRed:green:blue:alpha:)` の不透明度も、同じく 0–1 に締まります。**色の成分は、これまでどおり締めません** — `red(color(510, 0, 0))` は 510 のままです。乗算済みの `LinearRGBA(premultipliedRed:…)` は渡した値をそのまま持ちます。
