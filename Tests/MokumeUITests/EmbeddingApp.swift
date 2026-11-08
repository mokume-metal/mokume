// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 埋め込む人が書くファイルそのもの (#3872)。**import は SwiftUI と MokumeUI の 2 つだけにする** —
// ここに `import mokume` や `import MokumeCore` を足すと、確かめたいこと (MokumeUI が SwiftUI と同じ名前の
// 型を持ち込まない) が確かめられなくなる。
//
// `MokumeUI` が MokumeCore (や MokumeGame) を丸ごと再エクスポートすると、`Image` と `Scene` が型を書く位置で
// 曖昧になり、このファイルは組めなくなる (`'Image' is ambiguous for type lookup in this context`)。
// スケッチ (`EmbeddedGame`) は別のファイルで `import mokume` して書いてある。

import MokumeUI
import SwiftUI

struct EmbeddingApp: App {
    /// 型を書く位置の `Image`。SwiftUI の `Image` に決まる。
    static let logo: Image = Image("logo")

    var body: some Scene {
        WindowGroup {
            SketchView(EmbeddedGame())
            Image("logo")
        }
    }
}
