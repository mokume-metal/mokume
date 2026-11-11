<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run`・`watch`・`render`・`bundle` が走らせる前に行う資材の宣言の検査が、SwiftPM が受け付ける `resources: [.copy("./assets")]` を「宣言が無い」として断っていたのを直しました。検査は `Package.swift` の文字列を照らしていたため、`./assets` や `assets/` の綴りを読めず、逆に別の target やコメントに `resources: [.copy("assets")]` があるだけで通していました。いまは各コマンドが読んだ SwiftPM の宣言 (`swift package dump-package`) で、`Sources/<名前>/assets` を含む target 自身がその置き場そのものを資材として挙げているかを見ます (`dump-package` を起こす回数は変わりません)。親のディレクトリ (`.copy("demo")`・`.copy(".")`) や置き場の中の 1 ファイルだけを挙げた宣言、`exclude:` で外した置き場は、束の直下に `assets` が入らないので止まるようになります。`watch` が子へ置き場の元を渡すかも、同じ読み方で決めます。SwiftPM が読めない `Package.swift` では、この検査は止めず、SwiftPM の理由を添えて止まる後の段に任せます。`watch` を読めない宣言で始めたときは、宣言が初めて読めた作り直しで見ます。
