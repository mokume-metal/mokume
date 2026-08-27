// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

@Suite("作業空間の色")
struct LinearRGBATests {
    @Test("乗算していない成分は、境界でアルファを乗算される")
    func straightIsPremultipliedAtTheBoundary() {
        let color = LinearRGBA(straightRed: 1, green: 0.5, blue: 0, alpha: 0.5)
        #expect(color.red == 0.5)
        #expect(color.green == 0.25)
        #expect(color.blue == 0)
        #expect(color.alpha == 0.5)
    }

    @Test("不透明なら乗算しても値は変わらない")
    func opaqueIsUnchanged() {
        let straight = LinearRGBA(straightRed: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        #expect(straight == LinearRGBA.opaque(red: 0.25, green: 0.5, blue: 0.75))
    }

    @Test("表示できる範囲の外側を切り捨てない")
    func keepsValuesOutsideTheDisplayableRange() {
        // 1.0 を超える明るさと負値は、出力段まで持ち越す値として保持する
        // (ADR-0011 決定 1)。ここで丸めると、後段のトーンマップが効かなくなる。
        let bright = LinearRGBA.opaque(red: 4, green: 0, blue: -0.25)
        #expect(bright.red == 4)
        #expect(bright.blue == -0.25)
    }

    @Test("完全に透明な色は成分もすべて 0")
    func transparentHasZeroComponents() {
        #expect(LinearRGBA.transparent == LinearRGBA(straightRed: 1, green: 1, blue: 1, alpha: 0))
    }
}
