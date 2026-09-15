<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`textOutline()` の説明に、返る周の分かれ方が書体と字によって変わることを書いた。既定の書体では `A` や `B` が重なった外周として返り `isHole` が立たないので、字を「外周 + 穴」の 1 つの形として扱いたいときは `textFont()` で書体を指定する。
