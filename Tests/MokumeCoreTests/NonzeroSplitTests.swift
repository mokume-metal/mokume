// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// `Triangulation.splitForNonzero` が、**縮退した入力**でも回り数が 0 でない所をちょうど
/// 1 度覆うかの検査 ([#1538])。
///
/// 縮退とは、同じ交わりを幾つもの辺の組が通る形 (行って戻る辺・重なって並ぶ辺)、頂点を
/// 通って向こう側へ抜ける形、辺の上にちょうど載る点である。浮動小数の位置の完全一致で
/// 点を繋ぐと、ここで周が閉じずに形が丸ごと消えた。
///
/// **物差しは標本点で数えた回り数である。** 形の囲みを格子に切った点のうち、辺から形の
/// 大きさの 0.5% 以内の点は、どちらに転んでもよいので数えない。分けた三角形で覆われる回数と
/// 回り数が食い違う点を数える。
///
/// [#1538]: https://github.com/mokume-metal/mokume/issues/1538
@Suite("交わった周を分ける: 縮退した入力")
struct NonzeroSplitTests {
    private typealias Triangle = (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)

    /// 回り数との食い違い。
    private struct Coverage {
        /// 回り数 0 なのに覆われた点。
        var spilled = 0
        /// 回り数が 0 でないのに覆われない点。
        var missing = 0
        /// 2 度以上覆われた点。
        var doubled = 0

        var mismatched: Int { spilled + missing + doubled }
    }

    /// 周の組に通しの番号を振る。
    private func numbered(_ rings: [[SIMD2<Float>]]) -> ([[Int]], [SIMD2<Float>]) {
        var points: [SIMD2<Float>] = []
        var indices: [[Int]] = []
        for ring in rings {
            indices.append(Array(points.count..<(points.count + ring.count)))
            points += ring
        }
        return (indices, points)
    }

    /// いまの手順 (分けずに `mergeHoles` → `triangulate`) の三角形。
    private func legacyTriangles(_ rings: [[SIMD2<Float>]]) -> [Triangle] {
        let (indices, points) = numbered(rings)
        let merged =
            indices.count == 1
            ? indices[0]
            : Triangulation.mergeHoles(outer: indices[0], holes: Array(indices.dropFirst()), points: points)
        let flat = merged.map { points[$0] }
        return Triangulation.triangulate(flat).map { (flat[$0.0], flat[$0.1], flat[$0.2]) }
    }

    /// 塗りの経路と同じく、分けられれば分けた組を、`nil` ならいまの手順で三角形にする。
    private func triangles(_ rings: [[SIMD2<Float>]]) -> (split: Triangulation.Split?, triangles: [Triangle]) {
        let (indices, points) = numbered(rings)
        guard let split = Triangulation.splitForNonzero(rings: indices, points: points) else {
            return (nil, legacyTriangles(rings))
        }
        let all = points + split.crossings.map(\.point)
        var result: [Triangle] = []
        for region in split.regions {
            let merged =
                region.holes.isEmpty
                ? region.outer
                : Triangulation.mergeHoles(outer: region.outer, holes: region.holes, points: all)
            let flat = merged.map { all[$0] }
            result += Triangulation.triangulate(flat).map { (flat[$0.0], flat[$0.1], flat[$0.2]) }
        }
        return (split, result)
    }

    private func coverage(
        _ rings: [[SIMD2<Float>]], _ triangles: [Triangle], steps: Int = 80
    ) -> Coverage {
        var low = SIMD2<Float>(repeating: .infinity)
        var high = SIMD2<Float>(repeating: -.infinity)
        for ring in rings {
            for point in ring {
                low = simd_min(low, point)
                high = simd_max(high, point)
            }
        }
        let margin = max(high.x - low.x, high.y - low.y) * 0.005
        var result = Coverage()
        for i in 0..<steps {
            for j in 0..<steps {
                let point = low + (high - low) * SIMD2(Float(i) + 0.4137, Float(j) + 0.6291) / Float(steps)
                if isNearAnEdge(point, rings, within: margin) { continue }
                let turns = winding(point, rings)
                var covered = 0
                for triangle in triangles where contains(triangle, point) { covered += 1 }
                if turns == 0, covered > 0 { result.spilled += 1 }
                if turns != 0, covered == 0 { result.missing += 1 }
                if covered > 1 { result.doubled += 1 }
            }
        }
        return result
    }

    private func winding(_ point: SIMD2<Float>, _ rings: [[SIMD2<Float>]]) -> Int {
        var total = 0
        for ring in rings {
            for index in ring.indices {
                let a = ring[index]
                let b = ring[(index + 1) % ring.count]
                let side = (b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y)
                if a.y <= point.y, b.y > point.y, side > 0 { total += 1 }
                if a.y > point.y, b.y <= point.y, side < 0 { total -= 1 }
            }
        }
        return total
    }

