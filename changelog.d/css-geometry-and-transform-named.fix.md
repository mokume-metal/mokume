<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` が、読まずに黙って消していた CSS の幾何の性質と変換を、捨てたものとして知らせるようになった。

`rect` の `width`・`circle` の `r`・`path` の `d` などを `style` 属性や `<style>` で書いた SVG、CSS の `transform`・`rotate` などを書いた SVG、`<svg>` 要素の `transform` 属性を書いた SVG は、これまでは何も知らせずに書いた値で描かれなかった。いまは `CSS property "width"` や `<svg transform="rotate(45)">` の形で知らせる。描き方は変わらない (属性の値で描き、変換は掛けない)。
