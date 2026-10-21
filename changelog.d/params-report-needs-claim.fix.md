<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

つまみの目録 (`.mokume/params/report.json`) を、区画の権利を持つ実行だけが書くようになった ([#2227](https://github.com/mokume-metal/mokume/issues/2227))。これまでは `mokume watch` を回したまま同じ場所で `swift run` や `mokume run` を起こすと、後から起こした実行が起動しただけで目録を自分の宣言に書き換え、プレビューが並べるつまみと、動かした値が効く先 (見張りの子) が割れていた。保存で見張りの世代が入れ替わる間も、次の世代は前の世代が去って権利を取るまで目録を書かず、プレビューのつまみは前の世代の宣言のまま並ぶ。

権利を持つ実行が 1 本だけのときの振る舞いは変わらない。見張りの世代交代の瞬間に、別に走らせた実行が観測・入力・つまみの要求の相手になりうることは、約束の外として `StartupReads` の説明と ADR-0032 に書いた。
