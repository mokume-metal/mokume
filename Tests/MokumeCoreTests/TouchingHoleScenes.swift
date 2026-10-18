// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

#if canImport(MokumeCore)
    @testable import MokumeCore
#endif

/// 穴が頂点で触れ合う・辺の途中に触れる場面を、固定の種から作って測る道具 ([#2508])。
/// CPU だけで動き、`Triangulation` の本番の道 (`splitForNonzero` → `mergeHoles` → 耳切り) を
/// そのまま通す。
///
/// 外周は 200×200 の矩形、穴は 10 おきの格子点に置いた 3〜5 角形で、互いの内側が重ならず、
/// 辺が長さを持って重ならない。**触れてよいのは 1 点だけ**で、頂点どうしが重なる・頂点が別の
/// 穴の辺の途中に載る (T 字) の 2 通りがある。
///
/// [#2508]: https://github.com/mokume-metal/mokume/issues/2508
nonisolated struct TouchingHoleScene: Sendable {
    var index: Int
    var outer: [SIMD2<Float>]
    var holes: [[SIMD2<Float>]]

    /// 外周から穴を引いた面積。
    var expectedArea: Float {
        holes.reduce(abs(Triangulation.signedArea(outer))) { $0 - abs(Triangulation.signedArea($1)) }
    }

    /// 外周と逆回りに揃えた穴。
    var orientedHoles: [[SIMD2<Float>]] {
        let turn = Triangulation.signedArea(outer)
        return holes.map { Triangulation.signedArea($0) * turn > 0 ? Array($0.reversed()) : $0 }
    }

    /// 本番の道 (`splitForNonzero` → `mergeHoles` → 耳切り) で分けた三角形。
    func triangles() -> [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] {
        Self.triangles(outer: outer, rings: orientedHoles)
    }

    /// 外周と、外周と逆回りに揃えた穴を、本番の道で三角形へ分ける。回りは揃え直さない
    /// (揃えるのは呼ぶ側 — 座標の大きい場面では `Float` の面積で回りを読み違えうるため)。
    static func triangles(
        outer: [SIMD2<Float>], rings: [[SIMD2<Float>]]
    ) -> [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] {
        let points = outer + rings.flatMap { $0 }
        var holeIndices: [[Int]] = []
        var next = outer.count
        for hole in rings {
            holeIndices.append(Array(next..<(next + hole.count)))
            next += hole.count
        }
        var triangles: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] = []
        var comparisons = 0
        if let split = Triangulation.splitForNonzero(
            rings: [Array(outer.indices)] + holeIndices, points: points, comparisons: &comparisons)
        {
            let all = points + split.crossings.map { $0.point }
            for region in split.regions {
                let merged =
                    region.holes.isEmpty
                    ? region.outer
                    : Triangulation.mergeHoles(
                        outer: region.outer, holes: region.holes, points: all, slack: split.slack)
                let flat = merged.map { all[$0] }
                for t in Triangulation.triangulate(flat, comparisons: &comparisons, slack: split.slack) {
                    triangles.append((flat[t.0], flat[t.1], flat[t.2]))
                }
            }
        } else {
            let merged = Triangulation.mergeHoles(
                outer: Array(outer.indices), holes: holeIndices, points: points
            ).map { points[$0] }
            for t in Triangulation.triangulate(merged) {
                triangles.append((merged[t.0], merged[t.1], merged[t.2]))
            }
        }
        return triangles
    }

    /// 本番の道で三角形へ分けた結果の、面積の誤差と、標本点の被覆の食い違いの数。
    ///
    /// 食い違いは、回り数が 0 でない点が三角形に覆われていない、回り数が 0 の点が覆われている、
    /// 1 点が 2 枚以上に覆われている、のどれか。標本は格子の 24×24 で、辺の上に載らないよう
    /// 半端にずらしてある。
    func measure() -> (areaError: Float, mismatches: Int) {
        let rings = orientedHoles
        let triangles = triangles()
        var painted: Float = 0
        for t in triangles { painted += abs(Triangulation.cross(t.1 - t.0, t.2 - t.0)) / 2 }
        var expected = abs(Triangulation.signedArea(outer))
        for hole in rings { expected -= abs(Triangulation.signedArea(hole)) }

        var mismatches = 0
        let step = Float(200) / 24
        var y = step * 0.3137
        while y < 200 {
            var x = step * 0.4119
            while x < 200 {
                let point = SIMD2<Float>(x, y)
                var winding = Self.winding(point, outer)
                for hole in rings { winding += Self.winding(point, hole) }
                var covered = 0
                for t in triangles where Self.contains(point, t.0, t.1, t.2) { covered += 1 }
                if (covered > 0) != (winding != 0) || covered > 1 { mismatches += 1 }
                x += step
            }
            y += step
        }
        return (abs(painted - expected), mismatches)
    }

    /// 誤っているか。面積が 0.5 より違うか、標本点の食い違いがある。
    var isPaintedWrong: Bool {
        let result = measure()
        return result.areaError > 0.5 || result.mismatches > 0
    }

    private static func winding(_ point: SIMD2<Float>, _ ring: [SIMD2<Float>]) -> Int {
        var total = 0
        for index in ring.indices {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            if a.y <= point.y {
                if b.y > point.y, Triangulation.cross(b - a, point - a) > 0 { total += 1 }
            } else if b.y <= point.y, Triangulation.cross(b - a, point - a) < 0 {
                total -= 1
            }
        }
        return total
    }

    private static func contains(
        _ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>
    ) -> Bool {
        let d1 = Triangulation.cross(b - a, p - a)
        let d2 = Triangulation.cross(c - b, p - b)
        let d3 = Triangulation.cross(a - c, p - c)
        return (d1 > 0 && d2 > 0 && d3 > 0) || (d1 < 0 && d2 < 0 && d3 < 0)
    }
}

