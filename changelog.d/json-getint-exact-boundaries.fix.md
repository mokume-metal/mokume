<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`JSONObject.getInt(_:)`・`JSONArray.getInt(_:)` が、`Int.min` より小さい整数 (`-9223372036854775809`) を `Int.min` として、端数のある数の文字 (`"1.0000000000000001"`) を整数として返していたのを直した。どちらも 0 を返して知らせる。2⁵³ を越える整数の文字 (`"9007199254740993.0"`) は桁を落とさずに返す。整数かどうかを、`Double` に丸めた後ではなく書かれた桁から決めるようにした ([#3950](https://github.com/mokume-metal/mokume/issues/3950))。
