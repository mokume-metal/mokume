<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**断片 (`makeShader`・`loadShader`・`makeEffect`・`loadEffect`・`makeComputation`・`loadComputation`) を組めなかったときの理由が、自分の書いた断片の行を指すようになりました。** これまでは本体が前に足す宣言のぶんだけずれた原文の行 (`program_source:1053:12` など) を名乗り、書いた断片のどこにも無い行を指していました。いまは文字列から作った断片なら `name:` の名前 (既定は `shader`・`effect`・`computation`)、ファイルから読んだ断片ならファイル名で、`shader:2:12: error: use of undeclared identifier 'foo'` のように出ます。保存して差し替えに失敗したときの理由も同じです。本体の前置きを指す知らせ (前置きの定義を断片で定義し直したときの「前の定義」など) は `mokume/Kinds.metal:29:15` のように本体の名前で出て、自分の断片と見分けられます。
