<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

スクロールを出来事として受け取れるようになりました。`mouseWheel(deltaX:deltaY:)` が**その 1 件ぶんの量**を引数で渡します。

```swift
func mouseWheel(deltaX: Float, deltaY: Float) {
    size = min(max(size + deltaY * 4, 20), 400)
}
```

**破壊的変更**: `mouseDragged()` は `mouseDragged(deltaX:deltaY:)` になりました。こちらもその 1 件で動いた量を受け取ります。

`scrollX` / `scrollY` / `dragX` / `dragY` は今までどおりフレームの合計で、`draw()` から読むためのものです。**コールバックの中でこれらを読むと、その出来事までの部分累計になります** — 1 フレームに 3 件届くと `a` + `(a+b)` + `(a+b+c)` を足し込む形になり、フレームに 1 件しか届かない環境では間違えた側も正しく動くので気付けません。1 件ぶんが要るときは引数を使ってください。
