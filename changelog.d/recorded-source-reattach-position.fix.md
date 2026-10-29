<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

記録した列を流す入り口 (`createOSC(messages:)`・`createTCPServer(messages:)` ほかのネットワークの口と `createSerial(lines:)`、`createGamepad(inputs:)`、`createCapture(frames:)`、`createAudioIn(file:)`・`createAudioIn(samples:sampleRate:)`) を、`detach` で外してから `attach` で足し直したときの再開位置を、**時刻どおり**に揃えました。足し直した後のフレームには、外さずに回したときと同じ値が入ります (外していた間の分は届きません)。

これまでは型ごとに違いました。ネットワークとシリアルは列の頭から、パッドとカメラは外す前の続きから、音のファイルと標本列は足し直した時刻を起点にして標本の頭から流し直していました。たとえば 6 つの値 `x0…x5` を流す入り口を、2 フレーム目で外して 4 フレーム目に足し直すと、5 フレーム目にはネットワークで `x0`、パッドとカメラで `x2` が入っていました。いまはどれも、外さずに回したときと同じ `x4` です。`createVideo` はもともとこの形で、動画の位置は外していた秒数だけ進みます。

各口の説明に「外して足し直しても、i 番目のフレームには `x[i]` が入る」を書きました。外さずに回すスケッチの値は変わりません。
