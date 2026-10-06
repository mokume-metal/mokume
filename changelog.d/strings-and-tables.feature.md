<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**文字のファイルと CSV を読み書きできるようになった** (`loadStrings` / `loadTable` / `saveTable`。待たない口 `requestStrings` / `requestTable` もある)。`loadStrings` は 1 行ずつの文字列を、`loadTable` は表 (`Table`) を返す。`header: true` なら最初の行を見出しとして読み、`row.getFloat("high")` のように列の名前で値を引ける。表に列を足して (`addColumn`)、値を書き (`setFloat` / `setString`)、`saveTable` で CSV に書き出せる。探す場所は `loadImage` と同じ。

CSV は引用符で囲んだセルの中のカンマと改行、`""` の引用符、CRLF、先頭の BOM を読む。**閉じない引用符や、列の数が見出しと合わない行は、壊れていた行を添えて投げる** (`DataFailure`) — 詰めたり捨てたりして読み進めると、値が 1 列ずつずれた表が黙って返るためである。数として読めないセル (空・`N/A` など) と無い列の名前は、`getFloat` が NaN を返し、初回だけ理由を知らせる。

表は値の型で、代入すると写しになる。行 (`table.rows`) は読むための写しなので、書き換えは `table.setFloat(i, "mean", v)` のように表に対して行う。
