<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

説明文の例と参照スケッチの色が、**0–255 の綴りで書かれるようになった** — `background(15, 18, 23)` / `fill(255, 204, 0)`。参照の面から入る人と、公開 API の一覧を読むエージェントの両方が、素の数値の目盛りを既定として学ぶ。

0–1 で計算した値から作る色は `LinearRGBA.display(red:green:blue:)` のまま残してある。**どちらの綴りかは 1 行を読めば決まる** ([ADR-0033](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md) 決定 2)。
