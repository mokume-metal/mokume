<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`noCursor()` / `cursor()` を追加した。`setup()` で `noCursor()` を呼ぶと、作品の面の上にポインタがあるあいだ矢印のカーソルが隠れる — `.fullScreen(2)` の展示でも、窓でも、束ねた `.app` でも同じで、面の外 (窓の枠・別の窓・別の画面) へ出せば見える。`cursor()` で戻る。

`requestPointerLock()` でカーソルを捕まえる口とは食い違わない。`noCursor()` の後に捕まえて放しても、面の上では隠れたままで、捕まえている間に `cursor()` を呼んでも捕まえの隠しは外れない。`mokume watch` の下では、作品の窓とプレビューのどちらの面の上でも隠れ、保存で作り直したスケッチが `noCursor()` を呼ばなければ矢印が戻る。書き出す絵は変わらない。`@Param` のつまみの面は、これまでどおり重なる (つまみの上では矢印が見える)。
