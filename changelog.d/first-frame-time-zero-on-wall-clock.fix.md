<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**窓で動かしているときも、最初のフレームの `time` が 0、`deltaTime` が 1 フレームぶん (60 fps なら 1/60 秒) から始まるようになりました。** これまでは、アプリの起動と `setup()` にかかった時間が最初のフレームの `time` に乗り (`setup()` に 2 秒かかれば約 2.0 から始まる)、最初の `deltaTime` も上限 (目標の 10 フレームぶん) まで長くなっていました。書き出し (`mokume render`) の時刻は前から 0 で始まっており、変わりません。`setup()` の長さは機械ごとに違うので、`time` から導いた動きの位相が機械ごとにずれていたのも揃います。最初の長い `deltaTime` を `min(deltaTime, …)` で抑えていた書き方はそのまま動きます (要らなくなります)。
