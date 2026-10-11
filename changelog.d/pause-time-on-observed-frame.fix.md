<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

時刻を指定した観測 (MCP の `observe` に `{"time": 5}` を渡す) が描き直す 1 枚の中で `pauseTime()` を呼ぶと、観測の秒 (5 秒) で `time` が止まり、撮った後も作品の時計へ戻らなかったのを直しました。その枚で止めたときは、観測が無ければその枚が持っていた秒で止まります。観測の枚で止めなければ、これまでどおり次の枚から元の時計へ戻ります。
