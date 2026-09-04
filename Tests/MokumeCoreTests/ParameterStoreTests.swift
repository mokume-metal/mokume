// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore
@testable import mokume

/// 合わせた値が、次に起動したときも残ること。
///
/// 置き場は `.mokume/state/params.json` で、**やりとりの区画とは別**である
/// ([ADR-0030](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md) 決定 6)。
/// 区画は「利用者が作ったときだけ有効」で成り立っているので、既定で効く保存が区画を
/// 作ると、頼んでいない外からの操作まで有効になってしまう。
@Suite("合わせた値が次の起動にも残る")
@MainActor
struct ParameterStoreTests {
    final class Knobbed: Sketch {
        @Param(0...200) var radius: Double = 80
        @Param(1...8) var count: Int = 3
        @Param var spinning: Bool = true
        @Param(choices: ["circle", "square"]) var shape: String = "circle"
    }

    /// 宣言を変えたあとのスケッチ。`radius` は型が変わり、`count` は消え、
    /// `shape` は候補が減った。
    final class Renamed: Sketch {
        @Param(choices: ["ring", "arc"]) var shape: String = "ring"
        @Param(0...8) var radius: Int = 4
        @Param var spinning: Bool = true
    }

    private func makeFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("params.json")
    }

    private func store(for sketch: any Sketch, at url: URL) -> ParamStore {
        ParamStore(registry: ParamRegistry(of: sketch), at: url)
    }

    /// 静かになるまで進める。
    private func settle(_ store: ParamStore) async {
        // 値が変わった知らせは隔離をまたいで届くので、フレームを進める前に受け取らせる
        await Task.yield()
        for _ in 0...ParamStore.quietFrames { store.tick() }
    }

    // MARK: - 往復

    @Test("動かした値が、次の起動で戻る")
    func valuesComeBack() async throws {
        let url = try makeFile()
        let first = Knobbed()
        let saving = store(for: first, at: url)
        saving.restore()
        first.radius = 120
        first.shape = "square"
        await settle(saving)
        #expect(saving.writeCount == 1)

        let second = Knobbed()
        store(for: second, at: url).restore()
        #expect(second.radius == 120)
        #expect(second.shape == "square")
        #expect(second.count == 3)
    }

    @Test("保存が無ければ、既定値のまま静かに始まる")
    func noSavedValuesIsNotAFailure() throws {
        let sketch = Knobbed()
        let restoration = store(for: sketch, at: try makeFile()).restore()
        #expect(restoration.isEmpty)
        #expect(sketch.radius == 80)
    }

    @Test("宣言が 1 つも無いスケッチには、保存を持たせない")
    func sketchesWithoutParamsGetNoStore() {
        final class Plain: Sketch {}
        #expect(ParamStore.makeIfNeeded(for: ParamRegistry(of: Plain())) == nil)
    }

    // MARK: - 合わなくなった値

    /// **名前と型の一致だけを採用の条件にする** (ADR-0030 決定 6)。それ以外の救済
    /// (型を変換して救う、など) を入れると、絵が理由なく変わる経路が増える。
    @Test("宣言を変えると、合わなくなった値は捨てられる")
    func mismatchedValuesAreDiscarded() async throws {
        let url = try makeFile()
        let before = Knobbed()
        let saving = store(for: before, at: url)
        saving.restore()
        before.radius = 120
        before.count = 5
        before.shape = "square"
        await settle(saving)

        let after = Renamed()
        let restoration = store(for: after, at: url).restore()

        #expect(
            restoration.discarded == [
                .init(name: "count", reason: .unknownName),
                .init(name: "radius", reason: .typeMismatch),
                .init(name: "shape", reason: .notInChoices),
            ])
        // 捨てた値は既定のまま。合う型のものだけが戻る
        #expect(after.radius == 4)
        #expect(after.shape == "ring")
        #expect(after.spinning == true)
    }

    /// **捨てたことを黙らない。** 文言の組み立ては純関数なので、ここから読める。
    @Test("捨てたことは、名前と理由を添えて言う")
    func discardsAreAnnounced() {
        let notice = ParamStore.notice(for: [
            .init(name: "count", reason: .unknownName),
            .init(name: "radius", reason: .typeMismatch),
        ])
        let line = try! #require(notice)
        #expect(line.contains("count"))
        #expect(line.contains("radius"))
        #expect(line.contains("もう宣言されていない"))
        #expect(line.contains("宣言と型が違う"))
        #expect(line.contains("2 個"))
    }

    @Test("捨てていなければ、何も言わない")
    func nothingDiscardedSaysNothing() {
        #expect(ParamStore.notice(for: []) == nil)
    }

    /// 範囲が縮んだときは捨てずに収める。**収めたことは黙らない** (ADR-0030 決定 3)。
    @Test("範囲が縮んだ値は、収めたうえで収めたことを返す")
    func narrowedRangesClampAndSaySo() async throws {
        final class Wide: Sketch {
            @Param(0...200) var radius: Double = 80
        }
        final class Narrow: Sketch {
            @Param(0...100) var radius: Double = 50
        }
        let url = try makeFile()
        let wide = Wide()
        let saving = store(for: wide, at: url)
        saving.restore()
        wide.radius = 180
        await settle(saving)

        let narrow = Narrow()
        let restoration = store(for: narrow, at: url).restore()
        #expect(restoration.discarded.isEmpty)
        #expect(restoration.clamped == [.init(name: "radius", requested: 180, value: 100)])
        #expect(narrow.radius == 100)
    }

    @Test("読めない保存は捨てて、既定値で始まる")
    func unreadableSavedValuesFallBackToDefaults() throws {
        let url = try makeFile()
        try "これは JSON ではない".write(to: url, atomically: true, encoding: .utf8)
        let sketch = Knobbed()
        let restoration = store(for: sketch, at: url).restore()
        #expect(restoration.isEmpty)
        #expect(sketch.radius == 80)
    }

    // MARK: - いつ書くか

    /// **つまみを引いている最中に毎フレーム書かない** (ADR-0030 決定 6)。
    @Test("続けて動かしても、書くのは静かになってから 1 回")
    func consecutiveChangesAreWrittenOnce() async throws {
        let url = try makeFile()
        let sketch = Knobbed()
        let saving = store(for: sketch, at: url)
        saving.restore()

        for step in 1...10 {
            sketch.radius = Double(step * 10)
            await Task.yield()
            saving.tick()
        }
        #expect(saving.writeCount == 0, "引いている最中に書いている")

        await settle(saving)
        #expect(saving.writeCount == 1)
    }

    @Test("動かさなければ、フレームが進んでも書かない")
    func quietFramesWriteNothing() throws {
        let saving = store(for: Knobbed(), at: try makeFile())
        saving.restore()
        for _ in 0..<(ParamStore.quietFrames * 3) { saving.tick() }
        #expect(saving.writeCount == 0)
    }

    /// 外から書いた側は反映を見に来るので、**静かになるのを待たせない** (決定 6)。
    @Test("外からの書き込みは、待たずにその場で保存される")
    func externalWritesAreSavedImmediately() throws {
        let url = try makeFile()
        let facet = url.deletingLastPathComponent().appendingPathComponent("params", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)

        let sketch = Knobbed()
        let registry = ParamRegistry(of: sketch)
        let saving = ParamStore(registry: registry, at: url)
        saving.restore()
        let surface = ParamSurface(directory: facet, registry: registry, store: saving)
        surface.start()

        try #"{"id":"a1","values":[{"name":"radius","type":"float","value":150}]}"#
            .write(to: facet.appendingPathComponent("request.json"), atomically: true, encoding: .utf8)
        surface.drain()

        // フレームを 1 つも進めずに保存されている
        #expect(saving.writeCount == 1)
        let restored = Knobbed()
        ParamStore(registry: ParamRegistry(of: restored), at: url).restore()
        #expect(restored.radius == 150)
    }

    /// 終わるときに落とすと、**引いたつまみの最後の 1 手だけが消える**。
    @Test("まとめている途中で終わっても、書き落とさない")
    func pendingChangesAreFlushedOnClose() async throws {
        let url = try makeFile()
        let sketch = Knobbed()
        let saving = store(for: sketch, at: url)
        saving.restore()
        sketch.radius = 111
        await Task.yield()
        saving.tick()
        #expect(saving.writeCount == 0)

        saving.flushIfPending()
        #expect(saving.writeCount == 1)

        let restored = Knobbed()
        store(for: restored, at: url).restore()
        #expect(restored.radius == 111)
    }

    // MARK: - 書き方

    /// **読み手が書きかけを掴むと、合わせた値がまとめて既定へ戻る** (ADR-0018 決定 3)。
    ///
    /// 見るのは**置き換わったかどうか**である。隣に作ったものを `rename` で持ってくると
    /// ファイルの背番号 (inode) が変わり、いま在るファイルへ上書きすると変わらない —
    /// つまり背番号が動いていれば、読み手が見るのは「前の内容」か「新しい内容」の
    /// どちらかでしかない。書きかけを掴む瞬間を検査から狙うことはできないので、
    /// **狙わずに済む書き方であること**を見る。
    @Test("書き込みは原子的で、書きかけを残さない")
    func writesAreAtomic() async throws {
        let url = try makeFile()
        let sketch = Knobbed()
        let saving = store(for: sketch, at: url)
        saving.restore()

        var identifiers: Set<UInt64> = []
        for step in 1...5 {
            sketch.radius = Double(step)
            await settle(saving)
            // どの時点で読んでも、読めるのは丸ごと 1 つの姿である
            let data = try Data(contentsOf: url)
            #expect(try JSONSerialization.jsonObject(with: data) as? [String: Any] != nil)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            identifiers.insert(attributes[.systemFileNumber] as? UInt64 ?? 0)
        }
        #expect(identifiers.count == 5, "同じファイルへ上書きしている (置き換えていない)")

        let left = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path)
        #expect(left == ["params.json"], "書きかけのファイルが残っている: \(left)")
    }

    @Test("7 つの型が、どれも往復する")
    func everyTypeSurvivesTheRoundTrip() async throws {
        final class Every: Sketch {
            @Param(0...10) var number: Double = 1
            @Param(0...10) var whole: Int = 2
            @Param var flag: Bool = false
            @Param(choices: ["a", "b"]) var word: String = "a"
            @Param var tint: LinearRGBA = .linear(red: 0.1, green: 0.2, blue: 0.3)
            @Param(-1...1) var pair: SIMD2<Float> = SIMD2(0, 0)
            @Param(-1...1) var triple: SIMD3<Float> = SIMD3(0, 0, 0)
        }
        let url = try makeFile()
        let before = Every()
        let saving = store(for: before, at: url)
        saving.restore()
        before.number = 3.5
        before.whole = 7
        before.flag = true
        before.word = "b"
        before.tint = .linear(red: 0.4, green: 0.5, blue: 0.6)
        before.pair = SIMD2(0.25, -0.5)
        before.triple = SIMD3(0.1, 0.2, 0.3)
        await settle(saving)

        let after = Every()
        store(for: after, at: url).restore()
        #expect(after.number == 3.5)
        #expect(after.whole == 7)
        #expect(after.flag == true)
        #expect(after.word == "b")
        #expect(after.tint == .linear(red: 0.4, green: 0.5, blue: 0.6))
        #expect(after.pair == SIMD2(0.25, -0.5))
        #expect(after.triple == SIMD3(0.1, 0.2, 0.3))
    }

    /// 保存は区画ではない。**保存したことで、外からの操作が有効にならない。**
    @Test("保存しても、やりとりの区画は作られない")
    func savingDoesNotOpenTheExchangeFacet() async throws {
        let url = try makeFile()
        let root = url.deletingLastPathComponent()
        let sketch = Knobbed()
        let saving = store(for: sketch, at: url)
        saving.restore()
        sketch.radius = 99
        await settle(saving)

        let facet = root.appendingPathComponent("params", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: facet.path))
        #expect(ParamSurface.makeIfEnabled(for: ParamRegistry(of: sketch), at: facet) == nil)
    }

    /// 捨てたことは診断だけでなく**応答にも出る** (決定 6)。端末を見ていない読み手が
    /// 「なぜ既定値なのか」を知る手段がこれしかない。
    @Test("捨てたことは、最初の応答にも載る")
    func discardsAppearInTheFirstReport() async throws {
        let url = try makeFile()
        let facet = url.deletingLastPathComponent().appendingPathComponent("params", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)

        let before = Knobbed()
        let saving = store(for: before, at: url)
        saving.restore()
        before.count = 5
        await settle(saving)

        let after = Renamed()
        let registry = ParamRegistry(of: after)
        let restoration = ParamStore(registry: registry, at: url).restore()
        ParamSurface(directory: facet, registry: registry).start(after: restoration)

        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let discarded = report["discarded"] as? [[String: Any]] ?? []
        #expect(discarded.contains { $0["name"] as? String == "count" })
        #expect(discarded.contains { $0["reason"] as? String == "unknownName" })
    }
}

