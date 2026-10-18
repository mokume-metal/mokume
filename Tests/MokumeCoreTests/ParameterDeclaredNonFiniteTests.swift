// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore
@testable import mokume

/// `@Param` の**生まれのときの宣言** (値・範囲) が非有限でも、保存とつまみの応答が止まらないこと
/// ([#2394](https://github.com/mokume-metal/mokume/issues/2394)・[#2475](https://github.com/mokume-metal/mokume/issues/2475))。
///
/// 値が**変わる**入口 (setter・`_modify`・`write`) の関所は #2271 で入った (`ParameterNonFiniteTests`)。
/// 生まれのときの値 (宣言の初期値・`init` の中の代入) と範囲は、マクロの init accessor を通って
/// ``ParamBox`` の初期化へ入り、setter は走らない。前の値が無いので「保つ」は成り立たず、
/// **値は型の零を載せ、範囲は書かなかったものとして扱い、どちらも置き場ごとに 1 度名乗る** (決定 A)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
@Suite("生まれのときの宣言が非有限でも、保存と応答は止まらない")
@MainActor
struct ParameterDeclaredNonFiniteTests {
    /// #2394 の本文の再現: 宣言の初期値が NaN。
    final class Bad: Sketch {
        @Param var radius: Double = .nan
        @Param var count: Int = 3
    }

    /// #2394 のコメントの再現: `init` の中の代入。setter ではなく init accessor を通る。
    final class InInit: Sketch {
        @Param var radius: Double
        @Param var count: Int = 3

        init() {
            radius = .nan
        }
    }

    /// 非有限を持ちうる 5 つの型を、どれも非有限で生む。
    final class BornBad: Sketch {
        @Param var number: Double = -.infinity
        @Param var single: Float = .infinity
        @Param var pair: SIMD2<Float> = SIMD2(1, .nan)
        @Param var triple: SIMD3<Float> = SIMD3(1, 2, .infinity)
        @Param var tint: LinearRGBA = LinearRGBA(premultipliedRed: 0.25, green: 0.5, blue: 0.75, alpha: .nan)
    }

    /// #2475 の本文の再現: 範囲の上端が無限。
    final class InfRange: Sketch {
        @Param(0...Double.infinity) var r: Double = 1
        @Param var count: Int = 3
    }

    /// 端が非有限の範囲を、`Float` の組と整数の値に書いた形。
    final class InfRangeTyped: Sketch {
        @Param(-Double.infinity...0) var pair: SIMD2<Float> = SIMD2(-1, -2)
        @Param(0...Int.max) var big: Int = 3
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-declared-nonfinite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func entry(_ name: String, in object: [String: Any], under key: String) -> [String: Any]? {
        let entries = object[key] as? [[String: Any]] ?? []
        return entries.first { $0["name"] as? String == name }
    }

    private func box<Value>(_ name: String, of sketch: any Sketch, as _: Value.Type) throws -> ParamBox<Value> {
        try #require(
            ParamRegistry(of: sketch).knobs.first { $0.declaration.name == name } as? ParamBox<Value>)
    }

