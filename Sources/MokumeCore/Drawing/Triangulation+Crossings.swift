// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// MARK: - 交わった周を分ける

nonisolated extension Triangulation {
    /// 周の組が交わった所。
    ///
    /// 交わった 2 辺を、**周の向きどおりの始点と終点の番号**と、交点が辺のどこにあるか
    /// (始点で 0・終点で 1) で持つ。呼ぶ側は、これで交点に持たせる値を 2 辺から補間する。
    nonisolated struct Crossing {
        nonisolated struct Side {
            var from: Int
            var to: Int
            var at: Float
        }

        var first: Side
        var second: Side
        /// 平らな座標での交点。1 本目の辺の上で求める。
        var point: SIMD2<Float>
    }

    /// 回り数が 0 でない所を囲む、外周 1 つとその穴。`mergeHoles` → `triangulate` へ
    /// そのまま通せる (外周は正の面積、穴は負の面積で回る)。
    nonisolated struct Region {
        var outer: [Int]
        var holes: [[Int]]
    }

    /// 周を交点で分けた結果。
    ///
    /// `regions` の番号のうち、渡した点の数以上のものは交点を指す — 番号 `points.count + k`
    /// が `crossings[k]` である。
    nonisolated struct Split {
        var crossings: [Crossing]
        var regions: [Region]
        /// 分けた周を三角形へ分けるときに、耳を塞ぐ点を数える許容 (距離)。
        /// ``triangulate(_:comparisons:slack:)`` へ渡す。
        ///
        /// 組み直した周は、元の 1 本の辺の上に交点を幾つも並べる。数の上では一直線でも、
        /// 浮動小数では厳密には並ばない。その辺の上に載る凹んだ角が丸めで辺のわずかに外へ
        /// 出ると、耳切りはその辺を 1 辺に持つ三角形を耳と取り違え、形の外まで塗る。点を
        /// 束ねた許容と同じ幅で、辺のすぐ外の角も耳を塞ぐと数える。
        var slack: Float = 0
    }

    /// 周の組 (外周と穴) が「外周の中に、互いに離れた、外周と逆に回る穴を開けた形」で
    /// なければ、**回り数が 0 でない所** (nonzero) を囲む周へ組み直す。その形なら `nil` を
    /// 返す ([#1538])。
    ///
    /// 耳切りと `mergeHoles` は、単純な外周の中に離れた穴が並ぶ形の手順である。周が自分と
    /// 交わる形・穴が外周を跨ぐ形・外周の外に置いた周・穴の中に置いた周をそのまま渡すと、
    /// どの規則でも外になる所まで塗るか、塗る所を塗らない。外周と同じ向きの穴は、回り数 2 の
    /// 所を 2 度塗る。そこで、そうした形だけをここで分けてから同じ道具へ通す。**単純な形は
    /// `nil` が返るので、呼ぶ側の手順は 1 ビットも変わらない。**
    ///
    /// 組み直すのは次のどれかに当たる形である。
    ///
    /// - **周が真に交わる。** 2 辺のどちらから見ても、もう一方の両端が逆の側にある組が
    ///   ある
    /// - **周が頂点を通って向こう側へ抜ける。** 辺の途中に別の頂点が載る所で、通り道
    ///   どうしが角度の順で交互に並ぶ。向きが重なってどちらとも決められない所も、組み直す
    ///   側へ送る。辺の途中に頂点が載って触れて戻るだけの所 (T の字・[#1148]) は数えない —
    ///   そこは耳切りが既に正しく扱う
    /// - **周が同じ点を 2 度通る** (別々に通る 2 つの頂点が同じ位置にある。別の周の頂点との
    ///   重なりも含む)。交わらずに触れて戻るだけでも組み直す。耳切りは触れ合う 2 つの葉が
    ///   同じ向きに回ると形の外まで塗る ([#1211] の形は通っていたが、#1886 の形は通らない)
    /// - **穴が外周と同じ向きに回る**
    /// - **穴が外周の中にない** (外周の外に置いた周・外周を包む周)
    /// - **穴が別の穴の中にある** (穴の中に置いた周)
    ///
    /// 穴の置き場所は、穴の点のうち、比べる周の辺に載らない最初の 1 つで決める (載る点は
    /// 数え方しだいで内にも外にもなる)。周どうしが交わらなければ、1 点で周全体の置き場所が
    /// 決まる。
    ///
    /// 交わりを探す手間は、耳切りと同じ次数に収める。辺の囲みの箱を周の順に束ねた木で、
    /// 囲みの重なる組だけを比べる。全部の組を比べると、交わらない大きな周で耳切りそのもの
    /// より重くなる。
    ///
    /// 組み直す手順は次のとおりである。
    ///
    /// 1. **近い点を 1 つに束ねる。** 形の大きさに比例する許容の中にある頂点と交点を、
    ///    1 つの点 (番号) として扱う。同じ交わりを、そこを通る辺の組ごとに別々に求めると、
    ///    1〜2 ulp ずれた点が幾つもできる。位置の完全一致で繋ぐと、そこで周が途切れる
    /// 2. 交点と、許容の中で辺の途中に載る点 (頂点・交点) で辺を分ける。端が相手の辺の
    ///    許容の中にある組は交点を作らず、載る点として扱う (同じ交わりを 2 度作らない)
    /// 3. 分けた辺を両端の番号の組で束ね、束ごとに両側の回り数を数える。**片側だけが 0 の
    ///    束**が塗る所の境で、塗る側が左になる向きで残す。回り数は、束が囲む面をたどって
    ///    隣の面から決める (`windingsBySide`)。
    /// 4. 残した辺を周へ繋ぐ。1 つの点から辺が 2 本以上出るときは、来た辺から時計回りに
    ///    見て最初の辺を選ぶ。塗る所の角ごとに周が閉じるので、砂時計は 1 点で触れ合う
    ///    2 つの三角形になる
    /// 5. 正の面積の周を外周、負の面積の周を穴とし、穴はそれを含むいちばん小さい外周へ付ける。
    ///    穴が同じ点を 2 度通るなら、その点で別々の穴に分ける (`separated`)
    ///
    /// 分けた周は、点を束ねた許容 (`Split.slack`) を付けて `mergeHoles` と耳切りへ渡す。
    ///
    /// **組み直せなかったときも `nil` を返す** (残した辺の出入りが点ごとに釣り合わない・
    /// 周が閉じない・塗る周が 1 つも残らない)。許容でも束ねきれない崩れた形で、形を丸ごと
    /// 捨てずに、いまの手順 (耳切り) へ戻すためである。
    ///
    /// 組み直す手間は、面をたどる所で束の数に比例し、面の回り数を決める半直線が繋がった
    /// 束の組ごとに全部の束と比べる。組み直す形でしか払わない。
    ///
    /// - Parameters:
    ///   - rings: 周をなす点の番号。最初が外周、残りが穴。3 点に満たない周は、
    ///     `mergeHoles` と同じく無視する。
    ///   - points: 番号で引ける点の平らな座標。
    ///   - comparisons: 点を舐めた延べ回数を積む先 (``Canvas`` の `pointScansInLastFrame`)。
    ///     星形か見る・交わりを探す辺・穴の置き場所を見る・組み直すときの半直線で束と比べる、
    ///     のそれぞれを数える。**組み直す手間は辺の数に比例しない**ので、ここに積まないと
    ///     二乗が戻っても数が動かない。
    ///
    /// [#1148]: https://github.com/mokume-metal/mokume/issues/1148
    /// [#1211]: https://github.com/mokume-metal/mokume/issues/1211
    /// [#1538]: https://github.com/mokume-metal/mokume/issues/1538
    static func splitForNonzero(
        rings: [[Int]], points: [SIMD2<Float>], comparisons: inout Int
    ) -> Split? {
        if rings.count == 1 {
            comparisons += rings[0].count
            if isStarShaped(rings[0], points: points) { return nil }
        }
        let edges = RingEdges(rings: rings, points: points)
        let survey = edges.survey()
        comparisons += survey.pairs
        guard survey.isTangled
            || holesAreOutOfPlace(rings: rings, points: points, comparisons: &comparisons)
        else {
            return nil
        }
        return edges.nonzeroSplit(crossings: survey.crossings, comparisons: &comparisons)
    }

    /// ``splitForNonzero(rings:points:comparisons:)`` の、回数を数えない形。
    static func splitForNonzero(rings: [[Int]], points: [SIMD2<Float>]) -> Split? {
        var comparisons = 0
        return splitForNonzero(rings: rings, points: points, comparisons: &comparisons)
    }

    /// 周が、点の重心から見て 1 周だけ回る星形か。**そうなら周は自分と交わらない。**
    ///
    /// 重心から見た向きが、どの辺でも同じ側へ (0 より大きく π より小さく) 回り、合わせて
    /// ちょうど 1 周するなら、周の点は重心のまわりに角度の順に並ぶ。辺どうしは重心から
    /// 見て別の角度の範囲に収まるので、交われない。凸な形・円・歯車・膨らんだ塊のような、
    /// 大きな周によくある形をここで先に通し、辺の組を探す手間を払わない。辺の数に比例する
    /// 手間で済む。
    ///
    /// 重心が周の上や外にある・向きが一直線になる辺がある (同じ位置の点が続くなど) と
    /// 星形とは言えないので `false` を返し、呼ぶ側は辺の組を探す。
    private static func isStarShaped(_ ring: [Int], points: [SIMD2<Float>]) -> Bool {
        guard ring.count >= 3 else { return true }
        var sum = SIMD2<Float>.zero
        for index in ring { sum += points[index] }
        let center = sum / Float(ring.count)
        guard center.x.isFinite, center.y.isFinite else { return false }
        var turn: Float = 0
        var laps = 0
        for position in ring.indices {
            let a = points[ring[position]] - center
            let b = points[ring[(position + 1) % ring.count]] - center
            let side = cross(a, b)
            // すべての辺が同じ側へ回る
            if turn == 0 { turn = side }
            guard side != 0, (side > 0) == (turn > 0) else { return false }
            // 重心から +x へ伸ばした半直線を何度跨ぐかで、回った周の数を数える
            if (a.y < 0) != (b.y < 0) {
                let x = a.x + (b.x - a.x) * (0 - a.y) / (b.y - a.y)
                if x > 0 { laps += 1 }
            }
        }
        return laps == 1
    }

    /// 穴のどれかが、外周と同じ向きに回るか、外周の外にあるか、別の穴の中にあるか。
    ///
    /// 置き場所は、比べる周の辺に載らない穴の点 1 つで見る (``placement(of:around:points:)``)。
    /// 辺の上の点は、半開きの数え方では辺の向きしだいで内にも外にもなり、外周の辺に触れる
    /// だけの穴を「外周の外」と取り違える。
    private static func holesAreOutOfPlace(
        rings: [[Int]], points: [SIMD2<Float>], comparisons: inout Int
    ) -> Bool {
        guard let outer = rings.first, outer.count >= 3 else { return false }
        let holes = rings.dropFirst().filter { $0.count >= 3 }
        guard !holes.isEmpty else { return false }
        // 外周と穴の点を 1 度ずつ舐め、穴ごとに外周の点を 1 度舐める (外の穴の囲みに掛かる
        // 穴は、その穴の点も舐める。ここでは数えない)
        comparisons += outer.count * (1 + holes.count) + holes.reduce(0) { $0 + $1.count }
        let outerArea = signedArea(of: outer, points: points)
        var boxes: [SIMD4<Float>] = []
        boxes.reserveCapacity(holes.count)
        for hole in holes {
            var box = SIMD4<Float>(.infinity, .infinity, -.infinity, -.infinity)
            for index in hole {
                let point = points[index]
                box = SIMD4(
                    min(box.x, point.x), min(box.y, point.y), max(box.z, point.x),
                    max(box.w, point.y))
            }
            boxes.append(box)
        }
        for (index, hole) in holes.enumerated() {
            // 外周と同じ向きの穴は、重なった所が回り数 2 になる。いまの手順では 2 度塗る
            let area = signedArea(of: hole, points: points)
            if outerArea != 0, area != 0, (area > 0) == (outerArea > 0) { return true }
            if placement(of: hole, around: outer, points: points) == 0 { return true }
            for (other, box) in boxes.enumerated() where other != index {
                let low = SIMD2(boxes[index].x, boxes[index].y)
                let high = SIMD2(boxes[index].z, boxes[index].w)
                guard low.x <= box.z, box.x <= high.x, low.y <= box.w, box.y <= high.y else { continue }
                if let turns = placement(of: hole, around: holes[other], points: points), turns != 0 {
                    return true
                }
            }
        }
        return false
    }

    /// 穴の点のうち、`ring` の辺に載らない最初の点のまわりの、`ring` の回り数。
    ///
    /// 頂点がすべて辺に載るなら、辺の中点で見る。それも載るなら決められないので `nil`。
    private static func placement(of hole: [Int], around ring: [Int], points: [SIMD2<Float>]) -> Int? {
        for index in hole {
            let probe = points[index]
            guard probe.x.isFinite, probe.y.isFinite else { continue }
            if let turns = windingOffEdges(of: probe, around: ring, points: points) { return turns }
        }
        for index in hole.indices {
            let probe = (points[hole[index]] + points[hole[(index + 1) % hole.count]]) / 2
            guard probe.x.isFinite, probe.y.isFinite else { continue }
            if let turns = windingOffEdges(of: probe, around: ring, points: points) { return turns }
        }
        return nil
    }

    /// 点のまわりの、周の回り数。点が周の辺の上にあれば `nil`。
    private static func windingOffEdges(
        of point: SIMD2<Float>, around ring: [Int], points: [SIMD2<Float>]
    ) -> Int? {
        var total = 0
        for index in ring.indices {
            let a = points[ring[index]]
            let b = points[ring[(index + 1) % ring.count]]
            let side = cross(b - a, point - a)
            if side == 0, point.x >= min(a.x, b.x), point.x <= max(a.x, b.x),
                point.y >= min(a.y, b.y), point.y <= max(a.y, b.y)
            {
                return nil
            }
            if a.y <= point.y, b.y > point.y, side > 0 { total += 1 }
            if a.y > point.y, b.y <= point.y, side < 0 { total -= 1 }
        }
        return total
    }

    /// 番号で引く周の、符号付きの面積の 2 倍。
    private static func signedArea(of ring: [Int], points: [SIMD2<Float>]) -> Float {
        var sum: Float = 0
        for index in ring.indices {
            let a = points[ring[index]]
            let b = points[ring[(index + 1) % ring.count]]
            sum += a.x * b.y - b.x * a.y
        }
        return sum
    }

    /// 点のまわりの、周の回り数。周の点は `position` で引く。
    fileprivate static func winding(
        of point: SIMD2<Float>, around ring: [Int], position: (Int) -> SIMD2<Float>
    ) -> Int {
        var total = 0
        for index in ring.indices {
            let a = position(ring[index])
            let b = position(ring[(index + 1) % ring.count])
            let side = cross(b - a, point - a)
            if a.y <= point.y, b.y > point.y, side > 0 { total += 1 }
            if a.y > point.y, b.y <= point.y, side < 0 { total -= 1 }
        }
        return total
    }
}

