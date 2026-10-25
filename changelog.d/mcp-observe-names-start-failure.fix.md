<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` が起こしたスケッチが、組み立ての失敗や `setup()` が投げた失敗で最初のフレームの前に終わったとき、MCP の `observe` が「応えない」の案内ではなく、起動できなかったことと理由の最初の行を返すようにした。理由の全文は `build_status` の `output` (`.mokume/build/status.json`) で読める。次の作り直しで起動できれば、この答えは出なくなる。
