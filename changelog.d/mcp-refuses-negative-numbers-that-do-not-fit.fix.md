<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume mcp` が、`Double` に収まらない負の数 (`-1e400`・`-1.8e308`) を含む行を、正の側 (`1e400`) と同じく `-32700` (parse error) で断るようになった ([#2476](https://github.com/mokume-metal/mokume/issues/2476))。これまでは負の側だけ `-inf` として読んで通したので、`"id":-1e400` の `tools/call` が道具まで走って応答の `id` が JSON にならず (`id` が `null` で `-32603`)、`"scale":-1e400` のような引数の数は `-inf` のまま道具へ渡っていた。`id`・引数・配列の中・通知のどこに書いても、その行は道具を走らせずに断られ、繋がりは切れない。`Double` の最小値ちょうど (`-1.7976931348623157e308`) はこれまでどおり読める。
