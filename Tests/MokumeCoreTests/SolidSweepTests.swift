// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing
import simd

@testable import MokumeCore

/// 裏 → 表で描く置き場所の連なりを 1 回の描く呼び出しへ畳む部分 (``SolidSweep``・
/// ``SolidVertexSharing``)。GPU は要らない。
///
/// 見るのは次の 3 つ。**連なりの割り方** (描く呼び出しの数が置き場所の数でなく、印の並びで決まる)・
/// **添字の列の中身** (置き場所 1 つぶんの描く順が、置き場所ごとに描くときと同じ三角形を同じ順で残す)・
/// **使う判定**。2 つ目は、捨て方 (`.front` / `.back` / 捨てない) と三角形の巻き方を決まった向きで
/// 数える小さな模擬の描画で、置き場所ごとの描き方と畳んだ描き方が残す三角形の列を突き合わせる
/// ([#1947](https://github.com/mokume-metal/mokume/issues/1947))。頂点が形から求めた向きを持つときは、
/// 残る三角形ごとに光を当てる向きを裏返すかも突き合わせる
/// ([#2222](https://github.com/mokume-metal/mokume/issues/2222))。実際の絵の一致は
/// `SolidSweepRenderTests` が GPU で見る。
@Suite("裏 → 表の描き方を畳む")
struct SolidSweepTests {
    // MARK: - 部品の用意

    private func part(
        _ range: Range<Int>, always: Bool = false, insideOut: Bool = false, indexed: Bool = false
    ) -> SolidPart {
        SolidPart(range: range, isIndexed: indexed, showsBackFaces: always, insideOut: insideOut)
    }

    private func parts(
        _ list: [SolidPart], whole: Range<Int> = 0..<60, indexed: Bool = false
    ) -> SolidSweep.Parts {
        SolidSweep.Parts(whole: whole, isIndexed: indexed, backFaceParts: list)
    }

    // MARK: - 連なりの割り方

    @Test("置き場所が 0 なら連なりも無い")
    func noPlacementsMakeNoRuns() {
        let runs = SolidSweep.runs(instanceCount: 0, marks: [], parts: parts([part(0..<60)]))
        #expect(runs.isEmpty)
    }

    @Test("印が無く、いつも立つ部品も無い置き場所は、1 つの plain の連なりになる")
    func unmarkedPlacementsAreOnePlainRun() {
        let runs = SolidSweep.runs(instanceCount: 5, marks: [], parts: parts([part(0..<60)]))
        #expect(runs == [.init(instances: 0..<5, kind: .plain)])
    }

    @Test("全部の置き場所に印があれば、置き場所の数によらず連なりは 1 つ")
    func allMarkedPlacementsAreOneRun() {
        for count in [1, 2, 100, 8192] {
            let runs = SolidSweep.runs(
                instanceCount: count, marks: Array(0..<count), parts: parts([part(0..<60)]))
            #expect(runs == [.init(instances: 0..<count, kind: .allParts)], "置き場所 \(count)")
        }
    }

    @Test("全部の部品がいつも立つなら、印の並びによらず連なりは 1 つ")
    func alwaysShownPartsIgnoreMarks() {
        let runs = SolidSweep.runs(
            instanceCount: 10, marks: [1, 4, 5, 8], parts: parts([part(0..<60, always: true)]))
        #expect(runs == [.init(instances: 0..<10, kind: .allParts)])
    }

