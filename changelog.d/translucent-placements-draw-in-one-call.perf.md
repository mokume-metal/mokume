<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

半透明の塗り・加算・透けた絵を貼った形・利用者の断片で描いた立体を `shape(_:at:)` で大量に置いたときの 1 フレームが速くなった。奥の面を透かすために置き場所ごとに 2 回描いていたのを ([#1549](https://github.com/mokume-metal/mokume/issues/1549)・[#1565](https://github.com/mokume-metal/mokume/issues/1565))、置き場所の連なりごとに 1 回の描く呼び出しにまとめた ([#1947](https://github.com/mokume-metal/mokume/issues/1947))。`sphere(3, detail: 12)` を 1 つ記録した形を 10 万か所に置くと、半透明の色で 19.5〜19.6 ms、不透明な絵を貼った形で 19.5〜19.8 ms だった 1 フレームが、どちらも 6.0〜6.6 ms になる (release・Apple M3 Max)。1 万か所なら 2.3〜2.5 ms が 0.9〜1.0 ms になる。

絵は 1 画素も変わらない。置き場所どうしの重なりの順も今までどおり呼び出し順のままで、奥から順に置く責任は作品側にある。置き場所が少ないときと、法線を書いていない OBJ のモデル (向きを形から求めたもの) は、今までどおり置き場所ごとに描く。
