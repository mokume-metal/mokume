<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

画像と画素の 16 口 (`loadImage` / `requestImage` / `createImage` / `image` の 6 つ / `imageMode` / `tint` / `noTint` / `createGraphics` / `get` / `set` / `loadPixels`) に例を付け、うち 13 口に絵を 17 枚付けた。素材の絵はリポジトリに置かず、例の中で `createImage` か `createGraphics` から手続きで作っている。絵を付けられない 3 口 (`loadImage` / `requestImage` / `loadPixels`) には、付けられない理由を説明文に書いた。

`make example-shots` が、`setup()` を書いた例と `<!-- example: 文脈 … -->` の宣言を扱えるようになった。これまでは例を必ず `draw()` の本体として包んでいたので、投げる呼び出しを含む例 (絵を作る口はすべてそう) に絵が付けられなかった。
