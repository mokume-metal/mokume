// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 交わった周を、回り数が奇数の所だけ残して分ける ([#2880])。CPU だけで確かめる。
///
/// SVG の `fill-rule="evenodd"` は、自分と交わる 1 本の周にも掛かる。一筆書きの五芒星は、
/// 中央の五角形の回り数が 2 なので、`nonzero` では塗られ、`evenodd` では抜ける。
/// `Triangulation.splitForNonzero` の `evenOdd` が、同じ分け方で偶奇の塗りを出す。
///
/// 測り方: 標本点を格子に置き、**回り数 (`Double` で数える) の偶奇**が期待する被覆で、本番の
/// 道 (`splitForNonzero` → `mergeHoles` → 耳切り) が出した三角形がちょうど 1 枚で覆うか、
/// 1 枚も覆わないかを見る。
///
/// [#2880]: https://github.com/mokume-metal/mokume/issues/2880
@Suite("偶奇の塗りで分ける")
nonisolated struct EvenOddSplitTests {
    /// 一筆書きの五芒星 (#2880 の最小の再現と同じ点。SVG の座標で縦軸は下向き)。
    nonisolated static let pentagram: [SIMD2<Float>] = [
        SIMD2(120, 15), SIMD2(160, 140), SIMD2(55, 65), SIMD2(185, 65), SIMD2(80, 140),
    ]

    private nonisolated static func rectangle(
        _ x: Float, _ y: Float, _ width: Float, _ height: Float
    ) -> [SIMD2<Float>] {
        [SIMD2(x, y), SIMD2(x + width, y), SIMD2(x + width, y + height), SIMD2(x, y + height)]
    }

    private nonisolated static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        a.x * b.y - a.y * b.x
    }

    /// 点のまわりの、周の回り数 (`Double`)。
    private nonisolated static func winding(_ point: SIMD2<Double>, _ ring: [SIMD2<Float>]) -> Int {
        var total = 0
        for index in ring.indices {
            let a = SIMD2<Double>(ring[index])
            let b = SIMD2<Double>(ring[(index + 1) % ring.count])
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

    /// 本番の道 (`Canvas.fillTriangles` と同じ手順) で三角形へ分ける。
    nonisolated static func triangles(
        _ rings: [[SIMD2<Float>]], evenOdd: Bool
    ) -> [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] {
        let points = rings.flatMap { $0 }
        var indices: [[Int]] = []
        var next = 0
        for ring in rings {
            indices.append(Array(next..<(next + ring.count)))
            next += ring.count
        }
        var triangles: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] = []
        guard
            let split = Triangulation.splitForNonzero(
                rings: indices, points: points, evenOdd: evenOdd)
        else {
            let merged = Triangulation.mergeHoles(
                outer: indices[0], holes: Array(indices.dropFirst()), points: points)
            let flat = merged.map { points[$0] }
            for t in Triangulation.triangulate(flat) { triangles.append((flat[t.0], flat[t.1], flat[t.2])) }
            return triangles
        }
        var all = points
        for crossing in split.crossings { all.append(crossing.point) }
        for region in split.regions {
            let merged =
                region.holes.isEmpty
                ? region.outer
                : Triangulation.mergeHoles(
                    outer: region.outer, holes: region.holes, points: all, slack: split.slack)
            let flat = merged.map { all[$0] }
            var comparisons = 0
            for t in Triangulation.triangulate(flat, comparisons: &comparisons, slack: split.slack) {
                triangles.append((flat[t.0], flat[t.1], flat[t.2]))
            }
        }
        return triangles
    }

    /// 標本の格子の上で、塗るべきか (回り数が規則どおりか) と三角形の被覆が食い違う数と、
    /// 塗った標本の数。
    nonisolated static func mismatches(
        _ rings: [[SIMD2<Float>]], evenOdd: Bool
    ) -> (wrong: Int, painted: Int) {
        let triangles = triangles(rings, evenOdd: evenOdd)
        let all = rings.flatMap { $0 }
        let low = all.reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0, $1) }
        let high = all.reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        let step = SIMD2<Double>(high - low) / 48
        var wrong = 0
        var painted = 0
        for row in 0..<48 {
            for column in 0..<48 {
                let point = SIMD2<Double>(low) + step * SIMD2(Double(column) + 0.4119, Double(row) + 0.3137)
                var turns = 0
                for ring in rings { turns += winding(point, ring) }
                let expected = evenOdd ? turns % 2 != 0 : turns != 0
                var covered = 0
                for t in triangles
                where contains(point, SIMD2<Double>(t.0), SIMD2<Double>(t.1), SIMD2<Double>(t.2)) {
                    covered += 1
                }
                if covered > 1 || (covered == 1) != expected { wrong += 1 }
                if covered == 1 { painted += 1 }
            }
        }
        return (wrong, painted)
    }

    @Test("五芒星は evenodd で中央が抜け、nonzero では中央も塗られる (#2880)")
    func pentagramCenterFollowsTheRule() {
        let evenOdd = Self.mismatches([Self.pentagram], evenOdd: true)
        let nonzero = Self.mismatches([Self.pentagram], evenOdd: false)
        #expect(evenOdd.wrong == 0, "evenodd: 食い違う標本 \(evenOdd.wrong)")
        #expect(nonzero.wrong == 0, "nonzero: 食い違う標本 \(nonzero.wrong)")
        // 2 つの規則の差が残る: 中央の五角形のぶん、塗る標本が evenodd のほうが少ない
        #expect(evenOdd.painted < nonzero.painted, "\(evenOdd.painted) / \(nonzero.painted)")
        // 中央 (SVG の (120, 85)) の標本は、evenodd で塗られない
        let center = Self.triangles([Self.pentagram], evenOdd: true)
        let inside = center.contains {
            Self.contains(SIMD2(120, 85), SIMD2<Double>($0.0), SIMD2<Double>($0.1), SIMD2<Double>($0.2))
        }
        #expect(!inside, "中央が塗られている")
    }

    /// 向きの違う 2 本は、重なった所の回り数が 0 になって `nonzero` でも抜ける。同じ向きの 2 本は
    /// 重なった所が回り数 2 になり、`nonzero` では塗られるが `evenodd` では抜ける。
    @Test("重なる 2 本の周は、向きに依らず evenodd で重なりが抜ける (#2880)", arguments: [false, true])
    func overlappingRingsLeaveTheOverlapOut(_ reversed: Bool) {
        let first = Self.rectangle(0, 0, 60, 40)
        let second = Self.rectangle(40, 20, 60, 40)
        let rings = [first, reversed ? Array(second.reversed()) : second]
        let evenOdd = Self.mismatches(rings, evenOdd: true)
        #expect(evenOdd.wrong == 0, "食い違う標本 \(evenOdd.wrong)")
        let nonzero = Self.mismatches(rings, evenOdd: false)
        #expect(nonzero.wrong == 0, "nonzero: 食い違う標本 \(nonzero.wrong)")
        if reversed {
            // 向きが逆なら重なりの回り数は 0 で、どちらの規則でも抜ける。塗る標本は同じ
            #expect(evenOdd.painted == nonzero.painted, "\(evenOdd.painted) / \(nonzero.painted)")
        } else {
            // 同じ向きなら重なりは回り数 2 で、nonzero は塗り、evenodd は抜ける
            #expect(evenOdd.painted < nonzero.painted, "\(evenOdd.painted) / \(nonzero.painted)")
        }
    }

    /// 同じ周を 2 度重ねると、どの所も回り数が偶数で、何も塗られない。
    @Test("同じ周を重ねた形は、evenodd では何も塗らない (#2880)")
    func coincidentRingsPaintNothing() {
        let ring = Self.rectangle(0, 0, 40, 40)
        let result = Self.mismatches([ring, ring], evenOdd: true)
        #expect(result.painted == 0, "塗った標本 \(result.painted)")
        #expect(result.wrong == 0)
    }

    /// 自分と交わらない周は、規則に依らず同じに塗る (既存の塗りを変えない)。
    @Test("交わらない周は、evenodd でも nonzero でも同じ三角形になる (#2880)")
    func simpleRingIsUnchanged() {
        let ring = Self.rectangle(0, 0, 50, 30)
        let a = Self.triangles([ring], evenOdd: true)
        let b = Self.triangles([ring], evenOdd: false)
        #expect(a.count == b.count && a.count == 2)
        let concave: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(60, 0), SIMD2(60, 60), SIMD2(30, 20), SIMD2(0, 60)]
        #expect(Self.mismatches([concave], evenOdd: true).wrong == 0)
    }
}
