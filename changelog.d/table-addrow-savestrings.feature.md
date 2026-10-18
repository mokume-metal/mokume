<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

表を自分で作って書き出せるようになった。`Table(columns: ["frame", "x", "y"])` で見出しだけの表を作り、`addRow([Float(frameCount), mouseX, mouseY])` で数の行を足して、`saveTable` で CSV に書く (見出しありで `loadTable` すると同じ表に戻る)。列の数と合わない `addRow` は行を足さずに 1 度だけ知らせる。文字のセルは足した行へ `setString` で書く。

文字列を 1 行ずつ書く `saveStrings(lines, "out/notes.txt")` も足した。UTF-8 (BOM なし)・LF で書き、`loadStrings` で読み直すと同じ並びに戻る。引数は `saveTable` と同じく書く値が先・置き場が後で、Processing の `saveStrings(filename, data)` とは逆 (p5.js と同じ)。改行を含む要素は読み直すと行が分かれ、最初の要素の頭の U+FEFF は BOM として落ちるので、そのときは中身を変えずに書いて 1 度だけ知らせる。
