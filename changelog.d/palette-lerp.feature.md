<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**3 色以上の段から色を引く `paletteLerp(stops, amount)` を追加した** ([#2424](https://github.com/mokume-metal/mokume/issues/2424))。区切りは `(色, 位置)` の並びで、`amount` が位置の間にあれば両隣の色を `lerpColor` で混ぜる。熱さの段や地形の色を `t` から引くのに、区間を探して `lerpColor` を書き分けなくてよい。

```swift
let sky: [(LinearRGBA, Float)] = [
    (color(20, 30, 80), 0), (color(200, 60, 60), 0.6), (color(250, 220, 120), 1),
]
for y in 0..<Int(height) {
    fill(paletteLerp(sky, Float(y) / height))
    rect(0, y, width, 1)
}
```

区切りの規則は勾配 (`Gradient`) と同じ (位置の小さい順に安定に並べ直す・手前は最初の色・先は最後の色のまま伸びる)。`amount` は `lerpColor` と同じく 0…1 に締める。**混ぜる空間は `lerpColor` と同じ線形で、p5.js の `paletteLerp` (今の `colorMode()` の空間で混ぜる) と中間の色が違う** — 黒と白の真ん中は `red()` で約 187.5 になる。区切りが空なら透明な色、位置が数でない区切りは捨て、`amount` が数でなければ最初の色を返して、1 度だけ知らせる (落ちない)。
