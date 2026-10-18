// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 正規分布・配列から選ぶ・並べ替えが、種から同じ列で引かれることを見る ([#2419])。
///
/// 列の上の計算は ``Randomness`` が持つので、ここは GPU 無しで回る。作者の口 (``SketchPart/randomGaussian()``
/// など) がランタイムの同じ列から引くことは ``RandomPickSketchTests`` が見る。
///
/// **種は 3 に固定する** (Issue の完了条件の綴り)。種が固定なので結果は決定的で、偶然で落ちる
/// ことはない。平均と標準偏差の幅 (±0.05) は 1e4 回の標本の標準誤差 (平均で 0.01・標準偏差で
/// 0.007 ほど) の 5 倍以上で、生成器の偏りでなければ収まる。
///
/// [#2419]: https://github.com/mokume-metal/mokume/issues/2419
@Suite("正規分布・配列から選ぶ・並べ替え")
struct RandomPickTests {
    static let draws = 10_000

    static func meanAndDeviation(_ values: [Float]) -> (mean: Double, deviation: Double) {
        let count = Double(values.count)
        let mean = values.reduce(0) { $0 + Double($1) } / count
        let variance = values.reduce(0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / count
        return (mean, variance.squareRoot())
    }

    @Test("種 3 から 1e4 回引くと、平均 0・標準偏差 1 から ±0.05 に収まる")
    func gaussianHasUnitSpread() {
        var generator = Randomness(seed: 3)
        let values = (0..<Self.draws).map { _ in generator.gaussian() }
        let (mean, deviation) = Self.meanAndDeviation(values)
        #expect(abs(mean) < 0.05, "平均 \(mean)")
        #expect(abs(deviation - 1) < 0.05, "標準偏差 \(deviation)")
        #expect(values.allSatisfy { $0.isFinite })
    }

    /// 平均と標準偏差だけでは、一様な列を幅で縮めたものでも通りうる。正規分布なら ±1 の内に
    /// 68.3%・±2 の内に 95.4% が入る。
    @Test("±1・±2 の内に入る割合が正規分布のものに近い")
    func gaussianHasNormalShape() {
        var generator = Randomness(seed: 3)
        let values = (0..<Self.draws).map { _ in generator.gaussian() }
        let withinOne = Double(values.filter { abs($0) < 1 }.count) / Double(Self.draws)
        let withinTwo = Double(values.filter { abs($0) < 2 }.count) / Double(Self.draws)
        #expect(abs(withinOne - 0.683) < 0.02, "±1 の内 \(withinOne)")
        #expect(abs(withinTwo - 0.954) < 0.01, "±2 の内 \(withinTwo)")
    }

    @Test("同じ種から 2 度引くと同じ列になり、1 回で列を 2 つ進める")
    func gaussianIsReproducibleAndTakesTwoSteps() {
        var first = Randomness(seed: 3)
        var second = Randomness(seed: 3)
        let a = (0..<16).map { _ in first.gaussian() }
        let b = (0..<16).map { _ in second.gaussian() }
        #expect(a == b)

        // 1 回引いた後の列は、unitValue() を 2 つ進めた後の列と同じ
        var drawn = Randomness(seed: 3)
        var stepped = Randomness(seed: 3)
        _ = drawn.gaussian()
        _ = stepped.unitValue()
        _ = stepped.unitValue()
        #expect(drawn.unitValue() == stepped.unitValue())
    }

    /// 取り置きをすると、2 回目は列を進めずに取り置いた値を返す。どちらの回も 2 つ進むことを見る。
    @Test("2 つ目の値を取り置かない (2 回目も列を 2 つ進める)")
    func gaussianDoesNotCacheTheSecondValue() {
        var drawn = Randomness(seed: 3)
        var stepped = Randomness(seed: 3)
        _ = drawn.gaussian()
        _ = drawn.gaussian()
        for _ in 0..<4 { _ = stepped.unitValue() }
        #expect(drawn.unitValue() == stepped.unitValue())
    }

    @Test("添字は 0 以上 count 未満で、どの添字も出る")
    func indicesCoverTheRange() {
        var generator = Randomness(seed: 3)
        var seen = Set<Int>()
        for _ in 0..<1000 {
            let index = generator.index(below: 3)
            #expect(index.map { (0..<3).contains($0) } == true)
            if let index { seen.insert(index) }
        }
        #expect(seen == [0, 1, 2])
    }

    @Test("空なら nil を返し、それでも列を 1 つ進める")
    func emptyChoicesReturnNilAndStillStep() {
        var drawn = Randomness(seed: 3)
        var stepped = Randomness(seed: 3)
        #expect(drawn.index(below: 0) == nil)
        _ = stepped.unitValue()
        #expect(drawn.unitValue() == stepped.unitValue())
    }

    @Test("並べ替えは同じ種で同じ並びになり、要素の集合は変わらない")
    func shuffleIsReproducibleAndKeepsElements() {
        var first = Randomness(seed: 3)
        var second = Randomness(seed: 3)
        let source = [1, 2, 3, 4, 5]
        let a = first.shuffled(source)
        let b = second.shuffled(source)
        #expect(a == b)
        #expect(a.sorted() == source)
        #expect(source == [1, 2, 3, 4, 5])
    }

    @Test("並べ替えは要素の数より 1 少ない数だけ列を進める")
    func shuffleTakesCountMinusOneSteps() {
        var drawn = Randomness(seed: 3)
        var stepped = Randomness(seed: 3)
        _ = drawn.shuffled(Array(0..<10))
        for _ in 0..<9 { _ = stepped.unitValue() }
        #expect(drawn.unitValue() == stepped.unitValue())
    }

    @Test("空と 1 つの配列は並べ替えても同じで、列を進めない")
    func shortArraysDoNotStep() {
        var drawn = Randomness(seed: 3)
        var untouched = Randomness(seed: 3)
        #expect(drawn.shuffled([Int]()) == [])
        #expect(drawn.shuffled([7]) == [7])
        #expect(drawn.unitValue() == untouched.unitValue())
    }

    /// 並べ替えが偏っていないか。3 要素の並びは 6 通りで、6000 回並べ替えると各 1000 回ほど出る。
    /// 「最後と最初だけ入れ替える」ような崩れた実装だと、出ない並びができる。
    @Test("3 要素の 6 通りの並びが、どれも同じくらい出る")
    func shuffleReachesEveryOrder() {
        var generator = Randomness(seed: 3)
        var counts: [[Int]: Int] = [:]
        for _ in 0..<6000 { counts[generator.shuffled([0, 1, 2]), default: 0] += 1 }
        #expect(counts.count == 6)
        #expect(counts.values.allSatisfy { (850...1150).contains($0) }, "\(counts)")
    }
}

/// 作者の口がランタイムの列 (``random()`` と同じ 1 本) から引くことを見る ([#2419] 条件 1〜4)。
///
/// [#2419]: https://github.com/mokume-metal/mokume/issues/2419
@Suite(
    "正規分布・配列から選ぶ・並べ替え (作者の口)",
    .enabled(
        if: RenderDevice.isAvailable,
        "作者の口はランタイムを通るので GPU が要る。この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct RandomPickSketchTests {
    /// 何も描かないスケッチ。乱数を引くためだけにランタイムを立てる。
    final class Blank: Sketch {
        var settings = SketchSettings(width: 8, height: 8)
        init() {}
        func draw() {}
    }

    /// 製品と同じ口 (`withActiveRuntime`) で差してから呼ぶ (``RandomDistributionTests`` と同じ作法)。
    private func run<T>(_ body: (Blank) -> T) throws -> T {
        let sketch = Blank()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        var result: T?
        runtime.withActiveRuntime { result = body(sketch) }
        return try #require(result)
    }

    @Test("randomSeed(3) の後の randomGaussian() は平均 0・標準偏差 1、(10, 2) は平均 10・標準偏差 2 から ±0.05")
    func gaussianThroughTheSketch() throws {
        let (unit, shifted) = try run { sketch in
            sketch.randomSeed(3)
            let unit = (0..<RandomPickTests.draws).map { _ in sketch.randomGaussian() }
            sketch.randomSeed(3)
            let shifted = (0..<RandomPickTests.draws).map { _ in sketch.randomGaussian(10, 2) }
            return (unit, shifted)
        }
        let plain = RandomPickTests.meanAndDeviation(unit)
        #expect(abs(plain.mean) < 0.05, "平均 \(plain.mean)")
        #expect(abs(plain.deviation - 1) < 0.05, "標準偏差 \(plain.deviation)")
        let moved = RandomPickTests.meanAndDeviation(shifted)
        #expect(abs(moved.mean - 10) < 0.05, "平均 \(moved.mean)")
        #expect(abs(moved.deviation - 2) < 0.05, "標準偏差 \(moved.deviation)")
    }

    @Test("同じ種で 2 度引くと、どの口も同じ値を返す")
    func theSameSeedRepeats() throws {
        let (first, second) = try run { sketch in
            @MainActor func draw() -> ([Float], String?, Int?, [Int]) {
                sketch.randomSeed(3)
                let gaussians = (0..<8).map { _ in sketch.randomGaussian() }
                let letter = sketch.random(["a", "b", "c"])
                let empty = sketch.random([Int]())
                let order = sketch.shuffle([1, 2, 3, 4, 5])
                return (gaussians, letter, empty, order)
            }
            return (draw(), draw())
        }
        #expect(first.0 == second.0)
        #expect(first.1 != nil && first.1 == second.1)
        #expect(first.2 == nil && second.2 == nil)
        #expect(first.3 == second.3)
        #expect(first.3.sorted() == [1, 2, 3, 4, 5])
    }

    @Test("渡した配列は変わらない")
    func shuffleLeavesTheArgumentAlone() throws {
        let cards = [1, 2, 3, 4, 5]
        let mixed = try run { sketch in sketch.shuffle(cards) }
        #expect(cards == [1, 2, 3, 4, 5])
        #expect(mixed.sorted() == cards)
    }

    /// 3 本が random() と同じ 1 本の列を進めること。口を混ぜて引いた値が、同じ種の ``Randomness`` を
    /// 同じ順に進めた値と一致する。別の列から引いていれば、後ろの random() がずれる。
    @Test("3 本は random() と同じ列を進める")
    func allPortsShareOneSequence() throws {
        let palette = ["red", "yellow", "blue", "green"]
        let drawn = try run { sketch in
            sketch.randomSeed(3)
            let a = sketch.random()
            let g = sketch.randomGaussian(5, 2)
            let pick = sketch.random(palette)
            let order = sketch.shuffle([0, 1, 2, 3, 4, 5])
            let empty = sketch.random([String]())
            let b = sketch.random()
            return (a, g, pick, order, empty, b)
        }
        var line = Randomness(seed: 3)
        let a = line.unitValue()
        let g = line.gaussian() * 2 + 5
        let pick = line.index(below: palette.count).map { palette[$0] }
        let order = line.shuffled([0, 1, 2, 3, 4, 5])
        _ = line.index(below: 0)
        let b = line.unitValue()
        #expect(drawn.0 == a)
        #expect(drawn.1 == g)
        #expect(drawn.2 == pick)
        #expect(drawn.3 == order)
        #expect(drawn.4 == nil)
        #expect(drawn.5 == b)
    }
}
