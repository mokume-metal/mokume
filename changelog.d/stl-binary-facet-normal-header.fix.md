<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`loadModel` / `requestModel` が、見出し (先頭の 80 バイト) が `solid` で始まり `facet normal` を含むバイナリの STL を、空のモデルではなく書かれた面のとおりに読むようになった。** 読み手の Model I/O はこの見出しを文字の STL の頭と読み、面の無い形 (見出しに文字の面を書いていれば、その面) を返す。これまではそれを投げずに受け取っていた。いまは、そういう見出しのバイナリを、見出しを除いた写しを一時の置き場に書いて読み、ファイルの大きさから揃ったと読める面の数と照らす。数が合わなければ、空のモデルではなく `ModelFailure.unreadable` を投げる。一時の置き場に写しを書けないときも、`ModelFailure.unreadable` を投げる。

見出しが `solid` で始まるだけ・`facet normal` を含むだけのバイナリ・ほかのバイナリ・文字の STL の結果は変わらない。
