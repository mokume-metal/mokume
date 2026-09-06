<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描画 API に `Int` や `Double` をそのまま渡せるようになりました。これまでは受け口が `Float` 1 本だったので、`for i in 0..<n` のループ変数や `let gap = 120.0` (Swift は `Double` に推論します) を渡すには `Float(...)` と書き直す必要がありました。

```swift
let gap = 120.0
circle(gap, gap, 40)                 // 通る
for i in 0..<255 { fill(i, 0, 0) }   // 通る
```

**速さは変わりません。** 受け口だけを広げ、中は `Float` のまま持ちます。別のパッケージから測って 1 回あたり約 0.8 ナノ秒 (`circle` 本体の 1% 台) で、呼ぶ側で特殊化されるため `Float` を直に受けるのと同じ機械語に落ちます。

**個数や添字は `Int` のままです。** `sphere(半径, detail:)` の `detail` や、画素の添字、乱数の種のような「数え上げ」は広げていません。

**書き換えが要る場合があります。** 引数の型から式の型を逆算していた書き方は、型を名乗る必要が出ます。

```swift
rotate(.pi / 2)         // 通らなくなりました
rotate(Float.pi / 2)    // こう書きます
```

`.pi` を渡していても、`Float(index) / Float(count) * 2 * .pi` のように**他の項が型を決めている式はそのまま通ります**。実際、このリポジトリの 47 箇所の `.pi` のうち、書き換えが要ったのは 6 箇所でした。
