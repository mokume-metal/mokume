// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 値として持てる乱数源 ``RandomSource`` (#2418)。
///
/// **種の無い `init()` は置かない** — `RandomSource()` はコンパイルが通らない (リプレイの再現・#2603)。
/// それは型の宣言で守っていて、実行時の検査では書けない。
@Suite("値として持てる乱数源")
struct RandomSourceTests {
    private func draws(_ source: inout RandomSource, count: Int = 1000) -> [Float] {
        (0..<count).map { _ in Float.random(in: 0..<1, using: &source) }
    }

    /// 2 つの列の相関係数 (ピアソン)。
    private func correlation(_ a: [Float], _ b: [Float]) -> Double {
        let n = Double(a.count)
        let meanA = a.reduce(0) { $0 + Double($1) } / n
        let meanB = b.reduce(0) { $0 + Double($1) } / n
        var covariance = 0.0
        var varianceA = 0.0
        var varianceB = 0.0
        for (x, y) in zip(a, b) {
            let dx = Double(x) - meanA
            let dy = Double(y) - meanB
            covariance += dx * dy
            varianceA += dx * dx
            varianceB += dy * dy
        }
        return covariance / (varianceA * varianceB).squareRoot()
    }

    // MARK: - 完了条件 4: 同じ種から同じ列

    @Test("同じ種から作った 2 つの乱数源は、Float.random(in:using:) を 1,000 回引いて同じ列になる")
    func theSameSeedGivesTheSameSequence() {
        var first = RandomSource(seed: 20260829)
        var second = RandomSource(seed: 20260829)
        let a = draws(&first)
        let b = draws(&second)
        #expect(a == b)
        #expect(Set(a).count > 900, "列が縮退している")
        #expect(a.allSatisfy { $0 >= 0 && $0 < 1 })
    }

    @Test("種が違えば列が違い、写した後は別々に進む")
    func differentSeedsDifferAndCopiesDiverge() {
        var one = RandomSource(seed: 1)
        var two = RandomSource(seed: 2)
        #expect(draws(&one, count: 16) != draws(&two, count: 16))

        var original = RandomSource(seed: 5)
        var copy = original
        _ = original.next()
        #expect(copy.next() != original.next(), "写しが元と同じ位置から進んでいる")
    }

    @Test("init(seed:index:) は、番号が違えば別の列で、隣り合う種とも入れ替えとも重ならない")
    func indexedStreamsAreDistinct() {
        var streams: [[UInt64]] = []
        for (seed, index) in [(7, 0), (7, 1), (7, 2), (8, 0), (0, 7), (1, 0), (0, 1), (-7, 1), (7, -1)] {
            var source = RandomSource(seed: seed, index: index)
            streams.append((0..<8).map { _ in source.next() })
        }
        #expect(Set(streams.map { $0[0] }).count == streams.count, "先頭の値が重なった組がある")
        // 「種 + 番号」を足しただけの作り方だと (7, 1) と (8, 0) が同じ列になる
        var a = RandomSource(seed: 7, index: 1)
        var b = RandomSource(seed: 8, index: 0)
        #expect(a.next() != b.next())
    }

    @Test("隣り合う番号の列・隣り合う種の列は、相関しない")
    func neighbouringStreamsAreUncorrelated() {
        // 連番の種どうしで「ほとんど揃った」列を踏んだ記録 (Pond) を、隣り合う番号と種で見る
        for index in 0..<20 {
            var left = RandomSource(seed: 7, index: index)
            var right = RandomSource(seed: 7, index: index + 1)
            let r = correlation(draws(&left), draws(&right))
            #expect(abs(r) < 0.15, "番号 \(index) と \(index + 1) の相関 \(r)")
        }
        for seed in 0..<20 {
            var left = RandomSource(seed: seed, index: 3)
            var right = RandomSource(seed: seed + 1, index: 3)
            let r = correlation(draws(&left), draws(&right))
            #expect(abs(r) < 0.15, "種 \(seed) と \(seed + 1) の相関 \(r)")
        }
    }

