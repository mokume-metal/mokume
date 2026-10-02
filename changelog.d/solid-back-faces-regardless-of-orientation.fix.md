<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

半透明の塗り・加算 (`blendMode(.add)`)・透けた絵を貼った (`texture()`)・利用者の断片 (`shader()`) で描いた立体と、それらで記録した保持した形 (`createShape`) で、奥の面が透けて見えるかが形の向きで変わっていたのを直した。たとえば半透明の `sphere(40)` は、`rotateY(π)` するかどうかで中心の明るさが 1 層ぶんと 2 層ぶんに分かれ、球の中に横縞のような境目が出ていた。いまはどの向きでも、光を当てても、奥の面が全面で透ける ([#1549](https://github.com/mokume-metal/mokume/issues/1549)・[#1565](https://github.com/mokume-metal/mokume/issues/1565))。

1 つの形の中だけを裏の面 → 表の面の順に描くようにした。形どうしは今までどおり呼び出し順で重なり、並べ替えない (奥から順に置く責任は作品側にある)。その代わり、これらのスタイルで置いた形 (絵を貼った形は、絵が不透明でも) は 1 つにつき 2 回描くので、半透明・加算・絵を貼った球を 1000 個並べると 1 フレームが約 0.35 ms 長くなる (Apple M5)。不透明の形の費用は変わらない。粒 (`particles`) と `beginShape` で並べた頂点は対象外である。
