<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

細かさ (`pixelDensity`) を 1 より下げたスケッチで、`draw()` の中で本体を途中まで描いて `get()` や `loadPixels()` で描き切らせてから、描き場所へ `image(canvas)`・`texture(canvas)`・断片の面 (`ShaderSurface.graphics(canvas)`) で置くと、途中まで描いた絵ではなく前のフレームの絵が出ていたのを直しました。細かさ 1 では途中まで描いた絵が出ており、細かさで結果が食い違っていました。いまはどの細かさでも、置いた時点で描き切れている絵 (区切りが無ければ前のフレーム、あれば区切りまで・効果は通らない) が出ます。あわせて、時間方向の拡大 (`upscale: .temporal`) で、`draw()` の中で `canvas.output.readPixels()` などで出す先を読むと、図形が描く画素 1 個弱ずれて出ることがあったのを直しました。
