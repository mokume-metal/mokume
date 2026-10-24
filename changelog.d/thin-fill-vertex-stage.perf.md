<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`shader()` や `texture()` を付けた細い `rect` / `ellipse` を、向きをばらばらにして何千個も置く絵が速くなりました。1 画素より細い塗りの広げ方を CPU が 1 個ずつ組み直すのをやめ、GPU が置き場所ごとに広げるので、回転が全部違っても 1 つの雛形に畳まれます。絵は変わりません。保持した形 (`createShape`) の細い塗りは、これまでどおり置いた向きごとに 1 度組み直します。
