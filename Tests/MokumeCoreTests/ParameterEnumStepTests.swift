// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore
@testable import mokume

/// 色の組。**型の側に `ParamRepresentable` を書かない** (String を生の値に持つ `CaseIterable` の enum を、
/// そのまま `@Param` にできること — [#2438](https://github.com/mokume-metal/mokume/issues/2438))。
enum Palette: String, CaseIterable { case ember, tide, moss }

/// 自分で `ParamRepresentable` を書いた enum。**どちらの `init` にも当たる型を曖昧にしない**。
enum Mood: String, CaseIterable, ParamRepresentable {
    case calm, wild

    var paramValue: ParamValue { .string(rawValue) }
    init?(paramValue: ParamValue) {
        guard case .string(let text) = paramValue else { return nil }
        self.init(rawValue: text)
    }
}

/// enum を `@Param` にする。
///
/// 面に出る型は `string` のままで (ADR-0030 決定 4 の 6 型は増えない)、候補は enum の `allCases` から作る。
/// 外からの書き込みも保存の復元も、**文字の候補と同じ道**を通る。
@Suite("enum を @Param にする")
@MainActor
struct ParameterEnumTests {
    /// 作例どおり。enum の側には何も書き足していない。
    final class Painter: Sketch {
        @Param var palette: Palette = .ember
        @Param(0...1, step: 0.05) var density: Double = 0.4

        /// 網羅の `switch`。case を足して書き漏らすと、組む時点で止まる。
        var background: String {
            switch palette {
            case .ember: "ember"
            case .tide: "tide"
            case .moss: "moss"
            }
        }
    }

    /// 自分で `ParamRepresentable` を書いた enum と、候補を明示した宣言が、どちらも組める。
    final class Moody: Sketch {
        @Param var mood: Mood = .calm
        @Param(name: "sound") var tone: Mood = .wild
    }

    private func declaration(_ sketch: some Sketch, _ name: String) throws -> ParamDeclaration {
        try #require(sketch.params.first { $0.name == name })
    }

    // MARK: - 宣言 (条件 1)

    @Test("面には string を名乗り、候補は case の宣言順で出る。範囲も刻みも付かない")
    func declaresAStringWithTheCases() throws {
        let sketch = Painter()
        let palette = try declaration(sketch, "palette")
        #expect(palette.typeName == "string")
        #expect(palette.value == .string("ember"))
        #expect(palette.choices == ["ember", "tide", "moss"])
        #expect(palette.range == nil)
        #expect(palette.step == nil)
    }

    /// 「declare the choices and a knob appears」ではなく、候補から選ぶつまみが出る。
    @Test("窓には候補から選ぶつまみが出る")
    func showsAChoiceKnob() throws {
        let palette = try declaration(Painter(), "palette")
        #expect(KnobKind.forDeclaration(palette) == .choice(["ember", "tide", "moss"]))
    }

    @Test("コードからの代入は、そのまま面の値になる")
    func assignmentShowsOnTheSurface() throws {
        let sketch = Painter()
        sketch.palette = .moss
        #expect(sketch.background == "moss")
        #expect(try declaration(sketch, "palette").value == .string("moss"))
    }

    // MARK: - 外からの書き込み (条件 2)

    @Test("候補にある生の値は当たり、スケッチの case が変わる")
    func writingACaseApplies() {
        let sketch = Painter()
        let registry = ParamRegistry(of: sketch)
        #expect(registry.write(.string("tide"), to: "palette") == .applied)
        #expect(sketch.palette == .tide)
        #expect(sketch.background == "tide")
    }

    @Test("候補に無い生の値は、文字の候補と同じ理由で断られ、値は前のまま")
    func writingAStrangeNameIsRefused() {
        let sketch = Painter()
        let registry = ParamRegistry(of: sketch)
        #expect(registry.write(.string("sea"), to: "palette") == .notInChoices)
        #expect(sketch.palette == .ember)
        // 綴りの大文字小文字も別の値 (生の値は完全一致)
        #expect(registry.write(.string("Tide"), to: "palette") == .notInChoices)
        #expect(sketch.palette == .ember)
    }

    @Test("文字でない値は、型の違いとして断られる")
    func writingANumberIsATypeMismatch() {
        let sketch = Painter()
        let registry = ParamRegistry(of: sketch)
        #expect(registry.write(.int(1), to: "palette") == .typeMismatch)
        #expect(sketch.palette == .ember)
    }

