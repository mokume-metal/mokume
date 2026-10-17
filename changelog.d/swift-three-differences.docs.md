<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

Processing や p5.js から来て最初に踏む Swift の決まり 3 つが、リファレンスの入口の「Swift で 3 つだけ違うこと」にまとまりました。

`rotate(.pi / 4)` は型が決まらず赤くなるので `QUARTER_PI` などの定数か `Float.pi` で書くこと、`1 / 2` は 0 になるので片方に小数点を付けること、画像などを作る口は失敗を投げるので `try?` と `guard let` (理由を受け取るなら `do` / `catch`) で受けること。README のクイックスタートからこの節へ 1 行のリンクで届きます。
