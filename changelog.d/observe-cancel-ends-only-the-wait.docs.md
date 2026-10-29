<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

MCP の `observe` の説明に、取り消しは待ちだけを切ると書き足した。続けて撮る観測 (`count`・`every`) を取り消しても、スケッチは撮り終えるまで撮り続け (最長で約 4 分)、次の呼び出しはその後ろで待つ。振る舞いは変えず、ADR-0018 の決定 3 に決まりとして書いた。
