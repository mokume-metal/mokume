// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

// アンブレラだけを import する。個別モジュールを import しないことで、
// 「1 つの import で届く」(ADR-0016 決定 2) が実際に成立しているかの検査になる。
import mokume

@Suite("パッケージの骨格")
struct PackageStructureTests {
    @Test("アンブレラ 1 つで描画コアの API に届く")
    func umbrellaReExportsCore() {
        // 層をまたいだ依存はビルドが担保するので (ADR-0016 影響)、ここで見るのは
        // 「利用者の入口が 1 つで済んでいるか」だけ。
        let color = LinearRGBA.opaque(red: 1, green: 0, blue: 0)
        #expect(color.alpha == 1)
    }
}
