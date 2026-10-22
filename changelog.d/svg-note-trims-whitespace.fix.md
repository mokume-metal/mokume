<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` が値を知らせるとき、値の前後の空白を落とした文字で知らせるようになった。

形の属性の長さ (`<rect width=" abc ">` は `<rect width="abc">`)・入れ子の `<svg>` の `x` / `y`・`<svg>` の `transform`・`transform-origin` / `transform-box`・読めない `transform`・読めない `viewBox` が対象で、根の `<svg>` の大きさや `preserveAspectRatio` の知らせと同じ書式になる。描き方は変わらない。
