<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run` の窓 (実時間の時計) で流している動画が、ループの継ぎ目と `jump()` で描画を止めなくなった。先の数コマを本体の外で復号して待たせておき、フレームではその中から位置のコマを選ぶだけにした (これまでは継ぎ目と飛びのたびに読み手を作り直す間、4K で 41〜154 ms 止まっていた)。飛んだ先のコマが届くまでの数フレームは、前のコマが映ったまま `isNewFrame` が `false` になる。書き出し (`mokume render`)・`clock: .frames` の窓・時刻を指定した観測では、これまでどおり位置のコマがすぐ出る。4K の動画を流すと、先読みのぶん記憶が最大で約 95 MiB 増える ([#2523](https://github.com/mokume-metal/mokume/issues/2523))。
