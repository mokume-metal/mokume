<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

視点と投影の API に、同じ名前のラベル付きの形を足した。`camera(eye:center:up:)` は見る位置・見ている先・上方向を `Vector3` で取り、`perspective(fieldOfView:aspect:near:far:)`・`ortho(left:right:bottom:top:near:far:)` は数にラベルを付けて取る。`camera(200, -150, 300, 200, 150, 0, 0, 1, 0)` は `camera(eye: Vector3(200, -150, 300), center: Vector3(200, 150, 0), up: Vector3(0, 1, 0))` と書ける。

どれも同じ値を位置で渡す形と同じ視点・同じ投影になり、位置で渡す形はそのまま使える。`camera(eye:center:up:)` の `up:` は省けない。`Canvas` を直に呼ぶときも同じ形がある。
