<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`shader()` や `texture()` を付けた角丸の `rect` (`rect(x, y, w, h, r)`) も、輪郭 (`stroke`) が無ければ、角を丸めない `rect` と同じく、置き場所が違っても 1 つの雛形に畳まれるようになりました ([#3170](https://github.com/mokume-metal/mokume/issues/3170))。これまでは置くたびに CPU で角丸の周と細い塗りの片を組み直していたので、回転が全部違う細い角丸 `rect` を 10,000 個置く絵で、組み立てが 12〜13 ms から 6〜7 ms に半分になります (release・1280×720・細かさ 0.5)。輪郭のある角丸 `rect` は今までどおり置き場所ごとに組みます。絵は 1 ビットも変わりません。
