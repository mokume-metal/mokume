<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

音声ファイルを鳴らしながら、鳴っている音を解析できるようになりました。`song = try? loadSound("assets/song.wav")` で読み、`song?.play()` か `song?.loop()` で鳴らします。`pause()`・`stop()`・`amp(_:)`・`isPlaying` は Processing の `SoundFile` と同じ形です。解析の値は `AudioIn` と同じ名前 (`song.level`・`song.spectrumLevels`・生の `rms`・`decibels`・`spectrum`) で、`draw()` の前にそのフレームで鳴っている音の値が入ります。`mokume render` で書き出すときは鳴らさず、フレームの数から決めた位置の音を解析するので、書き出した絵は実時間で鳴らしたときと同じ時刻の音で動き、何度書き出しても同じになります。時刻が実時間かフレームの数え方かは、新しい `clock` で読めます。読めないファイルと長さ 0 のファイルは、`loadSound` が `AudioFailure` を投げて知らせます (`createAudioIn(file:)` に長さ 0 のファイルを渡したときも、`unreadable` ではなく `empty` になりました)。
