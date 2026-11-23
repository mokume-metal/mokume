<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

ウィンドウで `mokume run --record` した記録で、`soundTime`・`SoundFile` の `position`・`isPlaying` を読んだら、記録と `mokume replay` が「再現を保証しない」と読んだ値の名前つきで名乗るようになった。

ウィンドウでは音の時計が実際に鳴った音の進みで決まり、ウィンドウなしの再生ではフレームの数で決まるので、これらの値で描いた絵は再生で食い違いうる。これまでは名乗らず、黙って食い違いうる記録になっていた。音を鳴らすだけの作品と、ウィンドウなしで録った記録は、これまでどおり名乗らない。
