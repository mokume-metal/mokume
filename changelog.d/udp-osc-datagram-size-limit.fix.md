<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createUDP(listen:send:)` と `createOSC(listen:send:)` が受ける・送る 1 つの datagram の大きさを、9215 バイトまで (9216 バイト未満) と名乗るようにした。macOS の受け口は 9216 バイトを超える datagram を先頭 9216 バイトに黙って切るので、これまでは 20000 バイトの datagram が 9216 バイトの別の文字列として `messages` に入り、OSC では大きな束の頭のメッセージだけが届いていた。いまは 9216 バイト以上の datagram を丸ごと捨てて数え、次のフレームで「could not be read and was discarded」と診断に出す。切れたものと見分けられないので、ちょうど 9216 バイトの datagram も捨てる。`udp.send(_:)` と `osc.send(_:_:)` も、9216 バイト以上になるものは送らず、大きさと上限を 1 度だけ知らせる (これまでは送れずに「Check that something is listening there」と受け手が居ない見当で名乗っていた) ([#2325](https://github.com/mokume-metal/mokume/issues/2325))。
