<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

道具 (`mokume watch` / `mokume run` の窓・観測・つまみ) の下で動くスケッチと、`draw()` の中で `loadImage` を呼ぶスケッチで、フレームごとの固定の費用が減りました。ファイルが書き換わったかを見るたびに、所有者名などを含むファイルの属性をまとめて読んでいたためです。1 回あたり約 28 µs が 1 µs 未満になります。書き換わりの見分け方は変わりません。
