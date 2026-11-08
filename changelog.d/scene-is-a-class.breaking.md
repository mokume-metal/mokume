<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`MokumeGame` の `Scene` が struct から class (`final class`) になり、代入して渡した先が同じ場面を指すことを型で表すようになりました ([#3815](https://github.com/mokume-metal/mokume/issues/3815))。これまでも部品へ渡した `Scene` で切り替えると元の `Scene` も切り替わりましたが、struct なのに複製が独立しないので、「元の場面を取っておいて後で戻す」つもりの書き方で誤る余地がありました。切り替えが効くフレーム・`justEntered`・実行の外での読みは変わりません。

移行: 書き換えは要りません。`var scene = Scene(starting: Screen.title)`・`let`・部品へ渡す書き方・`Task.detached` の中で作る書き方は、そのまま組めます。`extension Scene` に `mutating` のメソッドを書いていたら `mutating` を外してください。同じ場面かどうかは `===` で問えます。
