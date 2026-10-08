<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

TCP・UDP・WebSocket で文字列を受けて送れるようになりました。`server = try createServer(5204)` (TCP。Processing の `Server` と同じ名前)・`socket = try createWebSocketServer(8025)`・`udp = try createUDP(listen: 6000, send: ("127.0.0.1", 6001))` は、`draw()` の前に、前のフレームの後に届いた文字列を全部、届いた順に `messages` へ入れます。TCP は改行で区切った 1 行、WebSocket は 1 通、UDP は 1 つの datagram が 1 つの文字列で、末尾の改行は落ちるので、`nc 127.0.0.1 5204` で打った `0.3` やブラウザの `ws.send("0.3")` がそのまま `Float(text)` で読めます。送る向きは `server.write("hit\n")`・`socket.write("hit")` (繋いでいる相手全員へ) と `udp.send("hit")` (`send` の宛先へ) です。`plugins` には何も書きません。

繋いでいる相手の数は `clientCount` で読め、相手が居ないときの `write` は 1 度だけ知らせます。UTF-8 として読めないもの (TCP は 64 KiB を超える行も) は捨て、捨てた数を次のフレームで知らせます。他のアプリがポートを使っていても作れて、`state` が `unavailable` になり、空けば受け始めます。`createServer(messages:)`・`createUDP(messages:)` は、記録した文字列の列をフレームごとに 1 束ずつ流し、ポートを開かずに同じスケッチを確かめられます。
