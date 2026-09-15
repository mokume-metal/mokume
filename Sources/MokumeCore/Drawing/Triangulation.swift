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
///
/// **字形の輪郭が普通に持つ 3 つの形を、正しい入力として扱う** ([#1148]・[#1211])。
/// どれも利用者が作った不正な形ではなく、`textOutline` で取った字をそのまま塗ると必ず現れる:
///
/// - **辺の上に別の点が載る** — T の横棒の下辺に、縦棒の角が載る
/// - **同じ位置の点が続く** — 曲線で閉じる周は、最後の点が最初の点と重なる
/// - **周が同じ点を 2 度通る** — 穴を畳んだ橋の継ぎ目や、腕と脚が 1 点で幹に触れる k
///
/// [#1148]: https://github.com/mokume-metal/mokume/issues/1148
/// [#1211]: https://github.com/mokume-metal/mokume/issues/1211
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
        dropFlatCorners(&ring, points, from: 0, untilClean: ring.count)

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
                // 切った跡で面積を持たない角が生まれうるのは、切り口の前後だけ
                dropFlatCorners(
                    &ring, points, from: (position + ring.count - 1) % ring.count, untilClean: 2)
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

    /// 面積を持たない角を、三角形を出さずに周から外す。
    ///
    /// 外すのは**前後の点と一直線に並び、進む向きが折り返す角**で、同じ位置に続く点もこれに
    /// 含まれる。凸とも凹とも言えないので耳の候補にならず、残りの周がこの角でしか切れなく
    /// なると分け方が止まる。周が同じ点を 2 度通る形では、最後に「行って戻るだけ」の周が
    /// 残り、そこから実在しない三角形を切り出してしまう。
    ///
    /// **一直線でも折り返さない角は外さない。** 外すと、別の周がその点に触れていたとき、
    /// その点が辺の上に載った点になって耳を塞ぐ。
    ///
    /// - Parameters:
    ///   - start: 見始める位置。
    ///   - run: 外すものが無い角がこれだけ続いたら終える。周全体を見るなら周の長さを渡す。
    private static func dropFlatCorners(
        _ ring: inout [Int], _ points: [SIMD2<Float>], from start: Int, untilClean run: Int
    ) {
        var position = start
        var clean = 0
        while ring.count > 3, clean < run {
            let a = points[ring[(position + ring.count - 1) % ring.count]]
            let b = points[ring[position]]
            let c = points[ring[(position + 1) % ring.count]]
            if cross(b - a, c - b) == 0, dot(b - a, c - b) <= 0 {
                ring.remove(at: position)
                // 外した跡で、1 つ前の角が新たに潰れていないかを見直す
                position = (position + ring.count - 1) % ring.count
                clean = 0
            } else {
                position = (position + 1) % ring.count
                clean += 1
            }
        }
    }

    /// 切り落としてよい角か。
    ///
    /// 条件は 2 つ — その角が出っ張っていること、そして**残りの点をひとつも含まないこと**。
    /// 2 つ目を見ないと、凹んだ形で「形の外を通る三角形」を作ってしまう。
    ///
    /// **角と同じ位置にある点は数えない。** 周が同じ点を 2 度通る形では、その点が三角形の
    /// 角に重なる。数えると耳が永久に見つからない。位置を比べるのは中と判定された点だけで
    /// よい (角に重なる点は必ず中と判定される) ので、比べる手間は大半の点で掛からない。
    private static func isEar(
        _ points: [SIMD2<Float>], _ a: Int, _ b: Int, _ c: Int, ring: [Int]
    ) -> Bool {
        let pa = points[a]
        let pb = points[b]
        let pc = points[c]
        guard cross(pb - pa, pc - pb) > 0 else { return false }
        for index in ring where index != a && index != b && index != c {
            let point = points[index]
            guard isInside(point, pa, pb, pc) else { continue }
            if point == pa || point == pb || point == pc { continue }
            return false
        }
        return true
    }

    private static func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        a.x * b.y - a.y * b.x
    }

    /// 三角形の中か。**辺の上も「中」とする。**
    ///
    /// 含まないと数えると、切り口の辺の上に別の角が載っている三角形が耳として通り、形の外を
    /// 覆う ([#1148])。判定に許容幅は持たせない — 座標の大きさに比例した幅を試すと、
    /// 形の外にある点まで耳を塞いで分け方が止まり、壊れる字がかえって増えた。
    ///
    /// [#1148]: https://github.com/mokume-metal/mokume/issues/1148
    private static func isInside(
        _ point: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>
    ) -> Bool {
        let d1 = cross(b - a, point - a)
        let d2 = cross(c - b, point - b)
        let d3 = cross(a - c, point - c)
        return d1 >= 0 && d2 >= 0 && d3 >= 0
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
