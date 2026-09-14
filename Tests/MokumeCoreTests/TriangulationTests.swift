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

    @Test("点の足りない穴は無視される")
    func degenerateHolesAreIgnored() {
        let outer: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10),
        ]
        let merged = mergeHoles(outer: outer, holes: [[SIMD2(2, 2), SIMD2(4, 4)]])
        #expect(merged == outer)
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
