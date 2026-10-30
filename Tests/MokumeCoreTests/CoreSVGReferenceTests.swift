// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing
import simd

/// **SVG の参照 (`CoreSVGReference`) そのものの検査** (#3494 の条件 1)。GPU を要しない。
///
/// 参照は CoreSVG (`NSImage(contentsOf:)`) が CPU で描いた絵なので、**OS の版で値が動けば、mokume の SVG を
/// 比べる検査 (`SVGCoverageTests`) が正しい絵を赤にも、狂った絵を緑にもする**。ここは GPU が要らないので、
/// 下限の macOS (ADR-0009・GitHub ホストの `ci-check`) でも手元の版でも毎回走り、同じ値を返すことを見る。
/// 値が動けば、比べる検査より先にここが赤になる。
///
/// 見るのは、参照を使う側が頼る 3 つ: (1) 縁の中間値の誤差が小さい (解析的な面積との差が 0.1 以内 — 比べる検査が
/// 見るのは 50% の白黒と重心で、中間値ではない) (2) 塗り規則 `evenodd` が効く (#2880 の型) (3) 群の
/// `opacity` が子ごとではなく群として 1 度だけ掛かる (#2878 の型)。
@Suite("SVG の参照 (CoreSVG) は、手で解ける形の被覆を返す")
struct CoreSVGReferenceTests {
    private static func svg(_ body: String, width: Int = 128, height: Int = 128) -> String {
        "<svg xmlns='http://www.w3.org/2000/svg' width='\(width)' height='\(height)'>\(body)</svg>"
    }

    private static func total(_ values: [Double]) -> Double { values.reduce(0, +) }

    @Test("rect(10.5, 10.25, 20, 30) は、画素ごとに解析的な面積と 0.1 以内で、総和が 600 に近い")
    func axisAlignedRect() throws {
        let raster = try CoreSVGReference.render(
            svg: Self.svg("<rect x='10.5' y='10.25' width='20' height='30' fill='white'/>"), width: 128, height: 128)
        let polygon: [SIMD2<Double>] = [
            SIMD2(10.5, 10.25), SIMD2(30.5, 10.25), SIMD2(30.5, 40.25), SIMD2(10.5, 40.25),
        ]
        let analytic = CoverageReference.polygonCoverage(polygon, width: 128, height: 128)
        let worst = zip(raster.coverage, analytic).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 0.1, "画素ごとの最大の差 \(worst)")
        #expect(abs(Self.total(raster.coverage) - 600) < 2, "総和 \(Self.total(raster.coverage))")
        // 画素の向きは mokume の readPixels と同じ (左上が原点・y は下向き)
        #expect(raster[20, 20] > 0.99)
        #expect(raster[20, 60] < 0.01)
    }

    @Test("半径 12 の円は、画素ごとに解析的な面積と 0.1 以内で、総和が πr² に近い")
    func circle() throws {
        let raster = try CoreSVGReference.render(
            svg: Self.svg("<circle cx='64.3' cy='63.8' r='12' fill='white'/>"), width: 128, height: 128)
        let analytic = CoverageReference.circleCoverage(
            center: SIMD2(64.3, 63.8), radius: 12, width: 128, height: 128)
        let worst = zip(raster.coverage, analytic).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 0.1, "画素ごとの最大の差 \(worst)")
        #expect(abs(Self.total(raster.coverage) - .pi * 144) < 2, "総和 \(Self.total(raster.coverage))")
    }

    /// #2880 の最小の再現と同じ一筆書きの五芒星。中央の五角形は回り数が 2 で、evenodd では抜け、nonzero では塗られる。
    private static func star(_ rule: String) -> String {
        svg(
            "<path d='M64 8 L84 72 L30 34 L98 34 L44 72 Z' fill='white' fill-rule='\(rule)'/>",
            width: 128, height: 128)
    }

    @Test("evenodd の五芒星は中央が抜け、nonzero は中央も塗られる (どちらも先端は塗られる)")
    func fillRule() throws {
        let evenOdd = try CoreSVGReference.render(svg: Self.star("evenodd"), width: 128, height: 128)
        let nonzero = try CoreSVGReference.render(svg: Self.star("nonzero"), width: 128, height: 128)
        #expect(evenOdd[64, 22] > 0.99 && nonzero[64, 22] > 0.99, "上の先端")
        #expect(evenOdd[64, 40] < 0.01, "evenodd の中央が塗られている: \(evenOdd[64, 40])")
        #expect(nonzero[64, 40] > 0.99, "nonzero の中央が塗られていない: \(nonzero[64, 40])")
    }

    @Test("群の opacity は群として 1 度だけ掛かる (重なった所も opacity のまま・子ごとに掛けると 1−(1−o)² で濃くなる)")
    func groupOpacity() throws {
        let raster = try CoreSVGReference.render(
            svg: Self.svg(
                "<g opacity='0.8'><circle cx='50' cy='64' r='25' fill='white'/>"
                    + "<circle cx='78' cy='64' r='25' fill='white'/></g>"),
            width: 128, height: 128)
        #expect(abs(raster[64, 64] - 0.8) < 0.01, "重なった所 (両方の円の中) \(raster[64, 64])")
        #expect(abs(raster[40, 64] - 0.8) < 0.01, "片方だけの所 \(raster[40, 64])")
        // 子ごとに掛けるなら 0.96
        #expect(raster[64, 64] < 0.9)
    }

    // MARK: - 白黒と重心の道具

    @Test("halfTone は 0.5 以上を真にし、境目の 0.5 は真")
    func halfTone() {
        #expect(CoreSVGReference.halfTone([0, 0.49, 0.5, 0.51, 1]) == [false, false, true, true, true])
    }

    @Test("centroid は被覆で重みを付ける。画素の中心は +0.5・被覆が 0 なら nil")
    func centroid() throws {
        // 4×1: 左から 1・0・0・1 → 重心は x = 2 (中心の 0.5 と 3.5 の平均)
        let even = try #require(CoreSVGReference.centroid([1, 0, 0, 1], width: 4))
        #expect(even == SIMD2(2, 0.5))
        // 重みで寄る: 左の 1 と右の 0.5 → (0.5·1 + 3.5·0.5) / 1.5
        let weighted = try #require(CoreSVGReference.centroid([1, 0, 0, 0.5], width: 4))
        #expect(abs(weighted.x - (0.5 + 1.75) / 1.5) < 1e-12)
        #expect(CoreSVGReference.centroid([0, 0], width: 2) == nil)
    }

    @Test("mismatches は一致しない画素の数、edgePixels は縁の画素の数 (面の端も縁)")
    func counts() {
        #expect(CoreSVGReference.mismatches([true, false, true], [true, true, false]) == 2)
        // 3×3 の面で中央の 1 画素だけ真 → 縁 1。全部真 → 面の端の 8 画素が縁で中央は縁でない
        var one = [Bool](repeating: false, count: 9)
        one[4] = true
        #expect(CoreSVGReference.edgePixels(one, width: 3) == 1)
        #expect(CoreSVGReference.edgePixels([Bool](repeating: true, count: 9), width: 3) == 8)
    }
}