/// 固定の種から作る場面の集まり。
nonisolated enum TouchingHoleScenes {
    /// 触れ方。
    enum Kind: Sendable {
        /// 頂点どうしが重なる触れ方だけ。
        case vertexToVertex
        /// 頂点が別の穴の辺の途中に載る (T 字) 触れ方も含む。
        case includingTJunctions
    }

    /// `kind` の場面を `count` 個。種は `kind` ごとに固定。
    static func make(_ kind: Kind, count: Int) -> [TouchingHoleScene] {
        var state: UInt64 = kind == .vertexToVertex ? 20_251_014 : 2508
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let outer: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(200, 0), SIMD2(200, 200), SIMD2(0, 200)]
        return (0..<count).map { index in
            var polygons: [[SIMD2<Float>]] = []
            let wanted = 2 + next(9)
            var attempts = 0
            while polygons.count < wanted, attempts < 400 {
                attempts += 1
                let sides = 3 + next(kind == .vertexToVertex ? 3 : 2)
                let centre = (x: 1 + next(18), y: 1 + next(18))
                var lattice: [(x: Int, y: Int)] = []
                for _ in 0..<sides { lattice.append((centre.x + next(5) - 2, centre.y + next(5) - 2)) }
                if lattice.contains(where: { $0.x < 1 || $0.x > 19 || $0.y < 1 || $0.y > 19 }) {
                    continue
                }
                let polygon = lattice.map { SIMD2<Float>(Float($0.x) * 10, Float($0.y) * 10) }
                guard isSimple(polygon) else { continue }
                let clashes = polygons.contains {
                    kind == .vertexToVertex ? clashesBeyondVertices($0, polygon) : clashesBeyondPoints($0, polygon)
                }
                if !clashes { polygons.append(polygon) }
            }
            return TouchingHoleScene(index: index, outer: outer, holes: polygons)
        }
    }

    // MARK: - 幾何

    private static func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        Triangulation.cross(b - a, c - a)
    }

    /// 閉じた線分どうしが共有点を持つか (触れるのも含む)。格子点の整数なので厳密に比べる。
    private static func segmentsTouch(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>
    ) -> Bool {
        func within(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ r: SIMD2<Float>) -> Bool {
            min(p.x, q.x) <= r.x && r.x <= max(p.x, q.x) && min(p.y, q.y) <= r.y && r.y <= max(p.y, q.y)
        }
        let o1 = cross(a, b, c)
        let o2 = cross(a, b, d)
        let o3 = cross(c, d, a)
        let o4 = cross(c, d, b)
        if o1 != 0, o2 != 0, o3 != 0, o4 != 0, (o1 > 0) != (o2 > 0), (o3 > 0) != (o4 > 0) { return true }
        return (o1 == 0 && within(a, b, c)) || (o2 == 0 && within(a, b, d))
            || (o3 == 0 && within(c, d, a)) || (o4 == 0 && within(c, d, b))
    }

    /// 自分と交わらず、面積があり、隣り合う辺が折り返さない多角形か。
    private static func isSimple(_ polygon: [SIMD2<Float>]) -> Bool {
        guard abs(Triangulation.signedArea(polygon)) > 0 else { return false }
        let count = polygon.count
        for first in 0..<count {
            for second in (first + 1)..<count {
                let a = polygon[first]
                let b = polygon[(first + 1) % count]
                let c = polygon[second]
                let d = polygon[(second + 1) % count]
                if second == first + 1 || (first == 0 && second == count - 1) {
                    // 隣り合う辺が一直線なら折り返すものは許さない
                    if Triangulation.cross(b - a, d - c) == 0 { return false }
                    continue
                }
                if segmentsTouch(a, b, c, d) { return false }
            }
        }
        return true
    }

    private static func contains(_ point: SIMD2<Float>, _ polygon: [SIMD2<Float>]) -> Bool {
        var inside = false
        var last = polygon.count - 1
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[last]
            if (a.y > point.y) != (b.y > point.y),
                point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
            {
                inside.toggle()
            }
            last = index
        }
        return inside
    }

    private static func lies(_ point: SIMD2<Float>, on polygon: [SIMD2<Float>]) -> Bool {
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            if cross(a, b, point) == 0, min(a.x, b.x) <= point.x, point.x <= max(a.x, b.x),
                min(a.y, b.y) <= point.y, point.y <= max(a.y, b.y)
            {
                return true
            }
        }
        return false
    }

    /// 2 つの多角形が、頂点どうしが重なる以外の触れ方 (跨ぐ・重なる・辺に載る・内側に入る)
    /// をするか。
    private static func clashesBeyondVertices(_ p: [SIMD2<Float>], _ q: [SIMD2<Float>]) -> Bool {
        for i in p.indices {
            for j in q.indices {
                let a = p[i]
                let b = p[(i + 1) % p.count]
                let c = q[j]
                let d = q[(j + 1) % q.count]
                guard segmentsTouch(a, b, c, d) else { continue }
                // 触れてよいのは、端点どうしが重なる 1 点だけ
                guard a == c || a == d || b == c || b == d else { return true }
                // 同じ辺 (向きは逆) を共有するのは、触れるのではなく辺が重なる
                if (a == c && b == d) || (a == d && b == c) { return true }
                if Triangulation.cross(b - a, d - c) == 0, Triangulation.cross(b - a, c - a) == 0 {
                    let along = dot(b - a, d - c)
                    if (a == c && b != d && along > 0) || (b == d && a != c && along > 0)
                        || (a == d && b != c && along < 0) || (b == c && a != d && along < 0)
                    {
                        return true
                    }
                }
            }
        }
        return hasInnerPoint(of: p, inside: q) || hasInnerPoint(of: q, inside: p)
    }

    /// 2 つの多角形が、1 点で触れる (頂点どうし・頂点と辺の途中) 以外の触れ方をするか。
    private static func clashesBeyondPoints(_ p: [SIMD2<Float>], _ q: [SIMD2<Float>]) -> Bool {
        for i in p.indices {
            for j in q.indices {
                let a = p[i]
                let b = p[(i + 1) % p.count]
                let c = q[j]
                let d = q[(j + 1) % q.count]
                let o1 = cross(a, b, c)
                let o2 = cross(a, b, d)
                let o3 = cross(c, d, a)
                let o4 = cross(c, d, b)
                if o1 * o2 < 0, o3 * o4 < 0 { return true }
                if o1 == 0, o2 == 0 {
                    let along = b - a
                    let first = dot(c - a, along)
                    let second = dot(d - a, along)
                    let length = dot(along, along)
                    if min(max(first, second), length) > max(min(first, second), 0) { return true }
                }
            }
        }
        return hasInnerPoint(of: p, inside: q) || hasInnerPoint(of: q, inside: p)
    }

    /// `polygon` の頂点か辺の中点が、`other` の内側 (周の上は含まない) にあるか。内側へ入り込む
    /// 形 (重なる・入れ子) を見つける。
    private static func hasInnerPoint(of polygon: [SIMD2<Float>], inside other: [SIMD2<Float>]) -> Bool {
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            for point in [a, (a + b) / 2] where contains(point, other) && !lies(point, on: other) {
                return true
            }
        }
        return false
    }
}
