// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 穴が別の穴の辺の途中に T 字に触れる形の塗り ([#2655])。CPU だけで確かめる。
///
/// 頂点が別の穴の辺の途中に載る 2 つの穴に、離れた穴がもう 1 つ加わると、畳んだ周は辺の途中の
/// 点を残したまま、耳が辺の上の点で塞がれて耳切りが途中で止まり、塗りが大きく欠けた。別の周の
/// 頂点が辺の途中に載る形は、辺を頂点で割る組み直し (`splitForNonzero`) へ送り、頂点どうしが
/// 重なる形 (#1886) にして畳む。
///
/// [#2655]: https://github.com/mokume-metal/mokume/issues/2655
@Suite("T 字に触れる穴の塗り")
struct TJunctionHolesTests {
    nonisolated static let outer: [SIMD2<Float>] = [
        SIMD2(0, 0), SIMD2(200, 0), SIMD2(200, 200), SIMD2(0, 200),
    ]

    /// #2655 の最小の入力 (固定の種の場面 78)。
    ///
    /// - 穴 1 の頂点 (90,100) が、穴 2 の辺 (90,90)–(90,120) の途中に載る (T 字)
    /// - 穴 3 は離れている
    nonisolated static let holes: [[SIMD2<Float>]] = [
        [SIMD2(110, 90), SIMD2(90, 100), SIMD2(110, 70)],
        [SIMD2(90, 120), SIMD2(90, 90), SIMD2(80, 110)],
        [SIMD2(80, 140), SIMD2(60, 140), SIMD2(40, 100)],
    ]

    @Test("T 字に触れる 2 つの穴に離れた穴が加わっても、外周から引いた面積どおりに塗れる (#2655)")
    func thirdHoleDoesNotStopTheEarCutting() {
        let scene = TouchingHoleScene(index: 78, outer: Self.outer, holes: Self.holes)
        let result = scene.measure()
        #expect(result.areaError < 0.5, "面積の誤差 \(result.areaError)")
        #expect(result.mismatches == 0, "標本点の食い違い \(result.mismatches)")
        // 三角形は 1 枚も裏返らず、面積の総和が外周から穴を引いたものに一致する
        var area: Float = 0
        for t in scene.triangles() {
            let signed = Triangulation.cross(t.1 - t.0, t.2 - t.0) / 2
            #expect(signed > 0, "裏返った三角形 \(t)")
            area += signed
        }
        #expect(abs(area - scene.expectedArea) < 0.5, "面積の総和 \(area)・期待 \(scene.expectedArea)")
    }

    @Test("T 字に触れる 2 つの穴だけなら、これまでどおり塗れる (#2655)")
    func theTouchingPairAloneIsPainted() {
        let scene = TouchingHoleScene(index: 0, outer: Self.outer, holes: Array(Self.holes.prefix(2)))
        #expect(!scene.isPaintedWrong)
    }

    /// 穴の頂点が**外周の辺**の途中に載る形 (T 字) に、離れた穴がもう 1 つ加わる形。以前は外周の辺に
    /// 載る形を組み直さず、右の辺 (x = 200) に載る向きで、畳んだ周の辺の途中の点が耳を塞いで塗りが
    /// 大きく欠けた (面積の誤差 16,050)。外周と穴の位置を 90 度ずつ回して、4 つの辺の全部で見る。
    ///
    /// 穴 A の頂点 (200,110) が外周の右の辺に載り、穴 B は離れている。
    @Test("穴の頂点が外周のどの辺に載っても、離れた穴が加わって、外周から引いた面積どおりに塗れる (#2655)", arguments: 0..<4)
    func aHoleOnTheOuterEdgeWithAnotherHole(_ quarterTurns: Int) {
        func turned(_ point: SIMD2<Float>) -> SIMD2<Float> {
            var p = point
            for _ in 0..<quarterTurns { p = SIMD2(200 - p.y, p.x) }
            return p
        }
        let a: [SIMD2<Float>] = [SIMD2(180, 110), SIMD2(160, 100), SIMD2(200, 110)]
        let b: [SIMD2<Float>] = [SIMD2(100, 170), SIMD2(140, 170), SIMD2(110, 130)]
        let scene = TouchingHoleScene(
            index: 0, outer: Self.outer, holes: [a, b].map { $0.map(turned) })
        let result = scene.measure()
        #expect(result.areaError < 0.5, "面積の誤差 \(result.areaError)")
        #expect(result.mismatches == 0, "標本点の食い違い \(result.mismatches)")
    }

    /// 三角形・長方形・L 字を格子 0..20 に混ぜた場面 (`TouchingHoleScenes.mixedLattice`・内側が重ならなければ
    /// どんな触れ方もしてよい) のうち、直す前に誤った場面 (種・場面の番号)。種 1・2・3・2655 の各 5,000
    /// 場面のうち、穴の頂点が外周の辺に載る形がこの 10 場面だった。
    nonisolated static let formerlyWrong: [(seed: UInt64, index: Int)] = [
        (1, 2118), (1, 3187), (2, 1630), (3, 2701), (3, 3129), (3, 4711), (2655, 1395), (2655, 2862),
        (2655, 3200), (2655, 4572),
    ]

    @Test("直す前に誤った格子の混在場面が、面積どおりに塗れる (#2655)")
    func formerlyWrongMixedScenes() {
        for (seed, index) in Self.formerlyWrong {
            let scene = TouchingHoleScenes.mixedLattice(count: index + 1, seed: seed)[index]
            #expect(!scene.isPaintedWrong, "種 \(seed) 場面 \(index): \(scene.measure())")
        }
    }
}
