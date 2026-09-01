<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run` と `mokume watch` が、走らせる構成を選べるようになった (`-c release` / `--configuration release`)。これまでは選ぶ口が無く、名乗りはいつも `debug` のままだった — 速さは構成で数倍変わるので、名乗りを読んだ人がそれを動かせる必要がある。選ばなければ道具立ての既定に任せる。名乗る構成と、実際に組んで走らせる構成は同じ値から出る。
