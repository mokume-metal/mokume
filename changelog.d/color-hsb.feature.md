<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

色相・彩度・明度でも色を作れるようになった — `color(hue: 200, saturation: 80, brightness: 90)`。**色相は 0–360 の度、彩度と明度は 0–100 の百分率**で、`hue(_:)` / `saturation(_:)` / `brightness(_:)` が同じ目盛りで読み返す。

**色相は巻き戻る**ので、`color(hue: Float(frameCount), saturation: 70, brightness: 95)` と剰余なしで書ける。**彩度と明度は上へ突き抜けられる** — `brightness: 150` は表示範囲を超えた明るさ、`saturation: 120` は色域の外の色として保たれる。

目盛りは手本が割れている (Processing は 3 成分とも 0–255、p5 は 360/100/100) ので、その量について広く使われている単位を採った ([ADR-0033](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md) 決定 5)。
