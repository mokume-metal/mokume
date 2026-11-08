// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import SwiftUI
import Testing

/// 埋め込むファイル (`EmbeddingApp.swift`) が `import SwiftUI` と `import MokumeUI` だけで組める (#3872)。
///
/// **確かめの本体は、`EmbeddingApp.swift` が組めること**である。ここは組めた結果、型を書く位置の `Image` が
/// SwiftUI の型に決まったことを読む。
@Suite("MokumeUI で埋め込むファイル")
nonisolated struct EmbeddingAppTests {
    @Test("import SwiftUI と import MokumeUI を並べたファイルで、Image は SwiftUI の型に決まる")
    @MainActor
    func imageResolvesToSwiftUI() {
        #expect(type(of: EmbeddingApp.logo) == SwiftUI.Image.self)
    }
}