    @Test("番号の列は、他の番号を先に引いたかに依らない")
    func anIndexedStreamDoesNotDependOnTheOthers() {
        var alone = RandomSource(seed: 7, index: 12)
        let expected = draws(&alone, count: 32)
        for index in 0..<12 {
            var other = RandomSource(seed: 7, index: index)
            _ = draws(&other, count: 50)
        }
        var again = RandomSource(seed: 7, index: 12)
        #expect(draws(&again, count: 32) == expected)
    }

    // MARK: - 完了条件 5: Swift 標準の口で引ける

    @Test("randomElement(using:)・shuffled(using:)・Float.random(in:using:) が種に従う")
    func standardLibraryCallsFollowTheSeed() {
        let palette = Array(0..<20)
        func pick(_ seed: Int) -> (element: Int?, shuffled: [Int], value: Float) {
            var r = RandomSource(seed: seed)
            return (
                palette.randomElement(using: &r), palette.shuffled(using: &r),
                Float.random(in: -1...1, using: &r)
            )
        }
        let first = pick(11)
        let again = pick(11)
        #expect(first.element == again.element)
        #expect(first.shuffled == again.shuffled)
        #expect(first.value == again.value)
        #expect(first.shuffled != palette, "並べ替えていない")
        #expect(first.shuffled.sorted() == palette, "要素が欠けた・増えた")
        #expect(first.shuffled != pick(12).shuffled)
        #expect(first.value >= -1 && first.value <= 1)
    }

