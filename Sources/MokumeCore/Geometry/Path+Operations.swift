// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

nonisolated extension Path {
    /// 道どうしの和。重なる所の輪郭を消して、1 つの形の輪郭だけを残す。
    ///
    /// ``contains(_:)`` と同じ規則 (全部の部分道を 1 つの形とみなし、回り数が 0 でない所を内側とする) で内側を決める。
    /// 向きの逆な道どうしでも、重なりが抜けない。空の配列は空の道を返す。**1 つだけの配列も、重なる部分道を 1 つの形に
    /// まとめ直して返す** (`createPath { }` で重なった円を 1 つの道に入れても、重なりの内側に輪郭が残らない。開いた
    /// 部分道は閉じ、面を持たない部分道は落ちる)。3 つ以上は、前から 2 つずつ畳み込む (`(a ∪ b) ∪ c`)。**並べる順で
    /// 点列は変わりうる**が、内側は変わらない。
    ///
    /// 1 つだけの配列を通すと、始点と回る向きは CoreGraphics の出力で決まり、``point(at:)`` の答えが動きうる (内側と
    /// ``length`` は変わらない)。**数でない座標を含む部分道は演算の入力から落ちる** (その部分道の内側は結果に入らない。
    /// ``contains(_:)`` は有限の点だけで数えるので、そういう入力では内外が結果とずれる)。
    ///
    /// **結果は CoreGraphics が計算する。** 同じ機械・同じ OS の版なら点が一致し、OS の更新で動きうる。結果の部分道
    /// (外周と穴) は、``SketchPart/shape(_:_:_:)-(Path,_,_)`` が線を部分道ごとに引き、まとめて 1 つの図形として混ぜる。入力の頂点の近く (座標の丸めの
    /// 範囲) に戻ってきた点は、曲線が刻んだ点かどうかを引き継ぎ、近くに角があればその点は角になる (折れ目の形を置く
    /// 側に倒す)。交点など新しくできた点は角として扱う。座標の大きさに比べて頂点の間隔が極端に細かい入力 (半径 1 の円が
    /// 座標 1e6 にある、など) では、近さの範囲が頂点の間隔を越えるので、交点も刻みの点になる。
    ///
    /// SwiftUI を import したファイルでは、`mokume.Path` と書く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(18, 20, 26)
    ///     noFill()
    ///     stroke(240)
    ///     strokeWeight(2)
    ///     let a = Path(Circle(center: [170, 150], radius: 50))
    ///     let b = Path(Circle(center: [230, 150], radius: 50))
    ///     shape(Path.union([a, b]))   // 重なりの内側に輪郭が残らない
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 濃い下地に、2 つの円を合わせた 1 本の白い輪郭。重なりの内側に線は無い -->
    ///     ![濃い下地に、2 つの円を合わせた 1 本の白い輪郭。重なりの内側に線は無い](https://i.gyazo.com/dd442c004eb1b0ac2dcfc7ca45a729cd.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=adf96ed0 image=6a160a547b9135f7
    public static func union(_ paths: [Path]) -> Path {
        guard let first = paths.first else { return Path() }
        // 2 つ以上なら、先頭を単独で通さずに a ∪ b から畳み込む (単独で通すのは 1 つだけのとき)
        guard paths.count > 1 else { return first.operated(with: Path(), .union) }
        var result = first
        for next in paths.dropFirst() { result = result.operated(with: next, .union) }
        return result
    }

    /// この道から `other` の内側を引いた道。
    ///
    /// 内側の決め方と結果の性質は ``Path/union(_:)`` と同じ。`other` が空の道でも、重なる部分道を 1 つの形にまとめ直して返す (``Path/union(_:)`` の 1 つだけの配列と同じ)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(18, 20, 26)
    ///     noStroke()
    ///     fill(240)
    ///     let a = Path(Circle(center: [170, 150], radius: 50))
    ///     let b = Path(Circle(center: [230, 150], radius: 50))
    ///     shape(a.subtracting(b))   // 左の円の、右の円に重なる所が欠ける
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 濃い下地に、右側が円形に欠けた白い三日月 -->
    ///     ![濃い下地に、右側が円形に欠けた白い三日月](https://i.gyazo.com/8f732b6b93ebce2026d91fa2ee4e7132.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=3bf55c6b image=270e70ceae50383a
    public func subtracting(_ other: Path) -> Path {
        operated(with: other, .subtracting)
    }

    /// この道と `other` の内側が重なる所だけの道。どちらかが空の道なら、空の道を返す。
    ///
    /// 内側の決め方と結果の性質は ``Path/union(_:)`` と同じ。重なりが無ければ空の道になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(18, 20, 26)
    ///     noStroke()
    ///     fill(240)
    ///     let a = Path(Circle(center: [170, 150], radius: 50))
    ///     let b = Path(Circle(center: [230, 150], radius: 50))
    ///     shape(a.intersection(b))   // 2 つの円の重なりだけが残る
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 濃い下地に、2 つの円の重なりの形をした白いレンズ -->
    ///     ![濃い下地に、2 つの円の重なりの形をした白いレンズ](https://i.gyazo.com/69d648335720cd0020bef37903573b68.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=49cc6ded image=ca15084855ae5bdd
    public func intersection(_ other: Path) -> Path {
        operated(with: other, .intersection)
    }

    /// 道を `distance` だけ太らせた道。負なら内側へ縮めた道。**角は丸める。**
    ///
    /// 太らせた道の輪郭は、元の輪郭から `distance` 離れた所を通る。正なら、元の形の全部の点に半径 `distance` の円板を
    /// 重ねた形 (円板との和) で、尖った角の外側は半径 `distance` の弧になる (角を尖らせて延ばす形は無い — 細い角で
    /// 線が長く突き出すため)。負なら、輪郭から `-distance` 以内の所を削った形で、元の形より細い所は消える。半径 50 の
    /// 円を `offset(by: -50)` 以下にすると、空の道になる。
    ///
    /// 内側の決め方は ``contains(_:)`` と同じで、**開いた部分道も閉じた形として扱う** (線の道を太らせる口ではない)。
    /// 結果の性質 (CoreGraphics が計算する・点が 3 つに満たない部分道と数でない座標の部分道は落ちる) は
    /// ``Path/union(_:)`` と同じ。丸めた弧は隔たり 0.02 以下の折れ線に刻み、刻みの印を付ける。
    ///
    /// 輪郭を破線にするなら、道は割らずに ``SketchPart/strokeDash(_:_:)`` を指定して ``SketchPart/shape(_:_:_:)-(Path,_,_)``
    /// で引く。
    ///
    /// - `offset(by: 0)` は自分をそのまま返す
    /// - 数でない値・無限の値を渡すと、自分をそのまま返す (太らせ方が定まらない。落とさない)
    /// - 空の道は空の道を返す
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(18, 20, 26)
    ///     noFill()
    ///     let a = Path(Circle(center: [170, 150], radius: 50))
    ///     let b = Path(Circle(center: [230, 150], radius: 50))
    ///     let lens = a.intersection(b)
    ///     stroke(240)
    ///     strokeWeight(2)
    ///     shape(lens)
    ///     stroke(255, 160, 60)
    ///     strokeDash(10, 6)
    ///     shape(lens.offset(by: 14))   // 角は丸く太り、破線は strokeDash で引く
    ///     noStrokeDash()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 濃い下地に白いレンズの輪郭があり、その外側を、角を丸めた橙の破線の輪郭が 14 離れて囲んでいる -->
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 後で撮る
    public func offset(by distance: some ScalarConvertible) -> Path {
        let distance = Double(distance.asFloat)
        guard distance.isFinite, distance != 0 else { return self }
        if subpaths.isEmpty { return Path() }
        // 輪郭を太さ 2|d|・丸い折れ目で線にした形。閉じた部分道だけを線にするので、端の形は出ない
        let band = Path(
            cgPath: cgPath().copy(
                strokingWithWidth: 2 * abs(distance), lineCap: .round, lineJoin: .round, miterLimit: 10),
            inputs: [])
        // 線の輪郭は、交わって折れる所を除けば滑らか (辺をずらした線と折れ目の弧が接して続く)。だから全部の点を刻みとし、
        // 和・差で交わって新しくできた点だけが角になる (`StepTable` は表に無い点を角とする)
        let smooth = Path(
            subpaths: band.subpaths.map {
                Subpath(points: $0.points, isClosed: $0.isClosed, isCurveStep: Array(repeating: true, count: $0.points.count))
            })
        return distance > 0 ? operated(with: smooth, .union) : operated(with: smooth, .subtracting)
    }

    /// この道を線とみなし、`shape` の内側にある部分だけを残した道。ペンプロッタ風の斜線を形の中だけに引くのに使う。
    ///
    /// 自分の部分道は**線**として読む。開いた部分道は閉じず (2 点の線分も線)、閉じた部分道は閉じる辺も線に含める。
    /// `shape` の内側は ``contains(_:)`` と同じ数え方 (全部の部分道を 1 つの形とみなし、回り数が 0 でない所。開いた
    /// 部分道も閉じた形として扱う) で決める。線を縁で区切った区間ごとに、その中点を Float に丸めずに問う。結果は、
    /// 内側に残った片の並びで、**片は開いた部分道**になる。片の端点は `shape` の縁の上に乗り、片の点は元の向きのまま
    /// 並ぶ。閉じた部分道の始点が内側にあっても、始点の前後で 2 片に割れず 1 片で返る。**全部が内側にある閉じた部分道は、
    /// 閉じたまま**返る (長さは元と同じ)。
    ///
    /// 片は、部分道の順に、部分道の中では**片が始まる位置 (外から内へ入った点) が元の道を辿って先に来る順**に並ぶ。
    /// 始点の前後を繋いだ片は、終わり近くで入った点から始まるので、その部分道の片の最後に来る。
    ///
    /// - `shape` の縁に接するだけの線 (長さ 0 の片) は残さない
    /// - **縁にちょうど乗る線**は、``contains(_:)`` が縁の上の点に返す答えのとおりに残ったり消えたりする。四角の縁なら、
    ///   x の小さい側の縦の辺と y の小さい側の横の辺に乗る線は残り、反対側の 2 辺に乗る線は消える (四角の向きに依らない)。
    ///   だから `square.clipped(to: square)` は四角の線ではなく、残る 2 辺を繋いだ開いた L 字の 1 片になり、内側に
    ///   置いた閉じた形が縁と 1 辺を共有すると、その辺が消えて閉じなくなる。**縁に乗せたい線は、少し内側へ寄せてから
    ///   切る** (四角 (0, 0)–(100, 100) の縁なら、0.5 内側の (0.5, 0.5)–(99.5, 99.5) の四角を切る)
    /// - 全部が外側にある線と、空の `shape` は、空の道を返す。自分の部分道のうち、点が 2 つに満たないものと数でない
    ///   座標を持つものは、線にならないので入れない。`shape` の部分道のうち、点が 3 つに満たないもの (面を持たない) と
    ///   数でない座標を持つものは落ちる (``Path/union(_:)`` と同じ)。`shape` が有限の点だけなら、内側は
    ///   ``contains(_:)`` と同じ
    /// - **線として使うなら ``SketchPart/noFill()`` を指定してから** ``SketchPart/shape(_:_:_:)-(Path,_,_)`` で描く。
    ///   塗りを指定したまま描くと、3 点以上の片は (開いた片も) 閉じた形として塗られ、全部が内側にあって閉じたまま
    ///   返った部分道はその内側が全部塗られる (``contains(_:)`` と同じく、開いた部分道を閉じた形として塗るため)
    /// - 計算は本体の中で行い、OS に依らない。元の頂点は曲線が刻んだ点かどうかを引き継ぎ、縁で切ってできた端点は
    ///   角になる。手間は自分の辺の数と `shape` の辺の数の積に比例する (`shape` を囲む矩形から離れた辺は先に弾く)。
    ///   同じ線と形を毎フレーム切るなら、結果を持っておいて使い回す
    ///
    /// 円の和でできた雲の中だけに斜線を引き、外側に破線の縁を回す例。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     let cloud = Path.union((0..<6).map { i in
    ///         Path(Circle(center: [200 + Float(i) * 60, 300 + 30 * sin(Float(i) + time)], radius: 70))
    ///     })
    ///     background(18, 20, 26)
    ///     noFill()
    ///     stroke(240)
    ///     strokeWeight(2)
    ///     shape(cloud)                                   // 重なりの内側の線が消える
    ///     let hatch = createPath {
    ///         for x in stride(from: Float(-400), to: 1200, by: 8) {
    ///             beginShape(); vertex(x, 0); vertex(x + 400, 600); endShape()
    ///         }
    ///     }
    ///     stroke(240, 120)
    ///     shape(hatch.clipped(to: cloud))                // 斜線を雲の中だけに
    ///     stroke(255, 160, 60)
    ///     strokeDash(10, 6)
    ///     shape(cloud.offset(by: 14))                    // 外側に破線の縁 (strokeDash で引く)
    ///     noStrokeDash()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 濃い下地に、6 つの円を合わせた雲の白い輪郭が 1 本あり、内側だけに斜線が引かれ、外側を橙の破線の縁が囲んでいる | size=800x600 -->
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 後で撮る
    public func clipped(to shape: Path) -> Path {
        // CoreGraphics の `lineIntersection` は使わない。開いた折れ線 (点 3 つ以上) で最後の辺を落とし、外側の片を
        // 返すことがある (macOS 27.0.1 で確かめた)
        let region = ClipRegion(shape)
        guard !region.edges.isEmpty else { return Path() }
        var result: [Subpath] = []
        for subpath in subpaths where subpath.points.count >= 2 {
            guard subpath.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
            result += Self.clip(subpath, to: region)
        }
        return Path(subpaths: result)
    }

    /// ``clipped(to:)`` の相手。閉じた辺の並びとして持つ。
    private struct ClipRegion {
        /// 点が 3 つ以上で、全部が有限の部分道。
        var subpaths: [Subpath] = []
        /// `subpaths` の辺 (閉じる辺を含む)。
        var edges: [(from: SIMD2<Double>, to: SIMD2<Double>)] = []
        /// 全部の辺を囲む矩形。この外 (縁を含まない) の点は回り数が 0 で、この外にある線は辺と交わらない。
        var low = SIMD2<Double>(repeating: .infinity)
        var high = SIMD2<Double>(repeating: -.infinity)

        init(_ path: Path) {
            for subpath in path.subpaths where subpath.points.count >= 3 {
                guard subpath.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
                subpaths.append(subpath)
                let points = subpath.points.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
                var previous = points[points.count - 1]
                for current in points {
                    edges.append((previous, current))
                    low = pointwiseMin(low, current)
                    high = pointwiseMax(high, current)
                    previous = current
                }
            }
        }

        /// `low`…`high` の矩形が、相手を囲む矩形と離れている (縁で触れるだけなら離れていない)。
        func isApart(low: SIMD2<Double>, high: SIMD2<Double>) -> Bool {
            high.x < self.low.x || low.x > self.high.x || high.y < self.low.y || low.y > self.high.y
        }

        private static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }

        /// 線分 `from`→`to` が辺を横切る所の、線分の上の位置 (0 < t < 1) を `found` に足す。平行な辺は数えない。
        func crossings(from: SIMD2<Double>, to: SIMD2<Double>, into found: inout [Double]) {
            let direction = to - from
            let low = pointwiseMin(from, to)
            let high = pointwiseMax(from, to)
            for edge in edges {
                guard max(edge.from.x, edge.to.x) >= low.x, min(edge.from.x, edge.to.x) <= high.x,
                    max(edge.from.y, edge.to.y) >= low.y, min(edge.from.y, edge.to.y) <= high.y
                else { continue }
                let side = edge.to - edge.from
                let denominator = Self.cross(direction, side)
                guard denominator != 0 else { continue }
                let offset = edge.from - from
                let t = Self.cross(offset, side) / denominator
                let u = Self.cross(offset, direction) / denominator
                if t > 0, t < 1, u >= 0, u <= 1 { found.append(t) }
            }
        }

        /// ``Path/contains(_:)`` と同じ数え方の回り数 (``Path/winding(at:in:)``)。
        func winding(_ point: SIMD2<Double>) -> Int {
            if isApart(low: point, high: point) { return 0 }
            return Path.winding(at: point, in: subpaths)
        }
    }

    /// 部分道 1 つを切った片。
    struct ClipPiece: Equatable {
        var points: [SIMD2<Float>]
        var isCurveStep: [Bool]
    }

    /// 閉じた部分道の始点が内側にあるとき、始点の前で終わる最後の片と、始点から始まる最初の片を 1 片に繋ぐ。
    ///
    /// 片は 1 つの部分道から出たものだけを渡す (別の部分道の片を繋がない)。開いた部分道、始点か終わりが外側の
    /// 部分道、片が 1 つしか無い部分道は、そのまま返す。繋いだ片は最後に置く (始点より後の弧長から始まるため)。
    static func joinedAcrossStart(
        _ pieces: [ClipPiece], isClosed: Bool, startsInside: Bool, endsInside: Bool
    ) -> [ClipPiece] {
        guard isClosed, startsInside, endsInside, pieces.count >= 2, let first = pieces.first, let last = pieces.last
        else { return pieces }
        let joined = ClipPiece(
            points: last.points + first.points.dropFirst(), isCurveStep: last.isCurveStep + first.isCurveStep.dropFirst())
        return Array(pieces.dropFirst().dropLast()) + [joined]
    }

    /// 部分道 1 つを、辺ごとに相手の縁で区切り、区間の中点が内側の区間だけを残す。
    private static func clip(_ subpath: Subpath, to region: ClipRegion) -> [Subpath] {
        let points = subpath.points
        let marks = subpath.isCurveStep
        let count = points.count
        // 相手を囲む矩形から離れた部分道は、全部が外側
        let low = points.reduce(SIMD2<Float>(repeating: .infinity)) { pointwiseMin($0, $1) }
        let high = points.reduce(SIMD2<Float>(repeating: -.infinity)) { pointwiseMax($0, $1) }
        if region.isApart(low: SIMD2<Double>(low), high: SIMD2<Double>(high)) { return [] }
        var pieces: [ClipPiece] = []
        var current: ClipPiece?
        var startsInside: Bool?
        var endsInside = false
        var anyOutside = false
        // 辺ごとの区切りの位置。辺ごとに作り直さず使い回す
        var cuts: [Double] = []
        for index in 0..<(subpath.isClosed ? count : count - 1) {
            let next = (index + 1) % count
            let from = SIMD2<Double>(Double(points[index].x), Double(points[index].y))
            let to = SIMD2<Double>(Double(points[next].x), Double(points[next].y))
            guard from != to else { continue }
            cuts.removeAll(keepingCapacity: true)
            cuts.append(0)
            // 相手を囲む矩形から離れた辺は、区切らずに 1 区間とする (中点も矩形の外なので、回り数を数えずに外になる)
            if !region.isApart(low: pointwiseMin(from, to), high: pointwiseMax(from, to)) {
                region.crossings(from: from, to: to, into: &cuts)
                cuts[1...].sort()
            }
            cuts.append(1)
            for step in 0..<(cuts.count - 1) {
                let (t0, t1) = (cuts[step], cuts[step + 1])
                guard t1 > t0 else { continue }
                let inside = region.winding(from + (to - from) * ((t0 + t1) / 2)) != 0
                if startsInside == nil { startsInside = inside }
                endsInside = inside
                if inside {
                    if current == nil {
                        current =
                            t0 == 0
                            ? ClipPiece(points: [points[index]], isCurveStep: [marks[index]])
                            : ClipPiece(points: [Self.float(from + (to - from) * t0)], isCurveStep: [false])
                    }
                    // 内側の区間が続く間は、縁を横切った点 (回り数が 0 でないまま変わる所) を置かない
                    if t1 == 1 {
                        current?.points.append(points[next])
                        current?.isCurveStep.append(marks[next])
                    }
                } else {
                    anyOutside = true
                    if var piece = current {
                        if t0 > 0 {
                            piece.points.append(Self.float(from + (to - from) * t0))
                            piece.isCurveStep.append(false)
                        }
                        pieces.append(piece)
                    }
                    current = nil
                }
            }
        }
        if let piece = current { pieces.append(piece) }
        // 全部が内側の閉じた部分道は、閉じたまま返す
        if subpath.isClosed, !anyOutside, startsInside == true { return [subpath] }
        return joinedAcrossStart(
            pieces, isClosed: subpath.isClosed, startsInside: startsInside ?? false, endsInside: endsInside
        )
        .filter { piece in piece.points.contains { $0 != piece.points[0] } }  // 長さ 0 の片は残さない
        .map { Subpath(points: $0.points, isClosed: false, isCurveStep: $0.isCurveStep) }
    }

    private static func float(_ point: SIMD2<Double>) -> SIMD2<Float> {
        SIMD2<Float>(Float(point.x), Float(point.y))
    }

    private enum Operation {
        case union, subtracting, intersection
    }

    /// 演算の本体。**空の道との組でも CoreGraphics を通す**ので、重なる部分道は 1 つの形にまとまり、開いた部分道は閉じ、
    /// 面を持たない部分道は落ちる。
    private func operated(with other: Path, _ operation: Operation) -> Path {
        switch operation {
        case .union: if subpaths.isEmpty && other.subpaths.isEmpty { return Path() }
        case .subtracting: if subpaths.isEmpty { return Path() }
        case .intersection: if subpaths.isEmpty || other.subpaths.isEmpty { return Path() }
        }
        let lhs = cgPath()
        let rhs = other.cgPath()
        let result: CGPath
        switch operation {
        case .union: result = lhs.union(rhs, using: .winding)
        case .subtracting: result = lhs.subtracting(rhs, using: .winding)
        case .intersection: result = lhs.intersection(rhs, using: .winding)
        }
        return Path(cgPath: result, inputs: [self, other])
    }

    /// 閉じた部分道の `CGPath` にする。開いた部分道も閉じた形として扱う。3 点に満たない部分道と、数でない座標を持つ
    /// 部分道は、面を持たない (または座標が定まらない) ので入れない。
    private func cgPath() -> CGPath {
        let path = CGMutablePath()
        for subpath in subpaths where subpath.points.count >= 3 {
            guard subpath.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
            path.addLines(between: subpath.points.map { CGPoint(x: Double($0.x), y: Double($0.y)) })
            path.closeSubpath()
        }
        return path
    }

    /// 入力の頂点が持つ刻みの印を、座標の近さで引く表。
    ///
    /// CoreGraphics が入力の座標をそのまま返す版でなくても (座標を計算し直す版でも) 印を引き継げるよう、完全な一致ではなく
    /// 許容つきで探す。**許容は引く点自身の大きさで決める** (`座標の大きさ × 2⁻²⁰ + 1e-7`。Float の丸め幅の 16 倍ほどで、
    /// Float で持った座標が Double の計算を往復したときの丸めを越える)。入力全体の最大の座標では決めないので、遠い形が
    /// 1 つ混ざっても、手前の交点の許容は広がらない。**許容の内に入力の頂点が複数あれば、全部が刻みのときだけ刻みとし、
    /// 1 つでも角なら角とする** (折れ目の形を置く側に倒す)。許容の内に無ければ新しくできた点 (交点) なので角である。
    ///
    /// 限界: Float の精度そのものが頂点の間隔より粗い入力 (半径 1 の円が座標 1e6 にある、など。許容が頂点の間隔を越える)
    /// では、交点も近くの刻みの頂点に当たって刻みになる。
    private struct StepTable {
        /// x の昇順。
        private var points: [(x: Double, y: Double, isStep: Bool)] = []

        init(_ paths: [Path]) {
            for path in paths {
                for subpath in path.subpaths {
                    for (point, isStep) in zip(subpath.points, subpath.isCurveStep)
                    where point.x.isFinite && point.y.isFinite {
                        points.append((Double(point.x), Double(point.y), isStep))
                    }
                }
            }
            points.sort { $0.x < $1.x }
        }

        private static func tolerance(_ point: SIMD2<Double>) -> Double {
            max(abs(point.x), abs(point.y)) * 0x1p-20 + 1e-7
        }

        func isStep(_ point: SIMD2<Double>) -> Bool {
            let tolerance = Self.tolerance(point)
            // x が [point.x - tolerance, ...] に入る最初の位置を二分探索で探す
            var low = 0
            var high = points.count
            while low < high {
                let middle = (low + high) / 2
                if points[middle].x < point.x - tolerance { low = middle + 1 } else { high = middle }
            }
            var found = false
            var index = low
            while index < points.count, points[index].x <= point.x + tolerance {
                let candidate = points[index]
                let dx = candidate.x - point.x
                let dy = candidate.y - point.y
                if (dx * dx + dy * dy).squareRoot() <= tolerance {
                    if !candidate.isStep { return false }
                    found = true
                }
                index += 1
            }
            return found
        }
    }

    /// 曲線を刻むときの、折れ線と曲線の隔たりの上限。``init(_:)-(Circle)`` と同じ 0.02。
    private static let curveTolerance = 0.02

    /// 3 次の曲線を直線の並びへ割る。始点は含めず、終点を含める。
    ///
    /// 割る数は、2 階差分の大きさから隔たりが ``curveTolerance`` を越えない数を出す (上限 2048)。
    /// ``Canvas`` の字の輪郭の刻みと共有しないのは、あちらが字の大きさ向けに割る数を 24 までに絞った private の関数で、
    /// 絶対の隔たりで刻む道には粗すぎるため。
    private static func flatten(
        from p0: SIMD2<Double>, _ c1: SIMD2<Double>, _ c2: SIMD2<Double>, to p3: SIMD2<Double>
    ) -> [SIMD2<Double>] {
        func length(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
        let bend = max(length(p0 - 2 * c1 + c2), length(c1 - 2 * c2 + p3))
        let wanted = (0.75 * bend / curveTolerance).squareRoot().rounded(.up)
        let steps = wanted.isFinite ? Int(min(2048, max(1, wanted))) : 1
        var points: [SIMD2<Double>] = []
        points.reserveCapacity(steps)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let u = 1 - t
            points.append(u * u * u * p0 + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * p3)
        }
        return points
    }

    /// `CGPath` の演算結果を、閉じた部分道の並びへほどく。`inputs` は、刻みの印を引き継ぐ元の道。
    ///
    /// - 直線の要素はそのまま置く。折れ線どうしの演算の結果は直線だけになるが (円・四角・多角形で確かめた)、曲線の
    ///   要素が来ても形を落とさず、``flatten(from:_:_:to:)`` で刻む。**曲線を刻んだ途中の点は刻みの印を付ける**
    ///   (曲線の端点は入力との照合のまま)
    /// - 始点へ戻る終点は落とす (閉じる辺が長さ 0 になるのを避ける)
    /// - 閉じた後に `moveTo` を挟まず線が来たら、CoreGraphics の規則どおり、閉じた部分道の始点から続ける
    /// - 点が 3 つに満たない部分道と、Float に収まらない座標を持つ部分道は入れない (入力側と同じ扱い)
    init(cgPath: CGPath, inputs: [Path]) {
        let table = StepTable(inputs)
        var subpaths: [Subpath] = []
        var current: [SIMD2<Double>] = []
        /// 点ごとに、曲線を刻んだ途中の点か。
        var forced: [Bool] = []
        func finish() {
            defer {
                current = []
                forced = []
            }
            var points = current.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
            while points.count > 1, points.last == points.first {
                points.removeLast()
                forced.removeLast()
            }
            guard points.count >= 3 else { return }
            let steps = points.indices.map { index in
                forced[index] || table.isStep(SIMD2<Double>(Double(points[index].x), Double(points[index].y)))
            }
            subpaths.append(Subpath(points: points, isClosed: true, isCurveStep: steps))
        }
        func point(_ p: CGPoint) -> SIMD2<Double> { SIMD2(Double(p.x), Double(p.y)) }
        func append(_ points: [SIMD2<Double>]) {
            // 最後の 1 点 (曲線の端点) だけが照合に任せる点で、途中は刻みの点
            for (index, item) in points.enumerated() {
                current.append(item)
                forced.append(index < points.count - 1)
            }
        }
        cgPath.applyWithBlock { element in
            let item = element.pointee
            switch item.type {
            case .moveToPoint:
                finish()
                current = [point(item.points[0])]
                forced = [false]
            case .addLineToPoint:
                current.append(point(item.points[0]))
                forced.append(false)
            case .addQuadCurveToPoint:
                guard let from = current.last else { break }
                let control = point(item.points[0])
                let to = point(item.points[1])
                // 2 次は 3 次に読み替えられる
                append(
                    Self.flatten(
                        from: from, from + (control - from) * (2.0 / 3.0), to + (control - to) * (2.0 / 3.0), to: to))
            case .addCurveToPoint:
                guard let from = current.last else { break }
                append(Self.flatten(from: from, point(item.points[0]), point(item.points[1]), to: point(item.points[2])))
            case .closeSubpath:
                let start = current.first
                finish()
                // 閉じた後の線は、閉じた部分道の始点から続く
                if let start {
                    current = [start]
                    forced = [false]
                }
            @unknown default:
                break
            }
        }
        finish()
        self.init(subpaths: subpaths)
    }
}
