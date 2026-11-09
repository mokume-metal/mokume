<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

作例 (`Sketches/`) と説明文の例は、変換とスタイルを戻すのに `push()` と `pop()` を対で書く代わりに、閉包で戻す `push { … }` を使うようになりました。閉包の形は早期 `return` や `throw` でも戻り、対の形より速く動きます。`push()`/`pop()`・`pushMatrix()`/`popMatrix()`・`pushStyle()`/`popStyle()` はこれまでどおり使え、その口を説明する例は対の形のまま残しています。`pushMatrix()` と `pushStyle()` の説明にも `push { }` への案内を足し、索引の「変換とスタイルの push / pop」では `push { }` を先頭に置きました。
