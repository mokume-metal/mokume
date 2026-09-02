<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` が出す窓を触ると、走っているスケッチが反応するようになった。**作品の窓とプレビューのどちらでも効く** — どちらも送る前にキャンバスの座標へ写すので、窓の大きさの違いは届く前に吸収される ([ADR-0032](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md) 決定 4)。

経路は子の標準入力で、**`.mokume/input` の区画は 1 ビットも変わらない**。窓から入る出来事も面から入る出来事も、スケッチから見れば同じ受け皿に着く。
