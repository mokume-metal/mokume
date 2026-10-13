// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore
@testable import mokume

/// 範囲つきの整数の `@Param` へ、`Int` の端の値が書かれても落ちないこと
/// ([#2478](https://github.com/mokume-metal/mokume/issues/2478))。
///
/// 範囲は `Double` で持つので、収めるときに整数は `Double` を通る。`Double(Int.max)` は
/// `Int` に収まらない 2^63 へ丸まるので、上端が `Int.max` の宣言では収めた後の `Double` を
/// `Int` へ戻す変換が**プロセスごと落ちていた**。非有限の数 (``ParameterNonFiniteTests``) と
/// 違い、値はどれも有限で、根は「収めた後の `Int` への戻し方」である。
///
/// 2^53 を超える整数が `Double` を通って丸まるのは今までどおり (直す対象ではない)。ここが
/// 固定するのは、落ちないことと、端の値が端として入ることだけである。
@Suite("範囲つきの整数は Int の端でも落ちない")
@MainActor
struct ParameterIntRangeTests {
    final class Wide: Sketch {
        @Param(0...Int.max) var upper: Int = 1
        @Param(Int.min...0) var lower: Int = -1
    }

    final class Narrow: Sketch {
        @Param(1...8) var count: Int = 3
        @Param var free: Int = 7
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-intrange-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 要求を置いて、応えを取る。
    private func answer(_ request: String, from surface: ParamSurface, in facet: URL) throws
        -> ParamReport
    {
        try request.write(
            to: facet.appendingPathComponent("request.json"), atomically: true, encoding: .utf8)
        return try #require(surface.drain(), "要求が無言で捨てられた: \(request)")
    }

    private func knob(_ sketch: some Sketch, _ name: String) throws -> any DeclaredParam {
        try #require(ParamCatalog.indexed(from: sketch).first { $0.name == name }).box
    }

    // MARK: - 面から (完了条件 1・2・5)

    @Test("上端が Int.max の範囲へ Int.max を書いても落ちず、範囲の中の値として入る")
    func theUpperEndIsAccepted() throws {
        let facet = try makeDirectory()
        let sketch = Wide()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        let report = try answer(
            #"{"id":"i1","values":[{"name":"upper","type":"int","value":9223372036854775807}]}"#,
            from: surface, in: facet)

        #expect(sketch.upper == Int.max)
        #expect(report.rejected.isEmpty)
        #expect(report.clamped.isEmpty, "範囲の中の値なので、収めたことにはならない")
    }

    @Test("Double では 2^63 に丸まる Int.max - 1 も、落ちずに端として入る")
    func justBelowTheUpperEndDoesNotCrash() throws {
        let facet = try makeDirectory()
        let sketch = Wide()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        let report = try answer(
            #"{"id":"i2","values":[{"name":"upper","type":"int","value":9223372036854775806}]}"#,
            from: surface, in: facet)

        #expect(sketch.upper == Int.max)
        #expect(report.rejected.isEmpty)
        // 丸まって別の整数になったので、書いた値と入った値が違うことは応答に載る
        #expect(report.clamped.count == 1)
    }

    @Test("下端が Int.min の範囲へ Int.min を書いても落ちない")
    func theLowerEndIsAccepted() throws {
        let facet = try makeDirectory()
        let sketch = Wide()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        let report = try answer(
            #"{"id":"i3","values":[{"name":"lower","type":"int","value":-9223372036854775808}]}"#,
            from: surface, in: facet)

        #expect(sketch.lower == Int.min)
        #expect(report.rejected.isEmpty)
        #expect(report.clamped.isEmpty)
    }

    @Test("同じ要求の他の値も入る")
    func theOtherValuesStillGoIn() throws {
        let facet = try makeDirectory()
        let sketch = Wide()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        _ = try answer(
            #"{"id":"i4","values":[{"name":"upper","type":"int","value":9223372036854775807},{"name":"lower","type":"int","value":-5}]}"#,
            from: surface, in: facet)

        #expect(sketch.upper == Int.max)
        #expect(sketch.lower == -5)
    }

    // MARK: - 窓から (完了条件 3)

    @Test("窓の段付きスライダーを右端 (2^63) へ寄せても落ちず、Int.max になる")
    func theSliderAtTheRightEndDoesNotCrash() throws {
        let sketch = Wide()
        let box = try knob(sketch, "upper")

        KnobBinding.number(box, box.declaration.value).wrappedValue = 9_223_372_036_854_775_808.0

        #expect(sketch.upper == Int.max)
    }

    @Test("窓のスライダーを左端 (-2^63) へ寄せても落ちず、Int.min になる")
    func theSliderAtTheLeftEndDoesNotCrash() throws {
        let sketch = Wide()
        let box = try knob(sketch, "lower")

        KnobBinding.number(box, box.declaration.value).wrappedValue = -9_223_372_036_854_775_808.0

        #expect(sketch.lower == Int.min)
    }

    // MARK: - 変換そのもの

    @Test("最も近い整数へ丸め、Int に収まらなければ近いほうの端へ収める", arguments: [
        (6.7, 7), (6.5, 7), (-6.5, -7), (0.4, 0),
        (9_223_372_036_854_775_808.0, Int.max), (1e300, Int.max), (Double.infinity, Int.max),
        (-9_223_372_036_854_775_808.0, Int.min), (-1e300, Int.min), (-Double.infinity, Int.min),
        (Double.nan, 0),
    ])
    func theConversionSaturates(value: Double, expected: Int) {
        #expect(Int(roundingAndSaturating: value) == expected)
    }

    // MARK: - 陰性対照 (完了条件 4)

    @Test("小さな範囲は今までどおり: 外は端へ収めて clamped に載り、中は applied")
    func smallRangesBehaveAsBefore() throws {
        let facet = try makeDirectory()
        let sketch = Narrow()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        let outside = try answer(
            #"{"id":"n1","values":[{"name":"count","type":"int","value":99}]}"#,
            from: surface, in: facet)
        #expect(sketch.count == 8)
        #expect(outside.clamped == [.init(name: "count", requested: .int(99), value: .int(8))])
        #expect(outside.rejected.isEmpty)

        let inside = try answer(
            #"{"id":"n2","values":[{"name":"count","type":"int","value":5}]}"#,
            from: surface, in: facet)
        #expect(sketch.count == 5)
        #expect(inside.clamped.isEmpty)
        #expect(inside.rejected.isEmpty)
    }

    @Test("範囲を書かない Int は、収めずにそのまま入る")
    func anUnrangedIntIsUntouched() throws {
        let facet = try makeDirectory()
        let sketch = Narrow()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        let report = try answer(
            #"{"id":"u1","values":[{"name":"free","type":"int","value":9223372036854775807}]}"#,
            from: surface, in: facet)

        #expect(sketch.free == Int.max)
        #expect(report.clamped.isEmpty)
        #expect(report.rejected.isEmpty)
    }
}
