<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` が形の属性の長さを知らせるとき、値の前後の空白を落とした文字で知らせるようになった。

`<rect width=" abc ">` は `<rect width=" abc ">` ではなく `<rect width="abc">` と知らせる。根の `<svg>` の大きさや `preserveAspectRatio` の知らせと同じ書式になる。描き方は変わらない。
