<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` と `requestShape(_:)` が読む SVG の数を、SVG / CSS の数の文法 (10 進の綴りだけ) で読むようにした。これまでは長さ (`width`・`height`・`x`・`y`・`r`・`rx` / `ry`・`stroke-width` など)・不透明度 (`opacity`・`fill-opacity`・`stroke-opacity`)・`rgb()` の成分が 16 進の綴りを黙って数にしていて、`width="0x10"` は 16、`opacity="0x1p-1"` は 0.5 として効いていた (`viewBox` とパスの数は前から 10 進だけで、SVG の中で扱いが食い違っていた)。いまは `width="abc"` と同じく読めない値として名乗り、その口のいまの扱い (図形の寸法なら描かない、`stroke-width`・不透明度・塗りなら宣言を捨てて既定のまま) になる。ブラウザもこれらを数として読まない。

あわせて、`transform="translate&#10;(10)"` のように変換の名前と括弧のあいだに改行を置いた `transform` を読めるようにした (これまでは読めない変換として名乗り、変換が無いものとして描いていた)。

16 進の数を書いた SVG は、名乗られて既定値・宣言なしになる。10 進で書いた SVG の読み方は変わらない。
