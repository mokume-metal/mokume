// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import Testing

@testable import MokumeCore
@testable import mokume

/// `@Param` に非有限の数 (NaN・無限) が載らないこと ([#2271](https://github.com/mokume-metal/mokume/issues/2271))。
///
/// 載ると、保存 (`ParamStore.write`) もつまみの応答 (`ParamSurface`) も `JSONEncoder` が非有限を
/// 拒むので、**他の値も含めて全部が書けなくなる**。関所は置き場 (``ParamBox``) の 1 点で、作者の
/// コード・面からの書き込み・保存からの復元の 3 つの入口がそこを通る。拒んだ値は置かず、
/// **前の値を保ち、1 度だけ名乗る** ([ADR-0030] 決定 3)。
///
/// 値は 2 進で割り切れるものを選ぶ。`Float` と `Double` の間を往復して誤差が出る値だと、壊れたのか
/// 丸めなのかが見分けられない。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
@Suite("非有限の数は @Param に載らない")
@MainActor
struct ParameterNonFiniteTests {
    /// 完了条件の例そのまま: 範囲を宣言していない `Float`。
    final class Tuned: Sketch {
        @Param var radius: Float = 10
        @Param var count: Int = 3
    }

    /// 非有限を持ちうる 5 つの型。
    final class Typed: Sketch {
        @Param var number: Double = 2
        @Param var single: Float = 10
        @Param var pair: SIMD2<Float> = SIMD2(1, 2)
        @Param var triple: SIMD3<Float> = SIMD3(1, 2, 3)
        @Param var tint: LinearRGBA = LinearRGBA(premultipliedRed: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        @Param var count: Int = 3
    }

    /// `Double` で宣言していた値を `Float` へ変えたあとのスケッチ (宣言が変わった例)。
    final class Narrowed: Sketch {
        @Param var number: Float = 2
        @Param var count: Int = 3
    }

    /// 範囲を宣言した `Float`。
    final class Ranged: Sketch {
        @Param(0...1) var gain: Float = 0.5
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-nonfinite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func valueOf(_ name: String, in report: [String: Any]) -> Any? {
        let entries = report["params"] as? [[String: Any]] ?? []
        return entries.first { $0["name"] as? String == name }?["value"]
    }

    // MARK: - 作者のコードからの代入 (完了条件 1)

    @Test("非有限を書いても、前の値のまま", arguments: [Float.nan, .infinity, -.infinity])
    func anAssignmentIsRefused(_ bad: Float) {
        let sketch = Tuned()
        sketch.radius = bad
        #expect(sketch.radius == 10)
        #expect(sketch.params.first { $0.name == "radius" }?.value == .float(10))
    }

    @Test("複合代入 (get → set の経路) も前の値のまま", arguments: [Float.nan, .infinity, -.infinity])
    func aCompoundAssignmentIsRefused(_ bad: Float) {
        let sketch = Tuned()
        sketch.radius += bad
        #expect(sketch.radius == 10)
        sketch.radius *= bad
        #expect(sketch.radius == 10)
    }

    /// `@Param` の展開は `get` / `set` だけを作る (`_modify` は書かない) ので、`_modify` を通るのは
    /// 置き場の `value` を直に変える書き方である。そこも同じ関所に入る。
    @Test("置き場の value を直に変える書き方 (_modify) も前の値のまま", arguments: [Float.nan, .infinity, -.infinity])
    func aModifyIsRefused(_ bad: Float) {
        let box = ParamBox<Float>(name: "radius", value: 10)
        box.value += bad
        #expect(box.value == 10)
        box.value *= bad
        #expect(box.value == 10)
        box.value = bad
        #expect(box.value == 10)
    }

    @Test("拒んだあとも、有限の値は受け取る")
    func aFiniteValueStillGoesInAfterARefusal() {
        let sketch = Tuned()
        sketch.radius = .nan
        sketch.radius = 20
        #expect(sketch.radius == 20)
        sketch.radius += 5
        #expect(sketch.radius == 25)
    }

    // MARK: - 型ごと (完了条件 3)

