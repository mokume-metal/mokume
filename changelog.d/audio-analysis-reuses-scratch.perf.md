<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

音の解析 (`level`・`spectrum` など、`SoundFile`・`AudioIn`・合成音の値を読むとき) が、変換の入出力の一時配列を作り直さず使い回すようになった。値は変わらない (ビット一致)。解析 1 回あたりの配列の割り当ては 6 回 (約 20 KB) から 2 回 (約 4 KB) に減り、音を 50 個鳴らして毎フレーム全部読む作品で、解析にかかる時間が 1〜2 割短くなった ([#3086](https://github.com/mokume-metal/mokume/issues/3086))。
