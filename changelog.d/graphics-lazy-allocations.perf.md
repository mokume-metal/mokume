<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createGraphics()` で作る描き場所が、使わない置き場を GPU のメモリに取らなくなった。字を置くまでは字形を焼く 256×256 の面を持たず、描いた図形の種類の分だけ置き場を取るので、小さい描き場所を多く作るスケッチのメモリが減る。絵は変わらない。
