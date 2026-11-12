<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

JSON の値が `null` かを知らせずに確かめる `isNull` と、XML の名前・すべての子・整数・要素の文字の数・属性の有無と一覧を読む API、届いた文字の XML を読む `parseXML(_:)` を足した。`JSONObject.isNull(_:)`・`JSONArray.isNull(_:)` は無いキー・範囲の外の番号にも `true` を返す (Processing と同じ。値が `null` なのかキーが無いのかは `hasKey(_:)` と組んで分ける)。`XML` には `getName()`・引数なしの `getChildren()` (書かれた順)・`getInt(_:)`・`getIntContent()`・`getFloatContent()`・`hasAttribute(_:)`・`listAttributes()` (文字の順) が加わった。整数は丸めず、`"4.5"` は 0 を返して 1 度知らせる。`parseXML(_:)` は `loadXML(_:)` と同じ読み方で、壊れた文字は `DataFailure.malformed` を壊れた行と一緒に投げる ([#3645](https://github.com/mokume-metal/mokume/issues/3645))。
