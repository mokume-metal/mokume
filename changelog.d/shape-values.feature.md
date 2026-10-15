<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

2D の図形を値として持ち歩ける `Circle`・`Rect` と、点や速さを表す `Vector2` を追加した。`ball.intersects(paddle)` で当たり判定し、`point` が中にあるかを `contains(_:)` で問い、`move(by:)` で動かし、`draw()` で描ける。基準点はラベルで名乗る (`Rect(left:top:width:height:)`・`Rect(center:width:height:)`・`Circle(x:y:radius:)`) ので、`rectMode` / `ellipseMode` に依らず書いたとおりの場所で描き・判定する。`Rect(left: 24, top: 48, width: 40, height: 14, fill: color(239, 83, 80))` のように値に塗りを持たせると、`noFill()` の中でもその色で塗り、持たせなければ今の `fill()` に従う。

`Vector2(col * 44, 48)` のように `Int` の変数をそのまま渡せ、`+`・`-`・`*`・`/` と `length` (Processing の `mag()`) を持つ。どれも main actor の外 (通信の完了ハンドラなど) から作り・判定し・`Codable` で符号化できる。あわせて、色の値 `LinearRGBA` が `Hashable`・`Codable` になり、比べる・符号化する・成分から作る口が main actor の外でも使えるようになった。