    /// 面 (`.mokume/params`) を通した往復。応答には候補が載り、候補の外は理由つきで断られる。
    @Test("面を通しても、tide は当たり、sea は notInChoices で断られる")
    func overTheSurface() throws {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-enum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: facet) }
        let sketch = Painter()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        try """
        {"id":"e1","values":[
          {"name":"palette","type":"string","value":"tide"},
          {"name":"density","type":"float","value":0.37}
        ]}
        """.write(
            to: facet.appendingPathComponent("request.json"), atomically: true, encoding: .utf8)
        surface.drain()
        #expect(sketch.palette == .tide)

        let first = try report(in: facet)
        let entries = first["params"] as? [[String: Any]] ?? []
        let palette = try #require(entries.first { $0["name"] as? String == "palette" })
        #expect(palette["type"] as? String == "string")
        #expect(palette["value"] as? String == "tide")
        #expect(palette["choices"] as? [String] == ["ember", "tide", "moss"])
        // 刻みが目録に載る。外から書いた 0.37 は刻みへ丸めず、収めたとも名乗らない
        let density = try #require(entries.first { $0["name"] as? String == "density" })
        #expect(density["step"] as? Double == 0.05)
        #expect(density["value"] as? Double == 0.37)
        #expect((first["clamped"] as? [Any])?.isEmpty == true)
        #expect((first["rejected"] as? [Any])?.isEmpty == true)

        try """
        {"id":"e2","values":[{"name":"palette","type":"string","value":"sea"}]}
        """.write(
            to: facet.appendingPathComponent("request.json"), atomically: true, encoding: .utf8)
        surface.drain()
        let second = try report(in: facet)
        let rejected = second["rejected"] as? [[String: Any]] ?? []
        #expect(rejected.count == 1)
        #expect(rejected.first?["name"] as? String == "palette")
        #expect(rejected.first?["reason"] as? String == "notInChoices")
        #expect(sketch.palette == .tide)
    }

    private func report(in facet: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: - 型の側が ParamRepresentable を書いた enum

    @Test("ParamRepresentable を自分で書いた enum も、そのまま宣言でき、候補は case から補われる")
    func ownConformanceStillWorks() throws {
        let sketch = Moody()
        let mood = try declaration(sketch, "mood")
        #expect(mood.value == .string("calm"))
        #expect(mood.choices == ["calm", "wild"])
        // `name:` で名乗りを変えても同じ
        #expect(try declaration(sketch, "sound").choices == ["calm", "wild"])
        let registry = ParamRegistry(of: sketch)
        #expect(registry.write(.string("wild"), to: "mood") == .applied)
        #expect(sketch.mood == .wild)
        #expect(registry.write(.string("tame"), to: "mood") == .notInChoices)
    }
}

/// 保存した enum の case が、宣言を変えたあとに合わなくなる扱い (条件 3)。
///
/// 文字の候補と同じ文面で名乗り、コードの既定値が効く。case を足しただけなら保存はそのまま当たる。
@Suite("enum の保存と復元")
@MainActor
struct ParameterEnumStoreTests {
    final class Before: Sketch {
        @Param var palette: Palette = .ember
    }

    /// `tide` の case を消した版。
    enum Reduced: String, CaseIterable { case ember, moss }
    final class After: Sketch {
        @Param var palette: Reduced = .ember
    }

    /// `tide` を `sea` へ変えた版 (名前の変更も、保存した生の値から見れば消えたのと同じ)。
    enum Renamed: String, CaseIterable { case ember, sea, moss }
    final class Rename: Sketch {
        @Param var palette: Renamed = .ember
    }

    /// `sand` を足しただけの版。
    enum Wider: String, CaseIterable { case ember, tide, moss, sand }
    final class Widen: Sketch {
        @Param var palette: Wider = .ember
    }

    private func makeFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-enum-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("params.json")
    }

    /// `tide` を選んで保存した状態を作る。
    private func saveTide() async throws -> URL {
        let url = try makeFile()
        let before = Before()
        let saving = ParamStore(registry: ParamRegistry(of: before), at: url)
        saving.restore()
        before.palette = .tide
        await Task.yield()
        for _ in 0...ParamStore.quietFrames { saving.tick() }
        #expect(saving.writeCount == 1)
        return url
    }

    @Test("保存した case を消すと、候補の外として捨てて名乗り、コードの既定値の case が効く")
    func aRemovedCaseIsDiscarded() async throws {
        let url = try await saveTide()
        let after = After()
        var warnings: [String] = []
        let restoration = ParamStore(
            registry: ParamRegistry(of: after), at: url, warn: { warnings.append($0) }
        ).restore()

        #expect(restoration.discarded == [.init(name: "palette", reason: .notInChoices)])
        #expect(after.palette == .ember, "コードの既定値の case が効いていない")
        let line = try #require(warnings.first, "捨てたのに黙っていた")
        #expect(line.contains("palette"))
        #expect(line.contains("outside the choices that are allowed"))
        #expect(line.contains("Threw away 1 of the saved values"))
    }

    @Test("case の名前を変えても、保存した生の値は候補の外として捨てられる")
    func aRenamedCaseIsDiscarded() async throws {
        let url = try await saveTide()
        let rename = Rename()
        let restoration = ParamStore(registry: ParamRegistry(of: rename), at: url).restore()
        #expect(restoration.discarded == [.init(name: "palette", reason: .notInChoices)])
        #expect(rename.palette == .ember)
    }

    @Test("case を足しただけなら、保存した値はそのまま当たり、何も捨てない")
    func anAddedCaseKeepsTheSave() async throws {
        let url = try await saveTide()
        let widen = Widen()
        let restoration = ParamStore(registry: ParamRegistry(of: widen), at: url).restore()
        #expect(restoration.isEmpty)
        #expect(widen.palette == .tide)
    }
}

