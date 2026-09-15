<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`particles()` で描く粒が、どこから見ても画面に正対するようになりました。これまでは粒の板がワールドの XY 平面に固定されていたので、3 次元で `orbitControl()` や `camera()` で視点を回したり `rotateY()` で雲ごと回したりすると、板が横を向いて痩せ、真横では消えていました。視点を回さない 2 次元の絵は変わりません。ただし `rotate()` などで変換を回してから描いた粒は、位置は回りますが四角は傾かなくなります (変換から板が受け取るのは倍率だけです)。
