// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

// アンブレラだけを import する。個別モジュールを import しないことで、
// 「1 つの import で届く」(ADR-0016 決定 2) が実際に成立しているかを検査になる。
import mokume

@Suite("パッケージの骨格")
struct PackageStructureTests {
    @Test("アンブレラ 1 つで描画コアの API に届く")
    func umbrellaReExportsCore() {
        #expect(Mokume.foundationLayerName == "foundation")
    }

    @Test("描画コアから基盤層への依存が成立している")
    func coreDependsOnFoundation() {
        // 値が基盤層から来ていることを確かめる。層をまたいだ参照が
        // ビルド時に解決されていなければ、そもそもここまで到達しない
        #expect(Mokume.foundationLayerName.isEmpty == false)
    }
}
