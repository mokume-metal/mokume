<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

表から行の番号と列で 1 つのセルを読む `Table.getString(_:_:)`・`getFloat(_:_:)`・`getInt(_:_:)` と、行から整数を読む `TableRow.getInt(_:)` を追加した。番号で回すループで `table.rows[i]` と引くと呼ぶたびに全行を写していたが、`table.getFloat(i, "high")` は行を写さずにセルを読む。列は名前と番号のどちらでも渡せる。`getInt` は丸めず、`"2"`・`"2.0"`・`"1e3"` は整数として読み、`"2.5"`・`"N/A"`・`Int` に収まらない値は 0 を返して列ごとに 1 度知らせる。無い列・表の外の行は、行の口と同じ空の値 (空の文字・NaN・0) を返して 1 度だけ知らせる ([#3641](https://github.com/mokume-metal/mokume/issues/3641))。
