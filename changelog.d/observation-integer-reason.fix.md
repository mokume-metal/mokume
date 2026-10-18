<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

観測の要求の `count`・`every` に整数でない数 (`count: 2.5`) を書いたとき、応答が、どの鍵の何が悪いかを名乗るようになった。これまでは `warnings` が鍵を言わず「The given data was not valid JSON」と言い、構文の誤りを探しに行かされていた。いまは `count` のような鍵と、その値が整数でないことを言う。

範囲を越えた大きな数 (`count: 1e19`・30 桁の整数・`every: -1e400`・`scale: 1e400`) は、読めない要求として断らなくなった。符号の側の端へ寄せて、スキーマの約束どおり範囲の丸め (枚数・間隔) と実寸 (縮小率) で撮り、`warnings` で名乗る。MCP の窓口から同じ値を送ったときと揃う。理由にも名乗りにも数の字面は写さないので、桁が多くても 1 行は伸びない。
