<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

表 (`Table`)・JSON (`JSONObject`・`JSONArray`)・XML の読み出し (`getFloat` や `getString` ほか) は、**main actor の上に残る**ことを説明に書きました。`DispatchQueue.concurrentPerform` などで分けた先の閉包からは呼べないので、並列に回すときは、分ける前に `let heights = table.rows.map { $0.getFloat("height") }` のように値 (`[Float]` など) へ写しておきます。`map` の並列の説明に例を足し、4 つの型の説明がそこを指します。挙動は変わりません。

数と色の関数 (`map`・`color` ほか) だけが並列から呼べる、という線引きと、文書の読み出しを `nonisolated` にしなかった理由は [ADR-0010](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md) 決定 1 にあります。並列から文書を読みたい作品が出たら、作例を添えて比べ直します。
