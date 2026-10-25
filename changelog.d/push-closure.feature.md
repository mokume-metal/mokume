<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`push { … }` で、閉包の間だけ変換とスタイルを積んで戻せるようになりました。** 閉包を抜けると、途中で `return` しても投げても、積んだときの移動・回転・塗り・線へ戻ります。部品の早期 `return` が `pop()` を飛ばして、後に描く図形へ移動や色が漏れることがなくなります。描き場所 (`createGraphics`) でも同じく使えます。

**対の崩れた `push()` / `pop()` を、書いた行を名指して 1 度だけ知らせるようになりました。** 積んでいないのに `pop()` を呼んだとき (`pop() at MySketch/main.swift:12 had nothing to restore …`) と、`push()` を降ろさないままフレームが終わったときです。これまではどちらも黙って何もしませんでした。`push()`・`pop()`・`pushMatrix()`・`popMatrix()`・`pushStyle()`・`popStyle()` は呼んだ場所を受ける既定の引数 (`fileID:line:`) を持つようになりましたが、呼び方は変わりません。
