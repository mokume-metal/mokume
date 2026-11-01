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
    /// **結果は CoreGraphics が計算する。** 同じ機械・同じ OS の版なら点が一致し、OS の更新で動きうる。結果の部分道
    /// (外周と穴) は、``SketchPart/shape(_:_:_:)-(Path,_,_)`` が線を部分道ごとに引く。入力の頂点の近く (座標の丸めの
    /// 範囲) に戻ってきた点は、曲線が刻んだ点かどうかを引き継ぎ、近くに角があればその点は角になる (折れ目の形を置く
    /// 側に倒す)。交点など新しくできた点は角として扱う。
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
        var result = first.operated(with: Path(), .union)
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
    /// 許容つきで探す。許容は、絶対の 1e-3 と、座標の大きさの 2⁻²⁰ (Float の丸め幅の 16 倍ほど) の和で、Float で持った
    /// 座標が Double の計算を往復したときの丸めを越え、隣の頂点には届かない大きさである。**許容の内に入力の頂点が複数
    /// あれば、全部が刻みのときだけ刻みとし、1 つでも角なら角とする** (折れ目の形を置く側に倒す)。許容の内に無ければ
    /// 新しくできた点 (交点) なので角である。
    private struct StepTable {
        private struct Cell: Hashable {
            var x: Int
            var y: Int
        }

        private let tolerance: Double
        private var cells: [Cell: [(point: SIMD2<Double>, isStep: Bool)]] = [:]

        init(_ paths: [Path]) {
            var extent: Double = 0
            for path in paths {
                for subpath in path.subpaths {
                    for point in subpath.points where point.x.isFinite && point.y.isFinite {
                        extent = max(extent, abs(Double(point.x)), abs(Double(point.y)))
                    }
                }
            }
            tolerance = 1e-3 + extent * 0x1p-20
            for path in paths {
                for subpath in path.subpaths {
                    for (point, isStep) in zip(subpath.points, subpath.isCurveStep)
                    where point.x.isFinite && point.y.isFinite {
                        let at = SIMD2<Double>(Double(point.x), Double(point.y))
                        cells[cell(of: at), default: []].append((at, isStep))
                    }
                }
            }
        }

        private func cell(of point: SIMD2<Double>) -> Cell {
            // 桁が大きすぎて Int に収まらない座標は端に寄せる (同じ升に入るだけで、近さは距離で見直す)
            func index(_ value: Double) -> Int { Int(max(-4e18, min(4e18, (value / tolerance).rounded(.down)))) }
            return Cell(x: index(point.x), y: index(point.y))
        }

        func isStep(_ point: SIMD2<Double>) -> Bool {
            let home = cell(of: point)
            var found = false
            for dx in -1...1 {
                for dy in -1...1 {
                    guard
                        let candidates = cells[Cell(x: home.x &+ dx, y: home.y &+ dy)]
                    else { continue }
                    for candidate in candidates {
                        let gap = candidate.point - point
                        guard (gap.x * gap.x + gap.y * gap.y).squareRoot() <= tolerance else { continue }
                        if !candidate.isStep { return false }
                        found = true
                    }
                }
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
    ///   要素が来ても形を落とさず、``flatten(from:_:_:to:)`` で刻む
    /// - 始点へ戻る終点は落とす (閉じる辺が長さ 0 になるのを避ける)
    /// - 点が 3 つに満たない部分道と、Float に収まらない座標を持つ部分道は入れない (入力側と同じ扱い)
    init(cgPath: CGPath, inputs: [Path]) {
        let table = StepTable(inputs)
        var subpaths: [Subpath] = []
        var current: [SIMD2<Double>] = []
        func finish() {
            defer { current = [] }
            var points = current.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
            while points.count > 1, points.last == points.first { points.removeLast() }
            guard points.count >= 3 else { return }
            let steps = points.map { table.isStep(SIMD2<Double>(Double($0.x), Double($0.y))) }
            subpaths.append(Subpath(points: points, isClosed: true, isCurveStep: steps))
        }
        func point(_ p: CGPoint) -> SIMD2<Double> { SIMD2(Double(p.x), Double(p.y)) }
        cgPath.applyWithBlock { element in
            let item = element.pointee
            switch item.type {
            case .moveToPoint:
                finish()
                current.append(point(item.points[0]))
            case .addLineToPoint:
                current.append(point(item.points[0]))
            case .addQuadCurveToPoint:
                guard let from = current.last else { break }
                let control = point(item.points[0])
                let to = point(item.points[1])
                // 2 次は 3 次に読み替えられる
                current += Self.flatten(
                    from: from, from + (control - from) * (2.0 / 3.0), to + (control - to) * (2.0 / 3.0), to: to)
            case .addCurveToPoint:
                guard let from = current.last else { break }
                current += Self.flatten(
                    from: from, point(item.points[0]), point(item.points[1]), to: point(item.points[2]))
            case .closeSubpath:
                finish()
            @unknown default:
                break
            }
        }
        finish()
        self.init(subpaths: subpaths)
    }
}
