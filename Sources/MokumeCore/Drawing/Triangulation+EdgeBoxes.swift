// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

nonisolated extension Triangulation {
    /// 辺の囲みの箱を、**周の順に** 4 つずつ束ねた木。
    ///
    /// 周の辺は順に繋がっているので、周の順に束ねれば箱は小さいまとまりになる
    /// (凹んだ角の索引 ``ConcaveCorners`` のように並べ替える必要が無い)。x の左端で
    /// 並べて幅の重なる組を見る形も試したが、歯車のような周では左右の端で x の幅が
    /// 重なる辺が多く、4096 点で耳切りの 3 倍掛かった。
    ///
    /// 数でない座標の辺と長さの無い辺は、どの辺とも真には交われないので木に入れない
    /// (箱を空にする)。
    ///
    /// 周の交わりを探す ``Triangulation/RingEdges`` のほか、穴を畳む橋を遮る辺を引く
    /// ``BridgeObstacles`` が使う (後者は、穴を位置の近い順に並べて入れる・[#2370])。
    ///
    /// [#2370]: https://github.com/mokume-metal/mokume/issues/2370
    nonisolated struct EdgeBoxes {
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
}