/// 実数のスライダーの刻み (`step:`)。
///
/// **刻みは窓のスライダーの動き方だけを決める。** 外からの書き込み・保存の復元・コードからの代入は
/// 刻みへ丸めず、`clamped` は「宣言した範囲へ収めた」の意味のまま保つ。
@Suite("実数のスライダーの刻み")
@MainActor
struct ParameterStepTests {
    final class Dense: Sketch {
        @Param(0...1, step: 0.05) var density: Double = 0.4
        @Param(-1...1, step: 0.25) var drift: Vector2 = Vector2(0, 0)
        @Param(0...8) var weight: Float = 2
        @Param(1...8) var count: Int = 3
    }

    private func declaration(_ sketch: some Sketch, _ name: String) throws -> ParamDeclaration {
        try #require(sketch.params.first { $0.name == name })
    }

    // MARK: - 宣言とつまみ (条件 4)

    @Test("刻みは宣言に載り、つまみの種類へ渡る。書かなければ刻みは無い")
    func theStepReachesTheKnob() throws {
        let sketch = Dense()
        let density = try declaration(sketch, "density")
        #expect(density.step == 0.05)
        #expect(KnobKind.forDeclaration(density) == .slider(ParamRange(0...1), step: 0.05))
        // 組は成分のスライダーそれぞれの刻み
        let drift = try declaration(sketch, "drift")
        #expect(KnobKind.forDeclaration(drift) == .components(count: 2, range: ParamRange(-1...1), step: 0.25))
        // 書かなければ連続のまま
        let weight = try declaration(sketch, "weight")
        #expect(weight.step == nil)
        #expect(KnobKind.forDeclaration(weight) == .slider(ParamRange(0...8)))
        #expect(KnobKind.forDeclaration(weight) == .slider(ParamRange(0...8), step: nil))
    }

    /// 整数のスライダーは 1 刻みのまま (刻みの欄を持たない)。
    @Test("整数のスライダーは、刻みを書けず 1 刻みのまま")
    func integerSlidersStayAtOne() throws {
        let count = try declaration(Dense(), "count")
        #expect(count.step == nil)
        #expect(KnobKind.forDeclaration(count) == .steppedSlider(ParamRange(1...8)))
    }

    /// 宣言が実数でない値に刻みを持っていても (読み取った応答など)、整数のつまみは 1 刻み。
    @Test("実数でない宣言に刻みが載っていても、つまみはそれに従わない")
    func nonRealDeclarationsIgnoreAStep() {
        let integer = ParamDeclaration(
            name: "n", value: .int(3), range: ParamRange(1...8), step: 0.5)
        #expect(KnobKind.forDeclaration(integer) == .steppedSlider(ParamRange(1...8)))
    }

    // MARK: - 丸めない (条件 4)

    @Test("外から書いた 0.37 は 0.37 のまま当たり、収めたとは名乗らない")
    func anExternalWriteIsNotRoundedToTheStep() {
        let sketch = Dense()
        let registry = ParamRegistry(of: sketch)
        #expect(registry.write(.float(0.37), to: "density") == .applied)
        #expect(sketch.density == 0.37)
    }

    /// `clamped` は「宣言した範囲へ収めた」の意味のまま。刻みへ寄せたことは名乗らない。
    @Test("範囲の外は今までどおり収めて名乗り、刻みへは寄せない")
    func clampingKeepsItsMeaning() {
        let sketch = Dense()
        let registry = ParamRegistry(of: sketch)
        let outcome = registry.write(.float(1.5), to: "density")
        #expect(outcome == .clamped(requested: .float(1.5), applied: .float(1)))
        #expect(sketch.density == 1)
        // 範囲の中で刻みに乗らない値は、収めたことにならない
        #expect(registry.write(.float(0.123), to: "density") == .applied)
        #expect(sketch.density == 0.123)
    }