/// 復元が **`setup()` より先**に起きること (ADR-0030 決定 6)。
///
/// ここだけ走らせるスケッチが要るので GPU を使う。順序が逆だと、`setup()` で組み立てた
/// ものが復元前の値で作られ、**絵は復元後の値で描かれる**という食い違いが出る。
@Suite(
    "復元は setup より先",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct ParameterStoreRuntimeTests {
    final class Recorder: Sketch {
        var settings = SketchSettings(width: 8, height: 8, frameRate: 60)
        @Param(0...200) var radius: Double = 80
        var seenInSetup: Double?
        var seenInDraw: Double?

        init() {}
        func setup() { seenInSetup = radius }
        func draw() {
            seenInDraw = radius
            background(.linear(red: 0, green: 0, blue: 0))
        }
    }

    @Test("setup も最初の draw も、復元された値を見る")
    func setupSeesTheRestoredValue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("params.json")

        // 前回の実行に相当するもの
        let before = Recorder()
        let saving = ParamStore(registry: ParamRegistry(of: before), at: url)
        saving.restore()
        before.radius = 150
        await Task.yield()
        saving.flushIfPending()

        // 次の起動
        let after = Recorder()
        let runtime = try SketchRuntime(
            sketch: after, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            paramStore: ParamStore(registry: ParamRegistry(of: after), at: url))
        try runtime.advance()

        #expect(after.seenInSetup == 150)
        #expect(after.seenInDraw == 150)
    }
}
