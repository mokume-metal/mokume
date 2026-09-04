<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

光と質感の色も素の数値で書けるようになった — `ambientLight(90, 95, 110)` / `directionalLight(255, 244, 214, -0.5, 1, -0.3)` / `ambient(180)` / `emissive(40, 90, 140)`。**目盛りは 0–255** で、`pointLight` と `spotLight` も同じ形を受ける。

**向きを持つ光には灰色 1 つの形も不透明度も無い** — 手本が持たないためで、「光の不透明度」が何を指すのかを説明できない ([ADR-0033](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md) 決定 7)。灰色 1 つの形があるのは `ambientLight` / `ambient` / `emissive` の 3 つ。
