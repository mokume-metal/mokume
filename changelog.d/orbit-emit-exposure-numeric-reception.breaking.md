<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`orbitControl` の感度・`emit` の `rate`・`Canvas.exposure` が、`Int` や `Double` の変数をそのまま受けるようになりました** ([#2524](https://github.com/mokume-metal/mokume/issues/2524))。これまでは `Float` しか受けず、`orbitControl(Float(k), Float(k), Float(k))` や `emit(dust, from: e, rate: Float(n))` のように書き直す必要がありました。いまは `fill` などの描く口と同じく、`Float`・`Double`・`Int` のどれで持っていてもそのまま渡せます。`Sketch.exposure` は以前から総称だったので、`Canvas.exposure` だけが変わり、`Sketch.exposure` と同じ受け方になりました。数でない値・無限・負を断って注意する約束 (`exposure` は露出を変えず、`emit` は粒を出さない) は、これまでどおり `exposure` と `emit` だけのものです。`orbitControl` の感度は受け口で検めず、そのまま回す計算へ渡るので、感度の扱いは変わりません。どの口も既定値と返り値は変わりません。

```swift
let k = 2.0                        // Double
let n = 800                        // Int
orbitControl(k, k, k)              // 通る
emit(dust, from: .point(x, y), rate: n)   // 通る
canvas.exposure(1.15 as Double)    // 通る
```

受け方を描く口に揃えたので、描く口と同じ影響がこの 3 つの口にも出ます。

**1. `.nan` のような書き方は、型を名乗ります。** 渡す先が型を決めなくなったので、`.nan` や `.pi` だけでは `Float` と `Double` のどちらか決まらず、**コンパイルが通らなくなります**。

```swift
canvas.exposure(.nan)           // 通りません
canvas.exposure(Float.nan)      // こう書きます
```

**2. 整数だけで書いた割り算は、整数のまま計算されます。** こちらは**コンパイルが通ってしまう**ので、値や絵が黙って変わります。 変わるのは `orbitControl`・`emit` の `rate`・`Canvas.exposure` の 3 つの口です (`Sketch.exposure` は以前から総称で、`exposure(1 / 2)` は元から 0 でした)。

```swift
orbitControl(1 / 2)             // 感度 0 になり、回らなくなります (これまでは 0.5)
emit(dust, from: .point(x, y), rate: 1 / 2)   // 0 個になります (これまでは毎秒 0.5 個)
canvas.exposure(1 / 2)          // 露出 0 になり、絵が真っ黒になります (これまでは 0.5)
orbitControl(1 / 2.0)           // 0.5 が渡ります
```

**3. 引数の型から決まっていたものが、決まらなくなります。** `orbitControl(atan(1))` のように整数のリテラルを `atan` や `sin` に渡して受け口へ渡している所は、`Float` 版と `Double` 版のどちらか決まらず、**コンパイルが通らなくなります**。`atan(Float(1))` のように型を付けてください。

**移行**: これらの口へ `.nan`・`.infinity` などを渡している所は、`Float.nan` のように型を付けて綴ってください。引数に整数だけの割り算を書いている所は、片方に小数点を付けてください (`1 / 2` → `1 / 2.0`)。`width` や `time` のように面が返した数が式に入っていれば、全体が `Float` として計算されるのでそのままで構いません。なお、このリポジトリの参照スケッチ・作者の読む面・検査には、この 3 つの口へ整数だけの割り算を渡している呼び出しはありませんでした。
