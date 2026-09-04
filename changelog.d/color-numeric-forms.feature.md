<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

色を素の数値で指定できるようになった — `fill(255, 204, 0)` / `stroke(128)` / `background(15, 18, 23, 200)`。**目盛りは 0–255** で、`background` / `fill` / `stroke` / `tint` が 1〜4 引数を受ける。

色の値を作る `color(255, 204, 0)` と `color(hex: 0xFF_CC00)` も入った。読み出しは `red(_:)` / `green(_:)` / `blue(_:)` / `alpha(_:)` で、**書いたのと同じ 0–255 の目盛り**で返る。

0–1 で書きたいときは `LinearRGBA.display(red:green:blue:alpha:)` がこれまでどおり使える。**ラベルの無い素の数値は 0–255、ラベル付きは名前が目盛りを名乗る**という 1 本の規則で読み分ける ([ADR-0033](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md))。
