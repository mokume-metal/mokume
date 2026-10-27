// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
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
/// **根は、整数を `Double` へ移して収めていたこと。** 端が 2^53 を超えると `Double` の端が丸まり、
/// 宣言した端の外の値が範囲の中として通り (`0...(Int.max - 1)` へ `Int.max`)、範囲の中の値が
/// 丸められる (`0...Int.max` へ 2^53 + 1)。整数の宣言は端を `Int` のまま持ち、整数の値は
/// `Int` のまま収める。ここが固定するのは、落ちないことと、宣言した端そのものが範囲の中として
/// 通り、端の外は端へ収まって応答に載ることである。
@Suite("範囲つきの整数は Int の端でも落ちない")
@MainActor
struct ParameterIntRangeTests {
    final class Wide: Sketch {
        @Param(0...Int.max) var upper: Int = 1
        @Param(Int.min...0) var lower: Int = -1
    }

    final class WideBoth: Sketch {
        @Param(Int.min...Int.max) var both: Int = 0
    }

    /// 端が 2^53 を超え、`Double` では宣言した端を持てない範囲。
    final class Huge: Sketch {
        @Param(0...(1 << 62 + 1)) var big: Int = 1
        @Param(0...(Int.max - 1)) var nearMax: Int = 1
        @Param((Int.min + 1)...0) var nearMin: Int = -1
    }

    final class Narrow: Sketch {
        @Param(1...8) var count: Int = 3
        @Param var free: Int = 7
    }

    private func makeDirectory() throws -> URL {
        let directory = try TestScratch.directory("mokume-intrange")
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

    @Test("Double では 2^63 に丸まる Int.max - 1 は、丸めず書いた値のまま入る")
    func justBelowTheUpperEndIsKeptAsWritten() throws {
        let facet = try makeDirectory()
        let sketch = Wide()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        let report = try answer(
            #"{"id":"i2","values":[{"name":"upper","type":"int","value":9223372036854775806}]}"#,
            from: surface, in: facet)

        #expect(sketch.upper == Int.max - 1)
        #expect(report.rejected.isEmpty)
        #expect(report.clamped.isEmpty, "範囲の中の値なので、別の値にも収めたことにもならない")
    }

    @Test("2^53 を超える整数が、範囲の中で丸まらない", arguments: [
        "9007199254740993", "9007199254740995", "4611686018427387905", "-9007199254740993",
    ])
    func largeIntegersAreNotRounded(written: String) throws {
        let facet = try makeDirectory()
        let sketch = WideBoth()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        let report = try answer(
            #"{"id":"l1","values":[{"name":"both","type":"int","value":\#(written)}]}"#,
            from: surface, in: facet)

        #expect(sketch.both == Int(written))
        #expect(report.rejected.isEmpty)
        #expect(report.clamped.isEmpty)
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

    // MARK: - 端が 2^53 を超える範囲 (宣言した端と、その外)

    @Test("宣言した端そのものは範囲の中として入り、収めたことにならない", arguments: [
        ("big", "4611686018427387905", 4_611_686_018_427_387_905),
        ("nearMax", "9223372036854775806", Int.max - 1),
        ("nearMin", "-9223372036854775807", Int.min + 1),
    ])
    func theDeclaredEndIsInsideTheRange(name: String, written: String, expected: Int) throws {
        let facet = try makeDirectory()
        let sketch = Huge()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        let report = try answer(
            #"{"id":"e1","values":[{"name":"\#(name)","type":"int","value":\#(written)}]}"#,
            from: surface, in: facet)

        #expect(try knob(sketch, name).declaration.value == .int(expected))
        #expect(report.rejected.isEmpty)
        #expect(report.clamped.isEmpty, "宣言した端なので、収めたことにならない")
    }

    @Test("宣言した端の外は、端へ収まって応答に載る", arguments: [
        ("big", "9223372036854775807", 4_611_686_018_427_387_905),
        ("nearMax", "9223372036854775807", Int.max - 1),
        ("nearMin", "-9223372036854775808", Int.min + 1),
    ])
    func outsideTheDeclaredEndIsClamped(name: String, written: String, expected: Int) throws {
        let facet = try makeDirectory()
        let sketch = Huge()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        let report = try answer(
            #"{"id":"e2","values":[{"name":"\#(name)","type":"int","value":\#(written)}]}"#,
            from: surface, in: facet)

        #expect(try knob(sketch, name).declaration.value == .int(expected))
        #expect(report.rejected.isEmpty)
        #expect(
            report.clamped == [.init(name: name, requested: .int(Int(written)!), value: .int(expected))])
    }

    // MARK: - 応答の端 (完了条件の外・#2478 の反証 5)

    /// 整数の宣言の端を `Double` で出すと `Int.max` は 2^63 になり、読み手が端を `int` の値として
    /// 書き戻すと `Int` に収まらない数になる。端も整数のまま出す。
    @Test("応答の min と max は整数のまま出て、そのまま int の値として書き戻せる")
    func theRangeEndsAreWrittenAsIntegers() throws {
        let facet = try makeDirectory()
        let sketch = Wide()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        let reply = try String(contentsOf: facet.appendingPathComponent("report.json"), encoding: .utf8)
        #expect(reply.contains("9223372036854775807"), "上端が 2^63 に丸まって出ている: \(reply)")
        #expect(reply.contains("-9223372036854775808"))

        // 読んだ端をそのまま書き戻す
        let report = try answer(
            #"{"id":"back","values":[{"name":"upper","type":"int","value":9223372036854775807},{"name":"lower","type":"int","value":-9223372036854775808}]}"#,
            from: surface, in: facet)
        #expect(report.rejected.isEmpty)
        #expect(sketch.upper == Int.max)
        #expect(sketch.lower == Int.min)
    }

    // MARK: - 窓から (完了条件 3)

    @Test("窓の段付きスライダーを右端 (2^63) へ寄せても落ちず、Int.max になる")
    func theSliderAtTheRightEndDoesNotCrash() throws {
        let sketch = Wide()
        let box = try knob(sketch, "upper")

        KnobBinding.number(box, box.declaration.value).wrappedValue = 9_223_372_036_854_775_808.0

        #expect(sketch.upper == Int.max)
    }

    @Test("上端が Int.max - 1 の範囲では、スライダーを右端 (2^63) へ寄せても上端に収まる")
    func theSliderIsClampedToTheDeclaredEnd() throws {
        let sketch = Huge()
        let box = try knob(sketch, "nearMax")

        KnobBinding.number(box, box.declaration.value).wrappedValue = 9_223_372_036_854_775_808.0

        #expect(sketch.nearMax == Int.max - 1)
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
