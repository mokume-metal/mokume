<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

[README](https://github.com/mokume-metal/mokume#readme) を、はじめて触る人がそれだけを見て最初の 1 本を動かせるように書き直した。冒頭で「保存すると走っている絵が差し替わる」様子を動きで見せ、作例の絵と動きを並べた。始める前にそろえるもの (Apple Silicon と macOS の確かめ方・Xcode・Homebrew) に加え、**Xcode 26 では Metal Toolchain を別に入れないと最初のビルドが `unable to spawn process 'metal'` で止まる**ことと、その入れ方を書いた。最初の 1 本は、作る → 走らせる → 止める → コードを読む → 書き換えて差し替わるのを見る、までを順に辿れる。