    private func isNearAnEdge(_ point: SIMD2<Float>, _ rings: [[SIMD2<Float>]], within margin: Float) -> Bool {
        for ring in rings {
            for index in ring.indices {
                let a = ring[index]
                let b = ring[(index + 1) % ring.count]
                let length = length_squared(b - a)
                let t = length > 0 ? simd_clamp(dot(point - a, b - a) / length, 0, 1) : 0
                if distance(point, a + t * (b - a)) < margin { return true }
            }
        }
        return false
    }

    private func contains(_ triangle: Triangle, _ point: SIMD2<Float>) -> Bool {
        func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { u.x * v.y - u.y * v.x }
        let (a, b, c) = triangle
        let d1 = cross(b - a, point - a)
        let d2 = cross(c - b, point - b)
        let d3 = cross(a - c, point - c)
        return (d1 > 0 && d2 > 0 && d3 > 0) || (d1 < 0 && d2 < 0 && d3 < 0)
    }

    /// 種を固定した乱数。検査の組は実行ごとに変わらない。
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    // MARK: - 交わりが重なる形 (反証の指摘 1)

    /// 同じ交わりを 2 組の辺が通る。組ごとに求めた交点は 1〜2 ulp ずれる。
    @Test(
        "同じ交わりを幾つもの辺が通っても、形が消えない",
        arguments: ["行って戻る棘", "同じ線を逆にたどる"])
    func overlappingCrossingsKeepTheShape(_ name: String) throws {
        let ring: [SIMD2<Float>]
        switch name {
        case "行って戻る棘":
            // (80, 100)–(0, 60) を往復し、その往復を (0, 40)–(20, 80) が横切る
            ring = [SIMD2(80, 100), SIMD2(0, 60), SIMD2(80, 100), SIMD2(0, 40), SIMD2(20, 80)]
        default:
            // y = 40 の上を (20, 40) → (80, 40) → (0, 40) と戻り、(0, 60)–(80, 0) が横切る
            ring = [SIMD2(20, 40), SIMD2(80, 40), SIMD2(0, 40), SIMD2(0, 60), SIMD2(80, 0)]
        }
        let (split, triangles) = triangles([ring])
        let regions = try #require(split?.regions)
        #expect(!regions.isEmpty)
        let result = coverage([ring], triangles)
        #expect(result.mismatched == 0, "\(result)")
    }

    /// 外周の上辺に、穴の辺が重なって並ぶ (既定の書体の `A` の部品の上端と同じ形)。
    /// 3 本目の周の斜めの辺が、重なった所を横切る。
    @Test(
        "外周と穴の辺が重なる所を別の周が横切っても、形が消えない",
        arguments: ["横に揃った辺", "斜めの辺の上に補間で置いた点"])
    func overlappingEdgesCrossedByAnotherRingKeepTheShape(_ name: String) {
        var random = Seeded(state: name == "横に揃った辺" ? 99 : 7)
        var failures: [String] = []
        for trial in 0..<300 {
            let outer: [SIMD2<Float>]
            let part: [SIMD2<Float>]
            if name == "横に揃った辺" {
                outer = [SIMD2(10, 10), SIMD2(150, 10), SIMD2(150, 150), SIMD2(10, 150)]
                let left = Float(Int.random(in: 20...60, using: &random))
                let right = Float(Int.random(in: 90...140, using: &random))
                part = [SIMD2(left, 10), SIMD2(right, 10), SIMD2(80, 120)]
            } else {
                let top = Float.random(in: 5...20, using: &random)
                outer = [SIMD2(10, top), SIMD2(150, top + 3.3), SIMD2(150, 150), SIMD2(10, 150)]
                func onTop(_ s: Float) -> SIMD2<Float> { outer[0] + (outer[1] - outer[0]) * s }
                part = [onTop(0.2), onTop(0.8), SIMD2(80, 120)]
            }
            let x = Float.random(in: 40...120, using: &random)
            let crossing: [SIMD2<Float>] = [SIMD2(x - 3.7, -10), SIMD2(x + 4.1, -8), SIMD2(x + 1.3, 60)]
            let rings = [outer, part, crossing]
            let result = coverage(rings, triangles(rings).triangles, steps: 40)
            if result.mismatched > 0 { failures.append("\(trial): \(result)") }
        }
        #expect(failures.isEmpty, "\(failures.count) 件: \(failures.prefix(3))")
    }

