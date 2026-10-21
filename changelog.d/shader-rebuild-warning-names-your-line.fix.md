<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**保存して断片 (`loadShader`・`loadEffect`・`loadComputation`) の差し替えに失敗したときの端末の警告に、直す行が載るようになりました。** これまでは `shader: could not rebuild the fragment: Cannot build the shader: waves` で止まり、行と桁は観測の `failure` を引かないと分かりませんでした。いまは同じ 1 行の後ろに ` — waves.metal:2:12: error: use of undeclared identifier 'foo'` のように、理由の中の最初の `error:` の行が続きます (前に本体の前置きの警告が並んでいても飛ばします。入口を書き違えた断片は、期待する入口の形を言う行が載ります)。警告は 1 行のままで、観測の `failure` と `makeShader` などが投げる理由は変わりません。組み立てでない失敗 (読めなかったなど) の警告も今までどおりです。