    @Test("中身はスケッチの乱数と同じ生成器で、同じ種から同じ 64 ビットの列を出す")
    func itIsTheSketchsGenerator() {
        var source = RandomSource(seed: 42)
        var line = Randomness(seed: 42)
        for _ in 0..<16 { #expect(source.next() == line.next()) }
    }
}

/// スケッチの列を乱数源として出す ``SketchPart/randomSource``。走っているランタイムが要るので、GPU を使う。
@Suite(
    "スケッチの列としての randomSource",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SketchRandomSourceTests {
    enum Phase: CaseIterable, CustomTestStringConvertible {
        case setup
        case draw

        var testDescription: String { self == .setup ? "setup()" : "draw()" }
    }

    /// 台本を `setup()` か最初の `draw()` の中で 1 度だけ走らせるスケッチ。
    final class Probe: Sketch {
        var settings = SketchSettings(width: 16, height: 16)
        var phase = Phase.draw
        var script: ((Probe) -> Void)?

        init() {}
        func setup() { if phase == .setup { script?(self) } }
        func draw() { if phase == .draw { script?(self) } }
    }

    private func run(_ phase: Phase, _ script: @escaping (Probe) -> Void) throws {
        let probe = Probe()
        probe.phase = phase
        probe.script = script
        let runtime = try SketchRuntime(sketch: probe, gpu: try RenderDevice())
        runtime.start()
        try runtime.advance()
    }

    /// 種 `seed` の列の `count` 番目 (1 から数える)。実行の外で直に引く。
    private func value(seed: Int, at count: Int) -> Float {
        var line = Randomness(seed: seed)
        var last: Float = 0
        for _ in 0..<count { last = line.unitValue() }
        return last
    }

    @Test("randomSeed の後の randomSource は、その種の列から始まる", arguments: Phase.allCases)
    func theSourceStartsFromTheSeed(phase: Phase) throws {
        var first: UInt64 = 0
        try run(phase) { probe in
            probe.randomSeed(42)
            var source = probe.randomSource
            first = source.next()
        }
        var line = Randomness(seed: 42)
        #expect(first == line.next())
    }

    @Test(
        "using: &randomSource で引くと、random() と同じ 1 本の列を進める。randomSeed で同じ並びに戻る",
        arguments: Phase.allCases)
    func drawingThroughTheSourceAdvancesTheSketchsLine(phase: Phase) throws {
        let palette = Array(0..<50)
        var shuffledOnce: [Int] = []
        var shuffledAgain: [Int] = []
        var afterShuffle: Float = -1
        var restoredPick: Int?
        var firstPick: Int?
        try run(phase) { probe in
            probe.randomSeed(7)
            shuffledOnce = palette.shuffled(using: &probe.randomSource)
            afterShuffle = probe.random()
            // 同じ種へ戻せば、同じ並びに戻る
            probe.randomSeed(7)
            shuffledAgain = palette.shuffled(using: &probe.randomSource)
            // 引いた分だけ列が進んでいる (種を置き直すまで、次の選びは違う列から)
            probe.randomSeed(9)
            firstPick = palette.randomElement(using: &probe.randomSource)
            probe.randomSeed(9)
            _ = probe.random()
            restoredPick = palette.randomElement(using: &probe.randomSource)
        }
        #expect(shuffledOnce == shuffledAgain, "randomSeed で同じ並びに戻らない")
        #expect(shuffledOnce != palette)
        // 列は進んでいる: 直後の random() は、種 7 の列の最初の値ではない
        #expect(afterShuffle != value(seed: 7, at: 1), "using: &randomSource で引いたのに列が進んでいない")
        // 同じ種でも、先に random() を 1 つ引いた分、選びが変わりうる (列が 1 本であることを、
        // 値の一致ではなく「進んだ分ずれる」で見る)
        var line = Randomness(seed: 9)
        var source = RandomSource(core: line, origin: .max)
        #expect(firstPick == palette.randomElement(using: &source), "取り出して・進めて・戻すのが、列と食い違う")
        _ = line.unitValue()
        var shifted = RandomSource(core: line, origin: .max)
        #expect(restoredPick == palette.randomElement(using: &shifted), "random() を引いた分だけ列が進んでいない")
    }

    @Test("randomSource の next() は、random() と同じ 1 本の列の次の値になる", arguments: Phase.allCases)
    func nextOnTheSourceIsTheNextOfTheSketchsLine(phase: Phase) throws {
        var after: Float = -1
        try run(phase) { probe in
            probe.randomSeed(7)
            _ = probe.randomSource.next()
            after = probe.random()
        }
        #expect(after == value(seed: 7, at: 2), "next() の 1 つぶんが、スケッチの列に数えられていない")
    }

    @Test("乱数源を代入すると、種を書いたのと同じ列になる", arguments: Phase.allCases)
    func assigningASourceWritesTheSeed(phase: Phase) throws {
        var after: Float = -1
        try run(phase) { probe in
            probe.randomSeed(1)
            probe.randomSource = RandomSource(seed: 5)
            after = probe.random()
        }
        #expect(after == value(seed: 5, at: 1))
    }

    @Test("形の組み立ての中で書いた乱数源は抜けると外へ残らない。引くだけなら列を進める", arguments: Phase.allCases)
    func aSourceWrittenInsideAnAssemblyDoesNotLeak(phase: Phase) throws {
        var afterWrite: Float = -1
        var afterDraw: Float = -1
        var insideBuilt = false
        try run(phase) { probe in
            probe.randomSeed(1)
            // 組み立ての中で、新しい乱数源を代入する (種を書くのと同じ)
            _ = probe.createShape {
                probe.randomSource = RandomSource(seed: 42)
                insideBuilt = probe.random() == value(seed: 42, at: 1)
            }
            afterWrite = probe.random()
            // 引くだけなら、外の列を進める (戻さない)
            probe.randomSeed(2)
            _ = probe.createShape { _ = probe.randomSource.next() }
            afterDraw = probe.random()
        }
        #expect(insideBuilt, "組み立ての中で、代入した乱数源の列から引けていない")
        #expect(afterWrite == value(seed: 1, at: 1), "外の列が、中で代入した乱数源の列から続いている")
        #expect(afterDraw == value(seed: 2, at: 2), "中で引いた 1 つぶんが、外の列に数えられていない")
    }
}
