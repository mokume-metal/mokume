// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 穴が触れ合って囲んだ領域 (島) の塗り ([#2656])。CPU だけで確かめる。
///
/// `beginContour` で抜いた穴は、穴の内側だけが抜ける。2 つ以上の穴が触れ合って、外周に通じない領域
/// (島) を囲むと、島は「穴と穴の間」で、外周と穴の間と同じに塗られる (回り数が 0 でない領域が塗られる —
/// #1530・#1886・#2508 と同じ約束)。
///
/// **固定するのは「島が面積どおりに塗られる」ことで、どの道を通すかではない。** この 3 つの入力は、
/// 触れ方を組み直し (`splitForNonzero`) へ送る道でも、送らずに畳む道 (`mergeHoles` → 耳切り) でも、
/// 面積どおりに塗れる (触れ方の判定を全部外しても緑のまま)。組み直しへ送る判定そのものは、
/// `TJunctionHolesTests` と、固定の種の 400 場面の検査 (`AlignedHolesTests` の
/// `vertexTouchingScenesArePaintedOnce`・`tJunctionScenesDoNotRegress`) が見ている。
/// #2656 を出した時点の誤りは、#2657 の最初の版が長さ 0 の橋を遮っていたことに由来すると読める
/// (その版の誤りは 400 場面の検査が捕まえる。この 3 入力は捕まえない)。
///
/// 三角形は、本番の道 (`splitForNonzero` → `mergeHoles` → 耳切り) をそのまま通した結果を読む
/// (`TouchingHoleScene`)。外周はどれも (0,0)(200,0)(200,200)(0,200)。
///
/// [#2656]: https://github.com/mokume-metal/mokume/issues/2656
@Suite("穴が囲んだ島の塗り")
struct IslandHolesTests {
    nonisolated static let outer: [SIMD2<Float>] = [
        SIMD2(0, 0), SIMD2(200, 0), SIMD2(200, 200), SIMD2(0, 200),
    ]

    /// (a) T 字 2 点。穴 A (矢じり) の下の 2 つの角 (60,100)・(140,100) が、穴 B の辺 (40,100)–(160,100) の
    /// 途中に載る。島は (60,100)(100,80)(140,100)・面積 800。
    nonisolated static let tJunctions: [[SIMD2<Float>]] = [
        [SIMD2(60, 100), SIMD2(100, 80), SIMD2(140, 100), SIMD2(100, 60)],
        [SIMD2(40, 100), SIMD2(100, 140), SIMD2(160, 100)],
    ]

    /// (b) 頂点 2 点。A は (a) と同じで、B = (60,100)(100,140)(140,100)。A と B は頂点 (60,100)・(140,100) を
    /// 共有する (辺は共有しない)。島は (a) と同じ。
    nonisolated static let vertices: [[SIMD2<Float>]] = [
        [SIMD2(60, 100), SIMD2(100, 80), SIMD2(140, 100), SIMD2(100, 60)],
        [SIMD2(60, 100), SIMD2(100, 140), SIMD2(140, 100)],
    ]

    /// (c) 3 つの穴の輪。どの 2 つも頂点を 1 つだけ共有する。島は (100,60)(140,130)(60,130)・面積 2,800。
    nonisolated static let ring: [[SIMD2<Float>]] = [
        [SIMD2(100, 60), SIMD2(140, 130), SIMD2(170, 60)],
        [SIMD2(140, 130), SIMD2(60, 130), SIMD2(100, 180)],
        [SIMD2(60, 130), SIMD2(100, 60), SIMD2(30, 60)],
    ]

    /// 期待する塗りの面積 (手で計算した。外周 40,000 から穴の面積を引く)。**得られた三角形から計算した値
    /// ではない。**
    ///
    /// - (a): 40,000 − 800 − 2,400 = 36,800 (穴 A = 1,600 の中の島 800 は、A の面積に含まれない)
    /// - (b): 40,000 − 800 − 1,600 = 37,600
    /// - (c): 40,000 − 2,450 − 2,000 − 2,450 = 33,100
    struct Island: CustomTestStringConvertible, Sendable {
        let name: String
        let holes: [[SIMD2<Float>]]
        let area: Float
        /// 島の内側の点 (塗られる) と、穴の内側の点 (抜ける)。
        let inside: SIMD2<Float>
        let hole: SIMD2<Float>

        var testDescription: String { name }
    }

    nonisolated static let islands: [Island] = [
        Island(
            name: "(a) T 字 2 点", holes: tJunctions, area: 36_800, inside: SIMD2(100, 95),
            hole: SIMD2(100, 70)),
        Island(
            name: "(b) 頂点 2 点", holes: vertices, area: 37_600, inside: SIMD2(100, 95),
            hole: SIMD2(100, 70)),
        Island(
            name: "(c) 3 つの穴の輪", holes: ring, area: 33_100, inside: SIMD2(100, 110),
            hole: SIMD2(140, 80)),
    ]

    @Test("穴が囲んだ島は、外周から穴を引いた面積どおりに塗られ、三角形は裏返らず重ならない (#2656)", arguments: islands)
    func islandIsPainted(_ island: Island) {
        let scene = TouchingHoleScene(index: 0, outer: Self.outer, holes: island.holes)
        #expect(abs(scene.expectedArea - island.area) < 0.5, "手計算の面積 \(island.area)・場面の期待 \(scene.expectedArea)")
        let result = scene.measure()
        #expect(result.areaError < 0.5, "面積の誤差 \(result.areaError)")
        #expect(result.mismatches == 0, "標本点の食い違い \(result.mismatches)")
        var area: Float = 0
        for t in scene.triangles() {
            let signed = Triangulation.cross(t.1 - t.0, t.2 - t.0) / 2
            #expect(signed > 0, "裏返った三角形 \(t)")
            area += signed
        }
        #expect(abs(area - island.area) < 0.5, "面積の総和 \(area)・期待 \(island.area)")
        // 島の内側は塗られ (1 回だけ)、穴の内側は抜ける
        #expect(coverage(scene, at: island.inside) == 1, "島の内側の被覆 \(coverage(scene, at: island.inside))")
        #expect(coverage(scene, at: island.hole) == 0, "穴の内側の被覆 \(coverage(scene, at: island.hole))")
    }

    /// 点 `p` を覆う三角形の数。
    private func coverage(_ scene: TouchingHoleScene, at p: SIMD2<Float>) -> Int {
        scene.triangles().filter { t in
            let d1 = Triangulation.cross(t.1 - t.0, p - t.0)
            let d2 = Triangulation.cross(t.2 - t.1, p - t.1)
            let d3 = Triangulation.cross(t.0 - t.2, p - t.2)
            return d1 > 0 && d2 > 0 && d3 > 0
        }.count
    }
}
