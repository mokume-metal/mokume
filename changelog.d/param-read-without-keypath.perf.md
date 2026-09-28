<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`@Param` を付けた値を読む速さが、1 回約 490 ns から約 7 ns になりました。読むたびに、変更を追跡するための鍵 (key path) を作り直していたためです。`draw()` の中で粒やセルごとにつまみの値を読む書き方で効きます。窓のつまみや外からの書き込みで値が動いたことが伝わる仕組みは、今までどおりです。
