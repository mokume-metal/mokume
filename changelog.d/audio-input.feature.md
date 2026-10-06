<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

マイクの音を解析できるようになりました。`mic = createAudioIn()` と呼べば、`draw()` の前にそのフレームの音を解析した値が入ります。生の値 (`mic.rms`・`mic.decibels`・帯域ごとの `mic.spectrum`) と、-60〜0 dBFS を 0〜1 に写した値 (`mic.level`・`mic.spectrumLevels`) を別の名前で読めるので、絵に使うときは 0〜1 の値をそのまま大きさや明るさに渡せます。`plugins` には何も書きません。`audioInputDevices()` で入力の機材を列挙し、`device:` で 1 つを選べます。機材が無くても作れて、選んだ機材が抜かれたら `mic.state` が `disconnected` になります。`createAudioIn(file:)` と `createAudioIn(samples:sampleRate:)` は、音声ファイルや合成した標本列を鳴らさずに解析します。どの窓を解析するかはフレームの時刻だけで決まるので、書き出すたびに同じ値になります。束ねるときは `mokume-app.json` に `microphoneUsage` を書かないと `mokume bundle` が止まります。資材の名前を `loadImage` と同じ並びで場所へ解く `assetURL(_:)` も加わりました。
