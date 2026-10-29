// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing
import simd

/// **塗りの被覆の参照 (`CoverageReference`) そのものの検査** (#3217 の条件 1・3)。GPU を要しない。
///
/// 参照は GPU の絵と画素ごとに比べる物差しなので、物差しが狂えば `FillCoverageTests` は正しい絵を赤にも
/// するし、狂った絵を緑にもする。手で解ける形 (画素の境目に乗る長方形・菱形・円の 1/4) の値を固定して、
/// 参照の式を 1 か所壊すとここが赤になるようにする。
@Suite("塗りの被覆の参照は、手で解ける形の面積に一致する")
struct CoverageReferenceTests {
    private static func total(_ values: [Double]) -> Double { values.reduce(0, +) }

    @Test("軸に沿う rect(10.5, 10.25, 20, 30) は、縁の画素が 0.5・0.75 で、総和が 600")
    func axisAlignedRect() {
        let polygon: [SIMD2<Double>] = [
            SIMD2(10.5, 10.25), SIMD2(30.5, 10.25), SIMD2(30.5, 40.25), SIMD2(10.5, 40.25),
        ]
        #expect(abs(CoverageReference.polygonArea(polygon, pixel: 10, 20) - 0.5) < 1e-12)
        #expect(abs(CoverageReference.polygonArea(polygon, pixel: 20, 10) - 0.75) < 1e-12)
        #expect(abs(CoverageReference.polygonArea(polygon, pixel: 10, 10) - 0.375) < 1e-12)
        #expect(CoverageReference.polygonArea(polygon, pixel: 15, 20) == 1)
        #expect(CoverageReference.polygonArea(polygon, pixel: 9, 20) == 0)
        let coverage = CoverageReference.polygonCoverage(polygon, width: 64, height: 64)
        #expect(abs(Self.total(coverage) - 600) < 1e-9, "総和 \(Self.total(coverage))")
    }

