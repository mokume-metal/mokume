<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

スケッチが走っていないときに語彙を呼んでも、プロセスが落ちなくなった。走っていないときとは、自作の型 (`struct Player: SketchPart`) の `init()` の中・後片付けの後・`draw()` で起こした `Task` の中を指す。

- 読み取りは 0 や空を返す。`width`・`height`・`frameCount`・`time`・`deltaTime`・`random(…)` は 0、`clock` は `.wallClock` になる。
- 描く口・状態を書く口 (`circle`・`fill`・`translate` など) は何もしない。
- どちらも口ごとに 1 度だけ警告し、警告は観測の応答 (`warnings`) にも載る。以前は窓が開く前に落ち、理由も観測から読めなかった。

面から作る資源 (`createGraphics`・`loadImage`・`createShape` など) は、返す値を作れないので従来どおり止まる。止まるときの文面は、呼んだ口の名前を名乗るようになった ([#2265](https://github.com/mokume-metal/mokume/issues/2265))。
