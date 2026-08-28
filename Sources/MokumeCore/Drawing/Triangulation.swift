// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 周の点列を三角形へ分ける。
///
/// 図形の塗りは「周の最初の点から扇状に分ける」形で出しているが、これは**凸な形でしか
/// 正しくない** — 凹んだ形では扇が形の外へはみ出す。矩形や三角形や扇は凸なので扇のままで
/// よく、**凹みうる経路 (利用者が頂点を並べた形) だけがここを通る**。
///
/// 耳を切る方式を使う。頂点が 3 つになるまで「切り落としてよい角」を探して外していく。
enum Triangulation {
    /// 単純な多角形を三角形へ分ける。返すのは点の番号の 3 つ組。
    ///
    /// **自己交差した形では正しい分け方が存在しない。** その場合でも落ちず、無限に
    /// 回らず、切れるところまで切って返す — 利用者が描いた形を拒むより、何かを描く。
    static func triangulate(_ points: [SIMD2<Float>]) -> [(Int, Int, Int)] {
        guard points.count >= 3 else { return [] }
        if points.count == 3 { return [(0, 1, 2)] }

        // 回る向きを揃える。以降の凸判定はこの向きを前提にする
        var ring = Array(points.indices)
        if signedArea(points) < 0 { ring.reverse() }

        var triangles: [(Int, Int, Int)] = []
        // 1 周まわって 1 つも切れなければ打ち切るので、上限は「残り頂点 x 周」で足りる
        var attemptsLeft = points.count * points.count

        while ring.count > 3, attemptsLeft > 0 {
            var clippedSomething = false
            for position in ring.indices {
                let previous = ring[(position + ring.count - 1) % ring.count]
                let current = ring[position]
                let next = ring[(position + 1) % ring.count]
                attemptsLeft -= 1
                guard isEar(points, previous, current, next, ring: ring) else { continue }
                triangles.append((previous, current, next))
                ring.remove(at: position)
                clippedSomething = true
                break
            }
            // 切れる角が 1 つも無い = 単純な多角形ではない。そこで止める
            if !clippedSomething { break }
        }

        if ring.count == 3 {
            triangles.append((ring[0], ring[1], ring[2]))
        }
        return triangles
    }

    /// 穴を持つ形を、**穴のない 1 つの周**へ畳む。
    ///
    /// 三角形化そのものを穴に対応させるのではなく、橋を架けて 1 周にしてから同じ道具へ
    /// 通す。道具が 1 つで済み、穴が「一部の経路でだけ効く」状態を作らない。
    ///
    /// 橋は、穴のいちばん右の点から外周の点へ架ける。**架けた線が他の辺を跨がない点**を
    /// 選ぶ — 跨ぐと、畳んだ周が自己交差して三角形化が途中で止まる。
    ///
    /// 受け渡すのは**点そのものではなく番号**である。畳んだ周から元の頂点を引ける
    /// ようにするためで、立体の頂点が持つ色や面の向きは点の座標には載っていない。
    ///
    /// - Parameters:
    ///   - outer: 外周をなす点の番号。
    ///   - holes: 穴をなす点の番号。
    ///   - points: 番号で引ける点の位置。
    static func mergeHoles(outer: [Int], holes: [[Int]], points: [SIMD2<Float>]) -> [Int] {
        var ring = outer
        // 右にある穴から順に畳む。左から畳むと、後の橋が前の橋を跨ぎやすい
        let ordered = holes
            .filter { $0.count >= 3 }
            .sorted {
                (rightmost($0, points)?.x ?? 0) > (rightmost($1, points)?.x ?? 0)
            }

        for hole in ordered {
            guard let entryIndex = rightmostIndex(hole, points) else { continue }
            let entry = points[hole[entryIndex]]
            guard let bridgeIndex = bridgeTarget(ring: ring, points: points, from: entry) else {
                continue  // 架けられる先が無ければ、その穴は諦める (塗りが埋まるだけ)
            }
            // 外周を橋の点で開き、穴を 1 周ぶん通してから戻る
            var merged = Array(ring[0...bridgeIndex])
            for step in 0...hole.count {
                merged.append(hole[(entryIndex + step) % hole.count])
            }
            merged.append(ring[bridgeIndex])
            merged.append(contentsOf: ring[(bridgeIndex + 1)...])
            ring = merged
        }
        return ring
    }

    // MARK: - 部品

    /// 符号付きの面積。向きの判定に使う (大きさは見ない)。
    static func signedArea(_ points: [SIMD2<Float>]) -> Float {
        var sum: Float = 0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// 切り落としてよい角か。
    ///
    /// 条件は 2 つ — その角が出っ張っていること、そして**残りの点をひとつも含まないこと**。
    /// 2 つ目を見ないと、凹んだ形で「形の外を通る三角形」を作ってしまう。
    private static func isEar(
        _ points: [SIMD2<Float>], _ a: Int, _ b: Int, _ c: Int, ring: [Int]
    ) -> Bool {
        let pa = points[a]
        let pb = points[b]
        let pc = points[c]
        guard cross(pb - pa, pc - pb) > 0 else { return false }
        for index in ring where index != a && index != b && index != c {
            if isInside(points[index], pa, pb, pc) { return false }
        }
        return true
    }

    private static func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        a.x * b.y - a.y * b.x
    }

    private static func isInside(
        _ point: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>
    ) -> Bool {
        let d1 = cross(b - a, point - a)
        let d2 = cross(c - b, point - b)
        let d3 = cross(a - c, point - c)
        // 辺の上は「含まない」とする — 含めると耳が見つからず、分け方が止まる
        return d1 > 0 && d2 > 0 && d3 > 0
    }

    private static func rightmost(_ ring: [Int], _ points: [SIMD2<Float>]) -> SIMD2<Float>? {
        rightmostIndex(ring, points).map { points[ring[$0]] }
    }

    private static func rightmostIndex(_ ring: [Int], _ points: [SIMD2<Float>]) -> Int? {
        ring.indices.max { points[ring[$0]].x < points[ring[$1]].x }
    }

    /// 橋を架ける先を、外周の点から選ぶ。
    private static func bridgeTarget(
        ring: [Int], points: [SIMD2<Float>], from entry: SIMD2<Float>
    ) -> Int? {
        var best: (index: Int, distance: Float)?
        for index in ring.indices {
            let candidate = points[ring[index]]
            let delta = candidate - entry
            let distance = delta.x * delta.x + delta.y * delta.y
            if let current = best, current.distance <= distance { continue }
            guard
                !crossesAnyEdge(
                    ring: ring, points: points, from: entry, to: candidate, skipping: index)
            else {
                continue
            }
            best = (index, distance)
        }
        return best?.index
    }

    /// 架けた線が、外周のどれかの辺を跨ぐか。
    private static func crossesAnyEdge(
        ring: [Int], points: [SIMD2<Float>], from: SIMD2<Float>, to: SIMD2<Float>,
        skipping target: Int
    ) -> Bool {
        for index in ring.indices {
            let next = (index + 1) % ring.count
            // 橋の端点を共有する辺は、跨いだことにしない
            if index == target || next == target { continue }
            if segmentsIntersect(from, to, points[ring[index]], points[ring[next]]) { return true }
        }
        return false
    }

    private static func segmentsIntersect(
        _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>, _ p4: SIMD2<Float>
    ) -> Bool {
        let d1 = cross(p2 - p1, p3 - p1)
        let d2 = cross(p2 - p1, p4 - p1)
        let d3 = cross(p4 - p3, p1 - p3)
        let d4 = cross(p4 - p3, p2 - p3)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }
}
