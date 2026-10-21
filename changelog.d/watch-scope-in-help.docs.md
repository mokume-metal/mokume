<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`mokume help` の `watch` の行と README・ドキュメントに、保存で作り直す範囲と、範囲の外を書きました。** 見張るのは `Package.swift`・`Sources/` の下の `.swift`・`Sources/<名前>/assets/` の下の普通のファイルです (隠しファイルとシンボリックリンクは数えず、`.metal` の断片は作り直さずに走らせたまま差し替わります)。`Package.swift` で `assets/` 以外に宣言した資材 (`.process("Resources")`・`.copy("data.json")`・`path:` を変えた target)・`Package.resolved`・パスで指した依存を変えても作り直さないので、そのときは `mokume watch` を起こし直してください。振る舞いは変えていません。