    @Test("45° に回した 20×20 は総和が 400。菱形 |x|+|y|≤1 は、原点の 4 画素が 0.5 ずつ")
    func rotatedRect() {
        let rotated = CoverageReference.rotatedRect(
            center: SIMD2(64.3, 64.1), half: SIMD2(10, 10), angle: .pi / 4)
        let coverage = CoverageReference.polygonCoverage(rotated, width: 128, height: 128)
        #expect(abs(Self.total(coverage) - 400) < 1e-9, "総和 \(Self.total(coverage))")

        // 半幅 1/√2 の正方形を 45° 回した菱形 |x|+|y|≤1。原点を角に持つ 4 画素は、辺で半分に切られる
        let diamond = CoverageReference.rotatedRect(
            center: .zero, half: SIMD2(repeating: 1 / 2.0.squareRoot()), angle: .pi / 4)
        for (x, y) in [(0, 0), (-1, 0), (0, -1), (-1, -1)] {
            #expect(abs(CoverageReference.polygonArea(diamond, pixel: x, y) - 0.5) < 1e-12, "(\(x), \(y))")
        }
        #expect(CoverageReference.polygonArea(diamond, pixel: 1, 0) < 1e-12)
        // 巻き方向を逆にしても同じ
        #expect(
            abs(CoverageReference.polygonArea(diamond.reversed(), pixel: 0, 0) - 0.5) < 1e-12)
    }

    @Test("回した rect の向きは rotate と同じ (y が下向きで、正の角は x 軸から y 軸へ)")
    func rotationDirection() {
        // 長い辺 (半幅 4) を 45° 回すと、中心から右下 (+x, +y) へ伸びる。右上へは伸びない
        let long = CoverageReference.rotatedRect(center: SIMD2(10, 10), half: SIMD2(4, 0.5), angle: .pi / 4)
        #expect(CoverageReference.polygonArea(long, pixel: 12, 12) > 0.5, "右下の画素が塗られる")
        #expect(CoverageReference.polygonArea(long, pixel: 12, 7) == 0, "右上の画素は塗られない")
    }

    @Test("円は半径 12 で面積 πr² (±1e-3)。円の 1/4 を含む画素は π/4")
    func circle() {
        let disk = CoverageReference.circleCoverage(
            center: SIMD2(40.3, 41.7), radius: 12, width: 96, height: 96)
        let expected = Double.pi * 144
        #expect(abs(Self.total(disk) - expected) < 1e-3, "総和 \(Self.total(disk)) 期待 \(expected)")

        // 画素の角を中心にした半径 1 の円は、その角に接する 4 画素が 1/4 円 (π/4) ずつ
        for (x, y) in [(10, 10), (9, 10), (10, 9), (9, 9)] {
            let area = CoverageReference.circleArea(center: SIMD2(10, 10), radius: 1, pixel: x, y)
            #expect(abs(area - Double.pi / 4) < 1e-4, "(\(x), \(y)): \(area)")
        }
        // 画素の中心に置いた半径 0.5 の円は、その 1 画素の中に収まる
        let inscribed = CoverageReference.circleArea(center: SIMD2(10.5, 10.5), radius: 0.5, pixel: 10, 10)
        #expect(abs(inscribed - Double.pi / 4) < 1e-4, "\(inscribed)")
        #expect(CoverageReference.circleArea(center: SIMD2(10.5, 10.5), radius: 0.5, pixel: 11, 10) < 1e-9)
    }

    @Test("本体の両端の遊びの写しは、0 と 1 を動かさず、0 / 1 の近くを 1/256 だけ内へ寄せる")
    func snapped() {
        #expect(CoverageReference.snapped(0) == 0)
        #expect(CoverageReference.snapped(1) == 1)
        #expect(CoverageReference.snapped(0.5) == 0.5)
        #expect(CoverageReference.snapped(1.0 / 258) < 1e-15, "1/258 以下は 0 へ揃う")
        #expect(abs(CoverageReference.snapped(0.04) - (0.04 * (1 + 2.0 / 256) - 1.0 / 256)) < 1e-15)
        #expect(CoverageReference.snapped(257.0 / 258) > 1 - 1e-15, "257/258 以上は 1 へ揃う")
    }

    @Test("標本の面積と半平面の式は、厳密な面積と食い違わない")
    func sampledAndHalfPlane() {
        // 画素の中心を通る 45° の縁は、画素を半分に割る
        #expect(abs(CoverageReference.halfPlaneArea(0, SIMD2(1, 1)) - 0.5) < 1e-12)
        // 軸に沿う縁は線形の渡し (中心から 0.25 手前の縁は、画素の 1/4)
        #expect(abs(CoverageReference.halfPlaneArea(0.25, SIMD2(1, 0)) - 0.25) < 1e-12)
        let tilted = CoverageReference.rotatedRect(center: SIMD2(20.4, 20.7), half: SIMD2(5, 3), angle: 0.6)
        for (x, y) in [(20, 18), (17, 20), (24, 22), (22, 23)] {
            let sampled = CoverageReference.sampledArea(x, y, samples: 96) { point in
                Self.insideConvex(tilted, SIMD2(Double(point.x), Double(point.y)))
            }
            let exact = CoverageReference.polygonArea(tilted, pixel: x, y)
            #expect(abs(Double(sampled) - exact) < 0.01, "(\(x), \(y)): 標本 \(sampled) 厳密 \(exact)")
        }
    }

    /// 凸多角形の内か (巻き方向を問わず、全辺で同じ側)。
    private static func insideConvex(_ polygon: [SIMD2<Double>], _ point: SIMD2<Double>) -> Bool {
        var signs = Set<Bool>()
        for index in polygon.indices {
            let (a, b) = (polygon[index], polygon[(index + 1) % polygon.count])
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            signs.insert(cross >= 0)
        }
        return signs.count == 1
    }

    // MARK: - 約束の表

    @Test("三角形の経路の図形を「面積」で比べる行は、表が拒んで名乗る (AA なしは約束の内)")
    func tableRefusesAreaOnTheTrianglePath() {
        for shape in CoverageTable.Shape.allCases {
            #expect(throws: CoverageTable.Refusal.self, "\(shape.rawValue)") {
                try CoverageTable.row(shape, on: .triangles, comparing: .area)
            }
        }
        do {
            _ = try CoverageTable.row(.rotatedRect, on: .triangles, comparing: .area)
            Issue.record("拒まれなかった")
        } catch let refusal as CoverageTable.Refusal {
            #expect(refusal.description.hasPrefix("[coverage] 三角形の経路の「回した rect の塗り」を「面積」"), "\(refusal)")
            #expect(refusal.description.contains("50% の白黒と重心"), "\(refusal)")
            #expect(refusal.description.contains("ADR-0039"), "\(refusal)")
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test("距離関数の経路の塗りの 3 図形は、面積で比べる行があり、許容は 1/255・0.012・0.02")
    func tableHasTheFillRows() throws {
        let tolerances = try CoverageTable.Shape.allCases.map {
            try CoverageTable.row(
                $0, on: .distanceField, comparing: $0 == .axisAlignedRect ? .snappedArea : .area
            ).tolerance
        }
        #expect(tolerances == [1.0 / 255, 0.012, 0.02])
    }

    @Test("表に行が無い組 (参照を持たない比べ方) は、経路が約束していても比べない")
    func tableRefusesWhatItDoesNotHold() {
        #expect(throws: CoverageTable.Refusal.self) {
            try CoverageTable.row(.circle, on: .distanceField, comparing: .linearRamp)
        }
    }

    @Test("表の行はどれも、経路が約束する量で比べている")
    func everyRowIsWithinItsPromise() {
        for row in CoverageTable.rows {
            #expect(
                CoverageTable.promises(row.route).contains(row.quantity),
                "\(row.shape.rawValue): \(row.route.rawValue)は\(row.quantity.rawValue)を約束しない")
            #expect(row.tolerance > 0 && row.tolerance < 0.1, "\(row.shape.rawValue): \(row.tolerance)")
        }
    }
}
