<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

音を合成して鳴らせるようになりました。Processing Sound と同じ型・同じ呼び口で、オシレータ (`createSinOsc()`・`createSqrOsc()`・`createTriOsc()`・`createSawOsc()`)・ノイズ (`createWhiteNoise()`・`createPinkNoise()`)・包絡 (`createEnv()`)・濾波器 (`createLowPass()`・`createHighPass()`・`createBandPass()`)・エフェクト (`createReverb()`・`createDelay()`) を作れます。`osc = createSinOsc()` で作り、`osc?.play(440, 0.5)` で鳴らし、`draw()` の中で `osc?.freq(map(mouseX, 0, width, 100, 1000))` のように動かします。音を `filter.process(noise, 800)` のようにエフェクトへ通すと、通した音はエフェクトの出口を通って鳴り、エフェクトの出口を別のエフェクトへ通すこともできます。合成した音は再生 (`SoundFile`) と同じ音の流れに入り、`level`・`spectrumLevels`・生の `rms`・`decibels`・`spectrum` を `AudioIn` と同じ名前で読めます (エフェクトは出口の音の値です)。`mokume render` で書き出すときは鳴らさず、フレームの数から標本を進めて解析するので、同じ操作からは何度書き出しても同じ値になります。範囲の外の値は丸め、数でない値は無視して、それぞれ 1 度だけ知らせます (投げません)。
