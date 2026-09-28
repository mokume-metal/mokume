<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

全頂点に `normal()` を指定した自由形状で、使わない面法線の計算と一時配列の確保を省くようになった。指定した法線・陰影・利用者 shader に渡す値は変わらず、未指定の法線を含む形状は従来通り形から向きを求める。
