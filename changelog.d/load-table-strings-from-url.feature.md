<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadTable()`・`requestTable()`・`loadStrings()`・`requestStrings()` が、名前が `http://` か `https://` で始まれば URL から読むようになりました ([#2470](https://github.com/mokume-metal/mokume/issues/2470))。「ウェブに公開」したスプレッドシートの CSV の URL をそのまま渡せば、値を書き換えるだけで作品が変わります。JSON と XML の口と同じ決まりで、URL でなければこれまでどおりファイルとして探します。

URL の本文も、ファイルと同じ決まり (UTF-8・先頭の BOM を読み飛ばす・CSV の引用符と改行) で読みます。2xx 以外の状態や繋がらないときは `DataFailure.unreachable` を投げます。同期版は、届くまで返らず、待つのは呼んでから最長 60 秒です。`setup()` の中で 1 度読むためのもので、フレームを止めずに読むのは `requestTable()` / `requestStrings()` です。
