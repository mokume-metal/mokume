<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

外のサーバへ繋ぎに行く口を足しました ([#2470](https://github.com/mokume-metal/mokume/issues/2470))。`createTCPClient("127.0.0.1", 7000)` は TCP で、`createWebSocketClient("wss://relay.example/room")` は WebSocket (`ws://` も `wss://` も) で繋ぎます。サーバから届いたものは `messages` から読み、`TCPClient.write(_:)` / `WebSocketClient.send(_:)` で書きます。手元の制御盤や TouchDesigner の TCP/IP DAT、展示室の中継サーバに繋いで、値を受けたり合図を送ったりできます。Processing の `Client` に当たります。

サーバが居なくても、居なくなっても作れます。繋げない間の `state` は `.unavailable`、繋がると `.running`、繋がっていたのが切れると `.disconnected` で、**切れても繋げなくても 1 秒ごとに繋ぎ直し続けます** (返事をしない相手は 5 秒で諦めて繋ぎ直します)。間隔は固定で、変える口はありません。繋がっていない間の書き込みは、1 度だけ診断に出して捨てます。

相手なしで確かめるときは、記録した列を `createTCPClient(messages:)` / `createWebSocketClient(messages:)` で流せます (`createTCPServer(messages:)` と同じ形です)。走っていない所 (初期化子の中など) から呼ぶと、繋ぐ口は `NetworkFailure.notRunning(call:)` を投げ、記録を流す口は 1 度だけ警告して何も届かないものを返します。`createWebSocketClient` に `ws://` か `wss://` で読めない綴りを渡すと `NetworkFailure.invalidHost` を投げます。
