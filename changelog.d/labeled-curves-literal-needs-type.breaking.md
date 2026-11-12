<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

曲線のラベル付きの形 (`bezier(from:control1:control2:to:)`・`curve(from:control1:control2:to:)`・`bezierVertex(control1:control2:to:)`・`quadraticVertex(control:to:)`) に点を配列リテラル (`[40, 200]`) で渡す書き方は、コンパイルが通らなくなった。立体の曲線のために `Vector3` を受ける同じラベルの形を足したので、配列リテラルからは `Vector2` か `Vector3` かが決まらない (`line(_:_:)`・`vertex(_:)` の `Vector2` と `Vector3` の形と同じ)。

移行: 点を `Vector2(40, 200)` と型を書いて渡す。たとえば `bezier(from: [40, 200], control1: [120, 40], control2: [280, 40], to: [360, 200])` は `bezier(from: Vector2(40, 200), control1: Vector2(120, 40), control2: Vector2(280, 40), to: Vector2(360, 200))` と書く。
