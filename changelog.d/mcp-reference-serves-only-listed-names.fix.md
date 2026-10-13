<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume mcp` の `reference` が、配っている一覧にある名前の文書だけを返すようになった ([#2395](https://github.com/mokume-metal/mokume/issues/2395))。`name` に `../outside` を渡すと、これまでは面の仕様の置き場の 1 つ上にある `outside.schema.json` の中身が返った (読めたのは末尾が `.schema.json` のファイルだけ)。いまは `a/b` や `..` と同じく、一覧に無い名前として `There is no document by that name: …` (`isError: true`) で断る。一覧にある名前・`api`・`startup` はこれまでどおり読める。
