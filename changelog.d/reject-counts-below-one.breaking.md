<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

組み立てで受け取る数が 1 を割ったとき、黙って 1 に丸めずに型のついたエラーで断るようにしました ([#1642](https://github.com/mokume-metal/mokume/issues/1642))。**0 以下を渡していたスケッチは、これまでのように動き続けず、起動や `setup()` の時点で断られます。**

- `SketchSettings.frameRate` (と、ランタイムへ渡す時計 `.frameIndex(frameRate:)` の刻み) が 0 以下なら、起動の組み立てが新しい `RenderFailure.invalidFrameRate` を投げます。これまでは黙って 1 fps で走っていました
- `createGraphics(_:_:)` の幅・高さが 0 以下なら `RenderFailure.invalidSize` を、`createImage(_:_:)` なら `ImageFailure.unplaceable` を投げます。これまでは 1×1 が返っていました
- `makeNumbers(count:)` と `makeParticles(count:)` の `count` が 0 以下なら、新しい `RenderFailure.invalidCount` を投げます。これまでは 1 個ぶんが返っていました

移行: `frameRate: 0` を「止める」の意味で書いていたなら、`frameRate` は 1 以上にして `setup()` で `noLoop()` を呼んでください。大きさや数に 0 以下が入りうるなら、渡す前に 1 以上へ直してください。`RenderFailure` を `switch` で網羅している場合は、コンパイル時に `invalidFrameRate` と `invalidCount` の枝が足りないと指摘されるので、枝を足してください。
