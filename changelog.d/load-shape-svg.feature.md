<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**SVG のファイルを、画素ではなく形として読めるようになった** (`loadShape`。待たない口 `requestShape` もある)。Illustrator や Figma で描いたロゴを `logo = try loadShape("assets/logo.svg")` で読み、`shape(logo, x, y)` で置く。読んだ形は `createShape` で組み立てた形と同じもので、`scale()` で拡大しても縁は滑らかに出る。色は SVG に書いたものが焼き付き、置き場所ごとに `Placement(fill:)` で色を掛けられる (白で描いた SVG なら、掛けた色がそのまま出る)。

読むのはパス (`d` の命令すべて)・矩形 (角丸を含む)・円・楕円・線・折れ線・多角形、群と `transform`・`viewBox`、塗りと線の色と不透明度・線の太さ・端と角の形・`fill-rule`、それに属性・`style` 属性・`<style>` のクラスの規則 (Illustrator の書き出しの既定の形)。字・画像・`use`・グラデーションの塗り・切り抜き・マスク・フィルタ・破線などは描かず、**何を何回・最初にどの行で捨てたかを、そのファイルにつき 1 度知らせる**。描ける部分は描く。

ファイルが見つからない・UTF-8 でない・XML として壊れている・根が `<svg>` でないときは、理由を添えて投げる (`DataFailure`)。

`swift run reference-sketches shapes-from-svg` で、読んだロゴを等倍と 4 倍で置き、白い印に色を掛けて回す作例が見られる。
