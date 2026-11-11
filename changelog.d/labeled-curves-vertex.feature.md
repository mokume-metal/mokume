<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

ベジェ曲線と、読み取り位置 (UV) を取る `vertex` に、同じ名前のラベル付きの形を足した。`bezier(from:control1:control2:to:)`・`bezierVertex(control1:control2:to:)`・`quadraticVertex(control:to:)` は端点と制御点を `Vector2` で取り、どれが端でどれが制御点かを呼び出しの行で読める。`vertex(_:uv:)` は位置を `Vector2` か `Vector3` で、読み取り位置を `uv:` の `Vector2` で取る。`bezier(40, 200, 120, 40, 280, 40, 360, 200)` は `bezier(from: Vector2(40, 200), control1: Vector2(120, 40), control2: Vector2(280, 40), to: Vector2(360, 200))` と、`vertex(0, 0, 0, 0, 1)` は `vertex(Vector3(0, 0, 0), uv: Vector2(0, 1))` と書ける。

どれも同じ値を位置で渡す形と同じ絵になり、位置で渡す形はそのまま使える。`Canvas` を直に呼ぶときも同じ形がある。
