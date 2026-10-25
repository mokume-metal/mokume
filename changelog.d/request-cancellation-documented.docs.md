<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

待つ読み込みの口 (`requestImage`・`requestModel`・`requestShape`・`requestStrings`・`requestTable`・`requestJSONObject`・`requestJSONArray`・`requestXML`) の説明に、呼んだ `Task` を取り消したときの今の振る舞いを書いた。ファイルは取消を見ないので読み終えて値か失敗を返し、URL は受け取りをやめて `DataFailure.unreachable` (理由は `cancelled`) を投げる。スケッチが終わった後に届いても落ちない。`requestImage` の説明には、別の絵を要求し直すとき、取り消した前の絵が遅れて届いても番号の照合で採らない書き方の例を足した。口の振る舞いは変えていない。取消の扱いは約束ではなく、[#2760](https://github.com/mokume-metal/mokume/issues/2760) と合わせて決める。
