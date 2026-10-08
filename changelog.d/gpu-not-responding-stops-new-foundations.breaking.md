<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

GPU の完了を待つのが制限時間 (`RenderDevice.waitLimitSeconds`) を一度でも越えたプロセスでは、新しい `RenderDevice` を作らないようにしました。`RenderDevice()` と `RenderDevice(device:)` は、新しい `RenderFailure.gpuNotResponding` を投げ、`RenderDevice.isAvailable` は `false` を返します ([#2052](https://github.com/mokume-metal/mokume/issues/2052))。

文面の 1 行目は、最初に制限時間を越えた待ちの種類・時間・時刻を名乗ります。2 行目は、プロセスを起こし直すよう促します。期限を越えた待ちからは、1 フレームが描きすぎたのか、GPU が答えなくなったのかを見分けられません。そのため、重い 1 フレームでも同じように断ります。文面も両方の場合を名乗ります。印が立った瞬間には、同じことを 1 行の警告でも伝えます。窓で描いているスケッチが描けるようになったときの「Drawing has recovered」にも、このことを言い添えます。

これまでは、GPU が答えなくなった後も、土台を作るたびに GPU へコマンドを渡す発行口が 1 本ずつ増えていました。止まった発行口が溜まると、画面の描画ごと Mac が止まります。#2052 では、検査が土台を作り直し続けて、カーネルパニックまで行きました。既にある `RenderDevice` はそのまま使えます。その待ちは、今までどおり `.timedOut` で打ち切られます。

移行: 1 つのプロセスで `RenderDevice` を作り直し続ける道具 (1 枚描いて書き出すことを繰り返すなど) は、期限切れの後に `.gpuNotResponding` を受け取ります。受け取ったら、そのプロセスで描くのをやめて起こし直してください。`RenderFailure` を `switch` で網羅している場合は、コンパイル時に `gpuNotResponding` の枝が足りないと指摘されます。枝を足してください。
