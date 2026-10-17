<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

「数の型」の説明に、`i * width / count` のように `Int` の添字と `Float` を混ぜた式を書いたときの誤りを足した。コンパイラは添字ではなく `width` を「`Int` ではない」と指すが、直すのは添字の側 (`Float(i)`) で、添字を経ずに `Float` のまま回すなら `stride(from: Float(0), to: width, by: step)` が使える。挙動は変えていない。
