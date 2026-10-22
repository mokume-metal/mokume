<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` が、CSS の全体キーワード (`initial`・`unset`・`revert`・`revert-layer`) を、`inherit` と同じく勝った宣言として読むようになった。

これまでは `fill: initial` のようなキーワードを読めない値として知らせて捨て、下に書いた値 (`fill="red"` など) で描いていた。いまは CSS のとおり、`initial` は性質の初めの値 (`fill` なら黒・`opacity` なら 1)、`unset` は受け継ぐ性質なら親の値・そうでなければ初めの値になり、`revert`・`revert-layer` は `unset` と同じに読む。`clip-path: initial` などの描けない効果は、効果なしとして知らせない。根の `<svg>` の `width: inherit` は `auto` と同じに読み、形の長さの属性 (`<rect x="unset">`) は知らせて描かないのをやめて 0 や `auto` と読む。
