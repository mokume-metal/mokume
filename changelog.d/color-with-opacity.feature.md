<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

色の値の不透明度を薄めた色を作る `color(c, alpha)` を追加した。`let faint = color(Palette.ink, 0.12 * 255)` のように、`Placement(fill:)` や `emit(color:)`、`lerpColor` の両端へ渡す色を値として作れる。乗算済みの成分を手で縮めて書いていた `fade` が要らなくなる。

不透明度は `fill(c, alpha)` と同じ式で、**0–255 の目盛りで、置き換えずに掛ける**。半透明の色に 255 を渡しても不透明にはならず (`color(c, 255)` は `c` のまま)、`color(color(28, 28, 30, 128), 128)` の不透明度は 64 あまりになる。範囲の外は掛ける率を 0–1 に締める (400 は 255 と、-100 は 0 と同じ)。数でない値・無限の不透明度は受けず、透明な色を返して 1 度だけ知らせる。足すだけで、既存の絵は変わらない ([#2422](https://github.com/mokume-metal/mokume/issues/2422))。
