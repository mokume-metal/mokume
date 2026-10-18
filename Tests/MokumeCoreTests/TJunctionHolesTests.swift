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

    /// 穴の頂点が外周の辺の途中に載る形 (T 字) は、これまでどおり組み直さず、塗れる
    /// (`NonzeroSplitTests` が組み直さないことを見る)。
    @Test("穴の頂点が外周の辺の途中に載っても、外周から引いた面積どおりに塗れる (#2655)")
    func aHoleVertexOnTheOuterEdgeIsPainted() {
        let hole: [SIMD2<Float>] = [SIMD2(100, 0), SIMD2(80, 30), SIMD2(120, 30)]
        let far: [SIMD2<Float>] = [SIMD2(40, 120), SIMD2(60, 120), SIMD2(50, 150)]
        let scene = TouchingHoleScene(index: 0, outer: Self.outer, holes: [hole, far])
        #expect(!scene.isPaintedWrong)
    }
}
