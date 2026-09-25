<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**半透明の立体に `emissive()` を掛けたとき、自ら出す光が塗りの不透明度のぶんだけ乗るようになった。** これまでは自発光だけが不透明度を掛けずに足されていたので、`fill(255, 255, 255, 0)` の透明な球でも `emissive(255, 0, 0)` の赤が満額で下地に加算され、不透明の赤い球と同じ絵になっていた。α 128 の面では、下地は半分に薄まるのに自発光だけが満額で乗っていた。色はアルファ乗算済みで扱い、アルファ 0 の色は下地を変えない、という約束 ([ADR-0011](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md) 決定 4・`BlendMode` の説明) に、自発光も艶と同じく沿わせた。保持した形 (`createShape`) で置いた立体も同じ。不透明の立体の絵は変わらない。
