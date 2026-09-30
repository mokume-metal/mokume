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
    }

    /// 周の組 (外周と穴) が「外周の中に、互いに離れた穴を開けた形」でなければ、**回り数が
    /// 0 でない所** (nonzero) を囲む周へ組み直す。その形なら `nil` を返す ([#1538])。
    ///
    /// 耳切りと `mergeHoles` は、単純な外周の中に離れた穴が並ぶ形の手順である。周が自分と
    /// 交わる形・穴が外周を跨ぐ形・外周の外に置いた周・穴の中に置いた周をそのまま渡すと、
    /// どの規則でも外になる所まで塗るか、塗る所を塗らない。そこで、そうした形だけをここで
    /// 分けてから同じ道具へ通す。**単純な形は `nil` が返るので、呼ぶ側の手順は 1 ビットも
    /// 変わらない。**
    ///
    /// 組み直すのは次のどれかに当たる形である。
    ///
    /// - **周が真に交わる。** 2 辺のどちらから見ても、もう一方の両端が逆の側にある組が
    ///   ある。端が辺の上に載る・同じ点を 2 度通る形 (字形の輪郭が普通に持つ形・[#1148]・
    ///   [#1211]) は数えない — そこは耳切りが既に正しく扱う
    /// - **穴の最初の点が、外周の中にない** (外周の外に置いた周・外周を包む周)
    /// - **穴の最初の点が、別の穴の中にある** (穴の中に置いた周)
    ///
    /// 外周と同じ向きに並べた穴は組み直さない。回り数 2 の所として塗られ、いまの手順でも
    /// 同じ絵になる。
    ///
    /// 交わりを探す手間は、耳切りと同じ次数に収める。辺の囲みの箱を周の順に束ねた木で、
    /// 囲みの重なる組だけを比べる。全部の組を比べると、交わらない大きな周で耳切りそのもの
    /// より重くなる。
    /// 穴の置き場所は、穴の最初の点 1 つを外周と、囲みの箱に入る別の穴とで数えるだけである。
    ///
    /// 組み直す手順は次のとおりである。
    ///
    /// 1. 交点で辺を分ける。別の辺の途中に載る角でも分ける
    /// 2. 分けた辺を位置の組で束ね、束ごとに両側の回り数を数える。**片側だけが 0 の束**が
    ///    塗る所の境で、塗る側が左になる向きで残す
    /// 3. 残した辺を周へ繋ぐ。1 つの位置から辺が 2 本以上出るときは、来た辺から時計回りに
    ///    見て最初の辺を選ぶ。塗る所の角ごとに周が閉じるので、砂時計は 1 点で触れ合う
    ///    2 つの三角形になる
    /// 4. 正の面積の周を外周、負の面積の周を穴とし、穴はそれを含むいちばん小さい外周へ付ける
    ///
    /// 組み直す手間は辺の数の二乗になる (回り数を束ごとに全部の辺から数える)。組み直す
    /// 形でしか払わない。
    ///
    /// - Parameters:
    ///   - rings: 周をなす点の番号。最初が外周、残りが穴。3 点に満たない周は、
    ///     `mergeHoles` と同じく無視する。
    ///   - points: 番号で引ける点の平らな座標。
    ///
    /// [#1148]: https://github.com/mokume-metal/mokume/issues/1148
    /// [#1211]: https://github.com/mokume-metal/mokume/issues/1211
    /// [#1538]: https://github.com/mokume-metal/mokume/issues/1538
    static func splitForNonzero(rings: [[Int]], points: [SIMD2<Float>]) -> Split? {
        if rings.count == 1, isStarShaped(rings[0], points: points) { return nil }
        let edges = RingEdges(rings: rings, points: points)
        let found = edges.crossings()
        guard !found.isEmpty || holesAreOutOfPlace(rings: rings, points: points) else {
            return nil
        }
        return Split(
            crossings: found.map(\.crossing),
            regions: edges.nonzeroRegions(crossings: found))
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

    /// 穴のどれかが外周の外にあるか、別の穴の中にあるか。見るのは穴の最初の点だけである
    /// (周どうしが交わらなければ、1 点で周全体の置き場所が決まる)。
    private static func holesAreOutOfPlace(rings: [[Int]], points: [SIMD2<Float>]) -> Bool {
        guard let outer = rings.first, outer.count >= 3 else { return false }
        let holes = rings.dropFirst().filter { $0.count >= 3 }
        guard !holes.isEmpty else { return false }
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
            let probe = points[hole[0]]
            guard probe.x.isFinite, probe.y.isFinite else { continue }
            if winding(of: probe, around: outer, points: points) == 0 { return true }
            for (other, box) in boxes.enumerated() where other != index {
                guard probe.x >= box.x, probe.x <= box.z, probe.y >= box.y, probe.y <= box.w
                else { continue }
                if winding(of: probe, around: holes[other], points: points) != 0 { return true }
            }
        }
        return false
    }

    /// 点のまわりの、周の回り数。
    fileprivate static func winding(
        of point: SIMD2<Float>, around ring: [Int], points: [SIMD2<Float>]
    ) -> Int {
        winding(of: point, around: ring) { points[$0] }
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

        init(rings: [[Int]], points: [SIMD2<Float>]) {
            self.points = points
            for ring in rings where ring.count >= 3 {
                for position in ring.indices {
                    from.append(ring[position])
                    to.append(ring[(position + 1) % ring.count])
                }
            }
        }

        /// 見つけた交わり。辺は `from` / `to` の何番目か。
        struct Found {
            var crossing: Crossing
            var firstEdge: Int
            var secondEdge: Int
        }

        /// 真の交わりを探す。
        func crossings() -> [Found] {
            let tree = EdgeBoxes(from: from, to: to, points: points)
            var found: [Found] = []
            var pending: [(level: Int, box: Int)] = []
            for first in from.indices where tree.isPlaced(first) {
                let a = points[from[first]]
                let b = points[to[first]]
                let reach = tree.box(of: first)
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
                        guard let (t, u) = Self.properCrossing(a, b, c, d) else { continue }
                        found.append(
                            Found(
                                crossing: Crossing(
                                    first: .init(from: from[first], to: to[first], at: t),
                                    second: .init(from: from[second], to: to[second], at: u),
                                    point: a + t * (b - a)),
                                firstEdge: first, secondEdge: second))
                    }
                }
            }
            return found
        }

        /// 2 辺が、どちらの端でもない所で交わるか。交わるなら、交点がそれぞれの辺の
        /// どこにあるか (始点で 0・終点で 1) を返す。
        ///
        /// **符号の比べ方は、積ではなく符号どうしで見る。** 積は小さな値どうしで 0 に落ちる。
        private static func properCrossing(
            _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>
        ) -> (Float, Float)? {
            let c1 = Triangulation.cross(b - a, c - a)
            let c2 = Triangulation.cross(b - a, d - a)
            guard (c1 > 0 && c2 < 0) || (c1 < 0 && c2 > 0) else { return nil }
            let c3 = Triangulation.cross(d - c, a - c)
            let c4 = Triangulation.cross(d - c, b - c)
            guard (c3 > 0 && c4 < 0) || (c3 < 0 && c4 > 0) else { return nil }
            return (c3 / (c3 - c4), c1 / (c1 - c2))
        }

        /// 交点で分けた辺から、回り数が 0 でない所を囲む周を組む。
        func nonzeroRegions(crossings found: [Found]) -> [Region] {
            let base = points.count
            func position(_ node: Int) -> SIMD2<Float> {
                node < base ? points[node] : found[node - base].crossing.point
            }

            // 1. 交点と、辺の途中に載る点で辺を分ける。辺ごとに、分ける点を辺の上の順に並べる
            var cuts = Array(repeating: [(at: Float, node: Int)](), count: from.count)
            for (index, item) in found.enumerated() {
                cuts[item.firstEdge].append((item.crossing.first.at, base + index))
                cuts[item.secondEdge].append((item.crossing.second.at, base + index))
            }
            addTouchingCorners(to: &cuts)

            // 2. 分けた辺を位置の組で束ね、束ごとに両側の回り数を数える。片側だけが 0 の束を、
            //    塗る側が左になる向きで残す
            let pieces = Self.pieces(from: from, to: to, cuts: cuts, position: position)
            var kept: [(from: Int, to: Int)] = []
            for piece in pieces where piece.net != 0 {
                let a = position(piece.low)
                let b = position(piece.high)
                let right = windingRight(of: (a + b) / 2, along: b - a, skipping: piece.edges)
                let left = right + piece.net
                if left != 0, right == 0 { kept.append((piece.low, piece.high)) }
                if left == 0, right != 0 { kept.append((piece.high, piece.low)) }
            }

            // 3. 残した辺を周へ繋ぐ
            let loops = Self.link(kept, position: position)

            // 4. 外周と穴に分け、穴を含むいちばん小さい外周へ付ける
            var regions: [Region] = []
            var areas: [Float] = []
            var holes: [[Int]] = []
            for loop in loops {
                var ring: [SIMD2<Float>] = []
                ring.reserveCapacity(loop.count)
                for node in loop { ring.append(position(node)) }
                let area = Triangulation.signedArea(ring)
                if area > 0 {
                    regions.append(Region(outer: loop, holes: []))
                    areas.append(area)
                } else if area < 0 {
                    holes.append(loop)
                }
            }
            for hole in holes {
                // 穴の辺の中点は、穴を含む外周の内側にある (辺の左が塗る所なので)
                let probe = (position(hole[0]) + position(hole[1])) / 2
                var owner: Int?
                for index in regions.indices
                where Triangulation.winding(of: probe, around: regions[index].outer, position: position) != 0
                    && (owner.map { areas[index] < areas[$0] } ?? true)
                {
                    owner = index
                }
                if let owner { regions[owner].holes.append(hole) }
            }
            return regions
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

            /// 2 つの箱が重なるか。触れるだけでも重なるとする (端が辺に載る組を落とさない)。
            static func overlap(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool {
                a.x <= b.z && b.x <= a.z && a.y <= b.w && b.y <= a.w
            }
        }

        /// 別の辺の途中に載る角で、その辺を分ける。
        ///
        /// 交わらない形では耳切りが扱う形 (T の横棒に縦棒の角が載る) だが、分けて繋ぎ直す
        /// ときは、載った所で辺を切らないと境の辺を繋げない。重なって並ぶ辺 (既定の書体の
        /// `A` の部品の上端) も、互いの端で切り合うので、重なった所が同じ位置の組になる。
        private func addTouchingCorners(to cuts: inout [[(at: Float, node: Int)]]) {
            for edge in from.indices {
                let a = points[from[edge]]
                let b = points[to[edge]]
                let span = b - a
                let length = dot(span, span)
                guard length > 0, length.isFinite else { continue }
                for corner in from.indices where corner != edge {
                    let point = points[from[corner]]
                    guard point != a, point != b, Triangulation.cross(span, point - a) == 0 else {
                        continue
                    }
                    let at = dot(point - a, span) / length
                    if at > 0, at < 1 { cuts[edge].append((at, from[corner])) }
                }
            }
        }

        /// 分けた辺の、位置の組ごとの束。
        struct Piece {
            /// 束の両端。位置の小さいほうが `low`。
            var low: Int
            var high: Int
            /// `low` から `high` へ向かう辺の数から、逆向きの辺の数を引いたもの。束の
            /// 左の回り数は、右より `net` だけ大きい。
            var net: Int
            /// 束に入った辺の、元の辺の番号。
            var edges: [Int]
        }

        /// 辺を分けた点で切り、同じ位置の組をなす切れ端を 1 つの束にまとめる。長さの無い
        /// 切れ端は捨てる (位置で繋ぐので、跨いで繋がる)。
        private static func pieces(
            from: [Int], to: [Int], cuts: [[(at: Float, node: Int)]],
            position: (Int) -> SIMD2<Float>
        ) -> [Piece] {
            var pieces: [Piece] = []
            var slot: [SIMD4<Float>: Int] = [:]
            for edge in from.indices {
                var nodes = [from[edge]]
                for cut in cuts[edge].sorted(by: { $0.at < $1.at }) { nodes.append(cut.node) }
                nodes.append(to[edge])
                for step in 0..<(nodes.count - 1) {
                    let start = nodes[step]
                    let end = nodes[step + 1]
                    let a = position(start)
                    let b = position(end)
                    guard a != b else { continue }
                    let forward = a.x < b.x || (a.x == b.x && a.y < b.y)
                    let key = forward ? SIMD4(lowHalf: a, highHalf: b) : SIMD4(lowHalf: b, highHalf: a)
                    if let index = slot[key] {
                        pieces[index].net += forward ? 1 : -1
                        if !pieces[index].edges.contains(edge) { pieces[index].edges.append(edge) }
                    } else {
                        slot[key] = pieces.count
                        pieces.append(
                            Piece(
                                low: forward ? start : end, high: forward ? end : start,
                                net: forward ? 1 : -1, edges: [edge]))
                    }
                }
            }
            return pieces
        }

        /// 辺の上の点 `point` のすぐ右 (`along` の向きに進んで右) の回り数。その点を通る辺
        /// (`skipped`) は数えない。
        ///
        /// 右へ伸ばした半直線を跨ぐ辺を、向きつきで数える (画素の中心で数える検査と同じ
        /// 半開きの規則を、`along` を縦に取った座標で行う)。半直線はその辺を跨がないので、
        /// 数えた値がすぐ右の回り数になり、すぐ左はそれより 1 大きい。
        private func windingRight(
            of point: SIMD2<Float>, along direction: SIMD2<Float>, skipping skipped: [Int]
        ) -> Int {
            var total = 0
            for edge in from.indices where !skipped.contains(edge) {
                let a = points[from[edge]]
                let b = points[to[edge]]
                let heightA = dot(a - point, direction)
                let heightB = dot(b - point, direction)
                let side = Triangulation.cross(b - a, point - a)
                if heightA <= 0, heightB > 0, side > 0 { total += 1 }
                if heightA > 0, heightB <= 0, side < 0 { total -= 1 }
            }
            return total
        }

        /// 向きのついた辺を周へ繋ぐ。返すのは、周ごとの辺の始点の番号。
        ///
        /// 辺は**番号ではなく位置で**繋ぐ。同じ位置の点が別の番号で並ぶ形 (周が同じ点を
        /// 2 度通る・曲線で閉じる周) でも、そこで途切れない。
        ///
        /// 1 つの位置から辺が 2 本以上出るときは、**来た辺を逆にたどる向きから時計回りに
        /// 見て、最初に出会う辺**を選ぶ。塗る所は来た辺の左にあり、そこから時計回りに
        /// 広がって、最初に出会う出る辺で閉じる — その辺を選ぶと、塗る所の角を 1 つずつ
        /// 回る周になる。
        private static func link(
            _ kept: [(from: Int, to: Int)], position: (Int) -> SIMD2<Float>
        ) -> [[Int]] {
            var leaving: [SIMD2<Float>: [Int]] = [:]
            for (index, edge) in kept.enumerated() {
                leaving[position(edge.from), default: []].append(index)
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
                    let here = position(kept[current].to)
                    let back = position(kept[current].from) - here
                    var best: (index: Int, angle: Float)?
                    for candidate in leaving[here] ?? [] where candidate == start || !used[candidate] {
                        let out = position(kept[candidate].to) - here
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
                if closed, loop.count >= 3 { loops.append(loop) }
            }
            return loops
        }
    }
}
