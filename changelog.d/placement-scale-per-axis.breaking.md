<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`Placement.scale` が `Float` から `Vector3` になり、軸ごとの倍率を持てるようになりました** ([#2460](https://github.com/mokume-metal/mokume/issues/2460))。`Placement(x: 100, y: 200, scale: Vector3(1, 4, 1))` のように渡すと、`shape(_:at:)` で置いた形が、`push()`・`translate(100, 200, 0)`・`scale(1, 4, 1)` を同じ順で書いて置いたものと同じ絵になります。高さだけ伸ばした箱 (棒グラフの街並み・音の柱) を、箱 1 つの形から `[Placement]` でまとめて置けます。倍率は形自身の軸に掛かり、回転より先に効きます (大きさ → 回転 → 位置)。数でない値・無限の成分を含む置き場所は、これまでの `scale` と同じく置かれません。

どの軸にも同じ倍率で作る書き方は、そのまま使えます。`Placement(x: 40, scale: 2)` は `Placement(x: 40, scale: Vector3(2, 2, 2))` と等しく、絵も変わりません (行列は 1 ビットも変わりません)。

壊れるのは、置き場所の `scale` を **`Float` として読む・書く**コードだけです。

| これまで | これから |
| --- | --- |
| `let size: Float = place.scale` | `let size = place.scale.x` (どの軸も同じ値で作ったなら、`.y`・`.z` も同じ) |
| `place.scale = 3` | `place.scale = Vector3(3, 3, 3)` |
| `place.scale += 0.1` | `place.scale += Vector3(0.1, 0.1, 0.1)` (1 軸だけなら `place.scale.x += 0.1`) |
| `canvas.scale(place.scale, place.scale, place.scale)` | `canvas.scale(place.scale.x, place.scale.y, place.scale.z)` |

`place.scale * 2` は `Vector3` を返します (`Float` を期待していた所は、軸を選んで読みます)。`Placement(x: …, scale: 2)` のように作る側の書き方は変わらないので、置き場所を作って `shape(_:at:)` へ渡すだけのコードは書き換えなしで組み上がります。