    /// 保存が `radius` と `count` の両方を書け、つまみの応答も置けることを見る (完了条件 1・2 の後半)。
    private func expectSavingAndReplyWork(for sketch: any Sketch) throws {
        let directory = try makeDirectory()
        let saved = directory.appendingPathComponent("params.json")
        var warnings: [String] = []
        let store = ParamStore(
            registry: ParamRegistry(of: sketch), at: saved, warn: { warnings.append($0) })
        store.flushNow()
        #expect(store.writeCount == 1, "保存が書けなかった: \(warnings)")
        #expect(warnings.isEmpty, "保存が書けなかった: \(warnings)")
        let values = try jsonObject(at: saved)
        #expect(entry("radius", in: values, under: "values")?["value"] as? Double == 0)
        #expect(entry("count", in: values, under: "values")?["value"] as? Int == 3)

        let facet = directory.appendingPathComponent("params", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        ParamSurface(directory: facet, sketch: sketch).start()
        let reply = try jsonObject(at: facet.appendingPathComponent("report.json"))
        #expect(entry("radius", in: reply, under: "params")?["value"] as? Double == 0)
        #expect(entry("count", in: reply, under: "params")?["value"] as? Int == 3)
    }

    // MARK: - 生まれのときの値 (#2394)

    @Test("宣言の初期値が NaN なら 0 を載せ、保存と応答は両方の値を書ける")
    func aNaNInitialValueStartsAtZero() throws {
        let sketch = Bad()
        #expect(sketch.radius == 0)
        #expect(sketch.params.first { $0.name == "radius" }?.value == .float(0))
        try expectSavingAndReplyWork(for: sketch)
    }

    @Test("init の中の代入が NaN でも、同じく 0 を載せ、保存と応答は書ける")
    func aNaNAssignedInInitStartsAtZero() throws {
        let sketch = InInit()
        #expect(sketch.radius == 0)
        try expectSavingAndReplyWork(for: sketch)
    }

    @Test("組と色は成分のどれかが非有限なら型の零を、Float の無限も 0 を載せる")
    func everyTypeStartsAtItsZero() {
        let sketch = BornBad()
        #expect(sketch.number == 0)
        #expect(sketch.single == 0)
        #expect(sketch.pair == SIMD2(0, 0))
        #expect(sketch.triple == SIMD3(0, 0, 0))
        #expect(sketch.tint == LinearRGBA(premultipliedRed: 0, green: 0, blue: 0, alpha: 0))
        #expect(sketch.params.allSatisfy { $0.value.hasOnlyFiniteNumbers })
    }

    @Test("畳んだことを、名前・書かれた値・載せた値を含めて置き場ごとに 1 度名乗る")
    func foldingTheValueIsSaidOnce() throws {
        let sketch = Bad()
        let radius = try box("radius", of: sketch, as: Double.self)
        let line = try #require(radius.warnings.message(for: .bornNotFinite), "畳んだのに黙っていた")
        #expect(line.contains("radius"))
        #expect(line.contains("nan"))
        #expect(line.contains("0.0"), "載せた値を言わない: \(line)")
        #expect(!line.contains("\n"))
        // 生まれは 1 度きり。後の代入の拒みは #2271 の鍵で別に言う (同じ行を繰り返さない)
        sketch.radius = .nan
        #expect(radius.warnings.message(for: .bornNotFinite) == line)
        #expect(radius.warnings.hasWarned(.notFinite))

        let pair = try box("pair", of: BornBad(), as: SIMD2<Float>.self)
        #expect(try #require(pair.warnings.message(for: .bornNotFinite)).contains("pair"))
    }

    @Test("有限の初期値では何も言わず、書いた値のまま")
    func aFiniteInitialValueIsLeftAlone() throws {
        let sketch = Bad()
        let count = try box("count", of: sketch, as: Int.self)
        #expect(!count.warnings.hasWarned(.bornNotFinite))
        let plain = ParamBox<Float>(name: "x", value: .greatestFiniteMagnitude)
        #expect(plain.value == .greatestFiniteMagnitude)
        #expect(!plain.warnings.hasWarned(.bornNotFinite))
        let negativeZero = ParamBox<Double>(name: "z", value: -0.0)
        #expect(negativeZero.value.sign == .minus, "有限の値を零へ畳んだ")
    }

    @Test("値が変わる入口の扱い (前の値を保つ) は変わらない")
    func theChangingEntriesStillKeepThePreviousValue() {
        let sketch = Bad()
        sketch.radius = .infinity
        #expect(sketch.radius == 0, "畳んだ 0 を保つ")
        sketch.radius = 5
        #expect(sketch.radius == 5)
        sketch.radius += .nan
        #expect(sketch.radius == 5)
        let box = ParamBox<Double>(name: "x", value: .nan, range: ParamRange(0...10))
        #expect(box.write(.float(.nan)) == .notFinite)
        #expect(box.value == 0)
    }

    // MARK: - 範囲の端 (#2475)

    @Test("上端が無限の範囲は書かなかったものとして扱い、応答は置けて min / max を持たない")
    func anInfiniteUpperBoundIsTreatedAsNoRange() throws {
        let facet = try makeDirectory()
        let sketch = InfRange()
        ParamSurface(directory: facet, sketch: sketch).start()

        let reply = try jsonObject(at: facet.appendingPathComponent("report.json"))
        let r = try #require(entry("r", in: reply, under: "params"))
        #expect(r["value"] as? Double == 1)
        #expect(r["min"] == nil)
        #expect(r["max"] == nil)
        #expect(entry("count", in: reply, under: "params")?["value"] as? Int == 3)
    }

    @Test("同じ宣言にスライダーは出ず、外からの書き込みは範囲へ収めない")
    func anInfiniteUpperBoundGetsNoKnobAndNoClamp() throws {
        let sketch = InfRange()
        let declaration = try #require(sketch.params.first { $0.name == "r" })
        #expect(declaration.range == nil)
        #expect(KnobKind.forDeclaration(declaration) == .none(.rangeNotDeclared))

        let r = try box("r", of: sketch, as: Double.self)
        #expect(r.write(.float(-5)) == .applied, "書かなかった範囲の下端 0 へ収めた")
        #expect(sketch.r == -5)
    }

    /// NaN の端はここに並べない。`Double.nan...1` は `ClosedRange` の precondition で落ち、
    /// `ClosedRange(uncheckedBounds:)` も debug では同じ所で落ちるので、``ParamRange`` は NaN の端を
    /// 持てない (応答の読み取りも `lower <= upper` を見るので組まない)。置き場が見るのは
    /// `isFinite` で、NaN も偽になる。
    @Test(
        "下端・両端が非有限の範囲も、書かなかった範囲として扱う",
        arguments: [
            0...Double.infinity,
            -Double.infinity...0,
            -Double.infinity...Double.infinity,
        ])
    func everyNonFiniteBoundIsDropped(_ bounds: ClosedRange<Double>) throws {
        let box = ParamBox<Double>(name: "r", value: 1, range: ParamRange(bounds))
        #expect(box.range == nil)
        #expect(box.declaration.range == nil)
        let line = try #require(box.warnings.message(for: .rangeNotFinite), "畳んだのに黙っていた")
        #expect(line.contains("\"r\""))
        #expect(!line.contains("\n"))
        let data = try JSONEncoder().encode(box.declaration)
        let written = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(written["min"] == nil && written["max"] == nil)
    }

    @Test("Float の組に書いた範囲も同じ。整数で書いた範囲は変わらない")
    func tuplesFoldAndIntegerRangesStay() throws {
        let sketch = InfRangeTyped()
        let pair = try box("pair", of: sketch, as: SIMD2<Float>.self)
        #expect(pair.range == nil)
        #expect(KnobKind.forDeclaration(pair.declaration) == .none(.rangeNotDeclared))
        #expect(pair.warnings.hasWarned(.rangeNotFinite))

        let big = try box("big", of: sketch, as: Int.self)
        #expect(big.range == ParamRange(0...Int.max))
        #expect(!big.warnings.hasWarned(.rangeNotFinite))
    }

    @Test("範囲を畳んだことを、名前と書かれた範囲を含めて 1 度名乗る。有限の範囲では言わない")
    func foldingTheRangeIsSaid() throws {
        let r = try box("r", of: InfRange(), as: Double.self)
        let line = try #require(r.warnings.message(for: .rangeNotFinite))
        #expect(line.contains("\"r\""))
        #expect(line.contains("inf"), "書かれた範囲を言わない: \(line)")

        let finite = ParamBox<Double>(name: "f", value: 1, range: ParamRange(0...10))
        #expect(finite.range == ParamRange(0...10))
        #expect(!finite.warnings.hasWarned(.rangeNotFinite))
        let huge = ParamBox<Double>(
            name: "h", value: 1, range: ParamRange(-Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude))
        #expect(huge.range != nil, "有限の端を畳んだ")
        #expect(!huge.warnings.hasWarned(.rangeNotFinite))
    }
}
