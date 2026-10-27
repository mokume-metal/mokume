<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Vector3` に `length`・`normalized()`・`limited(to:)` を追加し、`Vector2` との非対称を無くした。3 次元のベクトルの長さを求めて正規化するのに `simd` を取り出さなくてよくなる。0 ベクトルの正規化は変えずに返し、2 乗が溢れる大きさでも有限の長さで測る (`Vector2` と同じ約束)。

`Vector2` と `Vector3` に、Processing の `PVector` にある基本の演算も足した。2 点の距離 `distance(to:)`・内積 `dot(_:)`・補間 `interpolated(to:amount:)` は両方に、外積 `cross(_:)` は `Vector3` に、向きの角度 `angle` (Processing の `heading()`)・回転 `rotated(by:)`・角度から作る `Vector2(angle:length:)` (p5 の `fromAngle`) は `Vector2` にある。名前は Swift の慣行に従い、新しい値を返す (`rotated`・`interpolated`)。角度はラジアンで、正の角度は画面の上で時計回りになる (`rotate()` と同じ)。
