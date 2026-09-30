<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`background` の説明に、**不透明度は下地に重ならず、面をその色で置き換える**ことを書きました。`background(0, 20)` は面を不透明度 20 の黒 1 色にするので、前の絵は残りません。p5.js の残像の書き方 (毎フレーム `background(0, 20)`) は、こちらでは残像になりません。

残像を作るには、`background` の代わりに `fill(0, 20)` と `rect(0, 0, width, height)` で面と同じ大きさの四角を薄く重ねます。この書き方は、説明に例として載せました。

これは意図した違いで、手本には寄せません。Processing / p5.js に倣うのは**名前と引数の順序まで**で、同じ画素が出ることは約束しない、という線引きは [ADR-0020](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md) 決定 1 にあります。
