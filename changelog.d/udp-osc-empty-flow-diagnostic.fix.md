<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createUDP(listen:)` と `createOSC(listen:)` の受け口が、空の datagram で送り元の流れが閉じたとき、落ちたかもしれないことを送り元ごとに 1 度だけ診断に出すようになった。たとえば `udp :6000: an empty datagram from 127.0.0.1:51234 closed its flow, so datagrams that arrived from the same sender right after it (within about 1 ms) may have been dropped` と出る。macOS の受け口は、空の datagram を受けるとその送り元の流れを閉じることがあり、そのとき空の直後 (1 ミリ秒ほどの間) に同じ送り元から届いたものは、これまで数えず診断も出さずに落ちていた ([#2324](https://github.com/mokume-metal/mokume/issues/2324))。落ちた数は分からず、実際には何も落ちていなくても出る。同じ送り元には何度閉じても 1 度だけで、覚える送り元は 256 まで (超えたら先に覚えた送り元から忘れる)。
