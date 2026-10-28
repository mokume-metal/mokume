<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**音と動画の `jump(_:)` で終わりへ飛ばした後の `play()` は、頭から流れるようになりました。** これまでは、止まっている間に `jump(song.duration)` してから `play()` すると、`SoundFile` を直に鳴らす道は頭から鳴り、エフェクトへ通した道は無音のまま、口によって違いました。どちらも頭から鳴ります。`Movie` も、同じフレームで `jump(movie.duration)` と `play()` を呼ぶと終わりのコマのまま止まっていたのが、頭から流れます。鳴っている間に終わりへ飛ばすと、頭の音が約 1 フレーム出ていたのは、出ずに無音で止まります。 `jump(song.duration)`・`jump(movie.duration)` のように公開の `duration` をそのまま渡したときも、長さが単精度で表せない動画 (3.3 秒など) や長い音 (48 kHz で 256 秒超) で終わりの手前に着いて、頭から流れなかったり 1 標本だけ鳴って終わったりしていたのが、終わりへ着くようになりました。
