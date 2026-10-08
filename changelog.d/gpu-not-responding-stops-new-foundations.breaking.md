<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

GPU の完了を待つのが制限時間 (`RenderDevice.waitLimitSeconds`) を一度でも越えたプロセスでは、新しい `RenderDevice` を作らないようにしました。`RenderDevice()` と `RenderDevice(device:)` は、新しい `RenderFailure.gpuNotResponding` を投げます。文面の 1 行目で「GPU が答えなくなった」ことを、2 行目でプロセスを起こし直すことを名乗ります。`RenderDevice.isAvailable` は `false` を返します ([#2052](https://github.com/mokume-metal/mokume/issues/2052))。

これまでは、GPU が答えなくなった後も、土台を作るたびに GPU へコマンドを渡す発行口が 1 本ずつ増えていました。止まった発行口が溜まると、画面の描画ごと Mac が止まります。#2052 では、検査が土台を作り直し続けて、カーネルパニックまで行きました。既にある `RenderDevice` はそのまま使え、その待ちは今までどおり `.timedOut` で打ち切られます。

移行: 1 つのプロセスで `RenderDevice` を作り直し続ける道具 (1 枚描いて書き出すことを繰り返すなど) は、期限切れの後に `.gpuNotResponding` を受け取ります。受け取ったら、そのプロセスで描くのをやめて、起こし直してください。`RenderFailure` を `switch` で網羅している場合は、コンパイル時に `gpuNotResponding` の枝が足りないと指摘されるので、枝を足してください。
