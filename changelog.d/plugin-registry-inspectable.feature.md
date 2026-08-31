<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

外のパッケージが、束 (`Plugin`) の登録を単体で検査できるようになりました。`PluginRegistry()` を自分で 1 つ作って `register(into:)` に渡し、`outlets` / `inlets` を読めば「この束が出口と入り口をそれぞれ 1 つずつ登録する」ことがその場で確かめられます。**GPU も窓も要りません** — これまでは走らせて目で見るか、スケッチごと組み立てて GPU を要求する道しか無く、束の形を見るだけの検査が GPU の無い環境で丸ごと飛んでいました ([#605](https://github.com/mokume-metal/mokume/issues/605))。

足すのはこれまでどおり `add(outlet:)` / `add(inlet:)` からだけで、並びは足した順です。
