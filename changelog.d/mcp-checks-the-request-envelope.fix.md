<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume mcp` が、JSON-RPC の呼び出しの形が正しくない行を -32600 で断るようになった。`jsonrpc` が `"2.0"` でない (無い) 行・`id` が文字列でも数でもない行・`params` がオブジェクトでない (配列・数・文字列) 行が対象で (`params` を省くのと `null` は、これまでどおり省略と同じ)、これまでは `method` が文字列でありさえすれば呼び出しとして通り、型の違う `id` がそのまま答えに載り、配列の `params` は黙って空のオブジェクトに倒されていた ([#2353](https://github.com/mokume-metal/mokume/issues/2353))。断りの答えの `id` は、読める `id` (文字列・数) があればそれ、無ければ `null` になる。通知 (`id` の無い行) も、形が違えば通知かどうかを見ずに断る。

**`"id": null` の要求も断る。** MCP 2024-11-05 は request の ID に null を禁じており、`id: null` の答えは読めない行を断る誤り (`id: null`) と繋ぎ手から見分けが付かないため。これまでは `id: null` の要求にも道具を走らせて答えていた。`jsonrpc` を付けない・`"2.0"` 以外を付ける・`id: null` を送る自作の繋ぎ手は答えをもらえなくなる (誤りは返るので原因は分かる)。仕様どおりの MCP の繋ぎ手は影響を受けない。