    @Test("Double は非有限を値ごと受け取らない", arguments: [Double.nan, .infinity, -.infinity])
    func aDoubleIsRefused(_ bad: Double) {
        let sketch = Typed()
        sketch.number = bad
        #expect(sketch.number == 2)
    }

    @Test("組と色は、成分が 1 つでも非有限なら、値ごと受け取らない")
    func aSingleBadComponentRefusesTheWholeValue() {
        let sketch = Typed()

        sketch.pair = SIMD2(5, .nan)
        #expect(sketch.pair == SIMD2(1, 2))
        sketch.pair = SIMD2(-.infinity, 5)
        #expect(sketch.pair == SIMD2(1, 2))

        // 3 つの成分のどれでも (真ん中の y でも)
        sketch.triple = SIMD3(5, 6, .infinity)
        #expect(sketch.triple == SIMD3(1, 2, 3))
        sketch.triple = SIMD3(5, .nan, 7)
        #expect(sketch.triple == SIMD3(1, 2, 3))
        sketch.triple = SIMD3(.nan, 6, 7)
        #expect(sketch.triple == SIMD3(1, 2, 3))

        // 4 つの成分のどれでも (最後の不透明度でも)
        for bad in [
            LinearRGBA(premultipliedRed: .nan, green: 0, blue: 0, alpha: 1),
            LinearRGBA(premultipliedRed: 0, green: .infinity, blue: 0, alpha: 1),
            LinearRGBA(premultipliedRed: 0, green: 0, blue: -.infinity, alpha: 1),
            LinearRGBA(premultipliedRed: 0, green: 0, blue: 0, alpha: .nan),
        ] {
            sketch.tint = bad
            #expect(sketch.tint == LinearRGBA(premultipliedRed: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        }
    }

    // MARK: - 陰性対照 (完了条件 5)

    @Test("有限の値は今までどおり素通しする。範囲の外でも、コードからの代入は締めない")
    func finiteValuesPassThrough() {
        let sketch = Ranged()
        // 範囲 (0…1) の外。コードからの代入は締めない (ADR-0030 決定 3)
        sketch.gain = 999
        #expect(sketch.gain == 999)
        sketch.gain = -3
        #expect(sketch.gain == -3)

        // 有限の端 (Float の最大・最小の正の数・負のゼロ)
        let tuned = Tuned()
        tuned.radius = .greatestFiniteMagnitude
        #expect(tuned.radius == .greatestFiniteMagnitude)
        tuned.radius = .leastNonzeroMagnitude
        #expect(tuned.radius == .leastNonzeroMagnitude)
        tuned.radius = -0.0
        #expect(tuned.radius.sign == .minus)
    }

    // MARK: - 保存と応答が止まらない (完了条件 2)

    @Test("拒んだあとも、保存は他の値を含めて書ける")
    func savingStillWorks() throws {
        let url = try makeDirectory().appendingPathComponent("params.json")
        let sketch = Tuned()
        var warnings: [String] = []
        let store = ParamStore(
            registry: ParamRegistry(of: sketch), at: url, warn: { warnings.append($0) })
        sketch.count = 5
        sketch.radius = .nan
        store.flushNow()

        #expect(store.writeCount == 1)
        #expect(warnings.isEmpty, "保存が書けなかった: \(warnings)")
        let saved = try jsonObject(at: url)
        let entries = saved["values"] as? [[String: Any]] ?? []
        #expect(entries.count == 2)
        #expect(entries.first { $0["name"] as? String == "radius" }?["value"] as? Double == 10)
        #expect(entries.first { $0["name"] as? String == "count" }?["value"] as? Int == 5)
    }

    @Test("拒んだあとも、つまみの応答は他の値を含めて置かれる")
    func theReplyIsStillPlaced() throws {
        let facet = try makeDirectory()
        let sketch = Tuned()
        sketch.count = 5
        sketch.radius = .infinity
        ParamSurface(directory: facet, sketch: sketch).start()

        let reply = try jsonObject(at: facet.appendingPathComponent("report.json"))
        #expect(valueOf("radius", in: reply) as? Double == 10)
        #expect(valueOf("count", in: reply) as? Int == 5)
    }

    // MARK: - 面からの桁あふれ (完了条件 4)

    @Test("範囲を宣言していない Float へ 1e300 を書くと、∞ を載せずに拒む")
    func anOverflowFromTheSurfaceIsRefused() throws {
        let facet = try makeDirectory()
        let sketch = Tuned()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        try #"{"id":"o1","values":[{"name":"radius","type":"float","value":1e300}]}"#.write(
            to: facet.appendingPathComponent("request.json"), atomically: true, encoding: .utf8)
        let report = try #require(surface.drain())

        #expect(sketch.radius == 10)
        #expect(report.rejected == [.init(name: "radius", reason: .notFinite)])
        #expect(report.clamped.isEmpty)
        // 応答は置かれ、読める。拒んだことが理由つきで載る
        let reply = try jsonObject(at: facet.appendingPathComponent("report.json"))
        #expect(reply["id"] as? String == "o1")
        let rejected = reply["rejected"] as? [[String: Any]] ?? []
        #expect(rejected.count == 1)
        #expect(rejected.first?["name"] as? String == "radius")
        #expect(rejected.first?["reason"] as? String == "notFinite")
        #expect(valueOf("radius", in: reply) as? Double == 10)
    }