    @Test("印の付いた置き場所の塊ごとに連なりが割れる (置き場所の数ではなく塊の数)")
    func runsFollowTheBlocksOfMarks() {
        let runs = SolidSweep.runs(
            instanceCount: 10, marks: [2, 3, 4, 7], parts: parts([part(0..<60)]))
        #expect(
            runs == [
                .init(instances: 0..<2, kind: .plain),
                .init(instances: 2..<5, kind: .allParts),
                .init(instances: 5..<7, kind: .plain),
                .init(instances: 7..<8, kind: .allParts),
                .init(instances: 8..<10, kind: .plain),
            ])
    }

    @Test("印が交互に並ぶ列は、置き場所の数に比例して連なりが増える (畳めるのは続いた分だけ)")
    func alternatingMarksMakeManyRuns() {
        let runs = SolidSweep.runs(
            instanceCount: 100, marks: Array(stride(from: 0, to: 100, by: 2)), parts: parts([part(0..<60)]))
        #expect(runs.count == 100)
        #expect(runs.filter { $0.kind == .allParts }.count == 50)
    }

    @Test("一部の部品だけがいつも立つ列は、印の無い置き場所が someParts になる")
    func someAlwaysShownPartsMakeASubsetRun() {
        let list = [part(0..<30, always: true), part(30..<60)]
        let runs = SolidSweep.runs(instanceCount: 4, marks: [2], parts: parts(list))
        #expect(
            runs == [
                .init(instances: 0..<2, kind: .someParts),
                .init(instances: 2..<3, kind: .allParts),
                .init(instances: 3..<4, kind: .someParts),
            ])
    }

    @Test("昇順でない・重なる・範囲の外の印も、置き場所ごとの描き方と同じ連なりになる")
    func untidyMarksStillMakeTheSameRuns() {
        let runs = SolidSweep.runs(
            instanceCount: 6, marks: [4, 1, 1, 2, 99, -3], parts: parts([part(0..<60)]))
        #expect(
            runs == [
                .init(instances: 0..<1, kind: .plain),
                .init(instances: 1..<3, kind: .allParts),
                .init(instances: 3..<4, kind: .plain),
                .init(instances: 4..<5, kind: .allParts),
                .init(instances: 5..<6, kind: .plain),
            ])
    }

    @Test("区間の外・数え方の違う・空の部品は読まない")
    func unusablePartsAreIgnored() {
        let list = [
            part(0..<30), part(50..<70), part(10..<10), part(0..<30, indexed: true),
        ]
        let usable = parts(list)
        #expect(usable.all == [part(0..<30)])
    }

    // MARK: - 描く区間

    @Test("外向きの部品は .front → .back、内向きは .back → .front の順に描く")
    func partsDrawBackThenFront() {
        let outward = SolidSweep.passes(whole: 0..<30, shown: [part(0..<30)], plainCull: .none)
        #expect(
            outward == [.init(range: 0..<30, cull: .front), .init(range: 0..<30, cull: .back)])
        let inward = SolidSweep.passes(
            whole: 0..<30, shown: [part(0..<30, insideOut: true)], plainCull: .none)
        #expect(
            inward == [.init(range: 0..<30, cull: .back), .init(range: 0..<30, cull: .front)])
    }

    @Test("部品の外の区間は、列の捨て方で 1 回、記録した順に挟まる")
    func gapsKeepTheirPlaceBetweenParts() {
        let list = [part(6..<12), part(18..<24, insideOut: true)]
        let passes = SolidSweep.passes(whole: 0..<30, shown: list, plainCull: .back)
        #expect(
            passes == [
                .init(range: 0..<6, cull: .back),
                .init(range: 6..<12, cull: .front), .init(range: 6..<12, cull: .back),
                .init(range: 12..<18, cull: .back),
                .init(range: 18..<24, cull: .back), .init(range: 18..<24, cull: .front),
                .init(range: 24..<30, cull: .back),
            ])
    }

    @Test("立つ部品が無ければ区間は列全体の 1 回")
    func noShownPartsDrawTheWholeOnce() {
        let passes = SolidSweep.passes(whole: 0..<30, shown: [], plainCull: .none)
        #expect(passes == [.init(range: 0..<30, cull: .none)])
    }

    // MARK: - 添字の列の中身

    /// 模擬の描画で、1 枚の三角形が表を向くか。面積 0 なら `nil` (どの捨て方でも画素を生まない)。
    ///
    /// 位置は画面の座標 (横 → 右・縦 → 下)。表の巻き方 `front` は画面で見たときの向き。
    private func facesFront(
        _ triangle: (Int, Int, Int), _ points: [SIMD2<Float>], front: MTLWinding
    ) -> Bool? {
        let (a, b, c) = (points[triangle.0], points[triangle.1], points[triangle.2])
        // 画面の座標 (縦が下) での符号付きの面積。正なら時計回り
        let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        guard area != 0 else { return nil }
        return (area > 0) == (front == .clockwise)
    }

    /// 捨て方 (`cull`) で数える模擬の描画が、1 枚の三角形を残すか。`.front` は表を捨て、`.back` は裏を
    /// 捨てる。面積 0 の三角形は数えない。
    private func survives(
        _ triangle: (Int, Int, Int), _ points: [SIMD2<Float>], cull: MTLCullMode,
        front: MTLWinding
    ) -> Bool {
        guard let isFront = facesFront(triangle, points, front: front) else { return false }
        switch cull {
        case .none: return true
        case .front: return !isFront
        case .back: return isFront
        @unknown default: return true
        }
    }

    /// 模擬の描画で残った三角形 1 枚。
    private struct Drawn: Equatable, CustomStringConvertible {
        /// 点の集合 (巻き方を入れ替えた写しと元が同じ印になる)。
        var mark: [Int]
        /// 光を当てる向きを、頂点に書いた向きから裏返すか。
        var flipsNormal: Bool

        init(_ triangle: (Int, Int, Int), flipsNormal: Bool) {
            mark = [triangle.0, triangle.1, triangle.2].sorted()
            self.flipsNormal = flipsNormal
        }

        var description: String { "\(mark)\(flipsNormal ? " 裏返す" : "")" }
    }

    /// 置き場所ごとに描くとき (`passes` を捨て方を替えながら描く) の、残る三角形の並び。
    ///
    /// `derived` なら頂点は形から求めた向きを持ち、断片は裏を向いた三角形で向きを裏返す
    /// (`Common.metal` の `isBackOfDerived`)。
    private func perPlacement(
        passes: [SolidSweep.Pass], indices: [UInt32]?, points: [SIMD2<Float>], front: MTLWinding,
        derived: Bool = false
    ) -> [Drawn] {
        var drawn: [Drawn] = []
        for pass in passes {
            for triangle in 0..<(pass.range.count / 3) {
                let at = pass.range.lowerBound + triangle * 3
                let vertices =
                    indices.map { (Int($0[at]), Int($0[at + 1]), Int($0[at + 2])) }
                    ?? (at, at + 1, at + 2)
                if survives(vertices, points, cull: pass.cull, front: front) {
                    let isFront = facesFront(vertices, points, front: front) ?? true
                    drawn.append(Drawn(vertices, flipsNormal: derived && !isFront))
                }
            }
        }
        return drawn
    }

    /// 畳んだ添字の列を `.back` 固定で描くときの、残る三角形の並び。
    ///
    /// 残る三角形は表を向くので、断片は向きを裏返さない。裏返すのは、添字に印
    /// (``SolidSweep/flipsNormal``) が立っていて頂点関数が裏返すときである。点の番号は印を外して読む。
    private func swept(
        program: [UInt32], points: [SIMD2<Float>], front: MTLWinding
    ) -> [Drawn] {
        let flag = SolidSweep.flipsNormal
        var drawn: [Drawn] = []
        var at = 0
        while at + 2 < program.count {
            let vertices = (
                Int(program[at] & ~flag), Int(program[at + 1] & ~flag), Int(program[at + 2] & ~flag)
            )
            let flags = [program[at], program[at + 1], program[at + 2]].map { $0 & flag != 0 }
            if survives(vertices, points, cull: .back, front: front) {
                // 印は三角形の 3 点で揃っていなければ、断片の補間した印と食い違う
                #expect(Set(flags).count == 1, "印が揃わない三角形 \(vertices)")
                drawn.append(Drawn(vertices, flipsNormal: flags[0]))
            }
            at += 3
        }
        return drawn
    }

    /// 決まった並びの乱数で、三角形の点を画面にばらまく。
    private func scatter(_ count: Int, seed: UInt64) -> [SIMD2<Float>] {
        var state = seed
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
        return (0..<count).map { _ in SIMD2(next() * 100, next() * 100) }
    }

    /// 頂点 0…999 をそのまま使う表で、添字の列を組む。`derived` なら全部の頂点が形から求めた向きを持つ
    /// (表の番号に ``SolidSweep/flipsNormal`` が立つ)。
    private func build(
        _ passes: [SolidSweep.Pass], indices: [UInt32]? = nil, derived: Bool = false
    ) -> [UInt32] {
        var program: [UInt32] = []
        let table = (0..<UInt32(1000)).map { derived ? $0 | SolidSweep.flipsNormal : $0 }
        let usable = SolidSweep.appendProgram(
            passes, indices: indices, vertexBase: 0, vertices: table, to: &program)
        #expect(usable)
        #expect(program.count == SolidSweep.programLength(of: passes))
        return program
    }

    @Test("外向きの部品の添字の列は、[裏返した写し → 元] の順に並ぶ")
    func outwardProgramIsFlippedThenOriginal() {
        let passes = SolidSweep.passes(whole: 0..<6, shown: [part(0..<6)], plainCull: .none)
        #expect(build(passes) == [0, 2, 1, 3, 5, 4, 0, 1, 2, 3, 4, 5])
    }

    @Test("内向きの部品の添字の列は、[元 → 裏返した写し] の順に並ぶ")
    func inwardProgramIsOriginalThenFlipped() {
        let passes = SolidSweep.passes(
            whole: 0..<6, shown: [part(0..<6, insideOut: true)], plainCull: .none)
        #expect(build(passes) == [0, 1, 2, 3, 4, 5, 0, 2, 1, 3, 5, 4])
    }

    @Test("捨てない区間は、三角形ごとに [元, 写し] の対になる")
    func uncutGapsAreOriginalAndFlippedPairs() {
        let passes = SolidSweep.passes(whole: 0..<6, shown: [], plainCull: .none)
        #expect(build(passes) == [0, 1, 2, 0, 2, 1, 3, 4, 5, 3, 5, 4])
    }

    @Test("裏を捨てる区間は元のまま、表を捨てる区間は写しだけを足す")
    func cullingGapsKeepOneCopy() {
        #expect(build(SolidSweep.passes(whole: 0..<3, shown: [], plainCull: .back)) == [0, 1, 2])
        #expect(build(SolidSweep.passes(whole: 0..<3, shown: [], plainCull: .front)) == [0, 2, 1])
    }

    @Test("添字の列を指す区間は、添字の値をそのまま (写しは 2 点目と 3 点目を入れ替えて) 足す")
    func indexedRangesCopyTheirIndexValues() {
        let indices: [UInt32] = [9, 8, 7, 5, 4, 3]
        let passes = SolidSweep.passes(
            whole: 0..<6, shown: [part(0..<6, indexed: true)], plainCull: .none)
        #expect(build(passes, indices: indices) == [9, 7, 8, 5, 3, 4, 9, 8, 7, 5, 4, 3])
    }

    @Test("3 で割り切れない端の頂点は読まない")
    func raggedEndsAreNotRead() {
        let passes = SolidSweep.passes(whole: 0..<7, shown: [part(0..<7)], plainCull: .none)
        #expect(build(passes) == [0, 2, 1, 3, 5, 4, 0, 1, 2, 3, 4, 5])
        #expect(SolidSweep.programLength(of: passes) == 12)
    }

    // MARK: - 形から求めた向きを持つ頂点 (#2222)

    @Test("形から求めた向きの頂点は、写しの三角形にだけ印が立ち、元の三角形からは外れる")
    func derivedVerticesAreMarkedOnlyInCopies() {
        let flag = SolidSweep.flipsNormal
        let outward = SolidSweep.passes(whole: 0..<6, shown: [part(0..<6)], plainCull: .none)
        #expect(
            build(outward, derived: true)
                == [0 | flag, 2 | flag, 1 | flag, 3 | flag, 5 | flag, 4 | flag, 0, 1, 2, 3, 4, 5])
        let inward = SolidSweep.passes(
            whole: 0..<3, shown: [part(0..<3, insideOut: true)], plainCull: .none)
        #expect(build(inward, derived: true) == [0, 1, 2, 0 | flag, 2 | flag, 1 | flag])
        // 捨てない区間は [元, 写し] の対。裏を捨てる区間は元だけ、表を捨てる区間は写しだけ
        #expect(
            build(SolidSweep.passes(whole: 0..<3, shown: [], plainCull: .none), derived: true)
                == [0, 1, 2, 0 | flag, 2 | flag, 1 | flag])
        #expect(
            build(SolidSweep.passes(whole: 0..<3, shown: [], plainCull: .back), derived: true)
                == [0, 1, 2])
        #expect(
            build(SolidSweep.passes(whole: 0..<3, shown: [], plainCull: .front), derived: true)
                == [0 | flag, 2 | flag, 1 | flag])
        // 添字の列を指す区間も同じ (印は表から読む)
        #expect(
            build(
                SolidSweep.passes(whole: 0..<3, shown: [part(0..<3, indexed: true)], plainCull: .none),
                indices: [9, 8, 7], derived: true)
                == [9 | flag, 7 | flag, 8 | flag, 9, 8, 7])
    }

    @Test("印が 3 点で揃わない三角形を写しにするなら組めない (写しにしない区間なら組める)")
    func mixedTrianglesCannotBeCopied() {
        var table = Array(0..<UInt32(6))
        table[4] |= SolidSweep.flipsNormal
        var program: [UInt32] = []
        let shown = SolidSweep.passes(whole: 0..<6, shown: [part(0..<6)], plainCull: .none)
        #expect(
            !SolidSweep.appendProgram(shown, indices: nil, vertexBase: 0, vertices: table, to: &program))
        program = []
        let pairs = SolidSweep.passes(whole: 0..<6, shown: [], plainCull: .none)
        #expect(
            !SolidSweep.appendProgram(pairs, indices: nil, vertexBase: 0, vertices: table, to: &program))
        // 揃わない三角形が使わない区間にあるだけなら組める
        program = []
        let first = SolidSweep.passes(whole: 0..<3, shown: [part(0..<3)], plainCull: .none)
        #expect(
            SolidSweep.appendProgram(first, indices: nil, vertexBase: 0, vertices: table, to: &program))
        // 写しにしない区間 (裏を捨てる) は、揃わなくても印を外した元を足す
        program = []
        let kept = SolidSweep.passes(whole: 0..<6, shown: [], plainCull: .back)
        #expect(
            SolidSweep.appendProgram(kept, indices: nil, vertexBase: 0, vertices: table, to: &program))
        #expect(program == [0, 1, 2, 3, 4, 5])
    }

    @Test("表の外の頂点を指せば、組めない")
    func verticesOutsideTheTableMakeTheProgramImpossible() {
        let passes = SolidSweep.passes(whole: 0..<6, shown: [part(0..<6)], plainCull: .none)
        var program: [UInt32] = []
        // 頂点 0…4 しか持たない表
        #expect(
            !SolidSweep.appendProgram(
                passes, indices: nil, vertexBase: 0, vertices: Array(0..<5), to: &program))
        // 頂点の番号が表の始まりより前
        program = []
        #expect(
            !SolidSweep.appendProgram(
                passes, indices: nil, vertexBase: 1, vertices: Array(1..<7), to: &program))
        // 添字が表の外を指す
        program = []
        let wild = SolidSweep.passes(whole: 0..<3, shown: [part(0..<3, indexed: true)], plainCull: .none)
        #expect(
            !SolidSweep.appendProgram(
                wild, indices: [0, 1, 500], vertexBase: 0, vertices: Array(0..<10), to: &program))
        // 区間が添字の列の終わりを越える
        program = []
        let long = SolidSweep.passes(whole: 0..<6, shown: [part(0..<6, indexed: true)], plainCull: .none)
        #expect(
            !SolidSweep.appendProgram(
                long, indices: [0, 1, 2, 3], vertexBase: 0, vertices: Array(0..<10), to: &program))
    }

    @Test("頂点の表を渡すと、添字は表の番号になる (頂点の始まりがずれていても)")
    func verticesAreRemapped() {
        let passes = SolidSweep.passes(whole: 20..<23, shown: [], plainCull: .back)
        var program: [UInt32] = []
        _ = SolidSweep.appendProgram(
            passes, indices: nil, vertexBase: 20, vertices: [100, 100, 101], to: &program)
        #expect(program == [100, 100, 101])
    }

    /// 組み立てた区間で、置き場所ごとに描いたときと畳んだときに残る三角形が同じ列になる。
    ///
    /// 三角形の点を画面にばらまくので、表も裏も面積 0 に近いものも混ざる。部品が 2 つ (外向きと
    /// 内向き)・部品の外の区間・3 で割り切れない端・添字の列のどれも通す。頂点が形から求めた向きを
    /// 持つとき (#2222) は、残る三角形ごとに光を当てる向きを裏返すかも同じになる。
    @Test("置き場所ごとに描いたときと、畳んだときで、残る三角形と裏返す向きが同じ順に同じだけ並ぶ", arguments: [false, true], [false, true])
    func sweptProgramLeavesTheSameTrianglesInTheSameOrder(
        indexed: Bool, clockwise: Bool
    ) {
        let triangles = 60
        // 3 で割り切れない端 (2 点) まで持つ
        let corners = triangles * 3 + 2
        let points = scatter(corners, seed: indexed ? 7 : 11)
        // 添字の列は頂点を使い回す (番号は頂点の数より小さい)
        let indices: [UInt32]? =
            indexed ? (0..<corners).map { UInt32(($0 * 7 + 3) % points.count) } : nil
        let front: MTLWinding = clockwise ? .clockwise : .counterClockwise
        let whole = 0..<corners
        let list = [
            part(9..<45, indexed: indexed),
            part(60..<111, insideOut: true, indexed: indexed),
            part(130..<170, indexed: indexed),
        ]
        for cull in [MTLCullMode.none, .back] {
            for derived in [false, true] {
                let passes = SolidSweep.passes(whole: whole, shown: list, plainCull: cull)
                let legacy = perPlacement(
                    passes: passes, indices: indices, points: points, front: front, derived: derived)
                let program = build(passes, indices: indices, derived: derived)
                #expect(
                    swept(program: program, points: points, front: front) == legacy,
                    "捨て方 \(cull.rawValue)・形から求めた向き \(derived)")
                #expect(!legacy.isEmpty)
                // 形から求めた向きなら、裏返して光を当てる三角形が実際に混ざる (見張りが空振りしない)
                #expect(legacy.contains { $0.flipsNormal } == derived)
            }
        }
    }

    // MARK: - 使う判定

    @Test("置き場所が少なければ、添字の列を組まずに置き場所ごとに描く")
    func fewPlacementsDrawOneByOne() {
        // 球 (添字 1728 本・頂点 864 個) を 3 か所
        #expect(
            !SolidSweep.paysOff(instances: 3, passes: 2, programLength: 1728, vertices: 864))
        #expect(
            !SolidSweep.paysOff(instances: 1, passes: 2, programLength: 1728, vertices: 0))
    }

    @Test("置き場所が多ければ、添字の列で描く")
    func manyPlacementsDrawAsOne() {
        #expect(
            SolidSweep.paysOff(instances: 1000, passes: 2, programLength: 1728, vertices: 864))
        #expect(
            SolidSweep.paysOff(instances: 8192, passes: 2, programLength: 1728, vertices: 864))
    }

    @Test("大きな形は、列に入る上限 (8192) まで置いても添字の列を組まない")
    func hugeShapesNeverPayOff() {
        // 三角形 20 万枚 (添字 120 万本)
        #expect(
            !SolidSweep.paysOff(
                instances: Canvas.defaultInstanceCapacity, passes: 2, programLength: 1_200_000,
                vertices: 600_000))
    }

    @Test("判定の境目: 省ける呼び出しの費用が組む費用と等しければ使う")
    func theBoundaryIsInclusive() {
        let calls = SolidSweep.indicesPerCall
        #expect(SolidSweep.paysOff(instances: 5, passes: 2, programLength: 10 * calls, vertices: 0))
        #expect(!SolidSweep.paysOff(instances: 5, passes: 2, programLength: 10 * calls + 1, vertices: 0))
    }

    // MARK: - 同じ値の頂点

    private func vertex(
        _ x: Float, _ y: Float = 0, normal: SIMD3<Float> = SIMD3(0, 0, 1)
    ) -> SolidVertex {
        SolidVertex(
            position: SIMD3(x, y, 0), normal: normal, uv: SIMD2(0.5, 0.5),
            color: .linear(red: 1, green: 1, blue: 1))
    }

    @Test("値が同じ頂点は最初の頂点へ寄り、違う頂点は自分のまま")
    func equalVerticesShareTheFirst() {
        let list = [vertex(1), vertex(2), vertex(1), vertex(3), vertex(2), vertex(1)]
        let firsts = list.withUnsafeBufferPointer { SolidVertexSharing.firsts(of: $0) }
        #expect(firsts == [0, 1, 0, 3, 1, 0])
    }

    @Test("成分が 1 つでも違えば別の頂点 (どの成分も見ている)")
    func everyFieldDistinguishesVertices() {
        let base = vertex(1)
        var variants: [SolidVertex] = []
        func changed(_ edit: (inout SolidVertex) -> Void) {
            var other = base
            edit(&other)
            variants.append(other)
        }
        changed { $0.position.z += 1 }
        changed { $0.shapePosition.y += 1 }
        changed { $0.normal.w = 1 }
        changed { $0.normal.x += 1 }
        changed { $0.shapeNormal.z += 1 }
        changed { $0.uv.y += 1 }
        changed { $0.stroke = 1 }
        changed { $0.color.w = 0.5 }
        let list = [base] + variants
        let firsts = list.withUnsafeBufferPointer { SolidVertexSharing.firsts(of: $0) }
        #expect(firsts == Array(0..<UInt32(list.count)))
    }

    @Test("+0 と -0 は別の頂点として数える (ビットで比べる)")
    func signedZerosAreDistinct() {
        let list = [vertex(0), vertex(-0.0)]
        let firsts = list.withUnsafeBufferPointer { SolidVertexSharing.firsts(of: $0) }
        #expect(firsts == [0, 1])
    }

    @Test("頂点の成分を足したら、寄せる鍵にも足す (成分の数を見張る)")
    func theKeyCoversEveryStoredField() {
        // 鍵が見ている成分は 7 つ (位置・形自身の座標・向き・形自身の向き・読み取り位置・輪郭・色)。
        // 頂点に成分を足したらここが赤くなるので、`SolidVertexSharing.key(of:)` にも足す
        #expect(Mirror(reflecting: vertex(1)).children.count == 7)
        #expect(MemoryLayout<SolidVertex>.stride == 96)
    }

    @Test("同じ点を 6 枚が分け合う並びは、6 分の 1 の頂点数に寄る")
    func sharedCornersCollapse() {
        var list: [SolidVertex] = []
        for corner in 0..<50 {
            for _ in 0..<6 { list.append(vertex(Float(corner))) }
        }
        let firsts = list.withUnsafeBufferPointer { SolidVertexSharing.firsts(of: $0) }
        #expect(Set(firsts).count == 50)
        #expect(firsts.enumerated().allSatisfy { $0.element == UInt32($0.offset / 6 * 6) })
    }

    @Test("頂点が 0 個・1 個でも落ちない")
    func tinyInputs() {
        let none: [SolidVertex] = []
        #expect(none.withUnsafeBufferPointer { SolidVertexSharing.firsts(of: $0) }.isEmpty)
        let one = [vertex(1)]
        #expect(one.withUnsafeBufferPointer { SolidVertexSharing.firsts(of: $0) } == [0])
    }
}
