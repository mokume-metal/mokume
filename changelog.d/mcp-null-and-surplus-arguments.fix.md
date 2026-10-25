<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

エージェントの窓口 (`mokume mcp`) の道具が、引数の読み方を 2 つ揃えた。省略できる欄の `null` は省いたのと同じに読むようになり、`observe` の `time`・`count`・`every` に `null` を渡しても道具の誤りにならない (型の違う値 `"3"`・`true` は今までどおり断る)。反対に、道具が知らない名前の引数は、黙って捨てずに道具の誤りで断る。`observe` に `{"scal": 0.5}` と綴りを違えて渡すと、いままでは黙って等倍で撮っていたが、知らない名前 (`scal`) と受ける名前 (`time`・`scale`・`count`・`every`) を挙げて断る。各道具の `inputSchema` も `additionalProperties: false` を名乗る。