    @Test("Float に収まる最大は受け取り、わずかに超えると拒む")
    func theFloatBoundary() throws {
        let facet = try makeDirectory()
        let sketch = Tuned()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        let largest = Double(Float.greatestFiniteMagnitude)
        try #"{"id":"b1","values":[{"name":"radius","type":"float","value":\#(largest)}]}"#.write(
            to: facet.appendingPathComponent("request.json"), atomically: true, encoding: .utf8)
        let accepted = try #require(surface.drain())
        #expect(accepted.rejected.isEmpty)
        #expect(sketch.radius == .greatestFiniteMagnitude)

        // Float の最大を超える値は、丸めると ∞ になる
        try #"{"id":"b2","values":[{"name":"radius","type":"float","value":3.5e38}]}"#.write(
            to: facet.appendingPathComponent("request.json"), atomically: true, encoding: .utf8)
        let refused = try #require(surface.drain())
        #expect(refused.rejected == [.init(name: "radius", reason: .notFinite)])
        #expect(sketch.radius == .greatestFiniteMagnitude, "拒んだら前の値のまま")
    }

    @Test("範囲を宣言した Float は、桁あふれる値を範囲の端へ収める (拒まない)")
    func aRangedFloatStillClamps() throws {
        let facet = try makeDirectory()
        let sketch = Ranged()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        try #"{"id":"c1","values":[{"name":"gain","type":"float","value":1e300}]}"#.write(
            to: facet.appendingPathComponent("request.json"), atomically: true, encoding: .utf8)
        let report = try #require(surface.drain())

