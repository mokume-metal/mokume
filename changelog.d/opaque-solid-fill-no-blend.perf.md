<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

不透明な `box()` や `sphere()` を奥から手前へ何層も重ねる 3D スケッチが速くなりました。不透明と分かる塗りはブレンドを使わずに描くので、GPU が隠れた面の断片を省けます。絵は 1 画素も変わりません。半透明の塗り・`texture()`・`shader()`・`blendMode()` を使った塗りは、これまでと同じ描き方のままです。
