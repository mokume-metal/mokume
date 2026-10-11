<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

エージェントの窓口 (`mokume mcp`) が、JSON-RPC 2.0 の「通知には答えず、呼び出しには必ず答える」約束どおりに振る舞うようになった ([#2317](https://github.com/mokume-metal/mokume/issues/2317))。`id` の無い通知には、`initialize`・`tools/list`・`tools/call` でも何も返さない。これまでは `"id": null` で答えており、`tools/call` の通知は道具を実際に走らせていた (`input` なら事象がスケッチへ届いていた)。

逆に、答えるべき行には誤りを 1 行返す。JSON として読めない行には `-32700`、`method` の無い・文字列でない行や束 (配列) には `-32600` を、読める `id` で (読めなければ `null` で) 返す。これまでは黙って捨てていたので、繋いだ側は来ない答えを待ち続けることがあった。繋がりはどちらでも切らない。束は扱わない — 名乗る版 (MCP 2024-11-05) は束を含まない。応答の形の行 (`method` が無く `result` か `error` を持つもの) には答えず、これまでどおり黙って読み飛ばす。窓口は自分から要求を出さないので、届く応答に答える相手はいない。

`ping` に空の結果で答えるようになった ([#2318](https://github.com/mokume-metal/mokume/issues/2318))。これまでは `-32601` を返していたので、繋がりを保つために `ping` を送る繋ぎ手は誤りを受け取っていた。
