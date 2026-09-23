<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`noLoop()` / `loop()` / `redraw()` と `save()` / `beginRecord()` / `endRecord()` を呼び出しの外から頼んだときに、「the sketch is not running」と言わなくなりました。** これらが受け付けるのは `setup()`・`draw()`・`mousePressed()` などの入力のコールバックの中から呼んだときだけで、そこで起こした `Task` の中身は返った後に走るので外になります。これまではそこから頼むと、`draw()` が回り続けている最中でも「走っていない」と断っていたので、起動に失敗したのか終わったのかを疑うことになっていました。いまは「どこからなら受け付けるか・この呼び出しは外からだったので何もしなかった・`Task` も外に数える」と言います。断る振る舞いそのものは変わりません。`save()` / `beginRecord()` の断りは、行き先の名前を添えなくなりました。
