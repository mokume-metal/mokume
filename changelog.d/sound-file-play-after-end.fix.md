<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**スケッチが終わった後に `SoundFile` の `play()`・`loop()`・`Env.play` を呼んでも、`isPlaying` が `true` にならなくなりました。** スケッチが終わった後の音声ファイルはもう鳴りませんが、これまではこれらを呼ぶと鳴らないのに `isPlaying` が `true` になっていました。いまは `false` のままで、合成した音源 (`SinOsc` など) と同じく、鳴らない音を鳴っていると読ませません。`detach(_:)` で外している間に呼んだ `play()` は、これまでどおり `isPlaying` を `true` にし、`attach(_:)` で足し直したフレームから鳴ります。スケッチが終わった時点の `isPlaying` は `SoundFile` では `false`、合成した音源では終わる前の値のまま、という違いは変わらず、説明に書きました。
