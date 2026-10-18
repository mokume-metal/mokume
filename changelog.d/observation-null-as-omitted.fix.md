<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

観測の要求の `time: null` を、`time` を書かなかったのと同じ「時刻なし」として受けるようになった。これまでは `scale`・`count`・`every` の `null` は省略と読まれるのに、`time: null` だけが断られていた。

要求の形 (`Schemas/observe-request.schema.json`・`input-request.schema.json`) も、省略できる欄が `null` を受けると書いた。観測の `scale`・`count`・`every`・`time` と、入力の出来事の `button`・`dx`・`dy`・`characters`・`isRepeat` が対象で、`null` は欄を書かなかったのと同じに読む。`time: "5"` のような型の違う値は、これまでどおり断る。
