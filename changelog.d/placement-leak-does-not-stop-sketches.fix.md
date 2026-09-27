<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

置き漏れを見つけたとき、利用者のスケッチを止めないようにした。置き漏れとは、フレームの頭の検めが、mokume の守りの無い道でフレームの外に置かれたものを見つけることを指す。これまでは debug 組みで止まり、mokume の中の不具合を踏んだ作品ごと落ちた。いまは漏れたものを描かずに捨て、1 度だけ注意する (`… This is most likely a fault inside mokume — please report it …`)。この注意が出たら、文面ごと報告してほしい。止まるのは mokume 自身の検査の中だけである ([#1682](https://github.com/mokume-metal/mokume/issues/1682))。
