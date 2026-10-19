<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`createGraphics()` が、作りたての描き場所をもう一度塗り直さず、GPU の仕事が全部終わるのも待たなくなりました。** 作った描き場所は、これまでどおり透明な黒で始まります。層を `setup()` で多数作るスケッチや、フレームの途中で層を作るスケッチで、作るたびに乗っていた余計な塗りと待ちが無くなります。
