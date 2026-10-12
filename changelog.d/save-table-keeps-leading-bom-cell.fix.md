<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`saveTable` で書いた CSV を `loadTable` で読み直すと、最初のセル (見出しがあれば 1 列目の見出し、無ければ 1 行目の 1 列目) の頭にある U+FEFF が消え、そのセルが U+FEFF だけの 1 列の表では行ごと消えていたのを直しました ([#2340](https://github.com/mokume-metal/mokume/issues/2340))。`loadTable` はファイルの先頭の BOM を読み飛ばすので、`saveTable` は頭が U+FEFF のセルを `"…"` で囲んで書くようになりました。書いたファイルを同じ `header` で読み直すと、同じ表に戻ります。ほかのセルの書き方は変わりません。
