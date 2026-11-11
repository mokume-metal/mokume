<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

数の計算の API に、同じ名前のラベル付きの形を足した。`map(_:fromLow:fromHigh:toLow:toHigh:)`・`lerp(_:_:amount:)`・`lerpAngle(_:_:amount:)`・`lerpColor(_:_:amount:)`・`smoothstep(_:_:x:)`・`damp(_:toward:lambda:deltaTime:)`・`randomGaussian(mean:standardDeviation:)`・`noiseDetail(octaves:falloff:)` の 8 つで、`map(v, 0, width, -1, 1)` は `map(v, fromLow: 0, fromHigh: width, toLow: -1, toHigh: 1)` と書ける。

どれも同じ値を位置で渡す形と同じ値を返し (逆向きの範囲も同じ)、位置で渡す形はそのまま使える。`noiseDetail` の `falloff:` は省けて、既定値は位置の形と同じ 0.5。`Canvas` を直に呼ぶときも `noiseDetail(octaves:falloff:)` がある。
