// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import MokumeCore
@testable import mokume

/// 窓のつまみから値への書き戻し (``KnobBinding``) が、型ごとに正しい値を書くこと。
///
/// 窓を通した往復の検査 (`ParameterRoundTripTests`) が通すのは実数と候補の 2 つだけで、
/// 真偽・組の 1 成分・色・整数の丸めは**どの検査も通っていなかった**
/// ([#1386](https://github.com/mokume-metal/mokume/issues/1386))。書き戻しを取り違えても
/// 例外にはならず、つまみを動かすと違う値が入るだけになる。
///
/// **窓が値を書く口をそのまま通す。** ``DeclaredParam/write(_:)`` を直に呼ぶと窓を
/// 通したことにならない (``KnobBinding`` の説明)。窓を立てずに済むのは、口が
/// SwiftUI の `Binding` という値だからである。
@Suite("つまみから値への書き戻し")
@MainActor
struct KnobWritebackTests {
    final class Knobbed: Sketch {
        @Param var visible: Bool = false
        @Param(0...10) var count: Int = 3
        @Param(-1...1) var pair: SIMD2<Float> = SIMD2(0.25, -0.5)
        @Param(-1...1) var triple: SIMD3<Float> = SIMD3(0.125, 0.25, 0.375)
        @Param var tint: LinearRGBA = .linear(red: 0, green: 0, blue: 0)
    }

    private func knob(_ sketch: Knobbed, _ name: String) throws -> any DeclaredParam {
        try #require(ParamCatalog.indexed(from: sketch).first { $0.name == name }).box
    }

    // MARK: - 真偽

    @Test("トグルを入れれば真が、切れば偽が入る")
    func theToggleWritesTheFlag() throws {
        let sketch = Knobbed()
        let flag = KnobBinding.flag(try knob(sketch, "visible"))

        flag.wrappedValue = true
        #expect(sketch.visible == true)
        #expect(flag.wrappedValue == true)

        flag.wrappedValue = false
        #expect(sketch.visible == false)
        #expect(flag.wrappedValue == false)
    }

    // MARK: - 整数

    /// 整数のつまみは刻みつきのスライダーだが (`KnobKind.steppedSlider`)、スライダーが
    /// 返すのは実数である。**書き戻すのは最も近い整数**で、切り捨てると右へ引いた手が
    /// 1 つ手前の値に落ちる。実数のまま書き戻せば型が合わずに値が入らない (面の拒否と
    /// 同じ理由) ので、それもここで赤くなる。
    @Test("整数の宣言には、最も近い整数として書き戻す", arguments: [
        (6.7, 7), (6.3, 6), (0.4, 0), (9.6, 10),
    ])
    func integersAreRoundedToTheNearest(slid: Double, expected: Int) throws {
        let sketch = Knobbed()
        let box = try knob(sketch, "count")
        KnobBinding.number(box, box.declaration.value).wrappedValue = slid

        #expect(sketch.count == expected)
    }

    // MARK: - 組の 1 成分

    @Test("組の 1 成分を動かすと、その成分だけが変わる")
    func aComponentMovesOnlyItself() throws {
        let sketch = Knobbed()
        KnobBinding.component(try knob(sketch, "pair"), at: 0).wrappedValue = 0.75
        #expect(sketch.pair == SIMD2(0.75, -0.5))

        KnobBinding.component(try knob(sketch, "triple"), at: 2).wrappedValue = -0.625
        #expect(sketch.triple == SIMD3(0.125, 0.25, -0.625))
    }

    /// **窓が組を丸ごと持つと、外から 1 成分だけ書き換えられたときに古い成分で上書き
    /// してしまう** (``KnobBinding/component(_:at:)`` の説明)。掴んだ後に別の成分が外から
    /// 動いても、掴んだ口は読み直した値の上に書く。
    @Test("掴んだ後に外で動いた成分も、書き戻しで古い値に戻らない")
    func otherComponentsAreReadAfresh() throws {
        let sketch = Knobbed()
        let middle = KnobBinding.component(try knob(sketch, "triple"), at: 1)

        // 掴んでから、コードが別の成分を書き換える
        sketch.triple.x = -0.75
        middle.wrappedValue = 0.5

        #expect(sketch.triple == SIMD3(-0.75, 0.5, 0.375))
        #expect(middle.wrappedValue == 0.5)
    }

    // MARK: - 色

    /// 選ぶ欄の色は Display P3 のエンコード値で、作業空間は同じ原色の線形の値である
    /// ([ADR-0011] 決定 1・3)。**期待値は CoreGraphics に変換させて導く** — 実装の転送関数で
    /// 期待値を作ると、関数を通し忘れても通し方を誤っても一致してしまう。
    ///
    /// 作業空間の成分はアルファを乗算済みなので (同 決定 4)、半透明の色は乗算した値で
    /// 入る。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    @Test("選んだ色が、作業空間の線形の値として入る", arguments: [1.0, 0.5])
    func thePickedColorArrivesInWorkingSpace(opacity: Double) throws {
        let sketch = Knobbed()
        let (red, green, blue) = (1.0, 0.5, 0.25)
        KnobBinding.color(try knob(sketch, "tint")).wrappedValue = Color(
            .displayP3, red: red, green: green, blue: blue, opacity: opacity)

        let linear = Self.linearDisplayP3(red: red, green: green, blue: blue)
        let alpha = Float(opacity)
        let expected = LinearRGBA(
            straightRed: linear.red, green: linear.green, blue: linear.blue, alpha: alpha)
        let tint = sketch.tint
        #expect(abs(tint.red - expected.red) < 2e-3, "\(tint)")
        #expect(abs(tint.green - expected.green) < 2e-3, "\(tint)")
        #expect(abs(tint.blue - expected.blue) < 2e-3, "\(tint)")
        #expect(abs(tint.alpha - expected.alpha) < 2e-3, "\(tint)")
    }

    /// Display P3 のエンコード値を、同じ原色の線形の値へ移す。**CoreGraphics に変換させる。**
    private static func linearDisplayP3(red: Double, green: Double, blue: Double)
        -> (red: Float, green: Float, blue: Float)
    {
        let source = CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
            components: [red, green, blue, 1])!
        let moved = source.converted(
            to: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
            intent: .relativeColorimetric, options: nil)!
            .components!
        return (Float(moved[0]), Float(moved[1]), Float(moved[2]))
    }
}
