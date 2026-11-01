<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

PostScript 系 (CFF) の書体で `textOutline` が外周と穴を取り違えて返していたのを直した。ヒラギノや AppleSDGothicNeo のような書体では、`o` の外側の輪が `isHole` が `true` の周、内側の輪が `false` の周として、内側が先に返っていた。書体の巻きの向きが逆なためで、いまは字ごとに面積が最大の周を外周とみなして向きをそろえるので、どの書体でも外周が先・穴が後で、`isHole` は穴の周だけで `true` になる。
