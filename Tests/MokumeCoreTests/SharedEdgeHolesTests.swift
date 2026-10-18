// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 辺を共有する穴の塗り ([#2647])。CPU だけで確かめる。
///
/// 隣り合う穴が辺を重ねると、畳んだ周で重なった辺の両側が穴 (塗らない側) になる。穴の内側だけが
/// 抜け、外周と穴の間は塗られるという約束 (#1530・#1886・#2508) は、穴の並べ方によらない。
/// 測り方は ``CoordinateMagnitudeHolesTests`` と同じ (面積の相対誤差と標本点の被覆を `Double` で数える)。
///
/// [#2647]: https://github.com/mokume-metal/mokume/issues/2647
@Suite("辺を共有する穴の塗り")
struct SharedEdgeHolesTests {
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
    /// 畳んだ周は H1 と H3 の触れる点でつなぎ、H2 との触れる点は同じ位置を別々に通る。H3・H4 を
    /// 畳んだ穴の角が H2 の角に重なると、耳切りはその重なる角を数えずに、H2 の中へ入り込む
    /// 三角形を耳として通し、穴の中まで塗って、末尾に裏返った三角形が残った。
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
}
