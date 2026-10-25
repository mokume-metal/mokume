<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

走っているスケッチの中で起こした `Task` から、`AudioIn`・`Capture`・`TCPServer`・`WebSocketServer`・`TCPClient`・`WebSocketClient`・`UDPPort`・`OSCPort`・`Serial` の `stop()` と、公開の `detach(_:)` が効かなかった (警告だけが出て、機材やポートは動き続けた)。入り口・出口を足した実行を差込口ごとに控えるようにして、足した実行が走っている間は、`Task` の中 (`Task.detached` を含む) からも止まり、外れるようにした。足していないものと、スケッチが終わった後 (終わりの処理が既に閉じている) に呼んだ `stop()` は、今までどおり何もせず、型を付けた名前で 1 度だけ知らせる。
