<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描けなかったフレームで頼んだ `save()` が、**次に描けたフレームの絵で書かれたことを、利用者に知らせていなかった**のを直した。いまは書いたときに、`save("f3.png") was asked for in frame 3, but that frame's picture never reached the outlet (…), so the picture of frame 4, the next one that did, was written instead` と、行き先と頼んだフレーム・書いたフレームの番号を名指しして警告する (行き先ごとに 1 度)。描画が転んだ場合も GPU が仕事を打ち切った場合も、窓の有無も問わず言う。あわせて、`noLoop()` で止めたスケッチで描画が転んだとき、**転ぶ前の絵がそのフレームの番号で書かれていた**のを直した (閉じるときも同じ)。次に描けたフレームの絵で書く。
