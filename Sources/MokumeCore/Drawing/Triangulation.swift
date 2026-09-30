// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 周の点列を三角形へ分ける。
///
/// 図形の塗りは「周の最初の点から扇状に分ける」形で出しているが、これは**凸な形でしか
/// 正しくない** — 凹んだ形では扇が形の外へはみ出す。矩形や三角形や扇は凸なので扇のままで
/// よく、**凹みうる経路 (利用者が頂点を並べた形) だけがここを通る**。
///
/// `quad` も利用者が 4 点を並べるので凸とは限らないが、ここは通らない。4 点で閉じた割り方
/// (凹んだ点からの扇・交差した辺の砂時計) を自分で持つ (`Canvas.quadTriangles`・[#1534])。
/// 耳切りは自己交差した周を砂時計に割れない。
///
/// 耳を切る方式を使う。頂点が 3 つになるまで「切り落としてよい角」を探して外していく。
/// **費用が頂点の数の二乗にならないよう、3 つの手間を省く** ([#1595]):
///
/// - **切ったら頭へ戻らない。** 切り口の次の角を飛ばした所から探し続け (earcut と同じ)、
///   1 周まわって 1 つも切れなければ止める。頭から探し直すと、周の前のほうの切れない角を
///   切るたびに見直すことになる。次の角を飛ばすのは、同じ点から扇状に細い三角形を並べない
///   ためである
/// - **探すのは凸な角だけ。** 凹んだ角は耳にならないので、凸な角だけを周の順につないで
///   たどる。凹んだ入り江を埋めるときは 1 周に 1 つずつしか切れないので、凹んだ角まで
///   たどると 1 つ切るたびに周の全部を舐め直す
/// - **耳の判定で、凸でない角の点だけを比べる。** しかも位置の索引から、三角形に掛かりうる
///   所だけを引く。それで足りる理由は `isEar` が、索引の形は ``ConcaveCorners`` が持つ
///
/// どの耳をどの順に切るかは割り方として絵に出うる (頂点ごとの色・光・読み取り位置) が、
/// 割り方は公開の説明で約束していない。不透明の一様な塗りは、割り方に依らず同じ画素を覆う。
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
/// [#1534]: https://github.com/mokume-metal/mokume/issues/1534
/// [#1595]: https://github.com/mokume-metal/mokume/issues/1595
nonisolated enum Triangulation {
    /// 単純な多角形を三角形へ分ける。返すのは点の番号の 3 つ組。
    ///
    /// **自己交差した周は、ここへ来る前に分ける** (``splitForNonzero(rings:points:)``・
    /// [#1538])。頂点を並べた形の塗りは、周が交わるとそこで回り数が 0 でない所を囲む周へ
    /// 組み直してから、ここへ通す。
    ///
    /// それでも、自己交差した周を渡されたときに落ちず、無限に回らないことは約束として残す。
    /// 切れるところまで切って返す — 利用者が描いた形を拒むより、何かを描く。
    ///
    /// [#1538]: https://github.com/mokume-metal/mokume/issues/1538
    static func triangulate(_ points: [SIMD2<Float>]) -> [(Int, Int, Int)] {
        var comparisons = 0
        return triangulate(points, comparisons: &comparisons)
    }

    /// 単純な多角形を三角形へ分け、耳の判定で点を三角形と比べた回数を `comparisons` へ積む。
    ///
    /// 回数は**費用が二乗に戻っていないことを数で確かめる**ためにある (``Canvas`` の
    /// `pointScansInLastFrame`)。凸な形では 0 になる。
    static func triangulate(_ points: [SIMD2<Float>], comparisons: inout Int) -> [(Int, Int, Int)] {
        guard points.count >= 3 else { return [] }
        if points.count == 3 { return [(0, 1, 2)] }

        // 回る向きを揃える。以降の凸判定はこの向きを前提にする
        var order = Array(points.indices)
        if signedArea(points) < 0 { order.reverse() }
        var ring = EarRing(order: order, points: points)
        ring.dropFlatCorners(from: 0, untilClean: ring.count)

        var triangles: [(Int, Int, Int)] = []
        triangles.reserveCapacity(points.count - 2)
        // 1 周まわって 1 つも切れなければ打ち切るので、ふつうは届かない。
        // 自己交差した形でも止まることの、最後の保証として残す
        var attemptsLeft = points.count * points.count
        // 耳になりうるのは凸な角だけなので、凸な角だけを周の順にたどる
        var ear = ring.firstConvex(from: ring.entry)
        // ここへ戻るまでに 1 つも切れなければ、切れる角が無い
        var lapStart = ear

        while ring.count > 3, ear >= 0, attemptsLeft > 0 {
            let previous = ring.previous[ear]
            let next = ring.next[ear]
            attemptsLeft -= 1
            guard ring.isEar(previous, ear, next, comparisons: &comparisons) else {
                ear = ring.nextConvex[ear]
                // 切れる角が 1 つも無い = 単純な多角形ではない。そこで止める
                if ear == lapStart { break }
                continue
            }
            triangles.append((ring.vertex[previous], ring.vertex[ear], ring.vertex[next]))
            ear = ring.cut(ear)
            lapStart = ear
        }

        if ring.count == 3 {
            let last = ring.entry
            triangles.append(
                (ring.vertex[ring.previous[last]], ring.vertex[last], ring.vertex[ring.next[last]]))
        }
        return triangles
    }

    /// 穴を持つ形を、**穴のない 1 つの周**へ畳む。
    ///
    /// 三角形化そのものを穴に対応させるのではなく、橋を架けて 1 周にしてから同じ道具へ
    /// 通す。道具が 1 つで済み、穴が「一部の経路でだけ効く」状態を作らない。
    ///
    /// 橋は、穴のいちばん右の点から外周の点へ架ける。架ける先には、近い点のうち
    /// **架けた線がどの辺も跨がない点**を選ぶ — 跨ぐと、畳んだ周が自己交差して
    /// 三角形化が途中で止まる。見る辺は 3 つある:
    ///
    /// - **外周の辺** (先に畳んだ穴の辺も、畳んだ時点で外周に入っている)
    /// - **いま畳んでいる穴自身の辺** — 穴の右端から外周の近い点が左にあると、橋が穴の
    ///   中を通り抜ける ([#1530])
    /// - **まだ畳んでいない穴の辺** — 右の穴から架けた橋が、左の穴を横切りうる
    ///
    /// 橋の端点に接する辺は、跨いだことにしない。
    ///
    /// 受け渡すのは**点そのものではなく番号**である。畳んだ周から元の頂点を引ける
    /// ようにするためで、立体の頂点が持つ色や面の向きは点の座標には載っていない。
    ///
    /// - Parameters:
    ///   - outer: 外周をなす点の番号。
    ///   - holes: 穴をなす点の番号。
    ///   - points: 番号で引ける点の位置。
    ///
    /// [#1530]: https://github.com/mokume-metal/mokume/issues/1530
    static func mergeHoles(outer: [Int], holes: [[Int]], points: [SIMD2<Float>]) -> [Int] {
        var ring = outer
        // 右にある穴から順に畳む。左から畳むと、後の橋が前の橋を跨ぎやすい
        let ordered = holes
            .filter { $0.count >= 3 }
            .sorted {
                (rightmost($0, points)?.x ?? 0) > (rightmost($1, points)?.x ?? 0)
            }

        for (order, hole) in ordered.enumerated() {
            guard let entryIndex = rightmostIndex(hole, points) else { continue }
            let entry = points[hole[entryIndex]]
            // この穴と、まだ畳んでいない穴。先に畳んだ穴は `ring` に入っている
            let unmerged = ordered[order...]
            guard
                let bridgeIndex = bridgeTarget(
                    ring: ring, holes: unmerged, points: points, from: entry)
            else {
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

    static func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
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
    ///
    /// - Parameter holes: 跨いではならない穴。いま畳んでいる穴と、まだ畳んでいない穴。
    private static func bridgeTarget(
        ring: [Int], holes: ArraySlice<[Int]>, points: [SIMD2<Float>], from entry: SIMD2<Float>
    ) -> Int? {
        var best: (index: Int, distance: Float)?
        for index in ring.indices {
            let candidate = points[ring[index]]
            let delta = candidate - entry
            let distance = delta.x * delta.x + delta.y * delta.y
            if let current = best, current.distance <= distance { continue }
            guard
                !crossesAnyEdge(
                    ring: ring, points: points, from: entry, to: candidate, skipping: index),
                !crossesAnyHole(holes, points: points, from: entry, to: candidate)
            else {
                continue
            }
            best = (index, distance)
        }
        return best?.index
    }

    /// 架けた線が、外周 (先に畳んだ穴を含む) のどれかの辺を跨ぐか。
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

    /// 架けた線が、穴のどれかの辺を跨ぐか。
    ///
    /// 外すのは、**入口の点と同じ位置に端を持つ辺**である。穴自身の 2 辺がこれに当たる。
    /// 番号ではなく位置で比べるのは、最後の点が最初の点と重なる穴 (曲線で閉じる字の o) で、
    /// 同じ位置のもう 1 つの点に接する辺まで外すためである。
    private static func crossesAnyHole(
        _ holes: ArraySlice<[Int]>, points: [SIMD2<Float>], from: SIMD2<Float>, to: SIMD2<Float>
    ) -> Bool {
        for hole in holes {
            for index in hole.indices {
                let a = points[hole[index]]
                let b = points[hole[(index + 1) % hole.count]]
                if a == from || b == from { continue }
                if segmentsIntersect(from, to, a, b) { return true }
            }
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

// MARK: - 切っていく途中の周

extension Triangulation {
    /// 耳を切っていく途中の周。**位置ごとに前後の位置を持つ連結リスト**で、切った角を
    /// 詰め直さずに外す。
    ///
    /// 位置は、向きを揃えた後の周の何番目か。点の番号でつながないのは、穴を畳んだ橋の
    /// 継ぎ目で同じ点が周に 2 度現れるためである。
    ///
    /// 残っている角は、凸かどうかで 2 つに分けて持つ。**凸な角は周の順の連結リスト**
    /// (耳の候補をたどる)、**凸でない角は位置で引く索引** (耳を塞ぐ点を探す)。
    /// 角を外すたびに前後の角を見直して、入れ先を移す。
    nonisolated fileprivate struct EarRing {
        let points: [SIMD2<Float>]
        /// 位置ごとの点の番号。
        let vertex: [Int]
        private(set) var previous: [Int]
        private(set) var next: [Int]
        /// 残っている角の数。
        private(set) var count: Int
        /// 残っている角のどれか。
        private(set) var entry = 0

        private var isConvex: [Bool]
        private(set) var nextConvex: [Int]
        private var previousConvex: [Int]
        private var concave: ConcaveCorners

        init(order: [Int], points: [SIMD2<Float>]) {
            let total = order.count
            self.points = points
            vertex = order
            previous = (0..<total).map { ($0 + total - 1) % total }
            next = (0..<total).map { ($0 + 1) % total }
            count = total
            isConvex = Array(repeating: false, count: total)
            nextConvex = Array(repeating: -1, count: total)
            previousConvex = Array(repeating: -1, count: total)
            concave = ConcaveCorners()

            var corners: [Int] = []
            var lastConvex = -1
            var firstConvex = -1
            for node in 0..<total {
                guard turnsLeft(node) else {
                    corners.append(node)
                    continue
                }
                isConvex[node] = true
                if lastConvex >= 0 {
                    nextConvex[lastConvex] = node
                    previousConvex[node] = lastConvex
                } else {
                    firstConvex = node
                }
                lastConvex = node
            }
            if firstConvex >= 0 {
                nextConvex[lastConvex] = firstConvex
                previousConvex[firstConvex] = lastConvex
            }
            concave = ConcaveCorners(corners: corners, total: total, vertex: vertex, points: points)
        }

        /// 出っ張った角か。**一直線の角と、数でない座標の角は凸と数えない。**
        private func turnsLeft(_ node: Int) -> Bool {
            let a = points[vertex[previous[node]]]
            let b = points[vertex[node]]
            let c = points[vertex[next[node]]]
            return Triangulation.cross(b - a, c - b) > 0
        }

        /// `start` から周の順に見て、最初の凸な角。無ければ -1。
        func firstConvex(from start: Int) -> Int {
            var node = start
            for _ in 0..<count {
                if isConvex[node] { return node }
                node = next[node]
            }
            return -1
        }

        /// 耳の先 `tip` を切り、次に耳かを見る凸な角を返す。凸な角が残っていなければ -1。
        ///
        /// 見るのは**切り口の次の角を飛ばした先**である (earcut と同じ)。すぐ次の角を見ると、
        /// 同じ点から扇状に細い三角形を並べていく。
        mutating func cut(_ tip: Int) -> Int {
            let before = previous[tip]
            let after = next[tip]
            let following = nextConvex[tip]
            remove(tip)
            // 切った跡で面積を持たない角が生まれうるのは、切り口の前後だけ
            let (resume, dropped) = dropFlatCorners(from: before, untilClean: 2)
            if !dropped {
                // 切り口の次の角 `after` より先で、いちばん近い凸な角
                let candidate =
                    isConvex[after]
                    ? nextConvex[after]
                    : isConvex[before] ? nextConvex[before] : following
                if isConvex[candidate] { return candidate }
                // 凸な角が `tip` しか無かったか、`before` が凸でなくなった (自己交差した形)
            }
            return firstConvex(from: resume)
        }

        /// 角を周から外す。前後の角は形が変わるので、凸かどうかを見直す。
        private mutating func remove(_ node: Int) {
            let before = previous[node]
            let after = next[node]
            next[before] = after
            previous[after] = before
            count -= 1
            if entry == node { entry = after }
            // 外す角がまだ凸な角のリストにいるうちに見直す。凸になった前後の角は、
            // 外す角のすぐ前とすぐ後ろに入る
            reclassify(before, beside: node, ahead: true)
            reclassify(after, beside: node, ahead: false)
            if isConvex[node] {
                unlinkConvex(node)
                isConvex[node] = false
            } else {
                concave.remove(node)
            }
        }

        /// 前後の角が外れた角の、凸かどうかを見直して入れ先を移す。
        ///
        /// - Parameters:
        ///   - removed: 外れる角。
        ///   - ahead: この角が `removed` の前にあるか。
        private mutating func reclassify(_ node: Int, beside removed: Int, ahead: Bool) {
            let convex = turnsLeft(node)
            guard convex != isConvex[node] else { return }
            isConvex[node] = convex
            guard convex else {
                unlinkConvex(node)
                concave.insert(node)
                return
            }
            concave.remove(node)
            if isConvex[removed] {
                linkConvex(node, after: ahead ? previousConvex[removed] : removed)
                return
            }
            // 外れる角が凸でなければ、周を遡って凸な角を探す。面積を持たない角を
            // 外したときにしか起きない
            var search = previous[node]
            while search != node, !isConvex[search] { search = previous[search] }
            linkConvex(node, after: search)
        }

        private mutating func linkConvex(_ node: Int, after anchor: Int) {
            guard anchor != node else {
                nextConvex[node] = node
                previousConvex[node] = node
                return
            }
            let successor = nextConvex[anchor]
            nextConvex[anchor] = node
            previousConvex[node] = anchor
            nextConvex[node] = successor
            previousConvex[successor] = node
        }

        private mutating func unlinkConvex(_ node: Int) {
            let before = previousConvex[node]
            let after = nextConvex[node]
            nextConvex[before] = after
            previousConvex[after] = before
        }

        /// 面積を持たない角を、三角形を出さずに周から外す。返すのは見終えた次の位置と、
        /// 1 つでも外したか。
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
        @discardableResult
        mutating func dropFlatCorners(from start: Int, untilClean run: Int) -> (Int, Bool) {
            var node = start
            var clean = 0
            var dropped = false
            while count > 3, clean < run {
                let a = points[vertex[previous[node]]]
                let b = points[vertex[node]]
                let c = points[vertex[next[node]]]
                if Triangulation.cross(b - a, c - b) == 0, dot(b - a, c - b) <= 0 {
                    let before = previous[node]
                    remove(node)
                    dropped = true
                    // 外した跡で、1 つ前の角が新たに潰れていないかを見直す
                    node = before
                    clean = 0
                } else {
                    node = next[node]
                    clean += 1
                }
            }
            return (node, dropped)
        }

        /// 切り落としてよい角か。比べた点の数を `comparisons` へ積む。
        ///
        /// 条件は 2 つ — その角が出っ張っていること、そして**残りの点をひとつも含まないこと**。
        /// 2 つ目を見ないと、凹んだ形で「形の外を通る三角形」を作ってしまう。
        ///
        /// **比べるのは凸でない角の点だけでよい。** 三角形の 2 辺 (`a`–`b`・`b`–`c`) は周の辺
        /// なので、単純な多角形の周が三角形へ入り込むなら、残りの 1 辺 (`a`–`c`) から入って
        /// 同じ辺から出るしかない。入り込んだ部分のいちばん `b` 寄りの点で周は向きを返し、
        /// その角は凸にならない。凸な角の点しか中に無いなら、そもそも何も入り込んでいない。
        /// 自己交差した形ではこの理屈が崩れるが、そうした形は先に分けてから渡される
        /// (ここでは止まることだけを約束している)。凸でない角は索引 (``ConcaveCorners``) から、
        /// 三角形に掛かりうる所だけを引く。
        ///
        /// **角と同じ位置にある点は数えない。** 周が同じ点を 2 度通る形では、その点が三角形の
        /// 角に重なる。数えると耳が永久に見つからない。位置を比べるのは中と判定された点だけで
        /// よい (角に重なる点は必ず中と判定される) ので、比べる手間は大半の点で掛からない。
        func isEar(_ a: Int, _ b: Int, _ c: Int, comparisons: inout Int) -> Bool {
            let triangle = EarTriangle(
                indices: (vertex[a], vertex[b], vertex[c]),
                a: points[vertex[a]], b: points[vertex[b]], c: points[vertex[c]])
            guard Triangulation.cross(triangle.b - triangle.a, triangle.c - triangle.b) > 0 else {
                return false
            }
            return !concave.anyBlocks(
                triangle, vertex: vertex, points: points, comparisons: &comparisons)
        }
    }

    /// 耳の候補の三角形。
    nonisolated fileprivate struct EarTriangle {
        var indices: (Int, Int, Int)
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var c: SIMD2<Float>

        /// その点が、三角形を耳でなくするか。比べた回数を `comparisons` へ積む。
        func isBlocked(
            by index: Int, points: [SIMD2<Float>], comparisons: inout Int
        ) -> Bool {
            if index == indices.0 || index == indices.1 || index == indices.2 { return false }
            let point = points[index]
            comparisons += 1
            guard Triangulation.isInside(point, a, b, c) else { return false }
            return point != a && point != b && point != c
        }

        /// 箱 (`minX, minY, maxX, maxY`) の中の点が、三角形の中と判定されうるか。
        ///
        /// 見るのは 2 つ — 箱が三角形の囲みに掛かるか、と、どれかの辺の外に箱が丸ごと
        /// 出ていないか。
        ///
        /// **辺の外かは、`isInside` と同じ式を、箱の中で値が最も大きくなる隅で計算する。**
        /// 丸めは値の大小を入れ替えないので、その隅で辺の外と出れば、箱の中のどの点も同じ式で
        /// 外と出る。許容幅を持たずに、全部の点と比べたときと同じ点を拾う。
        ///
        /// **囲みのほうは、この一致を保たない。** 丸めのせいで囲みの外の点が中と出ることは、
        /// ほとんど一直線の角のすぐそばで起こりうる。そこを見落として耳を通しても、三角形が
        /// 形の外へ出るのは丸めの幅に収まる。囲みを見ないと、細い耳の辺を延ばした線に
        /// 跨がる遠くの箱がどれも残り、比べる数が点の数に見合わなくなる。
        func mayContainPoints(in box: SIMD4<Float>) -> Bool {
            let low = simd_min(a, simd_min(b, c))
            let high = simd_max(a, simd_max(b, c))
            if box.x > high.x || box.z < low.x || box.y > high.y || box.w < low.y { return false }
            return !(Self.highest(from: a, to: b, in: box) < 0
                || Self.highest(from: b, to: c, in: box) < 0
                || Self.highest(from: c, to: a, in: box) < 0)
        }

        private static func highest(
            from start: SIMD2<Float>, to end: SIMD2<Float>, in box: SIMD4<Float>
        ) -> Float {
            let edge = end - start
            let corner = SIMD2(edge.y <= 0 ? box.z : box.x, edge.x >= 0 ? box.w : box.y)
            return Triangulation.cross(edge, corner - start)
        }
    }

    /// 凸でない角を、位置で引く索引。
    ///
    /// **点を Z 順 (座標の桁を交互に並べた順) に並べ、4 つずつ箱に束ねた木**である。
    /// 耳の三角形に掛かりえない箱は中を見ない。箱は点の込み具合に合わせて小さくなる。
    /// 形の囲みを一様な升目に割る形も試したが、点が曲線の上に並ぶ (輪郭の点はたいてい
    /// そうである) と点の在る升に点が偏り、比べる数が点の数より速く増えた ([#1595])。
    ///
    /// 木は作るときに 1 度だけ組み、外した角は印を付けて数を減らすだけにする。後から
    /// 凸でなくなった角と、座標が数でない角は、木に入れずに毎回見る列に置く。前者は
    /// 面積を持たない角を外したときか自己交差した形でしか起きない。後者は箱に収まらず、
    /// 三角形の中と判定されることも無いはずだが、全部の点と比べていた頃の判定を
    /// 理屈に頼って削らない。
    ///
    /// [#1595]: https://github.com/mokume-metal/mokume/issues/1595
    nonisolated fileprivate struct ConcaveCorners {
        /// 1 つの箱に束ねる数。
        private static let fanOut = 4

        /// Z 順に並べた角の位置。
        private var items: [Int] = []
        private var itemAlive: [Bool] = []
        /// 位置ごとの、`items` の何番目か。木に入っていなければ -1。
        private var slot: [Int] = []
        /// 木の箱 (`minX, minY, maxX, maxY`)。葉の段から根の段へ並べる。
        private var boxes: [SIMD4<Float>] = []
        /// 箱の中に残っている角の数。
        private var alive: [Int] = []
        /// 段ごとの、`boxes` の何番目から始まるか。最後は `boxes.count`。
        private var levelStart: [Int] = [0, 0]
        /// 毎回見る角。
        private var loose: [Int] = []
        /// 位置ごとの、`loose` の何番目か。入っていなければ -1。
        private var looseSlot: [Int] = []

        init() {}

        init(corners: [Int], total: Int, vertex: [Int], points: [SIMD2<Float>]) {
            slot = Array(repeating: -1, count: total)
            looseSlot = Array(repeating: -1, count: total)

            var placed: [Int] = []
            placed.reserveCapacity(corners.count)
            var low = SIMD2<Float>(repeating: .infinity)
            var high = SIMD2<Float>(repeating: -.infinity)
            for node in corners {
                let point = points[vertex[node]]
                guard point.x.isFinite, point.y.isFinite else {
                    looseSlot[node] = loose.count
                    loose.append(node)
                    continue
                }
                placed.append(node)
                low = simd_min(low, point)
                high = simd_max(high, point)
            }
            guard !placed.isEmpty else { return }

            // Z 順に並べる。上位 32 ビットが Z 順、下位が位置
            let size = high - low
            let scale = SIMD2<Float>(
                size.x > 0 ? 65535 / size.x : 0, size.y > 0 ? 65535 / size.y : 0)
            var keys: [UInt64] = []
            keys.reserveCapacity(placed.count)
            for node in placed {
                let offset = (points[vertex[node]] - low) * scale
                let code = Self.spread(Self.quantize(offset.x))
                    | Self.spread(Self.quantize(offset.y)) << 1
                keys.append(UInt64(code) << 32 | UInt64(node))
            }
            keys.sort()
            items.reserveCapacity(keys.count)
            for key in keys { items.append(Int(key & 0xFFFF_FFFF)) }
            itemAlive = Array(repeating: true, count: items.count)
            for (index, node) in items.enumerated() { slot[node] = index }

            // 葉の段: 角を 4 つずつ箱に束ねる
            var levelCount = (items.count + Self.fanOut - 1) / Self.fanOut
            boxes.reserveCapacity(levelCount * 4 / 3 + 1)
            for leaf in 0..<levelCount {
                var box = SIMD4<Float>(.infinity, .infinity, -.infinity, -.infinity)
                let range = (leaf * Self.fanOut)..<min((leaf + 1) * Self.fanOut, items.count)
                for index in range {
                    let point = points[vertex[items[index]]]
                    box = Self.enclosing(box, SIMD4(lowHalf: point, highHalf: point))
                }
                boxes.append(box)
                alive.append(range.count)
            }
            // 上の段: 箱を 4 つずつ束ねる
            levelStart = [0]
            while levelCount > 1 {
                let childStart = levelStart[levelStart.count - 1]
                let childCount = levelCount
                levelStart.append(boxes.count)
                levelCount = (childCount + Self.fanOut - 1) / Self.fanOut
                for parent in 0..<levelCount {
                    var box = SIMD4<Float>(.infinity, .infinity, -.infinity, -.infinity)
                    var inside = 0
                    let range = (parent * Self.fanOut)..<min((parent + 1) * Self.fanOut, childCount)
                    for child in range {
                        box = Self.enclosing(box, boxes[childStart + child])
                        inside += alive[childStart + child]
                    }
                    boxes.append(box)
                    alive.append(inside)
                }
            }
            levelStart.append(boxes.count)
        }

        /// 0…65535 へ丸める。数でない値は 0 にする。
        private static func quantize(_ value: Float) -> UInt32 {
            guard value > 0 else { return 0 }
            return value < 65535 ? UInt32(value) : 65535
        }

        /// 下位 16 ビットを、1 ビットおきに広げる。
        private static func spread(_ value: UInt32) -> UInt32 {
            var bits = value & 0xFFFF
            bits = (bits | (bits << 8)) & 0x00FF_00FF
            bits = (bits | (bits << 4)) & 0x0F0F_0F0F
            bits = (bits | (bits << 2)) & 0x3333_3333
            bits = (bits | (bits << 1)) & 0x5555_5555
            return bits
        }

        private static func enclosing(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
            SIMD4(min(a.x, b.x), min(a.y, b.y), max(a.z, b.z), max(a.w, b.w))
        }

        /// 後から凸でなくなった角を入れる。木は組み直さず、毎回見る列に置く。
        mutating func insert(_ node: Int) {
            looseSlot[node] = loose.count
            loose.append(node)
        }

        /// 角を外す。入っていなければ何もしない。
        mutating func remove(_ node: Int) {
            let looseIndex = looseSlot[node]
            if looseIndex >= 0 {
                let last = loose.removeLast()
                if last != node {
                    loose[looseIndex] = last
                    looseSlot[last] = looseIndex
                }
                looseSlot[node] = -1
                return
            }
            let index = slot[node]
            guard index >= 0, itemAlive[index] else { return }
            itemAlive[index] = false
            var position = index / Self.fanOut
            for level in 0..<(levelStart.count - 1) {
                alive[levelStart[level] + position] -= 1
                position /= Self.fanOut
            }
        }

        /// 三角形を耳でなくする角があるか。比べた回数を `comparisons` へ積む。
        func anyBlocks(
            _ triangle: EarTriangle, vertex: [Int], points: [SIMD2<Float>],
            comparisons: inout Int
        ) -> Bool {
            for node in loose
            where triangle.isBlocked(by: vertex[node], points: points, comparisons: &comparisons) {
                return true
            }
            guard !items.isEmpty else { return false }
            return anyBlocks(
                triangle, level: levelStart.count - 2, box: 0, vertex: vertex, points: points,
                comparisons: &comparisons)
        }

        private func anyBlocks(
            _ triangle: EarTriangle, level: Int, box: Int, vertex: [Int], points: [SIMD2<Float>],
            comparisons: inout Int
        ) -> Bool {
            let flat = levelStart[level] + box
            guard alive[flat] > 0, triangle.mayContainPoints(in: boxes[flat]) else { return false }
            let first = box * Self.fanOut
            if level == 0 {
                for index in first..<min(first + Self.fanOut, items.count) where itemAlive[index] {
                    if triangle.isBlocked(
                        by: vertex[items[index]], points: points, comparisons: &comparisons)
                    {
                        return true
                    }
                }
                return false
            }
            let childCount = levelStart[level] - levelStart[level - 1]
            for child in first..<min(first + Self.fanOut, childCount)
            where anyBlocks(
                triangle, level: level - 1, box: child, vertex: vertex, points: points,
                comparisons: &comparisons)
            {
                return true
            }
            return false
        }
    }
}
