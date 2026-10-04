<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

細かさ (`pixelDensity`) を 1 より下げたスケッチで、`setup()` や止まっている間 (`noLoop()` の後のキーやマウスのコールバック) に本体を描いて `get()` や `loadPixels()` で描き切らせてから、描き場所へ `image(canvas)`・`texture(canvas)`・断片の面 (`ShaderSurface.graphics(canvas)`) で置くと、描き切った絵ではなく最後のフレームの絵が出ていたのを直しました。細かさ 1 では描き切った絵が出ており、細かさで結果が食い違っていました。いまはどの細かさでも、置いた時点で描き切れている絵が出ます。`set()` で書いただけ (描き切らせていない) の画素は、これまでの細かさ 1 と同じく置いた先には出ません。
