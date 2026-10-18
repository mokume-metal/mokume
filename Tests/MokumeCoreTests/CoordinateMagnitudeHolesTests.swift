// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 穴を抜いた塗りを、座標の桁を大きくして測る ([#2725])。CPU だけで確かめる。
///
/// [#2725]: https://github.com/mokume-metal/mokume/issues/2725
@Suite("座標の桁が大きい穴の塗り")
struct CoordinateMagnitudeHolesTests {
    /// 座標の写し方。`x * scale + offset` を縦横とも同じに掛ける。
    nonisolated struct Mapping: CustomTestStringConvertible, Sendable {
        var name: String
        var scale: Double
        var offset: Double
        var testDescription: String { name }

        func callAsFunction(_ point: SIMD2<Double>) -> SIMD2<Double> { point * scale + offset }
    }

    nonisolated static let identity = Mapping(name: "写さない", scale: 1, offset: 0)
    nonisolated static let translated1e4 = Mapping(name: "原点から 1e4 の平行移動", scale: 1, offset: 10_000)
    nonisolated static let translated1e5 = Mapping(name: "原点から 1e5 の平行移動", scale: 1, offset: 100_000)

    /// 拡大と、原点から 1e4 までの平行移動。
    nonisolated static let nearMappings: [Mapping] = [
        Mapping(name: "10 倍", scale: 10, offset: 0),
        Mapping(name: "1000 倍", scale: 1000, offset: 0),
        translated1e4,
    ]

    /// 原点から離した平行移動。**1e5 までを保証する** ([#2725])。1e6 は保証の外である。
    ///
    /// 3e4 で 25・5e4 で 463・65536 で 751 の場面が誤っていた (直す前)。
    ///
    /// [#2725]: https://github.com/mokume-metal/mokume/issues/2725
    nonisolated static let farMappings: [Mapping] = [
        Mapping(name: "原点から 3e4 の平行移動", scale: 1, offset: 30_000),
        Mapping(name: "原点から 5e4 の平行移動", scale: 1, offset: 50_000),
        Mapping(name: "原点から 65536 の平行移動", scale: 1, offset: 65_536),
        translated1e5,
        Mapping(name: "10 倍して原点から 1e5 の平行移動", scale: 10, offset: 100_000),
    ]

    /// 測る場面。穴は**写す前の小さな座標で**外周と逆回りに揃えておく。
    nonisolated struct Probe: Sendable {
        var name: String
        var outer: [SIMD2<Float>]
        var holes: [[SIMD2<Float>]]

        init(_ name: String, _ scene: TouchingHoleScene) {
            self.name = name
            outer = scene.outer
            holes = scene.orientedHoles
        }
    }

    nonisolated static let probes: [Probe] = {
        let vertex = TouchingHoleScenes.make(.vertexToVertex, count: 400).map {
            Probe("頂点で触れる \($0.index)", $0)
        }
        let tJunction = TouchingHoleScenes.make(.includingTJunctions, count: 400).map {
            Probe("T 字を含む \($0.index)", $0)
        }
        let aligned = (AlignedHolesTests.separate + AlignedHolesTests.touching + AlignedHolesTests.lattice)
            .map { Probe($0.name, TouchingHoleScene(index: 0, outer: $0.outer, holes: $0.holes)) }
        let touches = AlignedHolesTests.touches.map { Probe($0.name, $0.scene) }
        return vertex + tJunction + aligned + touches
    }()

    /// 相対の面積の誤差の上限。
    nonisolated static let areaTolerance = 1e-5

