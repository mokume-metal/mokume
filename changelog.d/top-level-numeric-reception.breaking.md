<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**色と数のトップレベルの口が、`Int` や `Double` の変数をそのまま受けるようになりました** ([#2255](https://github.com/mokume-metal/mokume/issues/2255))。対象は `color`・`color(hue:saturation:brightness:)`・`lerpColor` の `amount`・`map`・`lerp`・`constrain`・`norm`・`smoothstep`・`radians`・`degrees` です。これまでは `Float` しか受けず、`map(Float(i), 0, 10, 0, 1)` のように書き直す必要がありました。いまは `fill` などの描く口と同じく `map(i, 0, 10, 0, 1)` と書けます。返す値は `Float` のままです。

受け方を描く口に揃えたので、描く口と同じ 2 つの影響がこれらの口にも出ます。

**1. `.pi` のような書き方は、型を名乗ります。** 渡す先が型を決めなくなったので、`.pi` だけでは `Float` と `Double` のどちらか決まらず、**コンパイルが通らなくなります**。

```swift
degrees(2 * .pi)         // 通りません
degrees(2 * Float.pi)    // こう書きます
lerp(0, 10, .nan)        // 通りません — Float.nan と書きます
```

**2. 整数だけで書いた割り算は、整数のまま計算されます。** こちらは**コンパイルが通ってしまう**ので、値や絵が黙って変わります。

```swift
lerp(0, 10, 1 / 2)       // 0 になります (これまでは 5)
lerp(0, 10, 1 / 2.0)     // 5 が返ります
color(255 / 2)           // 127 の灰色になります (これまでは 127.5)
radians(360 / 7)         // 51 度ぶんになります (これまでは 51.43 度)
```

**移行**: これらの口へ `.pi`・`.nan`・`.infinity` などを渡している所は、`Float.pi` のように型を付けて綴ってください。引数に整数だけの割り算を書いている所は、片方に小数点を付けてください (`1 / 2` → `1 / 2.0`)。`width` や `time` のように面が返した数が式に入っていれば、全体が `Float` として計算されるのでそのままで構いません。
