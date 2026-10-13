<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` と `requestShape(_:)` が読む SVG の数を、SVG / CSS の数の文法 (10 進の綴りだけ) で読むようにした。これまでは長さ・不透明度 (`opacity`・`fill-opacity`・`stroke-opacity`)・`rgb()` の成分が 16 進の綴りを黙って数にしていて、`width="0x10"` は 16、`opacity="0x1p-1"` は 0.5 として効いていた (`viewBox` とパスの数は前から 10 進だけで、SVG の中で扱いが食い違っていた)。ブラウザもこれらを数として読まない。いまは 16 進の数を、同じ口に `abc` を書いたときと同じに扱う。

- **読めない値として名乗る口**: 図形の寸法と位置 (`rect` の `x`・`y`・`width`・`height`、`circle` の `cx`・`cy`・`r`、`ellipse` の `cx`・`cy`・`rx`・`ry`、`line` の `x1`…`y2`) はその図形を描かず、`stroke-width`・不透明度・`rgb()` で書いた塗りと線の色は宣言を捨てて既定のままにする
- **名乗らずに既定値へ倒れる口**: `<svg>` の `width`・`height`・`x`・`y` と `rect` の `rx`・`ry` は、`abc` と同じく黙って書いていないものとして読む (16 進が「効く」から「捨てられる」に変わる)。名乗らないこと自体は [#2556](https://github.com/mokume-metal/mokume/issues/2556) で扱う

あわせて、`transform="translate&#10;(10)"` のように変換の名前と括弧のあいだに改行を置いた `transform` と、`<style>` の中で `fill: rgb(255,` の後で折り返した色のように `rgb()` の引数のあいだに改行を置いた色を読めるようにした (これまでは読めない値として名乗り、変換が無いもの・既定の色として描いていた)。

16 進の数を書いた SVG は、名乗られるか黙って既定値・宣言なしになる。10 進で書いた SVG の読み方は変わらない。
