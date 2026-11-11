<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

表の行と列を書き換える `Table.clearRows()`・`removeRow(_:)`・`removeColumn(_:)`・`setInt(_:_:_:)`・`trim()`・`removeTokens(_:)` を追加した。`removeRow(0)` で古い行を捨てる記録や、`removeColumn("notes")` で要らない列を外した書き出しが、表の上で書ける。`setInt` は整数の綴り (`"3"`) で書き、`trim()` はセルの前後の空白 (タブ・改行を含む) を、`removeTokens(",$ ")` は名指した文字をセルから除く (`"$1,200"` は `"1200"`)。`trim` と `removeTokens` は列を名指して、その列だけを整えられる。無い列・表の外の行には何もせず、1 度だけ知らせる ([#3642](https://github.com/mokume-metal/mokume/issues/3642))。
