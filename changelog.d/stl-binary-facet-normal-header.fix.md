<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`loadModel` / `requestModel` が、見出し (先頭の 80 バイト) が `solid` で始まり `facet normal` を含むバイナリの STL を、空のモデルではなく書かれた面のとおりに読むようになった。** 読み手の Model I/O がこの見出しを文字の STL の頭と読み、面の無い形を返していたのを、投げずに空のモデルとして返していた。バイナリでも、読み手が返した面の数をファイルの大きさから揃ったと読める面の数と照らし、合わなければ見出しを除いて読み直す。それでも合わなければ、空のモデルではなく `ModelFailure.unreadable` を投げる。

見出しが `solid` で始まるだけ・`facet normal` を含むだけのバイナリ・ほかのバイナリ・文字の STL の結果は変わらない。
