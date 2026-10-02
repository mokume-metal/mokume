<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createShape { }` の中で書いた設定の扱いを、種類ごとに 1 通りに揃えました。

- 中で呼んだ `curveDetail()`・`curveTightness()`・`noiseSeed()`・`noiseDetail()` が、組み立ての後に描く曲線や揺らぎまで変えていたのを直しました。塗りや線と同じく形にだけ焼き付き、抜けると組み立て前の値へ戻ります。中で `curveDetail(2)` を呼ぶと、形は粗く刻まれ、外の曲線は元の細かさのまま出ます。
- `draw()` の中で組み立てたとき、中で書いた `clip()`・材質・`castShadow()` などは形にも入らず黙って消え、光・視点・`effects()` などはそのフレームにそのまま効いていました。形に焼き付かないこれらの設定は、`setup()` で組み立てたときと同じく、1 度注意して何もしないようにしました。面全体の明るさを決める `exposure()`・`toneMapping()` も、組み立ての中ではどこで組み立てても同じ扱いです。どれも組み立ての前か後で書いてください。
