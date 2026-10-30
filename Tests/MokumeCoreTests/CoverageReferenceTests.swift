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

    @Test("距離関数の経路の塗りの 3 図形は、面積で比べる行があり、許容 (円は半径の大きいときの下限) は 1/255・0.012・0.02")
    func tableHasTheFillRows() throws {
        let tolerances = try CoverageTable.Shape.allCases.map {
            try CoverageTable.row(
                $0, on: .distanceField, comparing: $0 == .rotatedRect ? .area : .snappedArea
            ).tolerance
        }
        #expect(tolerances == [1.0 / 255, 0.012, 0.02])
    }

    // MARK: - 曲線の縁の上限 (#3493)

    /// 本体の式の写しと真の面積を、半径 3〜30・画素と縁の相対位置の格子で比べた最大。画素と円の相対位置は、
    /// 縁までの距離 δ (画素の中心から見た円周の符号つき距離・画素の対角の半分の内) と、画素の軸に対する法線の向き θ
    /// (0〜45°・残りは対称) の 2 つで決まるので、乱数でなく格子で数える。
    private static let radii: [Double] = [3, 3.5, 4, 5, 6, 7, 8, 10, 12, 16, 20, 29]
    private static let normals: [Double] = (0...6).map { Double($0) * .pi / 4 / 6 }
    private static let offsets: [Double] = (-12...12).map { Double($0) / 16 }

    /// 画素 (100, 100) の中心から、向き θ へ距離 `radius + offset` だけ離れた所に円の中心を置く。
    private static func circle(radius: Double, offset: Double, angle: Double) -> SIMD2<Double> {
        SIMD2(100.5, 100.5) - SIMD2(cos(angle), sin(angle)) * (radius + offset)
    }

    @Test("曲線の縁 (円) の本体の式の写しは真の面積を下回らず、差 × R の最大は k の内で、k は 1.15 倍以内に収まる")
    func curvedEdgeModelStaysInsideTheConstant() {
        var largest = 0.0, smallest = 0.0, atLargest = ""
        for radius in Self.radii {
            for angle in Self.normals {
                for offset in Self.offsets {
                    let center = Self.circle(radius: radius, offset: offset, angle: angle)
                    let model = CoverageReference.circleModelCoverage(
                        center: center, radius: radius, pixel: 100, 100)
                    let exact = CoverageReference.snapped(
                        CoverageReference.circleArea(center: center, radius: radius, pixel: 100, 100))
                    let scaled = (model - exact) * radius
                    smallest = min(smallest, scaled)
                    if scaled > largest {
                        largest = scaled
                        atLargest = "R=\(radius) δ=\(offset) θ=\(angle)"
                    }
                }
            }
        }
        let k = CoverageTable.curvatureConstant
        #expect(largest <= k, "差 × R の最大 \(largest) が k = \(k) を越える (\(atLargest))")
        #expect(k <= largest * 1.15, "k = \(k) が模型の最大 \(largest) より緩すぎる (\(atLargest))")
        // 凸の縁は面積より暗くならない (写しの丸めは 1e-5 の内)
        #expect(smallest > -1e-4, "凸の縁が面積より暗い: \(smallest)")
    }

    @Test("凹の縁 (帯の内縁) は同じ大きさで暗く出て、差 × R は −k の内")
    func concaveEdgeIsDarkerByTheSameBound() {
        var darkest = 0.0, brightest = 0.0
        for radius in Self.radii {
            for angle in Self.normals {
                for offset in Self.offsets {
                    let center = Self.circle(radius: radius, offset: offset, angle: angle)
                    // 形の内は円板の外: 真の面積は 1 − 円板の被覆
                    let exact = CoverageReference.snapped(
                        1 - CoverageReference.circleArea(center: center, radius: radius, pixel: 100, 100))
                    let model = CoverageReference.circleHoleModelCoverage(
                        center: center, radius: radius, pixel: 100, 100)
                    let scaled = (model - exact) * radius
                    darkest = min(darkest, scaled)
                    brightest = max(brightest, scaled)
                }
            }
        }
        #expect(darkest < -0.1, "凹の縁が暗く出ていない: \(darkest)")
        #expect(darkest >= -CoverageTable.curvatureConstant, "凹の縁の差 × R \(darkest) が −k の外")
        #expect(brightest < 1e-4, "凹の縁が面積より明るい: \(brightest)")
    }

    @Test("円の行の許容は max(0.02, k / R + 余裕)。半径 7 以上は 0.02 のままで、小さいほど広い。許容は模型の差を余裕つきで覆う")
    func circleToleranceIsAFunctionOfTheRadius() throws {
        let row = try CoverageTable.row(.circle, on: .distanceField, comparing: .snappedArea)
        for radius in stride(from: 7.0, to: 30.0, by: 0.5) {
            #expect(row.tolerance(atRadius: radius) == 0.02, "半径 \(radius) の許容が 0.02 でない")
        }
        let k = CoverageTable.curvatureConstant
        #expect(abs(row.tolerance(atRadius: 3) - (k / 3 + CoverageTable.rounding)) < 1e-12)
        #expect(row.tolerance(atRadius: 3) > 0.04 && row.tolerance(atRadius: 3) < 0.05)
        var previous = Double.infinity
        for radius in stride(from: 3.0, to: 30.0, by: 0.25) {
            let tolerance = row.tolerance(atRadius: radius)
            #expect(tolerance <= previous, "半径が大きくなって許容が広がった: \(radius)")
            previous = tolerance
        }
        // 模型の差に、丸めの余裕が残る
        for radius in Self.radii {
            for angle in Self.normals {
                for offset in Self.offsets {
                    let center = Self.circle(radius: radius, offset: offset, angle: angle)
                    let model = CoverageReference.circleModelCoverage(
                        center: center, radius: radius, pixel: 100, 100)
                    let exact = CoverageReference.snapped(
                        CoverageReference.circleArea(center: center, radius: radius, pixel: 100, 100))
                    #expect(
                        model - exact <= row.tolerance(atRadius: radius) - CoverageTable.rounding + 1e-9,
                        "R=\(radius) δ=\(offset) θ=\(angle)")
                }
            }
        }
        // 暗い側 (本体 < 参照) は一方向の差なので、丸めの余裕だけ
        for radius in [3.0, 6, 12, 29] {
            #expect(row.darkTolerance(atRadius: radius) == CoverageTable.rounding)
        }
        // 曲線の行でない行は、半径によらず一定 (両側とも)
        let rect = try CoverageTable.row(.rotatedRect, on: .distanceField, comparing: .area)
        #expect(rect.tolerance(atRadius: 3) == rect.tolerance)
        #expect(rect.darkTolerance(atRadius: 3) == rect.tolerance)
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
