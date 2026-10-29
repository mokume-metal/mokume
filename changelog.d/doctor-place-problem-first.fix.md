<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume doctor` に、無い場所・ディレクトリでない場所・`Package.swift` の無いディレクトリを渡したとき、その一言 (`Place: … — nothing is there (check the path you gave)` など) を、環境の節の後ろの `What is here` に埋もれさせず、出力の先頭で言うようにしました。`What is here` の行と、ほかの出力・終了コード (いつも 0) は変わりません。スケッチの場所を診たときの出力もそのままです。
