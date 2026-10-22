<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`SoundFile` を `detach(_:)` で外して `attach(_:)` で足し直しても、もう一度鳴るようになった。これまでは足し直した後が無音のままで、出力の機材は開けているのに `No audio output could be opened` と知らせていた ([#3108](https://github.com/mokume-metal/mokume/issues/3108))。

鳴らし直すときは、外している間は手放していた読み込み済みの音を、読み込んだファイルからもう 1 度読む (外している間に標本の写しを持ち続けない)。ファイルが消えた・差し替わったなどで読み直せなければ、鳴らさずに実時間で位置を進め、そのことを 1 度だけ知らせる。書き出し (`mokume render`) は鳴らさないので、位置は変わらない。
