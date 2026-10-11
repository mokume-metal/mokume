<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createUDP(listen:)` と `createOSC(listen:)` の受け口が、空の datagram (0 バイト) を黙って捨てなくなった。これまでは空の datagram を受けるとその送り元の繋ぎを失敗として閉じ、空の datagram も、間を空けずに続いた datagram も、数えず診断も出さずに捨てていた (1 つの送り元から `"a"`・`""`・`"b"`・`"c"` を間を空けずに送ると、`messages` は `["a"]` だった)。いまは UDP では空の datagram が空の文字列 `""` として `messages` に入り (`udp.send("")` も相手に `""` として届く)、OSC では読めないものとして数えて次のフレームで診断に出す。ただし macOS の受け口は、空の datagram を受けるとその送り元の流れを閉じることがあり、そのとき空の直後 (1 ミリ秒ほどの間) に同じ送り元から届いたものは届かない ([#2324](https://github.com/mokume-metal/mokume/issues/2324))。
