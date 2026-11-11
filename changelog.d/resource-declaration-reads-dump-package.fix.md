<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run`・`watch`・`render`・`bundle` が走らせる前に行う資材の宣言の検査が、SwiftPM が受け付ける `resources: [.copy("./assets")]` を「宣言が無い」として断っていたのを直しました。検査は `Package.swift` の文字列を照らしていたため、`./assets` や `assets/` の綴りを読めず、逆に別の target やコメントに `resources: [.copy("assets")]` があるだけで通していました。いまは SwiftPM が解いた宣言 (`swift package dump-package`) を読み、`Sources/<名前>/assets` を持つ target 自身がその置き場を資材として挙げているかを見ます。宣言の読みは同じ実行の後の段と分け持つので、`dump-package` は 1 回のままです。SwiftPM が読めない `Package.swift` では、この検査は止めず、SwiftPM の理由を添えて止まる後の段に任せます。
