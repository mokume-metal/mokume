<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

JSON の配列を空から作って値を足し・書き換え・除き、`saveJSONArray(_:_:)` でファイルに書き出せるようになった。`JSONArray()` で作り、`append` で `Int`・`Float`・`String`・`Bool`・`JSONObject`・`JSONArray` を足す。番号の値は `setFloat` ほかで置き換え、`remove` で除く。配列の配列 (GeoJSON の `coordinates`) も組める。範囲の外の番号には書かず、1 度だけ知らせる (Processing は `null` で埋めて伸ばす)。NaN と無限は書かずに知らせる。書き方と書けない置き場の扱いは `saveJSONObject` と同じ ([#3644](https://github.com/mokume-metal/mokume/issues/3644))。