nonisolated extension Triangulation {
    /// 周の組の辺。
    nonisolated fileprivate struct RingEdges {
        let points: [SIMD2<Float>]
        var from: [Int] = []
        var to: [Int] = []
        /// 周ごとの、辺の番号の範囲。
        var rings: [Range<Int>] = []
        let tree: EdgeBoxes

        init(rings: [[Int]], points: [SIMD2<Float>]) {
            self.points = points
            for ring in rings where ring.count >= 3 {
                let start = from.count
                for position in ring.indices {
                    from.append(ring[position])
                    to.append(ring[(position + 1) % ring.count])
                }
                self.rings.append(start..<from.count)
            }
            tree = EdgeBoxes(from: from, to: to, points: points)
        }

        /// 見つけた交わり。辺は `from` / `to` の何番目か。
        struct Found {
            var crossing: Crossing
            var firstEdge: Int
            var secondEdge: Int
        }

        /// 周が交わるかを調べた結果。
        struct Survey {
            /// 後ろの辺と比べた辺の数。
            var pairs = 0
            /// 真の交わり。
            var crossings: [Found]
            /// 真の交わりか、頂点を通って向こう側へ抜ける所があるか。
            var isTangled: Bool
        }

        /// 1 つの位置を通る、周の通り道。
        enum Visit: Equatable {
            /// 辺 (`from` / `to` の何番目か) の始点の頂点を通る。
            case corner(Int)
            /// 辺の途中を通る。
            case through(Int)
        }

        /// 真の交わりと、頂点を通って向こう側へ抜ける所を探す。
        func survey() -> Survey {
            // **並びを手元に写してから回す。** `self` 越しに引くと、組ごとに並びの参照を
            // 数え直す手間が入り、C の字の 1024 点で探す手間が 4 割増えた
            let tree = tree
            let points = points
            let from = from
            let to = to
            var found: [Found] = []
            // 触れる所は稀なので、並びに積んでから位置ごとにまとめる
            var touches: [(SIMD2<Float>, Visit)] = []
            var pending: [(level: Int, box: Int)] = []
            var pairs = 0
            for first in from.indices where tree.isPlaced(first) {
                let a = points[from[first]]
                let b = points[to[first]]
                let reach = tree.box(of: first)
                // 数えるのは比べた辺の数で、組の数ではない。組や末端の箱ごとに数えると、
                // C の字の 4096 点で探す手間が 1 割増えた
                pairs += 1
                // 後ろの辺とだけ比べる (組を 1 度ずつ見る)。周の順に並んだ辺は位置も近いので、
                // 周の順に束ねた箱の木で、囲みの重なる辺だけを引ける
                pending.removeAll(keepingCapacity: true)
                pending.append((tree.rootLevel, 0))
                while let (level, box) = pending.popLast() {
                    let range = tree.edges(level: level, box: box)
                    guard range.upperBound > first + 1,
                        EdgeBoxes.overlap(tree.box(level: level, index: box), reach)
                    else { continue }
                    guard level == 0 else {
                        for child in tree.children(level: level, box: box) {
                            pending.append((level - 1, child))
                        }
                        continue
                    }
                    for second in max(range.lowerBound, first + 1)..<range.upperBound
                    where tree.isPlaced(second) && EdgeBoxes.overlap(tree.box(of: second), reach) {
                        let c = points[from[second]]
                        let d = points[to[second]]
                        // **符号の比べ方は、積ではなく符号どうしで見る。** 積は小さな値どうしで
                        // 0 に落ちる
                        let c1 = Triangulation.cross(b - a, c - a)
                        let c2 = Triangulation.cross(b - a, d - a)
                        if (c1 > 0 && c2 < 0) || (c1 < 0 && c2 > 0) {
                            let c3 = Triangulation.cross(d - c, a - c)
                            let c4 = Triangulation.cross(d - c, b - c)
                            if (c3 > 0 && c4 < 0) || (c3 < 0 && c4 > 0) {
                                let t = c3 / (c3 - c4)
                                let u = c1 / (c1 - c2)
                                found.append(
                                    Found(
                                        crossing: Crossing(
                                            first: .init(from: from[first], to: to[first], at: t),
                                            second: .init(from: from[second], to: to[second], at: u),
                                            point: a + t * (b - a)),
                                        firstEdge: first, secondEdge: second))
                                continue
                            }
                        }
                        // 真の交わりが 1 つでもあれば組み直すので、触れる所はもう見ない。
                        // 頂点はどれも、その点から出る辺の始点 (`a` か `c`) として 1 度ずつ
                        // 現れるので、始点どうしと、始点が相手の辺の途中に載る所だけを見る
                        guard found.isEmpty else { continue }
                        if a == c {
                            touches.append((a, .corner(first)))
                            touches.append((a, .corner(second)))
                        }
                        if c1 == 0, c != b, c != a, Self.isStrictlyBetween(c, a, b) {
                            touches.append((c, .through(first)))
                            touches.append((c, .corner(second)))
                        }
                        let span = tree.box(of: second)
                        guard a != c, a != d, a.x >= span.x, a.x <= span.z, a.y >= span.y, a.y <= span.w
                        else { continue }
                        if Triangulation.cross(d - c, a - c) == 0, Self.isStrictlyBetween(a, c, d) {
                            touches.append((a, .through(second)))
                            touches.append((a, .corner(first)))
                        }
                    }
                }
            }
            if !found.isEmpty { return Survey(pairs: pairs, crossings: found, isTangled: true) }
            var contacts: [SIMD2<Float>: [Visit]] = [:]
            for (point, visit) in touches where contacts[point]?.contains(visit) != true {
                contacts[point, default: []].append(visit)
            }
            for (point, visits) in contacts where visits.count >= 2 {
                if revisits(visits) || passesThrough(point, visits) {
                    return Survey(pairs: pairs, crossings: [], isTangled: true)
                }
            }
            return Survey(pairs: pairs, crossings: [], isTangled: false)
        }

        /// 1 つの位置を、周が頂点として 2 度以上通るか (別の周の頂点と重なる場合も含む)。
        ///
        /// 交わらず触れて戻るだけでも、耳切りは触れ合う 2 つの葉が同じ向きに回ると形の外まで
        /// 塗り、`mergeHoles` は触れた点へ架けた橋で穴の中を通る (#1886)。組み直すと、
        /// 繋ぎ方の規則が触れ合う点で周を葉ごとに分ける。
        ///
        /// 辺の途中に頂点が載るだけ (T の字の横棒に縦棒の角が載る・#1148) は数えない。
        /// 耳切りと、角の向きを見る `mergeHoles` の橋が正しく扱う。
        private func revisits(_ visits: [Visit]) -> Bool {
            var corners = 0
            for visit in visits {
                if case .corner = visit { corners += 1 }
            }
            return corners >= 2
        }

        /// 一直線に並ぶ 3 点で、`point` が `a` と `b` の間 (両端を除く) にあるか。
        private static func isStrictlyBetween(
            _ point: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>
        ) -> Bool {
            dot(point - a, b - a) > 0 && dot(point - b, a - b) > 0
        }

        /// 1 つの位置を通る通り道のどれかが、別の通り道の向こう側へ抜けるか。
        ///
        /// 通り道は、来た向きと出る向きの 2 本の向きで表す。2 つの通り道の 4 本の向きが、
        /// 角度の順で交互に並ぶなら、片方がもう片方を跨いでいる。向きが重なって決められない
        /// ときも抜けるとみなす (組み直す側へ送る。触れるだけの形を組み直しても絵は同じ)。
        private func passesThrough(_ point: SIMD2<Float>, _ visits: [Visit]) -> Bool {
            var ways: [(SIMD2<Float>, SIMD2<Float>)] = []
            for visit in visits {
                switch visit {
                case .through(let edge):
                    ways.append((points[from[edge]] - point, points[to[edge]] - point))
                case .corner(let edge):
                    guard let back = previousPosition(before: edge, at: point) else { continue }
                    ways.append((back - point, points[to[edge]] - point))
                }
            }
            for i in ways.indices {
                for j in ways.indices where j > i {
                    if Self.alternate(ways[i], ways[j]) != false { return true }
                }
            }
            return false
        }

        /// 辺 `edge` の始点へ来る前に周が居た、始点と違う位置。同じ位置の点が続けば遡る。
        private func previousPosition(before edge: Int, at point: SIMD2<Float>) -> SIMD2<Float>? {
            guard let ring = rings.first(where: { $0.contains(edge) }) else { return nil }
            var current = edge
            for _ in 0..<ring.count {
                current = current == ring.lowerBound ? ring.upperBound - 1 : current - 1
                let position = points[from[current]]
                guard position.x.isFinite, position.y.isFinite else { return nil }
                if position != point { return position }
            }
            return nil
        }

        /// 2 つの通り道の向きが、角度の順で交互に並ぶか。向きが重なって決められなければ `nil`。
        private static func alternate(
            _ first: (SIMD2<Float>, SIMD2<Float>), _ second: (SIMD2<Float>, SIMD2<Float>)
        ) -> Bool? {
            // 行って戻る通り道 (来た向きと出る向きが同じ) は、向こう側を持たない
            if sameDirection(first.0, first.1) || sameDirection(second.0, second.1) {
                for u in [first.0, first.1] {
                    for v in [second.0, second.1] where sameDirection(u, v) { return nil }
                }
                return false
            }
            guard let one = isBetween(second.0, from: first.0, to: first.1),
                let other = isBetween(second.1, from: first.0, to: first.1)
            else { return nil }
            return one != other
        }

        private static func sameDirection(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Bool {
            Triangulation.cross(u, v) == 0 && dot(u, v) > 0
        }

        /// `w` が、`u` から `v` へ反時計回りに回る間 (両端を除く) にあるか。`w` が `u` か
        /// `v` と同じ向きなら `nil`。`u` と `v` は同じ向きでないこと。
        private static func isBetween(
            _ w: SIMD2<Float>, from u: SIMD2<Float>, to v: SIMD2<Float>
        ) -> Bool? {
            if sameDirection(w, u) || sameDirection(w, v) { return nil }
            // `u` から測った角を、(0, π)・π・(π, 2π) の 3 つに分けて比べる
            func half(_ x: SIMD2<Float>) -> Int {
                let side = Triangulation.cross(u, x)
                return side > 0 ? 0 : side < 0 ? 2 : 1
            }
            let hw = half(w)
            let hv = half(v)
            if hw != hv { return hw < hv }
            return Triangulation.cross(w, v) > 0
        }

        /// 交わった周から、回り数が 0 でない所を囲む周を組む。組めなければ `nil`。
        func nonzeroSplit(crossings found: [Found], comparisons: inout Int) -> Split? {
            // 並びを手元に写す (``survey()`` と同じ理由)
            let tree = tree
            let points = points
            let from = from
            let to = to
            let base = points.count

            // 許容。形の大きさと、座標の大きさ (その位置での浮動小数の刻み) の大きいほうに
            // 比例させる
            var low = SIMD2<Float>(repeating: .infinity)
            var high = SIMD2<Float>(repeating: -.infinity)
            var magnitude: Float = 0
            for edge in from.indices where tree.isPlaced(edge) {
                for point in [points[from[edge]], points[to[edge]]] {
                    low = simd_min(low, point)
                    high = simd_max(high, point)
                    magnitude = max(magnitude, abs(point).max())
                }
            }
            guard low.x <= high.x else { return nil }
            let tolerance = max(max(high.x - low.x, high.y - low.y) * 0x1p-16, magnitude * 0x1p-20)
            guard tolerance > 0, tolerance.isFinite else { return nil }

            // 1. 交点を作る。端が相手の辺の許容の中にある組は、載る点として 2. で扱う
            var nodes = points
            var made: [Found] = []
            for item in found {
                let a = points[from[item.firstEdge]]
                let b = points[to[item.firstEdge]]
                let c = points[from[item.secondEdge]]
                let d = points[to[item.secondEdge]]
                if Self.distance(c, a, b) <= tolerance || Self.distance(d, a, b) <= tolerance
                    || Self.distance(a, c, d) <= tolerance || Self.distance(b, c, d) <= tolerance
                {
                    continue
                }
                nodes.append(item.crossing.point)
                made.append(item)
            }

            // 近い点を束ねる。束の代表は番号のいちばん小さい点 (頂点があれば頂点) で、
            // 位置もその点のものを使う
            var parent = Array(nodes.indices)
            func root(_ node: Int) -> Int {
                var node = node
                while parent[node] != node {
                    parent[node] = parent[parent[node]]
                    node = parent[node]
                }
                return node
            }
            var members: [Int] = []
            for edge in from.indices where tree.isPlaced(edge) {
                members.append(from[edge])
                members.append(to[edge])
            }
            members.append(contentsOf: base..<nodes.count)
            // **並びは番号の順に保つ** (集合の順で回すと、実行ごとに切り方が変わりうる)
            var seen = Array(repeating: false, count: nodes.count)
            var distinct: [Int] = []
            for node in members where !seen[node] {
                seen[node] = true
                distinct.append(node)
            }
            // 許容の幅の升目に入れ、隣り合う升目の点どうしだけを比べる。升目ごとの点は
            // 連結リストで持つ (`first` が升目の先頭、`after` が次の点)
            var first: [Int: Int] = [:]
            first.reserveCapacity(distinct.count)
            var after = [Int](repeating: -1, count: nodes.count)
            for node in distinct {
                let point = nodes[node]
                let column = Int((point.x / tolerance).rounded(.down))
                let row = Int((point.y / tolerance).rounded(.down))
                for dx in -1...1 {
                    for dy in -1...1 {
                        var other = first[Self.cell(column + dx, row + dy)] ?? -1
                        while other >= 0 {
                            if simd_distance(nodes[other], point) <= tolerance {
                                let (x, y) = (root(node), root(other))
                                if x != y { parent[max(x, y)] = min(x, y) }
                            }
                            other = after[other]
                        }
                    }
                }
                let key = Self.cell(column, row)
                after[node] = first[key] ?? -1
                first[key] = node
            }
            let representatives = distinct.filter { root($0) == $0 }

            // 2. 辺を切る点を集める。交点と、許容の中で辺の途中に載る点
            var cuts = Array(repeating: [Int](), count: from.count)
            var near: [Int] = []
            var queue: [(level: Int, box: Int)] = []
            for (index, item) in made.enumerated() {
                let node = root(base + index)
                cuts[item.firstEdge].append(node)
                cuts[item.secondEdge].append(node)
            }
            for node in representatives {
                let point = nodes[node]
                let reach = SIMD4(
                    point.x - tolerance, point.y - tolerance, point.x + tolerance, point.y + tolerance)
                tree.edges(overlapping: reach, into: &near, pending: &queue)
                comparisons += near.count
                for edge in near {
                    let start = root(from[edge])
                    let end = root(to[edge])
                    guard start != end, node != start, node != end else { continue }
                    let a = nodes[start]
                    let b = nodes[end]
                    let span = b - a
                    let at = dot(point - a, span) / dot(span, span)
                    guard at > 0, at < 1, simd_distance(point, a + at * span) <= tolerance else {
                        continue
                    }
                    cuts[edge].append(node)
                }
            }

            // 3. 切れ端を両端の番号の組で束ねる
            var bundles: [Bundle] = []
            var slot: [Int: Int] = [:]
            slot.reserveCapacity(from.count)
            var stops: [(at: Float, node: Int)] = []
            func add(_ start: Int, _ end: Int) {
                let forward = start < end
                let (low, high) = forward ? (start, end) : (end, start)
                let key = low &* nodes.count &+ high
                if let index = slot[key] {
                    bundles[index].net += forward ? 1 : -1
                } else {
                    slot[key] = bundles.count
                    bundles.append(Bundle(low: low, high: high, net: forward ? 1 : -1))
                }
            }
            for edge in from.indices where tree.isPlaced(edge) {
                let start = root(from[edge])
                let end = root(to[edge])
                guard start != end else { continue }
                guard !cuts[edge].isEmpty else {
                    add(start, end)
                    continue
                }
                let a = nodes[start]
                let span = nodes[end] - a
                let length = dot(span, span)
                stops.removeAll(keepingCapacity: true)
                for node in cuts[edge] where node != start && node != end {
                    stops.append((dot(nodes[node] - a, span) / length, node))
                }
                stops.sort { $0.at < $1.at }
                var previous = start
                for stop in stops where stop.node != previous {
                    add(previous, stop.node)
                    previous = stop.node
                }
                if end != previous { add(previous, end) }
            }
            bundles.removeAll { $0.net == 0 }
            guard !bundles.isEmpty else { return Split(crossings: [], regions: []) }

            //    両側の回り数を、面ごとに数える。束を両向きの半辺にし、点ごとに向きの順に並べて
            //    面をたどる。隣り合う面の回り数は束の `net` だけ違うので、繋がった束の組ごとに
            //    半直線を 1 本だけ引けば、残りの面は隣から決まる
            guard let right = windingsBySide(of: bundles, nodes: nodes, comparisons: &comparisons)
            else { return nil }

            //    片側だけが 0 の束を、塗る側が左になる向きで残す
            var kept: [(from: Int, to: Int)] = []
            var balance: [Int: Int] = [:]
            for (index, bundle) in bundles.enumerated() {
                let rightTurns = right[index]
                let leftTurns = rightTurns + bundle.net
                var edge: (from: Int, to: Int)?
                if leftTurns != 0, rightTurns == 0 { edge = (bundle.low, bundle.high) }
                if leftTurns == 0, rightTurns != 0 { edge = (bundle.high, bundle.low) }
                guard let edge else { continue }
                kept.append(edge)
                balance[edge.from, default: 0] += 1
                balance[edge.to, default: 0] -= 1
            }
            // 境の辺は、どの点でも入る数と出る数が等しい。崩れていれば数え違えている
            guard !kept.isEmpty, balance.values.allSatisfy({ $0 == 0 }) else { return nil }

            // 4. 残した辺を周へ繋ぐ
            guard let loops = Self.link(kept, nodes: nodes) else { return nil }

            // 5. 外周と穴に分け、穴を含むいちばん小さい外周へ付ける
            var regions: [Region] = []
            var areas: [Float] = []
            var holes: [[Int]] = []
            for loop in loops {
                var ring: [SIMD2<Float>] = []
                ring.reserveCapacity(loop.count)
                for node in loop { ring.append(nodes[node]) }
                let area = Triangulation.signedArea(ring)
                if area > 0 {
                    regions.append(Region(outer: loop, holes: []))
                    areas.append(area)
                } else if area < 0 {
                    holes.append(contentsOf: Self.separated(loop))
                }
            }
            guard !regions.isEmpty else { return nil }
            for hole in holes {
                // 穴の辺の中点は、穴を含む外周の内側にある (辺の左が塗る所なので)
                let probe = (nodes[hole[0]] + nodes[hole[1]]) / 2
                var owner: Int?
                for index in regions.indices
                where Triangulation.winding(of: probe, around: regions[index].outer, position: { nodes[$0] }) != 0
                    && (owner.map { areas[index] < areas[$0] } ?? true)
                {
                    owner = index
                }
                if let owner { regions[owner].holes.append(hole) }
            }

            // 交点のうち使ったものだけを、使った順に番号を振って返す
            var crossings: [Crossing] = []
            var renumbered: [Int: Int] = [:]
            func output(_ node: Int) -> Int {
                guard node >= base else { return node }
                if let known = renumbered[node] { return known }
                renumbered[node] = base + crossings.count
                crossings.append(made[node - base].crossing)
                return base + crossings.count - 1
            }
            for index in regions.indices {
                regions[index].outer = regions[index].outer.map(output)
                regions[index].holes = regions[index].holes.map { $0.map(output) }
            }
            return Split(crossings: crossings, regions: regions, slack: tolerance)
        }

        /// 升目の番号。
        private static func cell(_ column: Int, _ row: Int) -> Int {
            column &* 0x1_0000_0001 &+ row
        }

        /// 点から線分までの距離。
        private static func distance(
            _ point: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>
        ) -> Float {
            let span = b - a
            let length = dot(span, span)
            guard length > 0 else { return simd_distance(point, a) }
            let at = simd_clamp(dot(point - a, span) / length, 0, 1)
            return simd_distance(point, a + at * span)
        }

        /// 分けた辺の、両端の番号の組ごとの束。
        struct Bundle {
            /// 束の両端。番号の小さいほうが `low`。
            var low: Int
            var high: Int
            /// `low` から `high` へ向かう辺の数から、逆向きの辺の数を引いたもの。束の
            /// 左の回り数は、右より `net` だけ大きい。
            var net: Int
        }

        /// 束ごとの、右 (`low` から `high` へ進んで右) の回り数。数え違えていれば `nil`。
        ///
        /// 束を両向きの半辺 (`2 * 束` が `low` から `high`、`2 * 束 + 1` がその逆) にし、点から
        /// 出る半辺を向きの順に並べる。半辺の次は、行き着いた点で逆向きの半辺のすぐ時計回りに
        /// ある半辺で、たどると半辺の左の面を 1 周する。**隣り合う面の回り数は、境の束の `net`
        /// だけ違う**ので、面を隣へたどって決める。繋がった束の組 (面が隣でたどれる組) ごとに、
        /// 最初の面だけを ``windingRight(of:in:nodes:)`` の半直線で決める。
        ///
        /// 鎖ごとに半直線を引く形では、周が何度も交わる形 (なぞり書き) で鎖が短くなり、
        /// 手間が束の数の二乗に戻った。面でたどると、半直線は繋がった組の数だけで済む。
        ///
        /// 同じ面に 2 通りの回り数が付いたら、向きの順が丸めで崩れているので `nil` を返す。
        private func windingsBySide(
            of bundles: [Bundle], nodes: [SIMD2<Float>], comparisons: inout Int
        ) -> [Int]? {
            let halves = bundles.count * 2
            func origin(_ half: Int) -> Int {
                half & 1 == 0 ? bundles[half >> 1].low : bundles[half >> 1].high
            }
            func direction(_ half: Int) -> SIMD2<Float> { nodes[origin(half ^ 1)] - nodes[origin(half)] }

            // 点ごとに、出る半辺を向きの角の順に並べる
            var leaving: [Int: [Int]] = [:]
            for half in 0..<halves { leaving[origin(half), default: []].append(half) }
            var angle = [Float](repeating: 0, count: halves)
            for half in 0..<halves {
                let vector = direction(half)
                angle[half] = atan2(vector.y, vector.x)
            }
            var slot = [Int](repeating: 0, count: halves)
            for node in leaving.keys {
                let sorted = leaving[node]!.sorted { angle[$0] < angle[$1] || (angle[$0] == angle[$1] && $0 < $1) }
                leaving[node] = sorted
                for (index, half) in sorted.enumerated() { slot[half] = index }
            }
            comparisons += halves

            // 半辺の左の面に番号を振る
            var face = [Int](repeating: -1, count: halves)
            var faces: [[Int]] = []
            for start in 0..<halves where face[start] < 0 {
                var members: [Int] = []
                var half = start
                while face[half] < 0 {
                    face[half] = faces.count
                    members.append(half)
                    // 行き着いた点で、逆向きの半辺のすぐ時計回り (角の順で 1 つ前)
                    let around = leaving[origin(half ^ 1)]!
                    half = around[(slot[half ^ 1] + around.count - 1) % around.count]
                }
                // 1 周せずに別の面へ入ったなら、向きの順が崩れている
                guard half == start else { return nil }
                faces.append(members)
            }

            // 面の回り数を、隣の面から決める
            var turns = [Int?](repeating: nil, count: faces.count)
            var pending: [Int] = []
            for bundle in bundles.indices where turns[face[2 * bundle + 1]] == nil {
                // 右の面 = 逆向きの半辺の左の面
                turns[face[2 * bundle + 1]] = windingRight(of: bundle, in: bundles, nodes: nodes)
                comparisons += bundles.count
                pending.append(face[2 * bundle + 1])
                while let current = pending.popLast() {
                    guard let known = turns[current] else { continue }
                    for half in faces[current] {
                        // 半辺の左 (この面) は、右より、その向きの `net` だけ大きい
                        let net = half & 1 == 0 ? bundles[half >> 1].net : -bundles[half >> 1].net
                        let neighbor = face[half ^ 1]
                        let expected = known - net
                        if let other = turns[neighbor] {
                            guard other == expected else { return nil }
                        } else {
                            turns[neighbor] = expected
                            pending.append(neighbor)
                        }
                    }
                }
            }
            var right: [Int] = []
            right.reserveCapacity(bundles.count)
            for bundle in bundles.indices {
                guard let value = turns[face[2 * bundle + 1]] else { return nil }
                right.append(value)
            }
            return right
        }

        /// 束 `index` の中点のすぐ右 (`low` から `high` へ進んで右) の回り数。
        ///
        /// 右へ伸ばした半直線を跨ぐ束を、向きと数つきで数える (画素の中心で数える検査と
        /// 同じ半開きの規則を、束の向きを縦に取った座標で行う)。その束自身は数えない。半直線は
        /// その束を跨がないので、数えた値がすぐ右の回り数になる。**束どうしは両端の点を
        /// 共有するので、共有する点の高さは束のどちらから見ても同じ値になる** — 半開きの規則が
        /// 点ごとに矛盾なく効く。
        ///
        /// 跨いだ所が右か左かは、**跨いだ点の位置で決める** (束に対する中点の側の符号では
        /// 決めない)。格子の上の形では、半直線がちょうど別の束の上を通ることがある。その束の
        /// 両端の高さは誤差で 0 の上下に割れ、側の符号も誤差で決まる。跨いだ点は束の上に
        /// 載るので、束が中点から離れている限り正しい側に出る。
        private func windingRight(of index: Int, in bundles: [Bundle], nodes: [SIMD2<Float>]) -> Int {
            let start = nodes[bundles[index].low]
            let end = nodes[bundles[index].high]
            let middle = (start + end) / 2
            let direction = end - start
            let rightward = SIMD2(direction.y, -direction.x)
            var total = 0
            for (other, bundle) in bundles.enumerated() where other != index {
                let a = nodes[bundle.low]
                let b = nodes[bundle.high]
                let heightA = dot(a - middle, direction)
                let heightB = dot(b - middle, direction)
                guard (heightA <= 0) != (heightB <= 0) else { continue }
                let crossing = a + (heightA / (heightA - heightB)) * (b - a)
                guard dot(crossing - middle, rightward) > 0 else { continue }
                total += heightA <= 0 ? bundle.net : -bundle.net
            }
            return total
        }

        /// 辺の囲みの箱を、**周の順に** 4 つずつ束ねた木。
        ///
        /// 周の辺は順に繋がっているので、周の順に束ねれば箱は小さいまとまりになる
        /// (凹んだ角の索引 ``ConcaveCorners`` のように並べ替える必要が無い)。x の左端で
        /// 並べて幅の重なる組を見る形も試したが、歯車のような周では左右の端で x の幅が
        /// 重なる辺が多く、4096 点で耳切りの 3 倍掛かった。
        ///
        /// 数でない座標の辺と長さの無い辺は、どの辺とも真には交われないので木に入れない
        /// (箱を空にする)。
        fileprivate struct EdgeBoxes {
            private static let fanOut = 4
            /// 段ごとの箱。0 段目が辺そのもの、1 段目が辺を 4 つずつ束ねた箱。
            private var levels: [[SIMD4<Float>]] = []
            private var placed: [Bool] = []
            /// 段ごとの、箱 1 つが束ねる辺の数。
            private var spans: [Int] = [1]

            init(from: [Int], to: [Int], points: [SIMD2<Float>]) {
                var edges: [SIMD4<Float>] = []
                edges.reserveCapacity(from.count)
                placed.reserveCapacity(from.count)
                for edge in from.indices {
                    let a = points[from[edge]]
                    let b = points[to[edge]]
                    let usable = a.x.isFinite && a.y.isFinite && b.x.isFinite && b.y.isFinite && a != b
                    placed.append(usable)
                    edges.append(
                        usable
                            ? SIMD4(min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
                            : Self.empty)
                }
                levels = [edges]
                while levels[levels.count - 1].count > 1 {
                    let below = levels[levels.count - 1]
                    var above: [SIMD4<Float>] = []
                    above.reserveCapacity((below.count + Self.fanOut - 1) / Self.fanOut)
                    for start in stride(from: 0, to: below.count, by: Self.fanOut) {
                        var box = Self.empty
                        for index in start..<min(start + Self.fanOut, below.count) {
                            let child = below[index]
                            box = SIMD4(
                                min(box.x, child.x), min(box.y, child.y), max(box.z, child.z),
                                max(box.w, child.w))
                        }
                        above.append(box)
                    }
                    levels.append(above)
                    spans.append(spans[spans.count - 1] * Self.fanOut)
                }
            }

            private static let empty = SIMD4<Float>(.infinity, .infinity, -.infinity, -.infinity)

            var rootLevel: Int { levels.count - 1 }

            func isPlaced(_ edge: Int) -> Bool { placed[edge] }
            func box(of edge: Int) -> SIMD4<Float> { levels[0][edge] }
            func box(level: Int, index: Int) -> SIMD4<Float> { levels[level][index] }

            /// その段の箱が束ねる辺の番号。
            func edges(level: Int, box: Int) -> Range<Int> {
                let span = spans[level]
                return (box * span)..<min((box + 1) * span, levels[0].count)
            }

            func children(level: Int, box: Int) -> Range<Int> {
                let first = box * Self.fanOut
                return first..<min(first + Self.fanOut, levels[level - 1].count)
            }

            /// 囲みが `reach` と重なる辺を `result` へ入れ直す。`pending` は作業用の並び
            /// (呼ぶ側が使い回し、点ごとに並びを確保しない)。
            func edges(
                overlapping reach: SIMD4<Float>, into result: inout [Int],
                pending: inout [(level: Int, box: Int)]
            ) {
                result.removeAll(keepingCapacity: true)
                guard !levels[0].isEmpty else { return }
                pending.removeAll(keepingCapacity: true)
                pending.append((rootLevel, 0))
                while let (level, box) = pending.popLast() {
                    guard Self.overlap(self.box(level: level, index: box), reach) else { continue }
                    if level == 0 {
                        if placed[box] { result.append(box) }
                        continue
                    }
                    for child in children(level: level, box: box) { pending.append((level - 1, child)) }
                }
            }

            /// 2 つの箱が重なるか。触れるだけでも重なるとする (端が辺に載る組を落とさない)。
            static func overlap(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool {
                a.x <= b.z && b.x <= a.z && a.y <= b.w && b.y <= a.w
            }
        }

        /// 同じ点を 2 度以上通る周を、その点で分けた周の並び。
        ///
        /// 繋ぎ方の規則 (来た辺から時計回りに最初の辺) は、塗る所の角ごとに周を閉じるので、
        /// 外周は触れ合う所で別々の周に分かれる。**穴は逆に、触れ合う所で 1 つの周に繋がる**
        /// (穴の角は塗る所の外にある)。同じ点を 2 度通る穴を `mergeHoles` → 耳切りへ渡すと、
        /// 耳切りが形の外まで塗る。触れ合う点で分けると、どれも単純な穴になる。
        ///
        /// 分けた周は、始まりの点を 1 度だけ含む。2 点に満たない切れ端 (行って戻るだけ) は捨てる。
        private static func separated(_ loop: [Int]) -> [[Int]] {
            var path: [Int] = []
            var position: [Int: Int] = [:]
            var pieces: [[Int]] = []
            for node in loop {
                guard let start = position[node] else {
                    position[node] = path.count
                    path.append(node)
                    continue
                }
                let piece = Array(path[start...])
                for dropped in path[(start + 1)...] { position[dropped] = nil }
                path.removeSubrange((start + 1)...)
                if piece.count >= 3 { pieces.append(piece) }
            }
            if path.count >= 3 { pieces.append(path) }
            return pieces
        }

        /// 向きのついた辺を周へ繋ぐ。返すのは、周ごとの辺の始点の番号。周が閉じない・
        /// 使わない辺が残るなら `nil`。
        ///
        /// 1 つの点から辺が 2 本以上出るときは、**来た辺を逆にたどる向きから時計回りに
        /// 見て、最初に出会う辺**を選ぶ。塗る所は来た辺の左にあり、そこから時計回りに
        /// 広がって、最初に出会う出る辺で閉じる — その辺を選ぶと、塗る所の角を 1 つずつ
        /// 回る周になる。
        private static func link(_ kept: [(from: Int, to: Int)], nodes: [SIMD2<Float>]) -> [[Int]]? {
            var leaving: [Int: [Int]] = [:]
            for (index, edge) in kept.enumerated() {
                leaving[edge.from, default: []].append(index)
            }
            var used = Array(repeating: false, count: kept.count)
            var loops: [[Int]] = []
            for start in kept.indices where !used[start] {
                var loop: [Int] = []
                var current = start
                var closed = false
                // どの辺も 1 度しか通らないので、辺の数で必ず止まる
                for _ in 0..<kept.count {
                    used[current] = true
                    loop.append(kept[current].from)
                    let here = nodes[kept[current].to]
                    let back = nodes[kept[current].from] - here
                    var best: (index: Int, angle: Float)?
                    for candidate in leaving[kept[current].to] ?? []
                    where candidate == start || !used[candidate] {
                        let out = nodes[kept[candidate].to] - here
                        // `out` から `back` へ反時計回りに測った角 = `back` から `out` へ時計回りの角
                        var angle = atan2(Triangulation.cross(out, back), dot(out, back))
                        if angle <= 0 { angle += 2 * .pi }
                        if best.map({ angle < $0.angle }) ?? true { best = (candidate, angle) }
                    }
                    guard let next = best?.index else { break }
                    if next == start {
                        closed = true
                        break
                    }
                    current = next
                }
                guard closed else { return nil }
                if loop.count >= 3 { loops.append(loop) }
            }
            return loops
        }
    }
}
