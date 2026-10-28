<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**Processing・p5.js の形の `func mouseDragged()` (引数なし) が、呼ばれるようになりました。** これまでは、手本のとおりに引数なしで書いてもコンパイルは通り、一度も呼ばれませんでした (量を受ける `mouseDragged(deltaX:deltaY:)` だけが呼ばれていました)。押したまま動いた 1 件ごとに、`mouseDragged()` が 1 回、続けて `mouseDragged(deltaX:deltaY:)` が 1 回呼ばれます (`mouseMoved()` と同じ順序と回数です)。どちらか片方だけを書いても、書いた側が 1 件につき 1 回呼ばれ、量付きだけを書いていたスケッチの呼ばれ方は変わりません。

```swift
func mouseDragged() { x = mouseX }   // ドラッグで呼ばれ、x が mouseX に付いてくる
```

**引数なしの中で `dragX` / `dragY` を読んではいけません。** あちらはフレームの頭から足し込む合計なので、1 フレームに複数件届くと部分累計を足し込む形になります。1 件ぶんの量は `mouseDragged(deltaX:deltaY:)` の引数で受けます。引数なしの `mouseWheel()` は足していません (引数なしで読める正しい量が無いためです)。
