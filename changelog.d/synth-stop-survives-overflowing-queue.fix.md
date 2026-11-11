<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

合成音 (オシレータ・ノイズ) に 1 フレームで数千回の操作 (`freq()` など) を頼んだ直後に `stop()` を呼ぶと、停止が捨てられて `isPlaying` が `false` なのに音が鳴り続けていたのを直しました。同じ溢れ方で、受け付けられなかった `play()` が `isPlaying` を `true` にしたり、エフェクトの `stop()` が効かなかったり、`SoundFile` の `amp()` が解析の値だけ変えたりしていました。止める・エフェクトの入力を外す・音を手放す操作は溢れても必ず届き、受け付けられなかった `play()`・繋ぎ替え・音量は状態を変えず、そのことを 1 度だけ警告します。
