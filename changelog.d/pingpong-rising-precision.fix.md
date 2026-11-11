<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`pingpong` の `length` が大きいとき、立ち上がりの時刻が 0 に潰れなくなった。これまでは `pingpong(1, 100_000_000)` と `pingpong(2, 100_000_000)` がともに 0 を返していた。立ち上がりの区間では周期の中の位置をそのまま返し、負の `length` でも同じく `-1`・`-2` が返る。
