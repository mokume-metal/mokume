// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 穴が縦や横に揃って並ぶ形の三角形化 ([#2508])。CPU だけで確かめる。
///
/// 穴の辺が互いに同じ直線の上に載ると、橋の判定が端点の載る辺を跨ぎに数えず、橋は別の穴の
/// 角を串刺しにして架かった。畳んだ周が自分の上に折り返し、耳切りが三角形を取りこぼして
/// 穴の外まで塗りが欠けた。**物差しは面積の総和と三角形の数**である — 穴を畳んだ周は頂点が
/// `V + 2H` 個 (V は外周と穴の頂点の総数・H は穴の数) の 1 本の周になり、穴が互いに
/// 触れなければ `V + 2H − 2` 枚へ過不足なく分かれる。取りこぼしは枚数と面積の不足に出る。
///
/// 画素に出ることは `ContourFillTests` が GPU で 1 回ずつ確かめる。
///
/// [#2508]: https://github.com/mokume-metal/mokume/issues/2508
@Suite("揃って並ぶ穴の三角形化")
struct AlignedHolesTests {
    /// 外周と穴の組。穴は外周と逆回り。
    nonisolated struct Scene: CustomTestStringConvertible, Sendable {
        var name: String
        var outer: [SIMD2<Float>]
        var holes: [[SIMD2<Float>]]

        var testDescription: String { name }

        /// 外周から穴を引いた面積。
        var expectedArea: Float {
            holes.reduce(abs(Triangulation.signedArea(outer))) {
                $0 - abs(Triangulation.signedArea($1))
            }
        }
    }

    // MARK: - 場面

    private nonisolated static func square(_ size: Float) -> [SIMD2<Float>] {
        [SIMD2(20, 20), SIMD2(20 + size, 20), SIMD2(20 + size, 20 + size), SIMD2(20, 20 + size)]
    }

    /// 左上 `origin`・幅 `width`・高さ `height` の穴 (外周と逆回り)。
    private nonisolated static func hole(
        _ origin: SIMD2<Float>, width: Float = 10, height: Float = 10
    ) -> [SIMD2<Float>] {
        [
            origin, origin + SIMD2(0, height), origin + SIMD2(width, height),
            origin + SIMD2(width, 0),
        ]
    }

    private nonisolated static func scene(
        _ name: String, outer: Float = 240, _ origins: [SIMD2<Float>], size: Float = 10
    ) -> Scene {
        Scene(
            name: name, outer: square(outer),
            holes: origins.map { hole($0, width: size, height: size) })
    }

    /// 縦 1 列に `count` 個 (x を揃える)。
    private nonisolated static func column(_ count: Int) -> [SIMD2<Float>] {
        (0..<count).map { SIMD2(130, 30 + Float($0) * 40) }
    }

    private nonisolated static func row(_ count: Int) -> [SIMD2<Float>] {
        (0..<count).map { SIMD2(30 + Float($0) * 40, 130) }
    }

    private nonisolated static func grid(_ columns: Int, _ rows: Int) -> [SIMD2<Float>] {
        (0..<(columns * rows)).map {
            SIMD2(30 + Float($0 % columns) * 40, 30 + Float($0 / columns) * 40)
        }
    }

    /// 1 つおきに `shift` だけ横へずらした縦 1 列。
    private nonisolated static func zigzag(_ count: Int, shift: Float) -> [SIMD2<Float>] {
        (0..<count).map { SIMD2(130 + ($0 % 2 == 1 ? shift : 0), 30 + Float($0) * 40) }
    }

    /// 大きさの違う穴を、左か右の辺を揃えて縦に積む (間は 15 あける)。
    private nonisolated static func stacked(_ count: Int, rightAligned: Bool) -> Scene {
        var holes: [[SIMD2<Float>]] = []
        var top: Float = 30
        for index in 0..<count {
            let height = Float(10 + index * 5)
            let width = Float(20 + index * 7)
            let left: Float = rightAligned ? 300 - width : 100
            holes.append(hole(SIMD2(left, top), width: width, height: height))
            top += height + 15
        }
        return Scene(
            name: "\(rightAligned ? "右" : "左")の辺を揃えて積んだ大きさの違う穴 \(count) 個",
            outer: square(300), holes: holes)
    }

    /// 外周の左右の辺へ頂点が触れる三角形の穴を縦に並べる。
    private nonisolated static func touchingTheOuter(_ count: Int, left: Bool) -> Scene {
        let holes = (0..<count).map { index -> [SIMD2<Float>] in
            let y = 40 + Float(index) * 40
            return left
                ? [SIMD2(20, y), SIMD2(50, y + 10), SIMD2(50, y + 30)].reversed()
                : [SIMD2(320, y), SIMD2(290, y + 30), SIMD2(290, y + 10)].reversed()
        }
        return Scene(
            name: "外周の\(left ? "左" : "右")の辺へ頂点が触れる三角形の穴 \(count) 個",
            outer: square(300), holes: holes)
    }

    /// 頂点どうしで触れ合うひし形の格子。
    private nonisolated static func diamonds(_ columns: Int, _ rows: Int, half: Float) -> Scene {
        let holes = (0..<(columns * rows)).map { index -> [SIMD2<Float>] in
            let x = 60 + Float(index % columns) * 2 * half
            let y = 60 + Float(index / columns) * 2 * half
            return [
                SIMD2(x, y - half), SIMD2(x + half, y), SIMD2(x, y + half), SIMD2(x - half, y),
            ].reversed()
        }
        return Scene(
            name: "頂点で触れ合うひし形の \(columns)×\(rows) の格子 (半径 \(half))",
            outer: square(400), holes: holes)
    }

