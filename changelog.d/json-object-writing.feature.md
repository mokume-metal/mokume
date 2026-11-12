<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

JSON のオブジェクトを空から作ってキーに値を書き、`saveJSONObject(_:_:)` でファイルに書き出せるようになった。`JSONObject()` で作り、`setBoolean`・`setFloat`・`setInt`・`setString`・`setJSONObject`・`setJSONArray` で書く。計測の結果や設定を、Foundation に降りずに JSON で残せる。書き出しはキーを文字の順に並べ (同じ値からは同じファイルになる)、UTF-8・LF・字下げ 2 で書く。`loadJSONObject` で読み直すと同じオブジェクトに戻る。入れ子は、取り出した写しを書き換えて `setJSONObject` で戻す。`setFloat` は NaN と無限を書かず、キーごとに 1 度知らせる。書けない置き場では `DataFailure.unwritable` を投げ、書きかけを残さない ([#3643](https://github.com/mokume-metal/mokume/issues/3643))。
