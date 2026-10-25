// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 触れ合う穴の畳み方 ([#2647])。CPU だけで確かめる。
///
/// 穴が互いに触れ合って並ぶと、畳んだ周が触れる点で自分の角と重なり、耳切りが穴の中を跨ぐ三角形を
/// 耳として通すことがあった。穴の内側だけが抜け、外周と穴の間は塗られるという約束 (#1530・#1886・
/// #2508) は、穴の並べ方によらない。測り方は ``CoordinateMagnitudeHolesTests`` と同じ (面積の相対誤差と
/// 標本点の被覆を `Double` で数える)。
///
/// **根は `mergeHoles` の畳む順だった。** 触れ合う穴の鎖 (A が B に触れ、B が C に触れる) を、右にある
/// 穴から順に畳むと、A から橋で架けた C を先に畳み、後から畳む B が A と C の両方に触れる。入口の点で
/// 長さ 0 の橋を架けて対にできるのは 1 点だけなので、もう 1 点は対にならず、畳んだ周が自分の角と
/// 重なる (``wedgeOverlaps(of:)`` で数える)。触れる穴を先に畳めば、触れる点ごとに対にできる。
///
/// [#2647]: https://github.com/mokume-metal/mokume/issues/2647
@Suite("辺を共有する穴の塗り")
nonisolated struct SharedEdgeHolesTests {
    private nonisolated static func rectangle(
        _ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float
    ) -> [SIMD2<Float>] {
        [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1)]
    }

    nonisolated static let outer = rectangle(0, 0, 320, 320)

    /// #2647 の入力: 穴 A (x 60..80・y 60..100) と穴 B (x 40..80・y 100..160) が、y = 100 の
    /// x 60..80 の辺を共有する。
    nonisolated static let sharedPair = CoordinateMagnitudeHolesTests.Probe(
        "辺を共有する 2 つの穴",
        TouchingHoleScene(
            index: 0, outer: outer, holes: [rectangle(60, 60, 80, 100), rectangle(40, 100, 80, 160)]))

    /// **退行の札。** Issue の入力 (辺を共有する 2 つの穴) は、この直しの前から正しく塗れていた
    /// (完了条件 1 は既に満たされていた)。直しの検証は、直す前に赤くなる下の検査 (4 つの穴の鎖・直す前に
    /// 誤った場面・畳んだ周の重なり) が担う。
    @Test("辺を共有する 2 つの穴は、外周から引いた面積どおりに、重ならず塗れる (#2647)")
    func sharedEdgeIsPaintedOnce() {
        let result = CoordinateMagnitudeHolesTests.judge(Self.sharedPair, CoordinateMagnitudeHolesTests.identity)
        #expect(result.areaError < 1e-9, "面積の相対誤差 \(result.areaError)")
        #expect(result.mismatches == 0, "標本点の食い違い \(result.mismatches)")
    }

    /// 格子点 (20 おき) に長方形の穴をばらまいた場面。**隙間 0 で触れてよい** (辺を共有する・頂点で
    /// 触れる)。穴どうしの内側は重ならない。固定の種から決まる。
    nonisolated static func latticeScenes(count: Int, seed: UInt64 = 2647) -> [CoordinateMagnitudeHolesTests.Probe] {
        var state: UInt64 = seed
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        return (0..<count).map { trial in
            var rects: [(x: Int, y: Int, width: Int, height: Int)] = []
            let wanted = 2 + next(7)
            var attempts = 0
            while rects.count < wanted, attempts < 300 {
                attempts += 1
                let rect = (x: 1 + next(14), y: 1 + next(14), width: 1 + next(3), height: 1 + next(3))
                if rect.x + rect.width > 15 || rect.y + rect.height > 15 { continue }
                let apart = rects.allSatisfy {
                    rect.x >= $0.x + $0.width || $0.x >= rect.x + rect.width
                        || rect.y >= $0.y + $0.height || $0.y >= rect.y + rect.height
                }
                if apart { rects.append(rect) }
            }
            let holes = rects.map {
                rectangle(Float($0.x * 20), Float($0.y * 20), Float(($0.x + $0.width) * 20), Float(($0.y + $0.height) * 20))
            }
            return CoordinateMagnitudeHolesTests.Probe(
                "隙間 0 の格子点の穴 \(trial) (\(rects.count) 個)",
                TouchingHoleScene(index: trial, outer: outer, holes: holes))
        }
    }

    /// 直す前に誤った最小の場面 (格子点の穴の種 1・場面 2719 から、穴を 1 つずつ外して縮めた 4 つ)。
    ///
    /// H3 と H4 は辺を共有し (H4 の上辺が H3 の下辺に載る)、H3 は H1 と H2 の角に 1 点ずつ触れる。
    /// 右から畳むと H1・H2 を先に畳み (H2 は H1 の角から橋で架かる)、後から畳む H3 は H1 との触れる点でだけ
    /// 対になり、H2 との触れる点は対にならない。畳んだ周がそこで自分の角と重なり、耳切りは H2 の中へ
    /// 入り込む三角形を耳として通して、穴の中まで塗り、末尾に裏返った三角形が残った。
    nonisolated static let chain: [[SIMD2<Float>]] = [
        [SIMD2(180, 180), SIMD2(240, 180), SIMD2(240, 160), SIMD2(180, 160)],
        [SIMD2(180, 260), SIMD2(220, 260), SIMD2(220, 200), SIMD2(180, 200)],
        [SIMD2(140, 200), SIMD2(180, 200), SIMD2(180, 180), SIMD2(140, 180)],
        [SIMD2(140, 220), SIMD2(160, 220), SIMD2(160, 200), SIMD2(140, 200)],
    ]

    @Test("穴が辺を共有し、別の 2 つの穴の角に触れても、穴の中まで塗らない (#2647)")
    func sharedEdgeBetweenTouchingHoles() {
        let scene = TouchingHoleScene(index: 0, outer: Self.outer, holes: Self.chain)
        let probe = CoordinateMagnitudeHolesTests.Probe("辺を共有する穴が 2 つの穴に触れる", scene)
        let result = CoordinateMagnitudeHolesTests.judge(probe, CoordinateMagnitudeHolesTests.identity)
        #expect(result.areaError < 1e-9, "面積の相対誤差 \(result.areaError)")
        #expect(result.mismatches == 0, "標本点の食い違い \(result.mismatches)")
        // 三角形は 1 枚も裏返らない (耳切りが穴の中を跨ぐと、末尾に裏返った三角形が残った)
        for t in scene.triangles() {
            #expect(Triangulation.cross(t.1 - t.0, t.2 - t.0) > 0, "裏返った三角形 \(t)")
        }
    }

    /// 隙間 0 の格子点の穴で、直す前に誤った場面 (種・場面の番号)。種 1〜30 の各 3000 場面
    /// (計 9 万) のうち、直す前に誤ったのはこの 8 場面だけだった。
    nonisolated static let formerlyWrong: [(seed: UInt64, index: Int)] = [
        (1, 2719), (2, 2421), (10, 776), (12, 472), (20, 1261), (23, 2258), (25, 1644), (28, 2605),
    ]

    @Test("直す前に誤った隙間 0 の格子点の場面が、面積どおりに塗れる (#2647)")
    func formerlyWrongLatticeScenes() {
        for (seed, index) in Self.formerlyWrong {
            let probe = Self.latticeScenes(count: index + 1, seed: seed)[index]
            let result = CoordinateMagnitudeHolesTests.judge(probe, CoordinateMagnitudeHolesTests.identity)
            #expect(!CoordinateMagnitudeHolesTests.isWrong(result), "種 \(seed) 場面 \(index): \(result)")
        }
    }

    /// 畳んだ周の、頂点の通り道どうしの塗る側のくさびが重なる所の数。0 なら、触れ合う点ごとに周が
    /// 正しく対になっている。
    ///
    /// 周の左が塗る側。頂点を通るたびに、次の点の向きから前の点の向きへ反時計回りに回る角度の
    /// 範囲が、その通り道が持つ塗る側のくさびである。長さ 0 の橋で同じ位置に続く点は、1 つの通り道と
    /// みなす。
    nonisolated static func wedgeOverlaps(of ring: [SIMD2<Float>]) -> Int {
        var merged: [SIMD2<Float>] = []
        for point in ring where merged.last != point { merged.append(point) }
        if merged.count > 1, merged.first == merged.last { merged.removeLast() }
        let count = merged.count
        var visits: [SIMD2<Float>: [(Double, Double)]] = [:]
        func angle(_ vector: SIMD2<Float>) -> Double { atan2(Double(vector.y), Double(vector.x)) }
        for index in 0..<count {
            let here = merged[index]
            let from = angle(merged[(index + 1) % count] - here)
            var to = angle(merged[(index + count - 1) % count] - here)
            while to <= from { to += 2 * .pi }
            visits[here, default: []].append((from, to))
        }
        func overlap(_ a: (Double, Double), _ b: (Double, Double)) -> Bool {
            for shift in [-2 * Double.pi, 0, 2 * Double.pi] where min(a.1, b.1 + shift) - max(a.0, b.0 + shift) > 1e-9 {
                return true
            }
            return false
        }
        var total = 0
        for list in visits.values where list.count > 1 {
            for first in list.indices {
                for second in list.indices where second > first && overlap(list[first], list[second]) {
                    total += 1
                }
            }
        }
        return total
    }

    /// 本番の道 (`splitForNonzero` → `mergeHoles`) が畳んだ周。組み直した形は領域ごとの周をつなぐ。
    nonisolated static func foldedRing(of scene: TouchingHoleScene) -> [SIMD2<Float>] {
        let rings = scene.orientedHoles
        let points = scene.outer + rings.flatMap { $0 }
        var indices: [[Int]] = []
        var next = scene.outer.count
        for hole in rings {
            indices.append(Array(next..<(next + hole.count)))
            next += hole.count
        }
        guard
            let split = Triangulation.splitForNonzero(
                rings: [Array(scene.outer.indices)] + indices, points: points)
        else {
            return Triangulation.mergeHoles(
                outer: Array(scene.outer.indices), holes: indices, points: points
            ).map { points[$0] }
        }
        let all = points + split.crossings.map { $0.point }
        var folded: [SIMD2<Float>] = []
        for region in split.regions {
            let merged =
                region.holes.isEmpty
                ? region.outer
                : Triangulation.mergeHoles(
                    outer: region.outer, holes: region.holes, points: all, slack: split.slack)
            folded += merged.map { all[$0] }
        }
        return folded
    }

    /// 直す前に誤った場面のうち、触れる点が 2 つ以上ある鎖。畳んだ周が自分の角と重ならない
    /// (触れる点ごとに対になっている)。
    @Test("触れ合う穴の鎖を畳んだ周は、自分の角と重ならない (#2647)")
    func foldedRingDoesNotOverlapItself() {
        var scenes = [TouchingHoleScene(index: 0, outer: Self.outer, holes: Self.chain)]
        for (seed, index) in Self.formerlyWrong {
            let probe = Self.latticeScenes(count: index + 1, seed: seed)[index]
            scenes.append(TouchingHoleScene(index: index, outer: Self.outer, holes: probe.holes))
        }
        for scene in scenes {
            #expect(Self.wedgeOverlaps(of: Self.foldedRing(of: scene)) == 0, "場面 \(scene.index)")
        }
    }

    /// 直した後に別の鎖で見つかった、同じ根の場面 (反証役の生成器と、格子 0..20 の三角形・長方形・
    /// L 字の混在場面 20 万から。T 字に触れる点と、頂点どうしが触れる点が 1 つずつの鎖)。
    @Test("頂点と T 字で触れる穴の鎖も、畳んだ周が自分の角と重ならず、塗りが欠けない (#2647)")
    func mixedChainsAreFoldedWithoutOverlap() {
        func points(_ values: [(Float, Float)]) -> [SIMD2<Float>] { values.map { SIMD2($0.0, $0.1) } }
        let outer: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(200, 0), SIMD2(200, 200), SIMD2(0, 200)]
        let chains: [[[SIMD2<Float>]]] = [
            [
                points([(60, 120), (100, 120), (100, 110)]),
                points([(80, 120), (100, 150), (80, 150), (60, 140)]),
                points([(80, 110), (100, 70), (100, 110)]),
            ],
            [
                points([(130, 90), (170, 80), (170, 110)]), points([(150, 70), (150, 80), (170, 80)]),
                points([(170, 110), (190, 110), (190, 150), (170, 150)]),
                points([(140, 140), (140, 120), (150, 120)]),
            ],
        ]
        for (index, holes) in chains.enumerated() {
            let scene = TouchingHoleScene(index: index, outer: outer, holes: holes)
            #expect(Self.wedgeOverlaps(of: Self.foldedRing(of: scene)) == 0, "鎖 \(index)")
            #expect(!scene.isPaintedWrong, "鎖 \(index): \(scene.measure())")
        }
    }
}