    /// 穴どうしが触れない場面。畳んだ周が頂点 `V + 2H` 個の 1 周になるところまで見る。
    nonisolated static let separate: [Scene] = [
        scene("縦 1 列 2 個", column(2)),
        scene("縦 1 列 5 個", column(5)),
        scene("縦 1 列 6 個", column(6)),
        scene("横 1 行 5 個", row(5)),
        scene("5×5 の格子", grid(5, 5)),
        scene("2×2 の格子", grid(2, 2)),
        scene("1×5 の格子", grid(1, 5)),
        scene("3×6 の格子", grid(3, 6)),
        scene("1 つおきに 3 ずらした縦の列", zigzag(5, shift: 3)),
        scene("1 つおきに 3 ずらした縦の列 (6 個)", zigzag(6, shift: 3)),
        scene("1 つおきに 0.37 ずらした縦の列", zigzag(5, shift: 0.37)),
        scene("1 つおきに 10 ずらした (辺が揃う) 縦の列", zigzag(5, shift: 10)),
        scene(
            "一辺 20 の穴の縦 1 列", outer: 300,
            (0..<5).map { SIMD2(100, 30 + Float($0) * 50) }, size: 20),
        stacked(3, rightAligned: false),
        stacked(5, rightAligned: false),
        stacked(3, rightAligned: true),
        stacked(5, rightAligned: true),
        Scene(
            name: "同じ列で隙間の狭い穴 5 個", outer: square(300),
            holes: (0..<5).map { hole(SIMD2(100, 30 + Float($0) * 30), height: 20) }),
        Scene(
            name: "同じ行で隙間の狭い穴 5 個", outer: square(300),
            holes: (0..<5).map { hole(SIMD2(30 + Float($0) * 40, 100), width: 20) }),
    ]

    /// 穴が外周や互いに頂点で触れる場面。触れた点で周が自分に触れ、同じ位置の角が面積を持たずに
    /// 外れるので、三角形の数は `V + 2H − 2` に満たない。面積だけを見る。
    nonisolated static let touching: [Scene] =
        [1, 3, 6].flatMap { count in
            [touchingTheOuter(count, left: true), touchingTheOuter(count, left: false)]
        } + [
            diamonds(1, 2, half: 10), diamonds(2, 2, half: 10), diamonds(3, 4, half: 20),
            diamonds(6, 6, half: 5),
        ]

    /// 格子点 (20 おき) に長方形の穴をばらまいた場面。隙間を 1 目盛り空けるので、辺や頂点の
    /// 座標が互いにたくさん揃うが、穴どうしは触れない。乱数は固定の種から決まる。
    nonisolated static let lattice: [Scene] = {
        var state: UInt64 = 2508
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        return (0..<300).map { trial in
            var rects: [(x: Int, y: Int, width: Int, height: Int)] = []
            let wanted = 1 + next(8)
            var attempts = 0
            while rects.count < wanted, attempts < 200 {
                attempts += 1
                let rect = (
                    x: 1 + next(14), y: 1 + next(14), width: 1 + next(3), height: 1 + next(3)
                )
                if rect.x + rect.width > 15 || rect.y + rect.height > 15 { continue }
                let apart = rects.allSatisfy {
                    rect.x >= $0.x + $0.width + 1 || $0.x >= rect.x + rect.width + 1
                        || rect.y >= $0.y + $0.height + 1 || $0.y >= rect.y + rect.height + 1
                }
                if apart { rects.append(rect) }
            }
            return Scene(
                name: "格子点の穴 \(trial) (\(rects.count) 個)",
                outer: [SIMD2(0, 0), SIMD2(320, 0), SIMD2(320, 320), SIMD2(0, 320)],
                holes: rects.map {
                    hole(
                        SIMD2(Float($0.x * 20), Float($0.y * 20)), width: Float($0.width * 20),
                        height: Float($0.height * 20))
                })
        }
    }()

    // MARK: - 検査

    /// 穴を畳み、三角形へ分けた結果。
    private struct Result {
        var ring: [SIMD2<Float>]
        var triangles: [(Int, Int, Int)]
        var vertexCount: Int
        var holeCount: Int

        var area: Float {
            triangles.reduce(0) { total, t in
                let a = ring[t.0]
                let b = ring[t.1]
                let c = ring[t.2]
                return total + abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
            }
        }
    }

    private func run(_ scene: Scene) -> Result {
        let points = scene.outer + scene.holes.flatMap { $0 }
        var holeIndices: [[Int]] = []
        var next = scene.outer.count
        for hole in scene.holes {
            holeIndices.append(Array(next..<(next + hole.count)))
            next += hole.count
        }
        let merged = Triangulation
            .mergeHoles(outer: Array(scene.outer.indices), holes: holeIndices, points: points)
            .map { points[$0] }
        return Result(
            ring: merged, triangles: Triangulation.triangulate(merged), vertexCount: points.count,
            holeCount: scene.holes.count)
    }

    @Test(
        "穴が揃って並んでも、三角形の面積の総和が外周から穴を引いたものに一致する",
        arguments: separate + touching + lattice)
    func areaMatchesOuterMinusHoles(_ scene: Scene) {
        let result = run(scene)
        #expect(abs(result.area - scene.expectedArea) < 0.5)
    }

    @Test("穴が揃って並んでも、三角形の数が V + 2H − 2 になる", arguments: separate + lattice)
    func triangleCountIsVertexCountPlusTwiceHolesMinusTwo(_ scene: Scene) {
        let result = run(scene)
        #expect(result.ring.count == result.vertexCount + 2 * result.holeCount)
        #expect(result.triangles.count == result.vertexCount + 2 * result.holeCount - 2)
    }
}
