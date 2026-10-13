<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadModel` が OBJ の頂点 (`v`・`vn`・`vt`) の数を 10 進の綴りだけで読むようになった。16 進 (`v 0x10 0 0`・`vt 0x1p-1 0`) や、`vt` の読めない欄 (`vt abc 0.5`・`vt 0.5 0x1`・`vt 0.5 1\0`) を黙って数として置かず、読めない行として読み飛ばし、`Model.skippedLines` に数える。

これまでは `v 0x10 0 0` が x = 16 の頂点として置かれ、`vt` は読めない欄を飛ばして詰めていた (`vt abc 0.5` が u = 0.5・v = 0 として置かれる)。どちらも読み飛ばしに数えられないので、壊れたファイルに気付く手段が無かった。`v 1.5 -2 3e1`・`vt .5` のような 10 進の綴りの読み方は変わらない。
