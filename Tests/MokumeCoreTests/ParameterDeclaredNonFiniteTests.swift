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
        @Param var pair: Vector2 = Vector2(1, Float.nan)
        @Param var triple: Vector3 = Vector3(1, 2, Float.infinity)
        @Param var tint: Color = Color(premultipliedRed: 0.25, green: 0.5, blue: 0.75, alpha: .nan)
    }

    /// #2475 の本文の再現: 範囲の上端が無限。
    final class InfRange: Sketch {
        @Param(0...Double.infinity) var r: Double = 1
        @Param var count: Int = 3
    }

    /// 端が非有限の範囲を、`Float` の組と整数の値に書いた形。
    final class InfRangeTyped: Sketch {
        @Param(-Double.infinity...0) var pair: Vector2 = Vector2(-1, -2)
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
        #expect(sketch.pair == Vector2(0, 0))
        #expect(sketch.triple == Vector3(0, 0, 0))
        #expect(sketch.tint == Color(premultipliedRed: 0, green: 0, blue: 0, alpha: 0))
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

        let pair = try box("pair", of: BornBad(), as: Vector2.self)
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

    @Test("上端が無限の範囲は面に出さず、応答は置けて min / max を持たない")
    func anInfiniteUpperBoundIsNotShown() throws {
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

    /// メンテナの決定 (2026-10-18): 面に出せないのは JSON とスライダーの都合で、作者が書いた有限の端は
    /// 外からの書き込みに今までどおり効かせる。
    @Test("同じ宣言にスライダーは出ず、外からの書き込みは書かれた有限の端へ収める")
    func anInfiniteUpperBoundGetsNoKnobButStillClamps() throws {
        let sketch = InfRange()
        let declaration = try #require(sketch.params.first { $0.name == "r" })
        #expect(declaration.range == nil)
        #expect(KnobKind.forDeclaration(declaration) == .none(.rangeNotFinite))

        let r = try box("r", of: sketch, as: Double.self)
        #expect(r.write(.float(-5)) == .clamped(requested: .float(-5), applied: .float(0)))
        #expect(sketch.r == 0)
        #expect(r.write(.float(1e300)) == .applied, "無限の側では収めない")
        #expect(sketch.r == 1e300)
    }

    /// 作者は範囲を書いているので、「範囲を書けばつまみが出る」と言うと誤る。範囲を書いていない数値とは
    /// 言い分ける。
    @Test("窓は、端が非有限で出さないことを、範囲を書いていない数値とは別の注記で添える")
    func theWindowSaysWhyThereIsNoKnob() throws {
        let note = KnobKind.Reason.rangeNotFinite.note
        #expect(note != KnobKind.Reason.rangeNotDeclared.note)
        #expect(note.contains("not a finite number"))
        let plain = ParamBox<Double>(name: "p", value: 1)
        #expect(KnobKind.forDeclaration(plain.declaration) == .none(.rangeNotDeclared))
        // 応答から読み直した宣言は、端が非有限だったことを知らない (応答に書かない)
        let reread = try JSONDecoder().decode(
            ParamDeclaration.self, from: JSONEncoder().encode(try box("r", of: InfRange(), as: Double.self).declaration))
        #expect(reread.range == nil)
    }

    /// NaN の端はここに並べない。`Double.nan...1` は `ClosedRange` の precondition で落ち、
    /// `ClosedRange(uncheckedBounds:)` も debug では同じ所で落ちるので、``ParamRange`` は NaN の端を
    /// 持てない (応答の読み取りも `lower <= upper` を見るので組まない)。置き場が見るのは
    /// `isFinite` で、NaN も偽になる。
    @Test(
        "下端・両端が非有限の範囲も面に出さない。収めるのは有限の端があるときだけ",
        arguments: [
            (0...Double.infinity, -5.0, 0.0),
            (-Double.infinity...0, 5.0, 0.0),
            (-Double.infinity...Double.infinity, 5.0, 5.0),
        ])
    func everyNonFiniteBoundIsNotShown(_ bounds: ClosedRange<Double>, written: Double, settled: Double) throws {
        let box = ParamBox<Double>(name: "r", value: 1, range: ParamRange(bounds))
        #expect(box.declaration.range == nil)
        #expect(KnobKind.forDeclaration(box.declaration) == .none(.rangeNotFinite))
        let line = try #require(box.warnings.message(for: .rangeNotFinite), "畳んだのに黙っていた")
        #expect(line.contains("\"r\""))
        #expect(!line.contains("\n"))
        let data = try JSONEncoder().encode(box.declaration)
        let wire = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(wire["min"] == nil && wire["max"] == nil)

        _ = box.write(.float(written))
        #expect(box.value == settled)
        let hasFiniteEnd = bounds.lowerBound.isFinite || bounds.upperBound.isFinite
        #expect(box.range == (hasFiniteEnd ? ParamRange(bounds) : nil))
        #expect(
            line.contains(hasFiniteEnd ? "still brought to the finite end" : "not clamped"),
            "収めるかどうかを事実と違って言った: \(line)")
    }

    @Test("Float の組に書いた範囲も同じ。整数で書いた範囲は変わらない")
    func tuplesFoldAndIntegerRangesStay() throws {
        let sketch = InfRangeTyped()
        let pair = try box("pair", of: sketch, as: Vector2.self)
        #expect(pair.declaration.range == nil)
        #expect(KnobKind.forDeclaration(pair.declaration) == .none(.rangeNotFinite))
        #expect(pair.warnings.hasWarned(.rangeNotFinite))
        #expect(pair.write(.vector2(Vector2(3, -4))) == .clamped(requested: .vector2(Vector2(3, -4)), applied: .vector2(Vector2(0, -4))))

        let big = try box("big", of: sketch, as: Int.self)
        #expect(big.range == ParamRange(0...Int.max))
        #expect(!big.warnings.hasWarned(.rangeNotFinite))
    }

    /// 範囲が意味を持たない型には、つまみも収めも元から無い。起きないことを言わない。
    @Test("真偽・文字・色に書いた非有限の範囲は、応答から外したことだけを言う")
    func aRangeOnATypeWithoutKnobRangeSaysOnlyWhatHappens() throws {
        let flag = ParamBox<Bool>(name: "flag", value: true, range: ParamRange(0...Double.infinity))
        let text = ParamBox<String>(name: "text", value: "a", range: ParamRange(-Double.infinity...0))
        let ink = ParamBox<Color>(
            name: "ink", value: Color(premultipliedRed: 0, green: 0, blue: 0, alpha: 1),
            range: ParamRange(-Double.infinity...Double.infinity))
        let lines: [String?] = [
            flag.warnings.message(for: .rangeNotFinite), text.warnings.message(for: .rangeNotFinite),
            ink.warnings.message(for: .rangeNotFinite),
        ]
        for line in lines {
            let said = try #require(line)
            #expect(said.contains("leaves out min and max"))
            #expect(!said.contains("knob appears"), "出るはずの無いつまみを言った: \(said)")
            #expect(!said.contains("clamped") && !said.contains("brought to"), "起きない収めを言った: \(said)")
        }
        #expect(flag.declaration.range == nil)
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

    // MARK: - 型の零を作れない型 (#2858)

    /// 零を断る自作の型。
    struct NoZero: ParamRepresentable, Equatable {
        let length: Double
        var paramValue: ParamValue { .float(length) }
        init(_ length: Double) { self.length = length }
        init?(paramValue: ParamValue) {
            guard case .float(let value) = paramValue, value != 0 else { return nil }
            length = value
        }
    }

    /// 零を読むと非有限を返す自作の型。
    struct NaNZero: ParamRepresentable {
        let length: Double
        var paramValue: ParamValue { .float(length) }
        init(_ length: Double) { self.length = length }
        init?(paramValue: ParamValue) {
            guard case .float(let value) = paramValue else { return nil }
            length = value == 0 ? .nan : value
        }
    }

    @Test("型が有限の零をくれなければ畳めず、書かれた値のまま置いて、畳めなかったと言う")
    func aTypeWithoutAFiniteZeroIsSaidToBeUnfolded() throws {
        let refusing = ParamBox<NoZero>(name: "a", value: NoZero(.nan))
        #expect(refusing.value.length.isNaN)
        let nanZero = ParamBox<NaNZero>(name: "b", value: NaNZero(.infinity))
        #expect(nanZero.value.length == .infinity, "読み戻した零の NaN を載せた")
        for box in [refusing.warnings.message(for: .bornNotFinite), nanZero.warnings.message(for: .bornNotFinite)] {
            let line = try #require(box, "畳めなかったのに黙っていた")
            #expect(line.contains("gave no finite zero"))
            #expect(!line.contains("starts at"), "畳めていないのに畳んだと言った: \(line)")
        }
    }

    // MARK: - 畳めなかった宣言は、保存と応答から外す (#2858)

    /// 零を断る型の `a` を NaN で生ませ、有限の `count` と並べる。
    final class Unfoldable: Sketch {
        @Param var a: NoZero = NoZero(.nan)
        @Param var count: Int = 3
    }

    /// 読み戻した零が非有限の型 (`NaNZero`) でも同じ。
    final class UnfoldableNaNZero: Sketch {
        @Param var b: NaNZero = NaNZero(.infinity)
        @Param var count: Int = 3
    }

    /// 保存と応答が、`a` を載せず `count` だけを書けることを見る。
    private func expectOnlyCountIsSavedAndReplied(for sketch: any Sketch, left name: String) throws {
        let directory = try makeDirectory()
        let saved = directory.appendingPathComponent("params.json")
        var warnings: [String] = []
        let store = ParamStore(
            registry: ParamRegistry(of: sketch), at: saved, warn: { warnings.append($0) })
        store.flushNow()
        #expect(store.writeCount == 1, "保存が書けなかった: \(warnings)")
        #expect(warnings.isEmpty, "保存が書けなかった: \(warnings)")
        let values = try jsonObject(at: saved)
        #expect(entry("count", in: values, under: "values")?["value"] as? Int == 3)
        #expect(entry(name, in: values, under: "values") == nil, "畳めなかった宣言を保存に載せた")

        let facet = directory.appendingPathComponent("params", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        ParamSurface(directory: facet, sketch: sketch).start()
        let reply = try jsonObject(at: facet.appendingPathComponent("report.json"))
        #expect(entry("count", in: reply, under: "params")?["value"] as? Int == 3)
        #expect(entry(name, in: reply, under: "params") == nil, "畳めなかった宣言を応答に載せた")
    }

    @Test("零を断る型の宣言が NaN で生まれても、保存と応答は count だけを書ける (a は外す)")
    func anUnfoldableDeclarationIsLeftOutOfSavingAndReply() throws {
        try expectOnlyCountIsSavedAndReplied(for: Unfoldable(), left: "a")
        try expectOnlyCountIsSavedAndReplied(for: UnfoldableNaNZero(), left: "b")
    }

    @Test("外した宣言は、有限の値を代入するか外から書き込むと、次の保存と応答に戻る")
    func anUnfoldableDeclarationComesBackOnceFinite() throws {
        let sketch = Unfoldable()
        let registry = ParamRegistry(of: sketch)
        #expect(registry.declarations.map(\.name) == ["count"])

        sketch.a = NoZero(2)
        #expect(registry.declarations.map(\.name) == ["a", "count"])
        #expect(registry.declarations.first?.value == .float(2))

        let other = Unfoldable()
        let otherRegistry = ParamRegistry(of: other)
        #expect(otherRegistry.write(.float(5), to: "a") == .applied, "外している間も外からの書き込みは効く")
        #expect(otherRegistry.declarations.map(\.name) == ["a", "count"])
        #expect(other.a.length == 5)

        // 戻った後に、また非有限を書かれても前の値を保つので、外れない
        sketch.a = NoZero(.nan)
        #expect(registry.declarations.map(\.name) == ["a", "count"])
    }

    @Test("畳めなかったことを言う警告は、外したことと戻る条件を事実どおりに言い、止まるとは言わない")
    func theWarningSaysWhatWasLeftOut() throws {
        let refusing = ParamBox<NoZero>(name: "a", value: NoZero(.nan))
        let line = try #require(refusing.warnings.message(for: .bornNotFinite))
        #expect(line.contains("left out of the saved values and the knob reply"))
        #expect(line.contains("until it holds a finite number"))
        #expect(!line.contains("cannot be saved"), "止まると言った: \(line)")
        #expect(!line.contains("\n"))
    }

    @Test("有限に畳めた型は外さない。零へ畳んだ宣言は保存にも応答にも載る")
    func aFoldedDeclarationStaysInTheRegistry() {
        let registry = ParamRegistry(of: Bad())
        #expect(registry.declarations.map(\.name) == ["radius", "count"])
    }
}
