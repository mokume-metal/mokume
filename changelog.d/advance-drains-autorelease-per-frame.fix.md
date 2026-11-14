<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`SketchRuntime.advance()` や `Canvas.draw { }` を run loop の外で自分のループから回しても、`draw()` の中で作っては捨てる描き場所 (`createGraphics`) の GPU のメモリが伸び続けなくなった。どちらも 1 フレームごとに autorelease の置き場を空にする。ウィンドウ・`mokume render`・`mokume replay` は run loop が同じ区切りを持っていたので、これまでも伸びていない (`createGraphics(152, 122)` を毎フレーム 100 枚作る例で、600 フレームまで 48 MB のまま)。
