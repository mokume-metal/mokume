// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

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
