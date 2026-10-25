<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` が起こしたスケッチが、組み立ての失敗や `setup()` が投げた失敗で最初のフレームの前に終わったとき、MCP の `observe` が「応えない」の案内ではなく、起動できなかったことと理由の最初の行を返すようにした。理由の全文は `build_status` の `output` (`.mokume/build/status.json`) で読める。答えるのは `mokume watch` が動いている間だけで (止めた後に残った記録では答えない)、次の作り直しで起動できれば出なくなる。子が理由を渡せなかった回 (落ちた・実行できない成果物) は、記録の理由だけを言う。
