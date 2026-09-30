// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Testing
import simd

@testable import MokumeCore

/// 周の点列を三角形へ分ける道具。
///
/// **面積の保存**を主な物差しにする。「何枚に分かれたか」は分け方によって変わるが、
/// 分けた三角形の面積の合計が元の形の面積と一致することは、どの分け方でも成り立つ。
@Suite("三角形化")
struct TriangulationTests {
    private func area(of triangles: [(Int, Int, Int)], points: [SIMD2<Float>]) -> Float {
        triangles.reduce(0) { total, triangle in
            let a = points[triangle.0]
            let b = points[triangle.1]
            let c = points[triangle.2]
            return total + abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
        }
    }

    @Test("三角形はそのまま 1 枚")
    func aTriangleStaysWhole() {
        let points: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(0, 10)]
        #expect(Triangulation.triangulate(points).count == 1)
    }

    @Test("凸な形は面積を保って分かれる")
    func convexShapesKeepTheirArea() {
        let square: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10),
        ]
        let triangles = Triangulation.triangulate(square)
        #expect(triangles.count == 2)
        #expect(abs(area(of: triangles, points: square) - 100) < 0.01)
    }

    @Test("凹んだ形でも面積を保つ")
    func concaveShapesKeepTheirArea() {
        // 矢印のような形 (右辺の真ん中が内側へ凹む)
        let arrow: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(10, 5), SIMD2(0, 10), SIMD2(3, 5),
        ]
        let triangles = Triangulation.triangulate(arrow)
        let expected = abs(Triangulation.signedArea(arrow))
        #expect(abs(area(of: triangles, points: arrow) - expected) < 0.01)
        #expect(triangles.count == 2)
    }

    @Test("回る向きが逆でも同じ面積になる")
    func windingDirectionDoesNotMatter() {
        let clockwise: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10),
        ]
        let counterClockwise = Array(clockwise.reversed())
        let a = area(of: Triangulation.triangulate(clockwise), points: clockwise)
        let b = area(of: Triangulation.triangulate(counterClockwise), points: counterClockwise)
        #expect(abs(a - b) < 0.01)
    }

    @Test("自己交差した形でも落ちず、無限に回らない")
    func selfIntersectingShapesTerminate() {
        // 砂時計 (辺が交差する)
        let bowtie: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(10, 10), SIMD2(10, 0), SIMD2(0, 10),
        ]
        let triangles = Triangulation.triangulate(bowtie)
        // 正しい分け方は存在しないが、返ってくること自体が要件
        #expect(triangles.count >= 0)
    }

    @Test("点が足りなければ何も返さない", arguments: [0, 1, 2])
    func tooFewPointsProduceNothing(_ count: Int) {
        let points = (0..<count).map { SIMD2<Float>(Float($0), 0) }
        #expect(Triangulation.triangulate(points).isEmpty)
    }

    // MARK: - 字形の輪郭が持つ形

    @Test("辺の上に別の角が載る形でも、形の外を塗らない")
    func aCornerOnAnEdgeDoesNotLeakOutside() {
        // T の輪郭。横棒の下辺 y = 51 の上に、縦棒の角 (106, 51) と (123, 51) が載る。
        // 載った点を「含まない」と数えると、縦棒の下端から横棒の右端へ斜めに切った塊が
        // 耳として通る (#1148)
        let tee: [SIMD2<Float>] = [
            SIMD2(106, 170), SIMD2(106, 51), SIMD2(64, 51), SIMD2(64, 36),
            SIMD2(165, 36), SIMD2(165, 51), SIMD2(123, 51), SIMD2(123, 170),
        ]
        let triangles = Triangulation.triangulate(tee)
        // 横棒 101 x 15 + 縦棒 17 x 119
        #expect(abs(area(of: triangles, points: tee) - 3538) < 0.01)
    }

    @Test("切り口の辺に別の角が触れる形でも、形の外を塗らない")
    func aCornerTouchingTheCutDoesNotLeakOutside() {
        // 上から切り込んだ刻みの先 (5, 5) が、対角線 (0, 0)–(10, 10) に触れる。
        // 触れた点を「含まない」と数えると、刻みに被さる三角形が耳として通る。
        // T と違って辺が一直線に続かないので、折り返した角を落とすだけでは直らない
        let notched: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(6, 10),
            SIMD2(5, 5), SIMD2(4, 10), SIMD2(0, 10),
        ]
        let triangles = Triangulation.triangulate(notched)
        // 10 x 10 から、幅 2・深さ 5 の刻みを引く
        #expect(abs(area(of: triangles, points: notched) - 95) < 0.01)
    }

    @Test("最後の点が最初の点と重なる周でも、途中で止まらない")
    func aRepeatedClosingPointDoesNotStall() {
        // 曲線で閉じる周 (字の o) は、最後の点が最初の点と重なる。同じ位置の点が続く角は
        // 耳の候補にならないので、残りがその角でしか切れなくなると止まっていた (#1211)
        func ring(radius: Float, clockwise: Bool) -> [SIMD2<Float>] {
            var points = (0..<8).map { step -> SIMD2<Float> in
                let angle = Float(step) / 8 * 2 * .pi * (clockwise ? -1 : 1)
                return SIMD2(cos(angle) * radius + 30, sin(angle) * radius + 30)
            }
            points.append(points[0])
            return points
        }
        let outer = ring(radius: 20, clockwise: false)
        let hole = ring(radius: 12, clockwise: true)
        let merged = mergeHoles(outer: outer, holes: [hole])
        let triangles = Triangulation.triangulate(merged)
        let expected = abs(Triangulation.signedArea(outer)) - abs(Triangulation.signedArea(hole))
        #expect(abs(area(of: triangles, points: merged) - expected) < 0.5)
    }

    @Test("同じ点を 2 度通る周でも、形の外を塗らない")
    func aRingTouchingItselfDoesNotLeakOutside() {
        // 右辺の途中 (10, 5) から出た葉が、同じ点へ戻ってくる (Times の k の腕と脚)。
        // 最後に「行って戻るだけ」の周が残り、そこから実在しない三角形を切っていた (#1211)
        let pinched: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 5), SIMD2(20, 0),
            SIMD2(20, 10), SIMD2(10, 5), SIMD2(10, 10), SIMD2(0, 10),
        ]
        let triangles = Triangulation.triangulate(pinched)
        // 本体 10 x 10 + 葉 10 x 10 / 2
        #expect(abs(area(of: triangles, points: pinched) - 150) < 0.01)
    }

    /// **外周が 1 つの字だけを見る。** `i` や `%` のように外周を複数持つ字は、どの穴が
    /// どの外周に属するかを決める手間が、ここで見たいもの (三角形化) と関係しない。
    @Test(
        "字の輪郭を塗ると、面積が外周から穴を引いたものに一致する",
        arguments: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".map(String.init)
    )
    func glyphOutlinesKeepTheirArea(_ character: String) throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 72, nil)
        var codes = Array(character.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: codes.count)
        try #require(CTFontGetGlyphsForCharacters(font, &codes, &glyphs, codes.count))
        let path = try #require(CTFontCreatePathForGlyph(font, glyphs[0], nil))
        // 描くときと同じく、送りと基準線でずらした座標で見る
        let rings = Canvas.rings(of: path, originX: 123.37, baseline: 456.71)
        let outers = rings.filter { !$0.isHole }
        guard outers.count == 1 else { return }
        let holes = rings.filter(\.isHole).map(\.points)

        let merged = mergeHoles(outer: outers[0].points, holes: holes)
        let triangles = Triangulation.triangulate(merged)
        let expected =
            abs(Triangulation.signedArea(outers[0].points))
            - holes.reduce(0) { $0 + abs(Triangulation.signedArea($1)) }
        #expect(abs(area(of: triangles, points: merged) - expected) <= expected * 0.005)
    }

    // MARK: - 費用

    /// 耳の判定で点を三角形と比べる回数。**時間ではなく数で見る** ([#915] に倣う) —
    /// 時間は release でしか測れず、機械の都合で揺れる。
    ///
    /// 頭から探し直して全点と比べていた頃は、円 4000 点で約 800 万回だった ([#1595])。
    ///
    /// [#915]: https://github.com/mokume-metal/mokume/issues/915
    /// [#1595]: https://github.com/mokume-metal/mokume/issues/1595
    @Test("凸な形では、耳の判定で点を 1 つも比べない")
    func convexShapesCompareNoPoints() {
        let count = 4000
        let circle = (0..<count).map { step -> SIMD2<Float> in
            let angle = Float(step) / Float(count) * 2 * .pi
            return SIMD2(100 + 80 * cos(angle), 100 + 80 * sin(angle))
        }
        var comparisons = 0
        let triangles = Triangulation.triangulate(circle, comparisons: &comparisons)
        // 比べずに済ませたのではなく、切り終えたこと
        #expect(triangles.count == count - 2)
        #expect(comparisons == 0)
    }

    /// 凹みのある形では、凸でない点だけを比べる。その数が点の数に見合うこと。
    ///
    /// 形は起票の再現 (`r = 80 + 10 sin(7a)` を角度を等分に並べた周)。直す前は 1000 点で
    /// 約 52 万回 (点の数の 516 倍) で、点を倍にするたびに 4 倍になっていた。直した後は
    /// 1000〜8000 点で 2.2〜3.0 倍で、閾値の 5 倍はそこから取った ([#1595])。
    ///
    /// [#1595]: https://github.com/mokume-metal/mokume/issues/1595
    @Test("凹みのある形でも、比べる回数が点の数に見合う", arguments: [1000, 2000, 4000, 8000])
    func concaveShapesCompareInProportion(_ count: Int) {
        let wavy = (0..<count).map { step -> SIMD2<Float> in
            let angle = Float(step) / Float(count) * 2 * .pi
            let radius = 80 + 10 * sin(7 * angle)
            return SIMD2(100 + radius * cos(angle), 100 + radius * sin(angle))
        }
        var comparisons = 0
        let triangles = Triangulation.triangulate(wavy, comparisons: &comparisons)
        #expect(triangles.count == count - 2)
        #expect(comparisons <= 5 * count, "\(count) 点で \(comparisons) 回比べた")
    }

    // MARK: - 穴

    @Test("穴の面積は塗りから抜ける")
    func holesAreSubtractedFromTheFilledArea() {
        let outer: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(20, 0), SIMD2(20, 20), SIMD2(0, 20),
        ]
        // 内側を逆向きに回る穴
        let hole: [SIMD2<Float>] = [
            SIMD2(5, 5), SIMD2(5, 15), SIMD2(15, 15), SIMD2(15, 5),
        ]
        let merged = mergeHoles(outer: outer, holes: [hole])
        let triangles = Triangulation.triangulate(merged)
        // 外 400 - 穴 100 = 300
        #expect(abs(area(of: triangles, points: merged) - 300) < 0.5)
    }

    @Test("穴が 2 つでも抜ける")
    func twoHolesAreBothSubtracted() {
        let outer: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(30, 0), SIMD2(30, 20), SIMD2(0, 20),
        ]
        let left: [SIMD2<Float>] = [
            SIMD2(4, 5), SIMD2(4, 15), SIMD2(10, 15), SIMD2(10, 5),
        ]
        let right: [SIMD2<Float>] = [
            SIMD2(18, 5), SIMD2(18, 15), SIMD2(24, 15), SIMD2(24, 5),
        ]
        let merged = mergeHoles(outer: outer, holes: [left, right])
        let triangles = Triangulation.triangulate(merged)
        // 外 600 - 穴 60 x 2 = 480
        #expect(abs(area(of: triangles, points: merged) - 480) < 1)
    }

    /// 穴の右端 (70, 80) からいちばん近い外周の点は左の (10, 10) で、そこへ架けると
    /// 橋が穴そのものを横切る ([#1530])。
    ///
    /// [#1530]: https://github.com/mokume-metal/mokume/issues/1530
    @Test("橋が穴そのものを横切らない")
    func aBridgeDoesNotCrossItsOwnHole() {
        let outer: [SIMD2<Float>] = [
            SIMD2(10, 10), SIMD2(150, 10), SIMD2(150, 150), SIMD2(10, 150),
        ]
        let hole: [SIMD2<Float>] = [
            SIMD2(70, 80), SIMD2(60, 62), SIMD2(40, 62),
            SIMD2(30, 80), SIMD2(40, 98), SIMD2(60, 98),
        ]
        let merged = mergeHoles(outer: outer, holes: [hole])
        let triangles = Triangulation.triangulate(merged)
        // 外 19600 - 穴 1080 = 18520
        #expect(abs(area(of: triangles, points: merged) - 18520) < 1)
    }

    /// 右の穴からいちばん近い外周の点 (10, 40) へ架けると、まだ畳んでいない左の穴を
    /// 横切る。どちらの穴も単独なら正しく抜ける ([#1530])。
    ///
    /// [#1530]: https://github.com/mokume-metal/mokume/issues/1530
    @Test("橋がまだ畳んでいない穴を横切らない")
    func aBridgeDoesNotCrossAHoleNotYetMerged() {
        let outer: [SIMD2<Float>] = [
            SIMD2(10, 40), SIMD2(150, 40), SIMD2(150, 120), SIMD2(10, 120),
        ]
        let right: [SIMD2<Float>] = [
            SIMD2(70, 75), SIMD2(60, 75), SIMD2(60, 85), SIMD2(70, 85),
        ]
        let left: [SIMD2<Float>] = [
            SIMD2(30, 45), SIMD2(20, 45), SIMD2(20, 55), SIMD2(30, 55),
        ]
        let merged = mergeHoles(outer: outer, holes: [right, left])
        let triangles = Triangulation.triangulate(merged)
        // 外 11200 - 穴 100 x 2 = 11000
        #expect(abs(area(of: triangles, points: merged) - 11000) < 1)
    }

    /// 曲線で閉じる穴 (字の o) は、最後の点が最初の点と重なる。橋の入口に接する辺を
    /// 番号で外すと、同じ位置のもう 1 つの点に接する辺が「入口で跨いだ」と数えられ、
    /// 架ける先が 1 つも無くなって穴が消える。
    @Test("最後の点が最初の点と重なる穴にも、橋を架けられる")
    func aHoleClosedByARepeatedPointIsMerged() {
        let outer: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(60, 0), SIMD2(60, 60), SIMD2(0, 60),
        ]
        var hole = (0..<8).map { step -> SIMD2<Float> in
            let angle = -Float(step) / 8 * 2 * .pi
            return SIMD2(cos(angle) * 8 + 30, sin(angle) * 8 + 30)
        }
        hole.append(hole[0])
        let merged = mergeHoles(outer: outer, holes: [hole])
        let triangles = Triangulation.triangulate(merged)
        let expected = 3600 - abs(Triangulation.signedArea(hole))
        #expect(abs(area(of: triangles, points: merged) - expected) < 0.5)
    }

    @Test("点の足りない穴は無視される")
    func degenerateHolesAreIgnored() {
        let outer: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10),
        ]
        let merged = mergeHoles(outer: outer, holes: [[SIMD2(2, 2), SIMD2(4, 4)]])
        #expect(merged == outer)
    }

    // MARK: - 交わった周を分ける (#1538)

    @Test("単純な形は組み直さない", arguments: ["凸", "凹", "T", "同じ点を 2 度通る", "穴", "同じ向きの穴"])
    func simpleRingsAreLeftAlone(_ name: String) {
        let square: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
        let rings: [[SIMD2<Float>]]
        switch name {
        case "凸": rings = [square]
        case "凹":
            rings = [[SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(5, 3), SIMD2(0, 10)]]
        case "T":
            rings = [[
                SIMD2(106, 170), SIMD2(106, 51), SIMD2(64, 51), SIMD2(64, 36),
                SIMD2(165, 36), SIMD2(165, 51), SIMD2(123, 51), SIMD2(123, 170),
            ]]
        case "同じ点を 2 度通る":
            rings = [[
                SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 5), SIMD2(20, 0),
                SIMD2(20, 10), SIMD2(10, 5), SIMD2(10, 10), SIMD2(0, 10),
            ]]
        case "穴": rings = [square, [SIMD2(3, 3), SIMD2(3, 6), SIMD2(6, 6), SIMD2(6, 3)]]
        default: rings = [square, [SIMD2(3, 3), SIMD2(6, 3), SIMD2(6, 6), SIMD2(3, 6)]]
        }
        let (indices, points) = numbered(rings)
        #expect(Triangulation.splitForNonzero(rings: indices, points: points) == nil)
    }

    @Test("5 点の星は、交点を足した 10 点の凹んだ周 1 つになる")
    func aPentagramBecomesAConcaveStar() throws {
        let star: [SIMD2<Float>] = [
            SIMD2(80, 10), SIMD2(121, 137), SIMD2(13, 58), SIMD2(147, 58), SIMD2(39, 137),
        ]
        let (indices, points) = numbered([star])
        let split = try #require(Triangulation.splitForNonzero(rings: indices, points: points))
        #expect(split.crossings.count == 5)
        #expect(split.regions.count == 1)
        let region = try #require(split.regions.first)
        #expect(region.holes.isEmpty)
        #expect(region.outer.count == 10)
        let all = points + split.crossings.map(\.point)
        // 5 つの腕と中の五角形。どの点もちょうど 1 度だけ覆う
        let outline = region.outer.map { all[$0] }
        let triangles = Triangulation.triangulate(outline)
        let expected = Triangulation.signedArea(outline)
        #expect(expected > 0)
        #expect(abs(area(of: triangles, points: outline) - expected) < 0.01)
    }

    @Test("砂時計は、1 点で触れ合う 2 つの三角形になる")
    func anHourglassBecomesTwoTriangles() throws {
        let hourglass: [SIMD2<Float>] = [
            SIMD2(20, 20), SIMD2(140, 20), SIMD2(20, 140), SIMD2(140, 140),
        ]
        let (indices, points) = numbered([hourglass])
        let split = try #require(Triangulation.splitForNonzero(rings: indices, points: points))
        #expect(split.crossings.count == 1)
        let crossing = try #require(split.crossings.first)
        #expect(crossing.point == SIMD2(80, 80))
        #expect(crossing.first.at == 0.5 && crossing.second.at == 0.5)
        #expect(split.regions.count == 2)
        let all = points + split.crossings.map(\.point)
        for region in split.regions {
            #expect(region.outer.count == 3)
            #expect(region.holes.isEmpty)
            #expect(abs(Triangulation.signedArea(region.outer.map { all[$0] })) == 3600)
        }
    }

    @Test("外周を跨ぐ穴は、外周の中で切れ込みになり、外へ出た先は別の外周になる")
    func aStraddlingHoleSplitsIntoANotchAndATip() throws {
        let square: [SIMD2<Float>] = [SIMD2(20, 20), SIMD2(140, 20), SIMD2(140, 140), SIMD2(20, 140)]
        let hole: [SIMD2<Float>] = [SIMD2(100, 60), SIMD2(100, 100), SIMD2(155, 80)]
        let (indices, points) = numbered([square, hole])
        let split = try #require(Triangulation.splitForNonzero(rings: indices, points: points))
        #expect(split.crossings.count == 2)
        let all = points + split.crossings.map(\.point)
        var areas: [Float] = []
        for region in split.regions {
            #expect(region.holes.isEmpty)
            areas.append(Triangulation.signedArea(region.outer.map { all[$0] }))
        }
        areas.sort()
        // 外へ出た先は、穴の三角形 (底 40・高さ 55) の先の、高さ 15 の相似形
        let whole: Float = 0.5 * 40 * 55
        let tip: Float = whole * (15 * 15) / (55 * 55)
        #expect(areas.count == 2)
        #expect(abs(areas[0] - tip) < 0.01)
        // 残りは、穴の外周の中の部分が切れ込んだ矩形
        let notched: Float = 120 * 120 - (whole - tip)
        #expect(abs(areas[1] - notched) < 0.01)
    }

    /// 周の組に、通しの番号を振る。
    private func numbered(_ rings: [[SIMD2<Float>]]) -> ([[Int]], [SIMD2<Float>]) {
        var points: [SIMD2<Float>] = []
        var indices: [[Int]] = []
        for ring in rings {
            indices.append(Array(points.count..<(points.count + ring.count)))
            points += ring
        }
        return (indices, points)
    }

    // MARK: - 道具

    /// 点で渡して点で受け取る形。畳む本体は**番号で**受け渡すので、検査のために
    /// ここで番号へ付け替える (立体は同じ番号から色や面の向きを引く)。
    private func mergeHoles(outer: [SIMD2<Float>], holes: [[SIMD2<Float>]]) -> [SIMD2<Float>] {
        let points = outer + holes.flatMap { $0 }
        var holeIndices: [[Int]] = []
        var next = outer.count
        for hole in holes {
            holeIndices.append(Array(next..<(next + hole.count)))
            next += hole.count
        }
        return Triangulation
            .mergeHoles(outer: Array(outer.indices), holes: holeIndices, points: points)
            .map { points[$0] }
    }
}
