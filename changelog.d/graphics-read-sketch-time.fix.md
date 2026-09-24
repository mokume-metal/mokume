<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createGraphics()` で作った描き場所でも、時刻と刻みが画面と同じになった。これまでは描き場所の上だけ時刻が 0 のまま止まり、描き場所で塗った断片や掛けた効果の `in.time` が進まなかった (画面では脈打つ断片が、描き場所では最初の色で止まる)。描き場所で `particles()` した粒も、`frameRate` によらず 1/60 秒ずつ進んでいたので、`frameRate: 30` のスケッチでは画面の半分の速さで動き、寿命も倍に延びていた。いまはどちらも画面と同じ `time` と `deltaTime` を読み、描き場所から作った描き場所も同じである。描き場所で時刻を読まないスケッチの絵は変わらない。
