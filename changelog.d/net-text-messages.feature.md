<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

UDP で文字列を受けて送れるようになりました。`udp = try createUDP(listen: 6000, send: ("127.0.0.1", 6001))` と呼べば、`draw()` の前に、前のフレームの後に届いた文字列が全部、届いた順に `udp.messages` へ入ります。1 つの datagram が 1 つの文字列で、末尾の改行は落ちるので、`nc -u 127.0.0.1 6000` で打った `0.3` がそのまま `Float(text)` で読めます。`udp.send("hit")` で `send` の宛先へ送れます。`plugins` には何も書きません。

UTF-8 として読めないものは捨て、捨てた数を次のフレームで知らせます。他のアプリがポートを使っていても作れて、`udp.state` が `unavailable` になり、空けば受け始めます。`createUDP(messages:)` は、記録した文字列の列をフレームごとに 1 束ずつ流し、ポートを開かずに同じスケッチを確かめられます。
