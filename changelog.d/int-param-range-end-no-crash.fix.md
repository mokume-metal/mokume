<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

上端が `Int.max` の範囲を持つ整数の `@Param` (`@Param(0...Int.max)`) へ、外から `Int.max` かその近くの値を書いても、スケッチが落ちなくなった。窓の段付きスライダーを右端まで寄せたときも同じで、落ちずに `Int.max` が入る ([#2478](https://github.com/mokume-metal/mokume/issues/2478))。

範囲を `Double` で持つので、2^53 を超える整数は範囲つきの宣言へ書くと丸まる (`Int.max - 1` は `Int.max` になり、収めたこととして応答の `clamped` に載る)。この丸めは今までどおりで、落ちなくなっただけである。
