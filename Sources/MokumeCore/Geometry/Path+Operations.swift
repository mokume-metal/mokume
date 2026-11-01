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
    /// (外周と穴) は、``SketchPart/shape(_:_:_:)-(Path,_,_)`` が線を部分道ごとに引く。入力の頂点の近く (座標の丸めの
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