    /// 写した場面を本番の道に通し、**測る側は `Double` で**、面積の相対誤差と標本点の食い違いを数える。
    ///
    /// 本番の道へ渡すのは `Float` に丸めた写した座標で、期待の面積と回り数もその丸めた座標から
    /// 求める (製品が受け取った形を正とする)。`Float` の靴紐の公式は 1e5 の平行移動で項が 1e10 に
    /// なり、測る側の丸めが誤りに見えるので、測る側では `Triangulation.signedArea` を使わない。
    nonisolated static func judge(_ probe: Probe, _ mapping: Mapping) -> (
        areaError: Double, mismatches: Int
    ) {
        func place(_ point: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2<Float>(mapping(SIMD2<Double>(point)))
        }
        let outer = probe.outer.map(place)
        let holes = probe.holes.map { $0.map(place) }
        let triangles = TouchingHoleScene.triangles(outer: outer, rings: holes)

        let wide = { (ring: [SIMD2<Float>]) in ring.map { SIMD2<Double>($0) } }
        let outerD = wide(outer)
        let holesD = holes.map(wide)
        var expected = abs(area(outerD))
        for hole in holesD { expected -= abs(area(hole)) }
        var painted = 0.0
        for t in triangles {
            let (a, b, c) = (SIMD2<Double>(t.0), SIMD2<Double>(t.1), SIMD2<Double>(t.2))
            painted += abs(cross(b - a, c - a)) / 2
        }

        // 標本は写す前の外周の外接矩形を 24×24 に割り、`TouchingHoleScene.measure()` と同じ半端で
        // ずらして置き、同じ写像で写す
        let low = probe.outer.reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0, $1) }
        let high = probe.outer.reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        let step = SIMD2<Double>(high - low) / 24
        // 三角形を 1 度だけ `Double` へ広げ、囲みの箱を添える (標本ごとに広げ直さない。debug は遅い)
        let wideTriangles = triangles.map { t in
            let (a, b, c) = (SIMD2<Double>(t.0), SIMD2<Double>(t.1), SIMD2<Double>(t.2))
            return (a: a, b: b, c: c, low: simd_min(a, simd_min(b, c)), high: simd_max(a, simd_max(b, c)))
        }
        var mismatches = 0
        for row in 0..<24 {
            for column in 0..<24 {
                let original =
                    SIMD2<Double>(low) + step * SIMD2(Double(column) + 0.4119, Double(row) + 0.3137)
                let point = mapping(original)
                var turns = winding(point, outerD)
                for hole in holesD { turns += winding(point, hole) }
                var covered = 0
                for t in wideTriangles {
                    // 囲みの箱の外は、中でも外でも結果が同じ (数えない) ので先に捨てる
                    guard point.x >= t.low.x, point.x <= t.high.x, point.y >= t.low.y, point.y <= t.high.y
                    else { continue }
                    if contains(point, t.a, t.b, t.c) { covered += 1 }
                }
                if (covered > 0) != (turns != 0) || covered > 1 { mismatches += 1 }
            }
        }
        return (abs(painted - expected) / expected, mismatches)
    }

    nonisolated static func isWrong(_ result: (areaError: Double, mismatches: Int)) -> Bool {
        result.areaError > areaTolerance || result.mismatches > 0
    }

    // MARK: - 測る側の幾何 (`Double`)

    private nonisolated static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        a.x * b.y - a.y * b.x
    }

    /// 符号つきの面積。1 つ目の点からの差で足し、平行移動で項が大きくならないようにする。
    private nonisolated static func area(_ ring: [SIMD2<Double>]) -> Double {
        var sum = 0.0
        for index in ring.indices {
            sum += cross(ring[index] - ring[0], ring[(index + 1) % ring.count] - ring[0])
        }
        return sum / 2
    }

    private nonisolated static func winding(_ point: SIMD2<Double>, _ ring: [SIMD2<Double>]) -> Int {
        var total = 0
        for index in ring.indices {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            if a.y <= point.y {
                if b.y > point.y, cross(b - a, point - a) > 0 { total += 1 }
            } else if b.y <= point.y, cross(b - a, point - a) < 0 {
                total -= 1
            }
        }
        return total
    }

    private nonisolated static func contains(
        _ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>
    ) -> Bool {
        let d1 = cross(b - a, p - a)
        let d2 = cross(c - b, p - b)
        let d3 = cross(a - c, p - c)
        return (d1 > 0 && d2 > 0 && d3 > 0) || (d1 < 0 && d2 < 0 && d3 < 0)
    }

    // MARK: - 検査

    /// 写す前に正しかった場面のうち、`mapping` で写すと誤る場面の名前。
    nonisolated static func newlyWrong(_ mapping: Mapping) -> [String] {
        rightBeforeMapping.filter { isWrong(judge($0, mapping)) }.map(\.name)
    }

    /// 写す前に正しかった場面。
    nonisolated static let rightBeforeMapping = probes.filter { !isWrong(judge($0, identity)) }

    /// 写す前に誤るのは、`AlignedHolesTests.tJunctionScenesDoNotRegress` と同じ 1 場面だけ。比べる相手の
    /// 集合がこの判定 (相対誤差・`Double` の標本) でも変わらないことの確かめである。
    @Test("写す前に誤るのは、T 字を含む 78 だけ")
    func wrongBeforeMapping() {
        let wrong = Self.probes.filter { Self.isWrong(Self.judge($0, Self.identity)) }.map(\.name)
        #expect(wrong == ["T 字を含む 78"])
    }

    /// 2 のべきでない拡大と、原点から 1e4 までの平行移動。
    @Test(
        "写す前に正しかった場面は、拡大と 1e4 の平行移動で新しく誤らない",
        arguments: nearMappings)
    func scaledOrNearbyScenesStayRight(_ mapping: Mapping) {
        let wrong = Self.newlyWrong(mapping)
        #expect(wrong.isEmpty, "新しく誤る \(wrong.count) 場面: \(wrong.prefix(5))")
    }

    /// 原点から 1e5 まで離しても、写す前に正しかった場面は新しく誤らない ([#2725])。直す前は
    /// 1e5 で 1133 場面のうち 936 場面が誤った。1e6 は保証の外で、ここでは測らない。
    ///
    /// [#2725]: https://github.com/mokume-metal/mokume/issues/2725
    @Test(
        "写す前に正しかった場面は、原点から 1e5 離しても新しく誤らない (#2725)",
        arguments: farMappings)
    func farTranslatedScenesStayRight(_ mapping: Mapping) {
        let wrong = Self.newlyWrong(mapping)
        #expect(wrong.isEmpty, "新しく誤る \(wrong.count) 場面: \(wrong.prefix(5))")
    }

    /// 以前に誤っていた最小の場面: 外周 320 四方に、40×20 の長方形の穴が 1 つ
    /// (`AlignedHolesTests.lattice` の 6)。原点から 1e5 離すと、面積が約 0.8% 違い、標本点 3 つが
    /// 食い違った。
    @Test("外周 320 四方に長方形の穴 1 つでも、原点から 1e5 離して正しく塗れる (#2725)")
    func smallestFarTranslatedScene() {
        let probe = Probe(
            "長方形の穴 1 つ",
            TouchingHoleScene(
                index: 0, outer: [SIMD2(0, 0), SIMD2(320, 0), SIMD2(320, 320), SIMD2(0, 320)],
                holes: [[SIMD2(180, 260), SIMD2(180, 280), SIMD2(220, 280), SIMD2(220, 260)]]))
        #expect(!Self.isWrong(Self.judge(probe, Self.identity)))
        #expect(!Self.isWrong(Self.judge(probe, Self.translated1e4)))
        let far = Self.judge(probe, Self.translated1e5)
        #expect(!Self.isWrong(far), "面積の誤差 \(far.areaError)・標本の食い違い \(far.mismatches)")
    }

    /// 外周と同じ向きの穴 (回り数 2 の所は塗る) を、原点から 1e5 離しても同じ向きと読む。
    /// 向きを読み違えると穴として抜き、塗るべき所が欠ける (`Triangulation+Crossings` の
    /// `signedArea(of:points:)`)。組み直しが要ると決められた形は `splitForNonzero` が `nil` でなく返す。
    @Test("外周と同じ向きの穴は、原点から 1e5 離しても組み直す対象と読む (#2725)", arguments: [0.0, 100_000])
    func sameDirectionHoleIsReadFarFromOrigin(_ offset: Double) {
        let shift = SIMD2<Float>(repeating: Float(offset))
        let outer: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(320, 0), SIMD2(320, 320), SIMD2(0, 320)]
        let hole: [SIMD2<Float>] = [SIMD2(180, 260), SIMD2(220, 260), SIMD2(220, 280), SIMD2(180, 280)]
        let points = (outer + hole).map { $0 + shift }
        #expect(Triangulation.signedArea(Array(points[0..<4])) > 0)
        #expect(Triangulation.signedArea(Array(points[4..<8])) > 0)
        let split = Triangulation.splitForNonzero(rings: [[0, 1, 2, 3], [4, 5, 6, 7]], points: points)
        #expect(split != nil)
    }
}
