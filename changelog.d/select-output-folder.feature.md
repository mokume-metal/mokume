<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

保存先を選ばせる `selectOutput(_:)` と、フォルダを選ばせる `selectFolder(_:)` が入りました。`selectInput(_:)` と同じく `Task` の中で `if let path = await selectOutput("保存先を選ぶ") { try? saveStrings(lines, path) }` と書き、選べば絶対パス、取り消せば `nil` が返ります。ダイアログは直に走らせたウィンドウ・`mokume watch` の作品のウィンドウ・`SketchView` のホストのウィンドウのシートで出ます。待てるダイアログは 3 つの API で 1 つで、待っている間にどれかを呼ぶと前の待ちは `nil` で終わります。`mokume render` の下では、`.mokume/input` や MCP の `input` で `fileSelected` を送ると待ちが終わります。
