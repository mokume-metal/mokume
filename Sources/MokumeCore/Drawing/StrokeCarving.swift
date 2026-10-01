// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 1 本の線の片を、互いに重ねずに積むための引き算 ([#1536]・[#1562])。
///
/// 平面の線は、帯・折れ目の形・端の形・曲線の刻みの円板を別々の凸多角形として積む
/// (`Canvas.strokeRing`)。重ねたまま積むと、半透明の線や下地を読む混ぜ方で重なった所だけが
/// 2〜3 回混ざる。ここでは片を積む順に並べ、**先に置いた関係する片との差**を凸多角形の
/// 組として返す。形は変えず、塗る領域 (片の和) も変えない。
///
/// **どの片を引くか ([#1536] の判断 1):**
///
/// - 任意多角形 (`beginShape`・`triangle`・辺の交差する `quad`・`line`): 線に沿った隔たり
///   (弧長の区間どうしの隙間。閉じた周は一周で巡る) が太さ以内の片だけ。**線に沿って太さより
///   離れた部分が画面で重なる所は、別々の線が重なるのと同じく 2 回混ぜる。** 自己交差のほか、
///   自己交差しなくても、細長く並べた形の向かい合う辺や、刻みの細かい曲線の折り返しがそう
///   である (点を並べた細長い楕円は `ellipse()` と違って濃くなる)
/// - 基本図形 (`rect` / `ellipse` / `arc`・辺の交差しない `quad`): 先に置いた片を全部。
///   自己交差しないので、線全体を 1 つの領域として 1 回だけ混ぜる — 距離関数の経路と同じ
///   である ([#1562])。周の点は高々 1025 個 (``Canvas/segmentCount(forRadius:)``) なので、
///   全部を相手にしても箱で絞れば足りる
///
/// **相手は線に沿って前後へ探す。** 点の位置 (弧長) は単調に増えるので、窓に入る帯と点は
/// それぞれ添字の連続した範囲になる。先に置いた片を全部なめると、自己交差の多い線で
/// 費用が線の長さの 2 乗で増える。
///
/// 座標は変換を掛ける前の形自身の座標で持つ。平面の変換は位置を線形に写すだけなので、
/// 重なりは変換の後も同じである。
///
/// [#1536]: https://github.com/mokume-metal/mokume/issues/1536
/// [#1562]: https://github.com/mokume-metal/mokume/issues/1562
nonisolated struct StrokeCarving {
    /// 点ごとの、線に沿った位置 (弧長)。`positions[k]` が点 `k` で、閉じた周なら
    /// `positions[count]` が一周の長さ。
    private let positions: [Float]
    private let pointCount: Int
    private let segmentCount: Int
    private let isClosed: Bool
    /// 基本図形か (先に置いた片を全部引く)。
    private let wholeOutline: Bool
    /// 太さ。任意多角形で、線に沿った隔たりがこれ以内の片を引く。
    private let weight: Float

    /// 積んだ片。どれも反時計回り (x 右・y 上の数学の向き) の凸多角形。
    private var pieces = Polygons()
    /// 片ごとの、線に沿った位置の区間。帯は両端の点の位置、点の形は 1 点。
    private var lowers: [Float] = []
    private var uppers: [Float] = []
    /// 帯の添字ごとの片の添字。帯を置かなかった線分 (長さ 0) は -1。
    private var bandPieces: [Int]
    /// 点の添字ごとの、点に置いた形の片の添字。置かなかった点は -1。
    private var pointPieces: [Int]
    /// 同じ点に 2 つ目の形が来たときの片。骨はそうしないが、来たら常に相手に数える。
    private var unindexedPieces: [Int] = []
    /// 座標の大きさ。切り口の判定の許容差を、単精度の桁に合わせて決める。
    private var magnitude: Float = 1

    /// - Parameters:
    ///   - points: 周の点 (形自身の座標)
    ///   - isClosed: 周が閉じているか
    ///   - weight: 線の太さ
    ///   - wholeOutline: 基本図形の線か。そうなら先に置いた片を全部引く
    init(points: [SIMD2<Float>], isClosed: Bool, weight: Float, wholeOutline: Bool) {
        pointCount = points.count
        segmentCount = points.count < 2 ? 0 : (isClosed ? points.count : points.count - 1)
        self.isClosed = isClosed
        self.weight = weight
        self.wholeOutline = wholeOutline
        var positions: [Float] = [0]
        positions.reserveCapacity(segmentCount + 1)
        var length: Float = 0
        for index in 0..<segmentCount {
            length += simd_distance(points[index], points[(index + 1) % points.count])
            positions.append(length)
        }
        self.positions = positions
        bandPieces = [Int](repeating: -1, count: segmentCount)
        pointPieces = [Int](repeating: -1, count: points.count)
        // 片は、線分ごとの帯と点ごとの形で高々。積む前に容量を取り、伸ばすたびの再確保を避ける。
        // 保持した形は記録のたびにこれを組んで持つので ([#1920])、小さな線を大量に記録する形の
        // 記録時間に効く。点の数は片の形で決まるので、帯 1 枚ぶん (4 点) を見込む
        //
        // [#1920]: https://github.com/mokume-metal/mokume/issues/1920
        let pieceBound = segmentCount + points.count
        pieces.ranges.reserveCapacity(pieceBound)
        pieces.boxes.reserveCapacity(pieceBound)
        pieces.points.reserveCapacity(pieceBound * 4)
        lowers.reserveCapacity(pieceBound)
        uppers.reserveCapacity(pieceBound)
    }

    /// 線分 `segment` (点 `segment` から次の点まで) の帯を足す。`build` が凸多角形の周を積む。
    mutating func addBand(segment: Int, _ build: (inout [SIMD2<Float>]) -> Void) {
        guard segment < segmentCount,
            let index = add(positions[segment], positions[segment + 1], build)
        else { return }
        bandPieces[segment] = index
    }

    /// 点 `point` に置いた形 (折れ目・端・刻みの円板) を足す。`build` が凸多角形の周を積む。
    mutating func addPoint(_ point: Int, _ build: (inout [SIMD2<Float>]) -> Void) {
        guard point < pointCount else { return }
        let position = point < positions.count ? positions[point] : 0
        guard let index = add(position, position, build) else { return }
        if pointPieces[point] < 0 { pointPieces[point] = index } else { unindexedPieces.append(index) }
    }

    private mutating func add(
        _ lower: Float, _ upper: Float, _ build: (inout [SIMD2<Float>]) -> Void
    ) -> Int? {
        let start = pieces.points.count
        build(&pieces.points)
        let range = start..<pieces.points.count
        let area = range.count >= 3 ? Self.twiceArea(pieces.points, range) : 0
        guard area != 0, area.isFinite else {
            pieces.points.removeSubrange(range)
            return nil
        }
        if area < 0 { pieces.points[range].reverse() }
        let box = Box(pieces.points, range)
        pieces.ranges.append(range)
        pieces.boxes.append(box)
        magnitude = max(magnitude, abs(box.low).max(), abs(box.high).max())
        lowers.append(lower)
        uppers.append(upper)
        return pieces.ranges.count - 1
    }

    /// 片を積む順に、先に置いた関係する片を引いた残りを返す。
    ///
    /// 残りは片ごとに 0 個以上の凸多角形で、和は片の和と同じである。`emit` には周の点の並びと
    /// その区間 (反時計回り) と扇の要を渡す。要が `nil` なら周の最初の点から扇に割る。
    ///
    /// **相手は近い順に引く。** 線に沿って隣の片がたいてい大半を覆うので、近い順なら残りが
    /// 早く尽きて、遠い相手を見ずに済む。残りの囲みの箱に掛からない相手も飛ばす。
    ///
    /// **T 字の継ぎ目を作らない。** 引いた残りの縁は相手の辺の上を通るが、頂点は相手の頂点と
    /// 揃わない。そのまま積むと、同じ直線を 2 組の違う端点で引いた縁になり、画素の中心が
    /// ちょうど縁に乗る所 (利用者の置いた整数の点を通る縁) で、丸めのためにどちらの三角形にも
    /// 入らない穴か、両方に入る重なりが出る。縁の上に乗る相手の頂点を自分の周にも差し込んで、
    /// 隣り合う三角形が同じ端点の辺を分け合うようにする。差し込んだ周は、周の点と一直線に
    /// 並ばない重心を要にして扇に割る — 最初の点から割ると、差し込んだ点を含む辺が面積 0 の
    /// 三角形に落ち、分け合うはずの辺が消える。
    func carved(
        _ emit: (_ points: [SIMD2<Float>], _ rim: Range<Int>, _ hub: SIMD2<Float>?) -> Void
    ) {
        // 切り口の判定の許容差。点が直線からこれ以内なら「直線の上」と読む
        let tolerance = magnitude * 32 * Float.ulpOfOne
        let reach = tolerance * 4
        let count = pieces.ranges.count
        var stamps = [Int](repeating: -1, count: count)
        var candidates: [(gap: Float, piece: Int)] = []
        var work = Polygons()
        var next = Polygons()
        var scratch = Scratch()
        // 片ごとの残り (`owners` が片ごとの区間) と、重なっていた片の対
        var carved = Polygons()
        var owners: [Range<Int>] = []
        owners.reserveCapacity(count)
        var pairs: [(Int, Int)] = []
        for index in 0..<count {
            candidates.removeAll(keepingCapacity: true)
            collectCandidates(of: index, into: &candidates, stamps: &stamps)
            if candidates.count > 1 { candidates.sort { $0.gap < $1.gap } }
            work.removeAll()
            work.append(pieces.points, pieces.ranges[index], box: pieces.boxes[index])
            var rest = pieces.boxes[index]
            for (_, other) in candidates {
                guard rest.grown(by: tolerance).overlaps(pieces.boxes[other]) else { continue }
                next.removeAll()
                var touched = false
                for fragment in 0..<work.ranges.count {
                    let contact = Self.subtract(
                        pieces, other, from: work, fragment, tolerance: tolerance, into: &next,
                        scratch: &scratch)
                    if contact != .apart { touched = true }
                }
                if touched { pairs.append((index, other)) }
                swap(&work, &next)
                guard let box = work.box else { break }
                rest = box
            }
            let first = carved.ranges.count
            for fragment in 0..<work.ranges.count {
                carved.append(work.points, work.ranges[fragment], box: work.boxes[fragment])
            }
            owners.append(first..<carved.ranges.count)
        }

        // 片ごとの相手 (引いた相手と、引かれた相手) を詰めた並び
        var starts = [Int](repeating: 0, count: count + 1)
        for (a, b) in pairs {
            starts[a + 1] += 1
            starts[b + 1] += 1
        }
        for index in 0..<count { starts[index + 1] += starts[index] }
        var filled = starts
        var neighbors = [Int](repeating: 0, count: pairs.count * 2)
        for (a, b) in pairs {
            neighbors[filled[a]] = b
            filled[a] += 1
            neighbors[filled[b]] = a
            filled[b] += 1
        }

        var sources: [Int] = []
        var nearby: [SIMD2<Float>] = []
        var rim: [SIMD2<Float>] = []
        var onEdge: [(t: Float, point: SIMD2<Float>)] = []
        for index in 0..<count {
            let owner = owners[index]
            let around = starts[index]..<starts[index + 1]
            for fragment in owner {
                let range = carved.ranges[fragment]
                guard !around.isEmpty || owner.count > 1 else {
                    emit(carved.points, range, nil)
                    continue
                }
                // 縁が接しうる残り: 自分の片のほかの残りと、相手の片の残りのうち、箱が掛かるもの
                let box = carved.boxes[fragment].grown(by: reach)
                sources.removeAll(keepingCapacity: true)
                for other in owner where other != fragment && box.overlaps(carved.boxes[other]) {
                    sources.append(other)
                }
                for slot in around {
                    for other in owners[neighbors[slot]] where box.overlaps(carved.boxes[other]) {
                        sources.append(other)
                    }
                }
                guard !sources.isEmpty else {
                    emit(carved.points, range, nil)
                    continue
                }
                Self.insert(
                    into: carved, fragment, from: sources, reach: reach, nearby: &nearby, rim: &rim,
                    onEdge: &onEdge)
                if rim.count == range.count {
                    emit(carved.points, range, nil)
                } else {
                    var hub = SIMD2<Float>(0, 0)
                    for point in rim { hub += point }
                    emit(rim, 0..<rim.count, hub / Float(rim.count))
                }
            }
        }
    }

    /// 囲みの箱。
    private struct Box {
        var low: SIMD2<Float>
        var high: SIMD2<Float>

        init(low: SIMD2<Float>, high: SIMD2<Float>) {
            self.low = low
            self.high = high
        }

        init(_ points: [SIMD2<Float>], _ range: Range<Int>) {
            low = points[range.lowerBound]
            high = low
            for index in range {
                low = simd_min(low, points[index])
                high = simd_max(high, points[index])
            }
        }

        /// 内側どうしが重なるか (縁が接するだけなら偽)。
        func overlaps(_ other: Box) -> Bool {
            low.x < other.high.x && other.low.x < high.x && low.y < other.high.y
                && other.low.y < high.y
        }

        func grown(by amount: Float) -> Box {
            Box(low: low - amount, high: high + amount)
        }

        func union(_ other: Box) -> Box {
            Box(low: simd_min(low, other.low), high: simd_max(high, other.high))
        }
    }

    /// 凸多角形の組。点を 1 本の並びに詰め、多角形ごとの区間と囲みの箱を持つ。
    ///
    /// 残りを割るたびに多角形ごとの配列を作ると、確保だけで費用の大半を占める。
    private struct Polygons {
        var points: [SIMD2<Float>] = []
        var ranges: [Range<Int>] = []
        var boxes: [Box] = []

        mutating func removeAll() {
            points.removeAll(keepingCapacity: true)
            ranges.removeAll(keepingCapacity: true)
            boxes.removeAll(keepingCapacity: true)
        }

        mutating func append(_ source: [SIMD2<Float>], _ range: Range<Int>, box: Box) {
            let start = points.count
            points.append(contentsOf: source[range])
            ranges.append(start..<points.count)
            boxes.append(box)
        }

        /// 全部の多角形の囲みの箱。空なら `nil`。
        var box: Box? {
            guard var box = boxes.first else { return nil }
            for other in boxes.dropFirst() { box = box.union(other) }
            return box
        }
    }

    /// 割るときの作業場。呼び出しをまたいで使い回し、確保を払わない。
    private struct Scratch {
        var rest: [SIMD2<Float>] = []
        var inside: [SIMD2<Float>] = []
        var outside: [SIMD2<Float>] = []
    }

    /// 残り `fragment` の周の辺の上に乗る、ほかの残り (`sources`) の頂点を差し込んだ周を
    /// `rim` に作る。
    ///
    /// 相手の頂点のうち残りの箱に入るものを先に 1 度だけ拾い、辺ごとにはそれだけを見る。
    ///
    /// - Parameter reach: 辺からこれ以内の頂点を「辺の上」と読む
    private static func insert(
        into carved: Polygons, _ fragment: Int, from sources: [Int], reach: Float,
        nearby: inout [SIMD2<Float>], rim: inout [SIMD2<Float>],
        onEdge: inout [(t: Float, point: SIMD2<Float>)]
    ) {
        let range = carved.ranges[fragment]
        let box = carved.boxes[fragment].grown(by: reach)
        nearby.removeAll(keepingCapacity: true)
        for other in sources {
            for index in carved.ranges[other] {
                let candidate = carved.points[index]
                if candidate.x >= box.low.x, candidate.x <= box.high.x, candidate.y >= box.low.y,
                    candidate.y <= box.high.y
                {
                    nearby.append(candidate)
                }
            }
        }
        rim.removeAll(keepingCapacity: true)
        var previous = carved.points[range.upperBound - 1]
        for index in range {
            let point = carved.points[index]
            let edge = point - previous
            let lengthSquared = simd_length_squared(edge)
            onEdge.removeAll(keepingCapacity: true)
            if lengthSquared > 0 {
                let length = lengthSquared.squareRoot()
                let low = simd_min(previous, point) - reach
                let high = simd_max(previous, point) + reach
                for candidate in nearby {
                    guard candidate.x >= low.x, candidate.x <= high.x, candidate.y >= low.y,
                        candidate.y <= high.y, candidate != previous, candidate != point
                    else { continue }
                    let offset = candidate - previous
                    let across = (edge.x * offset.y - edge.y * offset.x) / length
                    guard abs(across) <= reach else { continue }
                    let t = simd_dot(offset, edge) / lengthSquared
                    guard t > 0, t < 1 else { continue }
                    if !onEdge.contains(where: { $0.point == candidate }) {
                        onEdge.append((t, candidate))
                    }
                }
            }
            if onEdge.count > 1 { onEdge.sort { $0.t < $1.t } }
            for inserted in onEdge { rim.append(inserted.point) }
            rim.append(point)
            previous = point
        }
    }

    /// 片 `index` が引く相手 (先に置いた片のうち、箱が掛かるもの) を、線に沿った隙間と共に集める。
    private func collectCandidates(
        of index: Int, into candidates: inout [(gap: Float, piece: Int)], stamps: inout [Int]
    ) {
        let box = pieces.boxes[index]
        let lower = lowers[index]
        let upper = uppers[index]
        let perimeter = positions[positions.count - 1]
        func take(_ other: Int) {
            guard other >= 0, other < index, stamps[other] != index else { return }
            stamps[other] = index
            guard box.overlaps(pieces.boxes[other]) else { return }
            // 線に沿った隙間。閉じた周は一周ずらした相手とも比べ、近いほうを取る
            var gap = max(0, lowers[other] - upper, lower - uppers[other])
            if isClosed {
                let ahead = max(0, lowers[other] + perimeter - upper, lower - uppers[other] - perimeter)
                let behind = max(0, lowers[other] - perimeter - upper, lower - uppers[other] + perimeter)
                gap = min(gap, ahead, behind)
            }
            candidates.append((gap, other))
        }
        if wholeOutline {
            for other in 0..<index { take(other) }
            return
        }
        for other in unindexedPieces { take(other) }
        for turn in isClosed ? -1...1 : 0...0 {
            let shift = Float(turn) * perimeter
            // 相手の区間を一周ずらしたものが [lower, upper] を太さだけ広げた窓に掛かるか
            let low = lower - weight - shift
            let high = upper + weight - shift
            // 帯: positions[k + 1] >= low かつ positions[k] <= high の k は連続する
            if segmentCount > 0 {
                var segment = Self.firstIndex(in: positions, from: 1, notBelow: low) - 1
                while segment < segmentCount, positions[segment] <= high {
                    take(bandPieces[segment])
                    segment += 1
                }
            }
            // 点: positions[p] が窓に入る p も連続する
            var point = Self.firstIndex(in: positions, from: 0, notBelow: low)
            while point < pointCount, positions[point] <= high {
                take(pointPieces[point])
                point += 1
            }
        }
    }

    /// `values[from...]` のうち、`bound` 以上の最初の添字。無ければ `values.count`。
    private static func firstIndex(in values: [Float], from start: Int, notBelow bound: Float) -> Int {
        var low = start
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < bound { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // MARK: - 凸多角形の差

    /// 符号付きの面積の 2 倍。反時計回りで正。
    private static func twiceArea(_ points: [SIMD2<Float>], _ range: Range<Int>) -> Float {
        var sum: Float = 0
        var previous = points[range.upperBound - 1]
        for index in range {
            let point = points[index]
            sum += previous.x * point.y - previous.y * point.x
            previous = point
        }
        return sum
    }

    /// 残り (`polygons` の `fragment` 番目) から片 (`cutters` の `cutter` 番目) を引いた残りを、
    /// 凸多角形の組として `result` に足す。
    ///
    /// 片の辺を 1 本ずつ延ばした直線で割り、外側を残りとして取り、内側を次の辺で割り続ける。
    /// **先に離れているかを見る** (箱と分離軸) — 離れているのに割り始めると、重ならない片まで
    /// 無用に刻んでしまう。
    ///
    /// - Returns: 接し方。重ならなければ残りをそのまま足す
    private static func subtract(
        _ cutters: Polygons, _ cutter: Int, from polygons: Polygons, _ fragment: Int,
        tolerance: Float, into result: inout Polygons, scratch: inout Scratch
    ) -> Contact {
        let range = polygons.ranges[fragment]
        let box = polygons.boxes[fragment]
        let edges = cutters.ranges[cutter]
        let contact =
            box.grown(by: tolerance).overlaps(cutters.boxes[cutter])
            ? separation(polygons.points, range, by: cutters.points, edges, tolerance: tolerance)
                ?? separation(cutters.points, edges, by: polygons.points, range, tolerance: tolerance)
                ?? .overlapping
            : .apart
        guard contact == .overlapping else {
            result.append(polygons.points, range, box: box)
            return contact
        }
        scratch.rest.removeAll(keepingCapacity: true)
        scratch.rest.append(contentsOf: polygons.points[range])
        var previous = cutters.points[edges.upperBound - 1]
        for index in edges {
            let point = cutters.points[index]
            let (hasOutside, hasInside) = split(
                scratch.rest, along: previous, point, tolerance: tolerance,
                outside: &scratch.outside, inside: &scratch.inside)
            if hasOutside {
                let outside = 0..<scratch.outside.count
                result.append(scratch.outside, outside, box: Box(scratch.outside, outside))
            }
            // 内側に何も残らなければ、残りは全部取り終えた
            guard hasInside else { return .overlapping }
            swap(&scratch.rest, &scratch.inside)
            previous = point
        }
        // 残った `rest` は片の内側なので捨てる
        return .overlapping
    }

    /// 2 つの凸多角形の接し方。
    private enum Contact {
        /// 離れている
        case apart
        /// 重ならないが、縁が同じ直線の上で接しうる (T 字の継ぎ目の相手に数える)
        case touching
        /// 重なる
        case overlapping
    }

    /// `points[range]` がどれも、`polygon[edges]` のある辺の外側 (か辺の上) にあるか。
    ///
    /// 外側にあれば、いちばん近い点が辺の直線から `tolerance` 以内かで、接しうるか
    /// (`touching`) 離れているか (`apart`) を返す。どの辺でも分けられなければ `nil`。
    private static func separation(
        _ points: [SIMD2<Float>], _ range: Range<Int>, by polygon: [SIMD2<Float>],
        _ edges: Range<Int>, tolerance: Float
    ) -> Contact? {
        var previous = polygon[edges.upperBound - 1]
        for edgeIndex in edges {
            let point = polygon[edgeIndex]
            let edge = point - previous
            let length = simd_length(edge)
            if length > 0 {
                var nearest = -Float.infinity
                for index in range {
                    let offset = points[index] - previous
                    nearest = max(nearest, (edge.x * offset.y - edge.y * offset.x) / length)
                    if nearest > tolerance { break }
                }
                if nearest <= tolerance { return nearest >= -tolerance ? .touching : .apart }
            }
            previous = point
        }
        return nil
    }

    /// 凸多角形を、`start` から `end` へ向かう直線で割る。左 (反時計回りの内側) が `inside`。
    ///
    /// 直線から `tolerance` 以内の点は両側に入れる。片側に入った点がどれも直線の上なら、その側は
    /// 面積を持たないので「無い」とする (戻り値)。
    ///
    /// **切り口の点は、直線の端点のごく近くなら端点そのものに揃える** — 残りの角が相手の角に
    /// 当たる所で、頂点を相手と共有させる (T 字の継ぎ目の手前の丸め)。軸に沿った直線の切り口は、
    /// 座標を直線の値そのものに揃える。矩形の角のように画素の中心が縁に乗る形で、丸めの
    /// ずれが漏れないようにする。
    private static func split(
        _ polygon: [SIMD2<Float>], along start: SIMD2<Float>, _ end: SIMD2<Float>, tolerance: Float,
        outside: inout [SIMD2<Float>], inside: inout [SIMD2<Float>]
    ) -> (hasOutside: Bool, hasInside: Bool) {
        outside.removeAll(keepingCapacity: true)
        inside.removeAll(keepingCapacity: true)
        let edge = end - start
        let length = simd_length(edge)
        guard length > 0 else {
            inside.append(contentsOf: polygon)
            return (false, true)
        }
        let weld = tolerance * 4
        var hasOutside = false
        var hasInside = false
        var previous = polygon[polygon.count - 1]
        let firstOffset = previous - start
        var previousDistance = (edge.x * firstOffset.y - edge.y * firstOffset.x) / length
        for point in polygon {
            let offset = point - start
            let pointDistance = (edge.x * offset.y - edge.y * offset.x) / length
            if (previousDistance > tolerance && pointDistance < -tolerance)
                || (previousDistance < -tolerance && pointDistance > tolerance)
            {
                let t = previousDistance / (previousDistance - pointDistance)
                var crossing = previous + (point - previous) * t
                if start.x == end.x { crossing.x = start.x }
                if start.y == end.y { crossing.y = start.y }
                if simd_distance(crossing, start) <= weld {
                    crossing = start
                } else if simd_distance(crossing, end) <= weld {
                    crossing = end
                }
                outside.append(crossing)
                inside.append(crossing)
            }
            if pointDistance >= -tolerance { inside.append(point) }
            if pointDistance <= tolerance { outside.append(point) }
            if pointDistance > tolerance { hasInside = true }
            if pointDistance < -tolerance { hasOutside = true }
            previous = point
            previousDistance = pointDistance
        }
        return (hasOutside && outside.count >= 3, hasInside && inside.count >= 3)
    }
}
