// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 穴のつなぎ (`Triangulation.mergeHoles`) の費用が、穴の数に対して二乗を越えて増えていないこと
/// ([#2370])。CPU だけで確かめる。
///
/// **時間ではなく数で見る** (``Triangulation/triangulate(_:comparisons:slack:)`` の
/// [#915] と同じ)。数えるのは、橋の相手を探すために周の点と距離を比べた数と、橋を遮るかを調べた
/// 辺の数。直す前は、橋を架けられる点が見つかるまでに、周の全点と全ての辺を何度も見直していて、
/// 穴 900 の格子で 1.4 秒掛かった (穴を 4 倍にすると 30 倍を越える)。
///
/// 場面は、4 点の穴を穴ごとに ±0.37 ずらして格子に並べた形。揃えて並べると穴の辺が互いに同じ
/// 直線に載り、別の経路 (`AlignedHolesTests`・[#2508]) の話になる。
///
/// [#2370]: https://github.com/mokume-metal/mokume/issues/2370
/// [#2508]: https://github.com/mokume-metal/mokume/issues/2508
/// [#915]: https://github.com/mokume-metal/mokume/issues/915
@Suite("穴のつなぎの費用")
struct MergeHolesCostTests {
    /// 外周 1 つと、`side` × `side` 個の 4 点の正方形の穴 (外周と逆回り)。穴の位置を穴ごとにずらす。
    nonisolated static func shiftedGrid(side: Int) -> (
        outer: [Int], holes: [[Int]], points: [SIMD2<Float>]
    ) {
        let pitch: Float = 4
        let size: Float = 1
        let extent = pitch * Float(side + 1)
        var points: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(extent, 0), SIMD2(extent, extent), SIMD2(0, extent),
        ]
        var holes: [[Int]] = []
        holes.reserveCapacity(side * side)
        for column in 0..<side {
            for row in 0..<side {
                let serial = Float(column * side + row)
                let x = pitch * Float(column + 1) - size / 2 + 0.37 * sin(serial * 1.618 + 0.3)
                let y = pitch * Float(row + 1) - size / 2 + 0.37 * cos(serial * 2.414 + 0.7)
                let base = points.count
                points.append(contentsOf: [
                    SIMD2(x, y + size), SIMD2(x + size, y + size), SIMD2(x + size, y), SIMD2(x, y),
                ])
                holes.append([base, base + 1, base + 2, base + 3])
            }
        }
        return ([0, 1, 2, 3], holes, points)
    }

    /// 畳んだ周を三角形へ分けた枚数と、塗れた面積。
    private nonisolated static func fill(
        _ merged: [Int], points: [SIMD2<Float>]
    ) -> (count: Int, area: Float) {
        let flat = merged.map { points[$0] }
        var area: Float = 0
        let triangles = Triangulation.triangulate(flat)
        for (a, b, c) in triangles {
            area += abs(Triangulation.cross(flat[b] - flat[a], flat[c] - flat[a])) / 2
        }
        return (triangles.count, area)
    }

    @Test("穴を 4 倍にしても、つなぐ手間は 16 倍を越えない", arguments: [(5, 10), (10, 20), (15, 30)])
    func comparisonsGrowQuadraticallyAtMost(_ small: Int, _ large: Int) {
        func comparisons(side: Int) -> Int {
            let scene = Self.shiftedGrid(side: side)
            var count = 0
            let merged = Triangulation.mergeHoles(
                outer: scene.outer, holes: scene.holes, points: scene.points, comparisons: &count)
            // 数えただけで済ませたのではなく、全ての穴を畳み終えたこと
            #expect(merged.count == scene.outer.count + scene.holes.count * 6)
            return count
        }
        let few = comparisons(side: small)
        let many = comparisons(side: large)
        #expect(few > 0)
        #expect(
            many <= 16 * few,
            "穴 \(small * small) で \(few) 回、穴 \(large * large) で \(many) 回 (\(Double(many) / Double(few)) 倍)")
    }

    @Test("ずらした格子は、1×1 から 30×30 まで、枚数も面積も過不足なく分かれる", arguments: Array(1...30))
    func shiftedGridsAreFilledExactly(_ side: Int) {
        let scene = Self.shiftedGrid(side: side)
        let merged = Triangulation.mergeHoles(
            outer: scene.outer, holes: scene.holes, points: scene.points)
        let result = Self.fill(merged, points: scene.points)
        // 穴を畳んだ周は頂点が V + 2H 個で、触れ合わなければ V + 2H − 2 枚へ分かれる
        let holes = side * side
        #expect(result.count == scene.points.count + 2 * holes - 2)
        let outer = Float(4 * (side + 1))
        let expected = outer * outer - Float(holes)
        #expect(abs(result.area / expected - 1) < 1e-4, "面積の比 \(result.area / expected)")
    }

    @Test("数えた回数は、橋を架ける穴が増えると増える")
    func comparisonsCountTheWork() {
        let scene = Self.shiftedGrid(side: 3)
        var one = 0
        _ = Triangulation.mergeHoles(
            outer: scene.outer, holes: Array(scene.holes.prefix(1)), points: scene.points,
            comparisons: &one)
        var all = 0
        _ = Triangulation.mergeHoles(
            outer: scene.outer, holes: scene.holes, points: scene.points, comparisons: &all)
        #expect(one > 0)
        #expect(all > 3 * one)
    }

    /// Canvas の経路が、穴のつなぎの手間を `pointScansInLastFrame` へ足すこと。足していないと、二乗に
    /// 戻っても数に映らない (直す前は `merged.count` だけを積んでいた)。
    @Suite(
        "Canvas の経路の数え口",
        .enabled(
            if: RenderDevice.isAvailable,
            "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
    )
    struct OnCanvas {
        private func scans(side: Int) throws -> Int {
            let scene = MergeHolesCostTests.shiftedGrid(side: side)
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 200)
            try canvas.draw {
                canvas.noStroke()
                canvas.fill(255)
                canvas.beginShape()
                for index in scene.outer { canvas.vertex(scene.points[index].x, scene.points[index].y) }
                for hole in scene.holes {
                    canvas.beginContour()
                    for index in hole { canvas.vertex(scene.points[index].x, scene.points[index].y) }
                    canvas.endContour()
                }
                canvas.endShape(.close)
            }
            return canvas.pointScansInLastFrame
        }

        @Test("穴のつなぎの手間が点の走査に積まれ、穴を 4 倍にしても 16 倍を越えない")
        func mergeCostReachesTheScanCounter() throws {
            let few = try scans(side: 10)
            let many = try scans(side: 20)
            // つなぎの手間だけで 3 万回を越える (`merged.count` だけを積んでいた頃は 数千回)
            #expect(few > 20_000, "穴 100 で \(few) 回")
            #expect(many <= 16 * few, "穴 100 で \(few) 回、穴 400 で \(many) 回")
        }
    }
}
