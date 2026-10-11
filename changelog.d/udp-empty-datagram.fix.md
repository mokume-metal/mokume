<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createUDP(listen:)` と `createOSC(listen:)` の受け口が、空の datagram (0 バイト) を受けても、その送り元から続けて届いたものを落とさなくなった。これまでは空の datagram を受けるとその送り元の繋ぎを閉じ、空の datagram も、間を空けずに続いた datagram も、数えず診断も出さずに捨てていた (1 つの送り元から `"a"`・`""`・`"b"`・`"c"` を送ると、`messages` は `["a"]` だった)。いまは UDP では空の datagram が空の文字列 `""` として `messages` に入り (`udp.send("")` も相手に `""` として届く)、OSC では読めないものとして数えて次のフレームで診断に出し、前後のメッセージはすべて届く ([#2324](https://github.com/mokume-metal/mokume/issues/2324))。