    /// 穴の最初の点を、外周の辺の上に補間で置く。点は辺のわずかに内か外に落ち、外なら
    /// 穴の辺が外周の辺を極めて短く横切る。
    @Test("穴の点を外周の辺の上に補間で置いても、いまの手順より悪くならない")
    func holesTouchingTheOuterRingByInterpolationDoNotGetWorse() {
        let outer: [SIMD2<Float>] = [SIMD2(13, 17), SIMD2(151, 29), SIMD2(143, 149), SIMD2(7, 141)]
        var random = Seeded(state: 5)
        var failures: [String] = []
        for trial in 0..<300 {
            let s = Float.random(in: 0.05...0.95, using: &random)
            let side = Int.random(in: 0...3, using: &random)
            let onEdge = outer[side] + (outer[(side + 1) % 4] - outer[side]) * s
            let center = SIMD2<Float>(77, 83)
            let q1 = center + SIMD2(Float.random(in: -30...30, using: &random), Float.random(in: -30...30, using: &random))
            let q2 = center + SIMD2(Float.random(in: -30...30, using: &random), Float.random(in: -30...30, using: &random))
            var hole = [onEdge, q1, q2]
            // 外周と逆に回す
            if (Triangulation.signedArea(hole) > 0) == (Triangulation.signedArea(outer) > 0) {
                hole = [onEdge, q2, q1]
            }
            let rings = [outer, hole]
            let now = coverage(rings, triangles(rings).triangles, steps: 40)
            let before = coverage(rings, legacyTriangles(rings), steps: 40)
            if now.mismatched > before.mismatched { failures.append("\(trial): \(now) / \(before)") }
        }
        #expect(failures.isEmpty, "\(failures.count) 件: \(failures.prefix(3))")
    }

    // MARK: - 頂点を通る交わり (反証の指摘 2)

    @Test(
        "頂点を通って向こう側へ抜ける周を、組み直して nonzero で覆う",
        arguments: ["横の辺が最初の点を通る", "斜めの辺に頂点が載る", "縦の辺に頂点が載る"])
    func ringsPassingThroughAVertexAreSplit(_ name: String) throws {
        let ring: [SIMD2<Float>]
        switch name {
        case "横の辺が最初の点を通る":
            ring = [SIMD2(40, 40), SIMD2(60, 20), SIMD2(0, 40), SIMD2(100, 40), SIMD2(60, 120)]
        case "斜めの辺に頂点が載る":
            ring = [SIMD2(40, 40), SIMD2(0, 120), SIMD2(120, 0), SIMD2(120, 80), SIMD2(20, 100)]
        default:
            ring = [SIMD2(40, 80), SIMD2(40, 0), SIMD2(20, 80), SIMD2(40, 20), SIMD2(80, 40)]
        }
        let (split, triangles) = triangles([ring])
        #expect(split != nil)
        let result = coverage([ring], triangles)
        #expect(result.mismatched == 0, "\(result)")
    }

    @Test("2 度通る点で交差する周も組み直す")
    func ringsCrossingAtARevisitedPointAreSplit() {
        // (50, 50) を 2 度通り、2 度目が 1 度目を跨ぐ (中心を点として持つ砂時計)
        let ring: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(50, 50), SIMD2(100, 100), SIMD2(100, 0), SIMD2(50, 50), SIMD2(0, 100),
        ]
        let (split, triangles) = triangles([ring])
        #expect(split != nil)
        let result = coverage([ring], triangles)
        #expect(result.mismatched == 0, "\(result)")
    }

    // MARK: - 同じ向きの穴 (反証の指摘 4)

    @Test("外周と同じ向きの穴は、重なった所を 1 度だけ覆う")
    func aSameDirectionHoleIsCoveredOnce() throws {
        let outer: [SIMD2<Float>] = [SIMD2(10, 10), SIMD2(150, 10), SIMD2(150, 150), SIMD2(10, 150)]
        let triangle: [SIMD2<Float>] = [SIMD2(40, 40), SIMD2(120, 40), SIMD2(80, 120)]
        let (split, triangles) = triangles([outer, triangle])
        let regions = try #require(split?.regions)
        // 三角形は外周に呑まれ、外周 1 つだけが残る
        #expect(regions.count == 1)
        #expect(regions.first?.holes.isEmpty == true)
        let result = coverage([outer, triangle], triangles)
        #expect(result.mismatched == 0, "\(result)")
    }

    // MARK: - 外周の辺に触れる穴 (反証の指摘 5)

    @Test(
        "外周の辺に点が載るだけの穴は組み直さない",
        arguments: ["最初の点が右の辺に載る", "最初の点が左の辺に載る", "最初の点が上の辺に載る", "2 つ目の点が右の辺に載る"])
    func holesTouchingTheOuterRingAreLeftAlone(_ name: String) {
        let outer: [SIMD2<Float>] = [SIMD2(10, 10), SIMD2(150, 10), SIMD2(150, 150), SIMD2(10, 150)]
        let hole: [SIMD2<Float>]
        switch name {
        case "最初の点が右の辺に載る": hole = [SIMD2(150, 80), SIMD2(100, 60), SIMD2(100, 100)]
        case "最初の点が左の辺に載る": hole = [SIMD2(10, 80), SIMD2(60, 100), SIMD2(60, 60)]
        case "最初の点が上の辺に載る": hole = [SIMD2(80, 10), SIMD2(60, 60), SIMD2(100, 60)]
        default: hole = [SIMD2(100, 100), SIMD2(150, 80), SIMD2(100, 60)]
        }
        #expect(Triangulation.signedArea(hole) * Triangulation.signedArea(outer) < 0)
        let (split, triangles) = triangles([outer, hole])
        #expect(split == nil)
        let result = coverage([outer, hole], triangles)
        #expect(result.mismatched == 0, "\(result)")
    }
}
