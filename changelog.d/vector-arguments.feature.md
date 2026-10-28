<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Vector2` / `Vector3` を、描く口と変換の口へそのまま渡せるようにした。`circle(pos.x, pos.y, 40)` や `line(a.x, a.y, b.x, b.y)` と毎回 `.x`・`.y` へ開かずに、`circle(pos, 40)`・`line(a, b)` と書ける。

足したのは `circle(_:_:)`・`point(_:)`・`line(_:_:)`・`translate(_:)`・`vertex(_:)` (`Vector2` と `Vector3` の両方。3 次元の口が無い `circle` は `Vector2` だけ) と、距離の `dist(_:_:)` (`Vector2` どうし・`Vector3` どうし)。`Canvas` を直に呼ぶときも同じ口がある。成分を渡した数の口と同じ絵・同じ変換になる (`dist` は `distance(to:)` と同じ値)。`Vector2` と `Vector3` の両方がある `translate`・`point`・`line`・`vertex` は、`translate([10, 20])` のように配列リテラルで渡すとどちらか決められず型が曖昧になる (コンパイルエラー)。`translate(Vector2(10, 20))` と型を名乗る。
