<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`Transform` の積む口と `jumpTime(_:)` が、`Int` や `Double` の変数をそのまま受けるようになりました** ([#2525](https://github.com/mokume-metal/mokume/issues/2525))。対象は `translate`・`rotate(by:)`・`rotateX(by:)`・`rotateY(by:)`・`rotateZ(by:)`・`scale`・`shearX(by:)`・`shearY(by:)` と `jumpTime(_:)` です。これまでは `Float` しか受けず、`let d = 2.0` を `t.translate(x: d, y: d)` や `jumpTime(s)` へ渡すには `Float(d)` と書き直す必要がありました。いまは `Transform.apply` や描く口と同じく、そのまま渡せます。受け口の型を広げただけで、計算は `Float` のままです。

```swift
var t = Transform.identity
let d = 2.0
t.translate(x: d, y: d)    // Float(d) と書かなくてよくなりました
t.rotate(by: d)
jumpTime(1.5)              // 変数でも、リテラルでも
```

受け方を描く口に揃えたので、描く口と同じ 2 つの影響がこれらの口にも出ます。

**1. `.pi` や `.nan` のような書き方は、型を名乗ります。** 渡す先が型を決めなくなったので、`.pi` だけでは `Float` と `Double` のどちらか決まらず、**コンパイルが通らなくなります**。

```swift
t.rotate(by: .pi / 2)          // 通りません
t.rotate(by: Float.pi / 2)     // こう書きます
t.scale(x: .nan, y: 2)         // 通りません — Float.nan と書きます
```

**2. 整数だけで書いた割り算は、整数のまま計算されます。** こちらは**コンパイルが通ってしまう**ので、値が黙って変わります。

```swift
t.rotate(by: 1 / 2)            // 0 を渡したことになります (これまでは 0.5)
t.rotate(by: 1 / 2.0)          // 0.5 が渡ります
jumpTime(90 / 60)              // 1 秒へ飛びます (これまでは 1.5 秒)
```

**移行**: これらの口へ `.pi`・`.nan`・`.infinity` などを渡している所は、`Float.pi` のように型を付けて綴ってください (`HALF_PI` など、型の決まった定数はそのまま渡せます)。引数に整数だけの割り算を書いている所は、片方に小数点を付けてください (`1 / 2` → `1 / 2.0`)。`width` や `time` のように面が返した数が式に入っていれば、全体が `Float` として計算されるのでそのままで構いません。

`Transform.apply(x:y:)`・`apply(x:y:z:)` の戻り値を `Vector2`・`Vector3` へ移す変更と同じ版に出ます。`Transform` まわりの直しを 1 回で済ませられます。

`LinearRGBA.display(…)`・`.linear(…)` は据え置きです。0–1 の目盛りで、0–255 の数を `n / 255` と直して渡す書き方が自然に出る口なので、広げると上の 2 のように `n / 255` が黙って 0 になるためです。音とカメラの口も、この変更の対象に入れていません。