    @Test("コードからの代入も、刻みへ丸めない")
    func assignmentIsNotRounded() {
        let sketch = Dense()
        sketch.density = 0.37
        #expect(sketch.density == 0.37)
        sketch.drift = Vector2(0.1, -0.9)
        #expect(sketch.drift == Vector2(0.1, -0.9))
    }

    private func makeFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-step-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("params.json")
    }

    @Test("保存の復元も、刻みへ丸めずに戻す")
    func restoringIsNotRounded() async throws {
        let url = try makeFile()
        let first = Dense()
        let saving = ParamStore(registry: ParamRegistry(of: first), at: url)
        saving.restore()
        first.density = 0.37
        await Task.yield()
        for _ in 0...ParamStore.quietFrames { saving.tick() }

        let second = Dense()
        let restoration = ParamStore(registry: ParamRegistry(of: second), at: url).restore()
        #expect(restoration.isEmpty)
        #expect(second.density == 0.37)
    }

    // MARK: - 断る (条件 4)

    @Test("0 以下・非有限の刻みは置かず、刻みの無いスライダーのまま 1 度だけ名乗る")
    func aBadStepIsRefusedOnce() throws {
        for bad in [0.0, -0.05, .nan, .infinity, -.infinity] {
            let box = ParamBox(name: "density", value: 0.4, range: ParamRange(0...1), step: bad)
            #expect(box.step == nil, "刻み \(bad) を置いた")
            #expect(box.declaration.step == nil)
            let line = try #require(box.warnings.message(for: .step), "刻み \(bad) を断ったのに黙っていた")
            #expect(line.contains("density"))
            #expect(line.contains("finite number above 0"))
            #expect(KnobKind.forDeclaration(box.declaration) == .slider(ParamRange(0...1)))
        }
    }

    @Test("書いていなければ、何も言わない。正しい刻みを置いたときも言わない")
    func noStepOrAGoodStepSaysNothing() {
        let plain = ParamBox(name: "a", value: 0.4, range: ParamRange(0...1))
        let good = ParamBox(name: "b", value: 0.4, range: ParamRange(0...1), step: 0.05)
        #expect(plain.step == nil)
        #expect(!plain.warnings.hasWarned(.step))
        #expect(good.step == 0.05)
        #expect(!good.warnings.hasWarned(.step))
    }

    @Test("実数でない値に付けた刻みも断り、置かない")
    func aStepOnANonRealValueIsRefused() throws {
        let integer = ParamBox(name: "n", value: 3, range: ParamRange(0...10), step: 0.5)
        #expect(integer.step == nil)
        #expect(try #require(integer.warnings.message(for: .step)).contains("not int"))
        let flag = ParamBox(name: "f", value: true, step: 1)
        #expect(flag.step == nil)
        #expect(flag.warnings.hasWarned(.step))
        // 実数の組は付けられる
        let pair = ParamBox(
            name: "p", value: Vector2(0, 0), range: ParamRange(-1...1), step: 0.25)
        #expect(pair.step == 0.25)
    }

    // MARK: - 目録 (条件 5)

    private func roundTrip(_ declaration: ParamDeclaration) throws -> ParamDeclaration {
        let data = try JSONEncoder().encode(declaration)
        return try JSONDecoder().decode(ParamDeclaration.self, from: data)
    }

    @Test("目録には step が載り、読み直しても同じ。刻みの無い宣言は鍵ごと省く")
    func theInventoryCarriesTheStep() throws {
        let declaration = ParamDeclaration(
            name: "density", value: .float(0.4), range: ParamRange(0...1), step: 0.05)
        let data = try JSONEncoder().encode(declaration)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["step"] as? Double == 0.05)
        #expect(try roundTrip(declaration) == declaration)

        let plain = ParamDeclaration(name: "d", value: .float(0.4), range: ParamRange(0...1))
        let plainObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        #expect(plainObject["step"] == nil)
        #expect(try roundTrip(plain).step == nil)
    }

    /// 道具のプレビューは目録から宣言を読み直す。書き手を信じ切らず、0 以下の刻みは無いものとして読む。
    @Test("読む側は、0 以下の刻みを無いものとして読む")
    func readingDropsABadStep() throws {
        let text = """
            {"name":"d","type":"float","value":0.4,"min":0,"max":1,"step":0}
            """
        let declaration = try JSONDecoder().decode(ParamDeclaration.self, from: Data(text.utf8))
        #expect(declaration.step == nil)
        #expect(declaration.range == ParamRange(0...1))
    }

    @Test("刻みが変わったことは、宣言が変わったこととして見える")
    func aStepChangeIsADeclarationChange() {
        let before = ParamDeclaration(
            name: "d", value: .float(0.4), range: ParamRange(0...1), step: 0.05)
        let after = ParamDeclaration(
            name: "d", value: .float(0.4), range: ParamRange(0...1), step: 0.1)
        #expect(before != after)
    }
}
