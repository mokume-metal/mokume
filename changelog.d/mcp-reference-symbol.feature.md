<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

MCP の `reference` が引数 `symbol` を受け、作品が依存している版の口ごとの説明と例を返すようになりました。`reference(name: "api", symbol: "ambientLight")` で、`ambientLight` の多重定義がすべて、宣言と説明の全文 (目盛りが 0…1 であること、置く場所、例) つきで読めます。`SoundFile.play` のように `型.名前` と書けば、その型の口だけに絞れます。説明は宣言の索引 (`reference(name: "api")`) には載せず、版ごとの Release の資産 `mokume-api-details-v<版>.json` から引くので、**依存している版と違う版の説明が返ることはありません** — 依存版に資産が無ければ、別の版で埋めずにそう答えます (索引は引けます)。新しく作るスケッチの `AGENTS.md` にも、未知の口を推測で書く前にこれで調べる案内が入ります。資産は、この変更を含む版から Release に付きます。
