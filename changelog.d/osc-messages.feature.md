<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

OSC のメッセージを受けて送れるようになりました。`osc = try createOSC(listen: 9000, send: ("127.0.0.1", 7000))` と呼べば、`draw()` の前に、前のフレームの後に届いたメッセージが全部、届いた順に `osc.messages` へ入ります。`message.address` で宛名を見分け、`message.float(0)`・`int(0)`・`string(0)` で引数を取り出します (型が合わなければ `nil`)。`osc.send("/hit", 1)` で `send` の宛先へ送れます。`plugins` には何も書きません。TouchDesigner や TouchOSC と、外のパッケージなしにやりとりできます。

読めない部分 (知らない型の印・途中で切れたバイト列など) を含むパケットは、推して読まずにそこから後ろを捨て、捨てた数を次のフレームで知らせます。他のアプリがポートを使っていても作れて、`osc.state` が `unavailable` になり、空けば受け始めます。`createOSC(messages:)` は、記録したメッセージの列をフレームごとに 1 束ずつ流し、ポートを開かずに同じスケッチを確かめられます。

外から届く出来事を落とさずに溜める入れ物 `ExternalQueue` も加わりました。上限を超えたら古いものから捨て、捨てた数と読めずに捨てた数を、次に読まれたときに知らせます。外のパッケージが自分の入り口を作るときにも使えます。
