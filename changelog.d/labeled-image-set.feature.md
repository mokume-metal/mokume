<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`image` に範囲を `Rect` で取る形を、`set` にラベル付きの形を足した。`image(_:in:)`・`image(_:in:from:)` は画像 (`Image`) にもグラフィックス (`Canvas`) にも使え、`image(img, 10, 20, 64, 64)` は `image(img, in: Rect(left: 10, top: 20, width: 64, height: 64))` と、`set(x, y, c)` は `set(x: x, y: y, to: c)` と書ける。

`Rect` を取る形は `imageMode` に従わず、値のとおり左上から置く (`Rect` は左上で置く値で、`Rect.draw()` が `rectMode` に従わないのと同じ)。既定のモード (`.corner`) なら位置で渡す形と同じ絵になる。`set(x:y:to:)` の座標は位置の形と同じ `Int`。位置で渡す形はそのまま使え、`Canvas` を直に呼ぶときも同じ形がある。
