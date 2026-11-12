<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

光の API に、同じ名前のラベル付きの形を足した。`pointLight(color:position:)`・`directionalLight(color:direction:)`・`spotLight(color:position:direction:angle:)` は、色を `LinearRGBA` で、位置と向きを `Vector3` で取る。`pointLight(255, 200, 150, 200, 100, 80)` は `pointLight(color: color(255, 200, 150), position: Vector3(200, 100, 80))` と書ける。

どれも同じ値を位置で渡す形と同じ光になり、位置で渡す形はそのまま使える。`spotLight` の `angle:` は省けて、既定値は位置の形と同じ π/6。`Canvas` を直に呼ぶときも同じ形がある。