        #expect(sketch.gain == 1)
        #expect(report.rejected.isEmpty)
        #expect(report.clamped.count == 1)
    }

    // MARK: - 組と色の成分の桁あふれ (面から)

    /// 要求を置いて、応えを取る。
    private func answer(_ request: String, from surface: ParamSurface, in facet: URL) throws
        -> ParamReport
    {
        try request.write(
            to: facet.appendingPathComponent("request.json"), atomically: true, encoding: .utf8)
        return try #require(surface.drain(), "要求が無言で捨てられた: \(request)")
    }

    /// `Float` で読むと `JSONDecoder` が文書ごと断り、要求が応答も警告もなしに捨てられていた。
    /// 同じ要求の他の値も入らない。**型で扱いが割れていた** (`float` の `1e300` は 1 件だけ拒まれる)。
    @Test("組の成分が Float に収まらなければ、その値だけを拒み、同じ要求の他の値は入る", arguments: [
        (#"{"type":"vec2","value":[1e300,0]}"#, "pair"),
        (#"{"type":"vec2","value":[0,-1e39]}"#, "pair"),
        (#"{"type":"vec3","value":[0,0,1e39]}"#, "triple"),
        (#"{"type":"color","value":{"red":1e300,"green":0,"blue":0,"alpha":1}}"#, "tint"),
        (#"{"type":"color","value":{"red":0,"green":0,"blue":0,"alpha":-1e39}}"#, "tint"),
    ])
    func aComponentOverflowIsRefusedAlone(wire: String, name: String) throws {
        let facet = try makeDirectory()
        let sketch = Typed()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        let report = try answer(
            #"{"id":"w1","values":[{"name":"count","type":"int","value":7},{"name":"\#(name)",\#(wire.dropFirst())]}"#,
            from: surface, in: facet)

        #expect(report.rejected == [.init(name: name, reason: .notFinite)])
        #expect(sketch.count == 7, "同じ要求の他の値は入る")
        #expect(sketch.pair == SIMD2(1, 2))
        #expect(sketch.triple == SIMD3(1, 2, 3))
        #expect(sketch.tint == LinearRGBA(premultipliedRed: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        // 応答は置かれ、要求の識別子を echo する
        let reply = try jsonObject(at: facet.appendingPathComponent("report.json"))
        #expect(reply["id"] as? String == "w1")
    }

    @Test("組と色の成分が Float の最大なら、受け取る")
    func theLargestFloatComponentIsAccepted() throws {
        let facet = try makeDirectory()
        let sketch = Typed()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        let report = try answer(
            #"{"id":"w2","values":[{"name":"pair","type":"vec2","value":[3.4028235e38,-3.4028235e38]},{"name":"tint","type":"color","value":{"red":3.4028235e38,"green":0,"blue":0,"alpha":1}}]}"#,
            from: surface, in: facet)

        #expect(report.rejected.isEmpty)
        #expect(sketch.pair == SIMD2(.greatestFiniteMagnitude, -.greatestFiniteMagnitude))
        #expect(sketch.tint.red == .greatestFiniteMagnitude)
    }

    @Test("保存の組の成分が Float に収まらなければ、その値だけを捨て、他の値は戻す")
    func anOverflowingSavedComponentIsDiscardedAlone() throws {
        let url = try makeDirectory().appendingPathComponent("params.json")
        try #"{"schemaVersion":1,"values":[{"name":"pair","type":"vec2","value":[1e300,0]},{"name":"count","type":"int","value":7}]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let sketch = Typed()
        var warnings: [String] = []
        let restoration = ParamStore(
            registry: ParamRegistry(of: sketch), at: url, warn: { warnings.append($0) }
        ).restore()

        #expect(restoration.discarded == [.init(name: "pair", reason: .notFinite)])
        #expect(sketch.count == 7, "保存の他の値は戻る")
        #expect(sketch.pair == SIMD2(1, 2))
        #expect(warnings.count == 1 && warnings[0].contains("pair"), "読めない保存として丸ごと捨てた: \(warnings)")
    }

    // MARK: - 保存からの復元 (面と同じ口)

    @Test("保存に Float へ桁あふれする値があれば、捨てて既定のまま")
    func anOverflowingSavedValueIsDiscarded() throws {
        let url = try makeDirectory().appendingPathComponent("params.json")
        try #"{"schemaVersion":1,"values":[{"name":"radius","type":"float","value":1e300},{"name":"count","type":"int","value":7}]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let sketch = Tuned()
        let restoration = ParamStore(
            registry: ParamRegistry(of: sketch), at: url, warn: { _ in }
        ).restore()

        #expect(sketch.radius == 10)
        #expect(sketch.count == 7, "他の値は戻る")
        #expect(restoration.discarded == [.init(name: "radius", reason: .notFinite)])
        #expect(restoration.clamped.isEmpty)
    }

    /// 保存はこのライブラリが書くので、有限の数しか入っていない。復元で `notFinite` が出る現実の
    /// 経路は、`Double` で宣言していた値を `Float` へ変えたとき (どちらも `float` を名乗るので
    /// 型の違いにはならない)。宣言が変わったケースなので、そう言う。
    @Test("Double で宣言していた値を Float へ変えると、桁あふれる保存は捨てられ、宣言が変わったと言う")
    func aNarrowedDeclarationDiscardsAnOverflowingValue() async throws {
        final class Wide: Sketch {
            @Param var number: Double = 2
            @Param var count: Int = 3
        }
        let url = try makeDirectory().appendingPathComponent("params.json")
        let wide = Wide()
        let saving = ParamStore(registry: ParamRegistry(of: wide), at: url, warn: { _ in })
        wide.number = 1e300
        wide.count = 7
        saving.flushNow()
        #expect(saving.writeCount == 1)

        let narrowed = Narrowed()
        var warnings: [String] = []
        let restoration = ParamStore(
            registry: ParamRegistry(of: narrowed), at: url, warn: { warnings.append($0) }
        ).restore()

        #expect(restoration.discarded == [.init(name: "number", reason: .notFinite)])
        #expect(narrowed.number == 2, "既定のまま")
        #expect(narrowed.count == 7)
        let line = try #require(warnings.first, "捨てたのに黙っていた")
        #expect(warnings.count == 1)
        #expect(line.contains("number"))
        #expect(line.contains("not a finite number"))
        #expect(line.contains("The declarations have changed"), "宣言が変わったケースである: \(line)")
    }

    // MARK: - 名乗り

    /// 毎フレーム書かれうる (`draw()` に書いた `radius = .nan`) ので、1 度だけ言う。標準エラーへ
    /// 実際に出た行は検査から読めないので、言った文面の控え (``WarningLog``) を読む。
    @Test("拒んだことを、名前・渡した値・保っている値を含めて 1 度だけ名乗る")
    func aRefusalIsSaidOnce() throws {
        let sketch = Tuned()
        let box = try #require(ParamRegistry(of: sketch).knobs.first as? ParamBox<Float>)
        #expect(!box.warnings.hasWarned(.notFinite), "何も書いていないのに名乗った")

        sketch.radius = .nan
        let first = try #require(box.warnings.message(for: .notFinite), "拒んだのに黙っていた")
        #expect(first.contains("radius"))
        #expect(first.contains("nan"))
        #expect(first.contains("10.0"), "保っている値を言わない: \(first)")
        #expect(!first.contains("\n"))

        // 2 度目からは言わない (別の非有限でも、複合代入でも)
        sketch.radius = .infinity
        sketch.radius += .nan
        box.value *= .infinity
        #expect(box.warnings.message(for: .notFinite) == first)
        #expect(box.warnings.count(where: { _ in true }) == 1)
    }

    @Test("置き場の value を直に変える書き方 (_modify) も、拒んだことを名乗る")
    func aModifyIsSaid() throws {
        let box = ParamBox<Float>(name: "radius", value: 10)
        box.value += .nan
        let line = try #require(box.warnings.message(for: .notFinite), "拒んだのに黙っていた")
        #expect(line.contains("radius"))
        #expect(line.contains("nan"))
        #expect(line.contains("10.0"), "戻した値を言う: \(line)")
    }

    @Test("組と色も、渡した値を名乗る")
    func aTupleIsNamedWithItsValue() throws {
        let sketch = Typed()
        let registry = ParamRegistry(of: sketch)
        let pair = try #require(registry.knobs.first { $0.declaration.name == "pair" } as? ParamBox<SIMD2<Float>>)
        sketch.pair = SIMD2(5, .nan)
        let line = try #require(pair.warnings.message(for: .notFinite))
        #expect(line.contains("pair"))
        #expect(line.contains("nan"))
    }

    @Test("有限の値は、範囲の外でも、何も名乗らない")
    func finiteValuesAreNotSaid() throws {
        let sketch = Ranged()
        let box = try #require(ParamRegistry(of: sketch).knobs.first as? ParamBox<Float>)
        sketch.gain = 999
        sketch.gain += 1
        box.value -= 1_000
        box.value = .greatestFiniteMagnitude
        #expect(!box.warnings.hasWarned(.notFinite))
    }

    /// 値が動いていないので、見ている側 (窓・保存) を起こさない。
    @Test("拒んだ代入は、変化として通知しない")
    func aRefusalDoesNotNotify() {
        let sketch = Tuned()
        let notified = Notice()
        withObservationTracking {
            _ = sketch.radius
        } onChange: {
            notified.fire()
        }
        sketch.radius = .nan
        #expect(!notified.fired)
        // 有限の値は通知する (見張りが死んでいないことの対照)
        sketch.radius = 11
        #expect(notified.fired)
    }

    /// `_modify` は yield の前に willSet を打つ形だと、拒んでも見張りの印が立ち、値の変わらない
    /// 応答が版を進めて書き直される。拒むときは通知を出さない。
    @Test("置き場の value を直に変える書き方 (_modify) も、拒んだときは変化として通知しない")
    func aRefusedModifyDoesNotNotify() {
        let box = ParamBox<Float>(name: "radius", value: 10)
        let notified = Notice()
        withObservationTracking {
            _ = box.value
        } onChange: {
            notified.fire()
        }
        box.value += .nan
        #expect(box.value == 10)
        #expect(!notified.fired)
        // 有限の値は通知する (見張りが死んでいないことの対照)
        box.value += 1
        #expect(box.value == 11)
        #expect(notified.fired)
    }

    /// 見張りの印が立たなければ、値が変わっていない応答を書き直さない (版が進まない)。
    @Test("拒んだ _modify は、つまみの応答を書き直させない")
    func aRefusedModifyDoesNotRewriteTheReply() async throws {
        let facet = try makeDirectory()
        let sketch = Tuned()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()
        let box = try #require(ParamRegistry(of: sketch).knobs.first as? ParamBox<Float>)
        // 譲るループ (窓) の形で回す。知らせは譲らなくても届く (#1704)
        await Task.yield()
        #expect(surface.drain() == nil)

        box.value += .nan
        await Task.yield()
        #expect(surface.drain() == nil, "値が変わらないのに応答を書き直した")

        // 有限の値なら書き直す (対照)
        box.value += 1
        await Task.yield()
        #expect(surface.drain() != nil)
    }

    // MARK: - 面からの書き込みを受ける口 (ParamBox.write)

    @Test("面から来た非有限は、範囲へ収めずに拒み、前の値のまま")
    func writeRefusesBeforeClamping() {
        let box = ParamBox<Double>(name: "x", value: 1, range: ParamRange(0...10))
        // 無限を範囲の端へ収めると、応答の clamped に無限が載って符号化できなくなる
        #expect(box.write(.float(.infinity)) == .notFinite)
        #expect(box.write(.float(-.infinity)) == .notFinite)
        #expect(box.write(.float(.nan)) == .notFinite)
        #expect(box.value == 1)
        // 有限は範囲へ収める (陰性対照)
        #expect(box.write(.float(999)) == .clamped(requested: .float(999), applied: .float(10)))
        #expect(box.value == 10)
        #expect(box.write(.float(5)) == .applied)
        #expect(box.value == 5)
    }

    @Test("面から来た組と色も、成分の 1 つが非有限なら値ごと拒む")
    func writeRefusesATupleWithABadComponent() {
        let pair = ParamBox<SIMD2<Float>>(name: "p", value: SIMD2(1, 2), range: ParamRange(0...10))
        #expect(pair.write(.vector2(SIMD2(3, .nan))) == .notFinite)
        #expect(pair.value == SIMD2(1, 2))

        let triple = ParamBox<SIMD3<Float>>(name: "t", value: SIMD3(1, 2, 3))
        #expect(triple.write(.vector3(SIMD3(3, 4, .infinity))) == .notFinite)
        #expect(triple.value == SIMD3(1, 2, 3))

        let ink = LinearRGBA(premultipliedRed: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        let tint = ParamBox<LinearRGBA>(name: "c", value: ink)
        #expect(
            tint.write(.color(LinearRGBA(premultipliedRed: 0, green: 0, blue: 0, alpha: .nan)))
                == .notFinite)
        #expect(tint.value == ink)
    }

    @Test("型が違えば、非有限であっても型の違いと答える")
    func aTypeMismatchComesFirst() {
        let count = ParamBox<Int>(name: "n", value: 3)
        #expect(count.write(.float(.nan)) == .typeMismatch)
        #expect(count.value == 3)
    }
}
