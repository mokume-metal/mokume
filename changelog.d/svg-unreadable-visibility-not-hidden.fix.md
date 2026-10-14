<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` と `requestShape(_:)` で、SVG の `visibility` に読めない値 (`abc`・空) を書いた要素が、黙って隠れていたのを直した。読めない値は書いていないものとして親の値を受け継いで描き、捨てたものとして知らせる (`visibility "abc"`)。`<rect visibility="abc"/>` はこれまで何も描かれなかったが、いまは描かれる。`visible`・`hidden`・`collapse` と CSS の `visibility` の宣言の扱いは変わらない。
