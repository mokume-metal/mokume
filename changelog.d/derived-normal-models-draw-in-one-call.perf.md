<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

法線を書いていない OBJ のモデル (向きを形から求めたもの) を記録した形も、半透明の塗り・加算・透けた絵・利用者の断片で `shape(_:at:)` により大量に置いたとき、置き場所ごとに 2 回描いていたのを、置き場所の連なりごとに 1 回の描く呼び出しにまとめた ([#2222](https://github.com/mokume-metal/mokume/issues/2222))。[#1947](https://github.com/mokume-metal/mokume/issues/1947) で他の形に入れたまとめ方の残りで、法線を書いていない立方体のモデルを半透明の色で 1 万か所に置くと、描く呼び出しが 20,000 回から 2 回になり、1 フレームが 2.9〜3.0 ms から 1.9〜2.0 ms になる (release・Apple M3 Max)。

絵は 1 画素も変わらない。裏を向いた面にも、置き場所ごとに描いたときと同じ向きで光が当たる。
