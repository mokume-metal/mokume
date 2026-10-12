<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

文字を数として取り出す口 (`JSONObject.getFloat` の文字の値・`XML.getFloat`・`TableRow.getFloat` の名前と番号) が数とする綴りを、**10 進の綴りだけ**にしました ([#2330](https://github.com/mokume-metal/mokume/issues/2330))。符号 (`+` / `-`) と数字・小数点 (`"18.5"`・`"-2"`・`"+5"`・`".5"`・`"5."`)、任意で指数 (`"1e3"`・`"1E-3"`) の形です。前後の空白は、**改行も含めて**落とすようになりました (`"3\n"`・`"\r\n3"` は 3。XML の `&#10;5` は 5)。

これまでは Swift の `Float(String)` が受ける綴りをそのまま通していたので、`"nan"` は知らせずに NaN、`"inf"`・`"Infinity"` は無限大、16 進の `"0x10"` は 16、`"0x1p3"` は 8 として読んでいました。これからは、どれも数でない文字として NaN を返し、初回だけ知らせます (`"N/A"` と同じ)。10 進だが `Float` に収まらない数 (`"1e39"`) は、これまでどおり無限大です。

`setFloat` で NaN や無限を書いたセルは `"nan"`・`"inf"` になるので、`getFloat` で読み直すと NaN と知らせになります (無限は値が変わります)。

移行: 16 進や `"inf"` の文字を数として読んでいた作品は、`getString` で文字を取り出し、自分で数にしてください (例: `Float(row.getString("level"))` は Swift の綴りをそのまま受けます。16 進だけなら `Int(text.dropFirst(2), radix: 16)`)。10 進の数だけを書いたファイルを読んでいる作品は、変更の必要がありません。
