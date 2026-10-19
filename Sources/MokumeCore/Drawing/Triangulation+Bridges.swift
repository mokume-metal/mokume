// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// MARK: - 橋を遮る辺の索引

nonisolated extension Triangulation {
    /// 橋を架ける線を遮りうる辺を、囲みの箱で引く索引 (``mergeHoles(outer:holes:points:comparisons:slack:)``・
    /// [#2370](https://github.com/mokume-metal/mokume/issues/2370))。
    ///
    /// **遮りうる辺の集合は、畳むあいだ増えるだけである。** 畳んだ周の辺は、外周の辺と、畳んだ穴の辺と、
    /// 架けた橋の辺のどれかで、外周と穴の辺は始めから全部わかっている (橋だけが増える)。そこで、外周と
    /// 全ての穴の辺は、最初に 1 度だけ箱の木に入れる。畳めずに諦めた穴は、後の橋を遮らない (周に
    /// 入らない) ので、辺を持ち主ごとに「生きている」かを持ち、諦めたら落とす。橋は、架けるたびに
    /// 別の並びへ足す。
    ///
    /// 木に入れる並びは、穴を位置の近い順 (Z 順) に並べたものにする。穴を畳む順 (右にある順) のままだと、
    /// 4 つずつ束ねた箱が縦に長く伸びて、狭い橋を引いても多くの箱に重なる。
    ///
    /// **引くのは箱の重なりだけで、遮るかどうかは今までどおり `bridgeIsBlocked` が決める。** 箱は、橋の
    /// 囲みを相対で少し広げて引く — 外積と内積が 0 かの比べは丸めを含み、線から丸めの幅だけ離れた点も
    /// 「線の上」と数えうるため、囲みに厳密に収まる辺だけを引くと、今までの判定が遮った辺を落としうる。
    /// 長さの無い辺と数でない座標の辺は木に入らない (``EdgeBoxes``)。長さの無い辺が橋を遮るのは、その
    /// 位置が橋の途中にあるときだけだが、その位置は隣の長さのある辺の端点でもあるので、そちらが遮る。
    nonisolated struct BridgeObstacles {
        private let points: [SIMD2<Float>]
        private let tree: EdgeBoxes
        /// 木の辺ごとの、始点と終点の点の番号
        private let from: [Int]
        private let to: [Int]
        /// 木の辺ごとの持ち主。外周は 0、畳む順の `rank` 番目の穴は `rank + 1`
        private let owner: [Int]
        private var alive: [Bool]
        /// 架けた橋 (端と、その囲み)。数は穴の数を越えない
        private var bridges: [(from: SIMD2<Float>, to: SIMD2<Float>, box: SIMD4<Float>)] = []
        private var found: [Int] = []
        private var pending: [(level: Int, box: Int)] = []

        /// - Parameters:
        ///   - outer: 外周をなす点の番号。
        ///   - holes: 畳む順に並べた穴 (点の番号)。持ち主の `rank` は、この並びの何番目か。
        init(outer: [Int], holes: [[Int]], points: [SIMD2<Float>]) {
            self.points = points
            var from: [Int] = []
            var to: [Int] = []
            var owner: [Int] = []
            func append(_ ring: [Int], owner id: Int) {
                for position in ring.indices {
                    from.append(ring[position])
                    to.append(ring[(position + 1) % ring.count])
                    owner.append(id)
                }
            }
            append(outer, owner: 0)
            for rank in Self.spatialOrder(of: holes, points: points) {
                append(holes[rank], owner: rank + 1)
            }
            self.from = from
            self.to = to
            self.owner = owner
            alive = Array(repeating: true, count: holes.count + 1)
            tree = EdgeBoxes(from: from, to: to, points: points)
        }

        /// 穴を畳めなかった。この穴の辺は、後の橋を遮らない。
        mutating func retire(hole rank: Int) {
            alive[rank + 1] = false
        }

        /// 橋を架けた。以後の橋を遮る。
        mutating func addBridge(from: SIMD2<Float>, to: SIMD2<Float>) {
            bridges.append((from, to, Self.box(from, to)))
        }

        /// 架けた線が、外周 (先に畳んだ穴を含む) か穴のどれかの辺に**遮られる**か。調べた辺の数を
        /// `comparisons` へ積む。
        ///
        /// 橋と辺は、橋の両端でだけ触れてよい。橋の途中で触れるものは、**跨ぐ辺だけでなく、
        /// 辺の端点が橋の途中に載るものも**遮る ([#2508])。穴を縦や横に揃えて並べると、別の穴の
        /// 辺が橋と同じ直線に載る。端点が橋に載る辺を跨ぎに数えないと、橋は穴の角を串刺しにして
        /// 架かり、畳んだ周が自分の上に折り返して耳切りが三角形を取りこぼす。
        ///
        /// 遮らないのは、橋が 1 本の辺に丸ごと収まる場合である。辺に沿って、その端点や触れた点へ
        /// 架けるのは、穴が触れた点で周を正しく連結する幅のない橋で、これまでも正しく塗れていた
        /// ([#1886])。収まらずに途中まで重なる辺は、端点が橋の途中に載るので遮られる。
        ///
        /// 橋の両端と同じ位置にある点は、辺の端点でも橋の途中とは数えない。位置で比べるのは、
        /// 最後の点が最初の点と重なる周 (曲線で閉じる字の o) や、畳んだ周の継ぎ目で、同じ位置の
        /// 点が幾つも現れるためである。
        ///
        /// [#1886]: https://github.com/mokume-metal/mokume/issues/1886
        /// [#2508]: https://github.com/mokume-metal/mokume/issues/2508
        mutating func obstructs(
            from: SIMD2<Float>, to: SIMD2<Float>, comparisons: inout Int
        ) -> Bool {
            let span = to - from
            let length = dot(span, span)
            // 長さ 0 の橋 (穴の入口が外周の点に重なる) は、何にも触れない。数でない橋も遮られない
            guard length > 0 else { return false }
            let box = Self.box(from, to)
            let margin =
                1e-5 * (max(max(abs(from.x), abs(from.y)), max(abs(to.x), abs(to.y)))
                    + max(abs(span.x), abs(span.y)))
            let reach = box + SIMD4(-margin, -margin, margin, margin)

            tree.edges(overlapping: reach, into: &found, pending: &pending)
            comparisons += found.count
            for edge in found where alive[owner[edge]] {
                if Triangulation.bridgeIsBlocked(
                    by: points[self.from[edge]], points[self.to[edge]], from: from, to: to,
                    span: span, length: length)
                {
                    return true
                }
            }
            comparisons += bridges.count
            for bridge in bridges where EdgeBoxes.overlap(bridge.box, reach) {
                comparisons += 1
                if Triangulation.bridgeIsBlocked(
                    by: bridge.from, bridge.to, from: from, to: to, span: span, length: length)
                {
                    return true
                }
            }
            return false
        }

        private static func box(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD4<Float> {
            SIMD4(min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
        }

        /// 穴の番号を、位置の近い順に並べる。穴の囲みの中心を、全体の囲みで 16 ビットに割り、2 つの座標の
        /// ビットを交互に並べた値 (Z 順) で並べる。同じ値は番号の順。
        private static func spatialOrder(of holes: [[Int]], points: [SIMD2<Float>]) -> [Int] {
            var centers: [SIMD2<Float>] = []
            centers.reserveCapacity(holes.count)
            var low = SIMD2<Float>(repeating: .infinity)
            var high = SIMD2<Float>(repeating: -.infinity)
            for hole in holes {
                var box = SIMD4<Float>(.infinity, .infinity, -.infinity, -.infinity)
                for index in hole {
                    let point = points[index]
                    guard point.x.isFinite, point.y.isFinite else { continue }
                    box = SIMD4(min(box.x, point.x), min(box.y, point.y), max(box.z, point.x), max(box.w, point.y))
                }
                let center = SIMD2((box.x + box.z) / 2, (box.y + box.w) / 2)
                centers.append(center)
                guard center.x.isFinite, center.y.isFinite else { continue }
                low = pointwiseMin(low, center)
                high = pointwiseMax(high, center)
            }
            let extent = high - low
            func cell(_ value: Float, _ origin: Float, _ size: Float) -> UInt32 {
                guard value.isFinite, size.isFinite, size > 0 else { return 0 }
                return UInt32(min(max((value - origin) / size * 65535, 0), 65535))
            }
            func spread(_ value: UInt32) -> UInt32 {
                var bits = value & 0xFFFF
                bits = (bits | (bits << 8)) & 0x00FF_00FF
                bits = (bits | (bits << 4)) & 0x0F0F_0F0F
                bits = (bits | (bits << 2)) & 0x3333_3333
                bits = (bits | (bits << 1)) & 0x5555_5555
                return bits
            }
            let keys = centers.map {
                spread(cell($0.x, low.x, extent.x)) | (spread(cell($0.y, low.y, extent.y)) << 1)
            }
            return holes.indices.sorted { keys[$0] != keys[$1] ? keys[$0] < keys[$1] : $0 < $1 }
        }
    }
}
