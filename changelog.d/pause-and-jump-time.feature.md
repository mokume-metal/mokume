<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描画を止めずに時刻だけを止める・再開する・飛ぶ `pauseTime()` / `playTime()` / `jumpTime(_:)` を追加した。絵を `time` の関数として書いておけば、再生位置を自分の変数で持たずに、キーで止めたりドラッグで擦ったりできる。止めている間と飛んだ枚の `deltaTime` は 0 で、再開すると止めた秒から続く。`mokume render` で書き出している最中も効き、書き出す枚数と動画の時刻の並びは変わらない。
