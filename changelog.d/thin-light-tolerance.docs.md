<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`strokeWeight(_:)`・`fill(_:)`・`pixelDensity` の説明で、1 画素より細い線・塗りの濃さが置く位置で ±25% ほどまで振れうることを名乗るようにした。動かしたときに目に見えて明滅する外れは引き続き直し、それより細かい揃えより描く速さを優先する ([#3859](https://github.com/mokume-metal/mokume/issues/3859))。描画は変わらない。
