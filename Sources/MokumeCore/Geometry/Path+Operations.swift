// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

nonisolated extension Path {
    /// 道どうしの和。重なる所の輪郭を消して、1 つの形の輪郭だけを残す。
    ///
    /// ``contains(_:)`` と同じ規則 (全部の部分道を 1 つの形とみなし、回り数が 0 でない所を内側とする) で内側を決める。
    /// 向きの逆な道どうしでも、重なりが抜けない。空の配列は空の道を返し、1 つだけの配列はその道をそのまま返す。
    /// 3 つ以上は、前から 2 つずつ畳み込む (`(a ∪ b) ∪ c`)。
    ///
    /// **結果は CoreGraphics が計算する。** 同じ機械・同じ OS の版なら点が一致し、OS の更新で動きうる。結果の部分道
    /// (外周と穴) は、``SketchPart/shape(_:_:_:)-(Path,_,_)`` が線を部分道ごとに引く。入力の頂点と同じ座標に戻ってきた
    /// 点は、曲線が刻んだ点かどうかを引き継ぐ。交点など新しくできた点は角として扱う。
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
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 後で撮る
    public static func union(_ paths: [Path]) -> Path {
        guard var result = paths.first else { return Path() }
        for next in paths.dropFirst() { result = result.operated(with: next, .union) }
        return result
    }

    /// この道から `other` の内側を引いた道。
    ///
    /// 内側の決め方と結果の性質は ``Path/union(_:)`` と同じ。`other` が空の道ならこの道をそのまま返す。
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
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 後で撮る
    public func subtracting(_ other: Path) -> Path {
        guard !subpaths.isEmpty, !other.subpaths.isEmpty else { return self }
        return operated(with: other, .subtracting)
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
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 後で撮る
    public func intersection(_ other: Path) -> Path {
        guard !subpaths.isEmpty, !other.subpaths.isEmpty else { return Path() }
        return operated(with: other, .intersection)
    }

    private enum Operation {
        case union, subtracting, intersection
    }

    private func operated(with other: Path, _ operation: Operation) -> Path {
        if subpaths.isEmpty { return operation == .union ? other : Path() }
        if other.subpaths.isEmpty { return operation == .intersection ? Path() : self }
        let lhs = cgPath()
        let rhs = other.cgPath()
        let result: CGPath
        switch operation {
        case .union: result = lhs.union(rhs, using: .winding)
        case .subtracting: result = lhs.subtracting(rhs, using: .winding)
        case .intersection: result = lhs.intersection(rhs, using: .winding)
        }
        // 刻みの印を引き継ぐ表。同じ座標が角でもあるなら角を取る (継ぎ目の形を残す側に倒す)
        var steps: [SIMD2<Float>: Bool] = [:]
        for path in [self, other] {
            for subpath in path.subpaths {
                for (point, isStep) in zip(subpath.points, subpath.isCurveStep) {
                    steps[point] = (steps[point] ?? true) && isStep
                }
            }
        }
        return Path(cgPath: result, steps: steps)
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

    /// `CGPath` の演算結果を、閉じた部分道の並びへほどく。
    ///
    /// 折れ線どうしの演算の結果は直線の要素だけになる (円・四角・乱数の多角形で確かめた)。曲線の要素が来ても落とさず、
    /// 終点だけを置く。
    private init(cgPath: CGPath, steps: [SIMD2<Float>: Bool]) {
        var subpaths: [Subpath] = []
        var current: [SIMD2<Float>] = []
        func finish() {
            if current.count >= 3 {
                subpaths.append(
                    Subpath(points: current, isClosed: true, isCurveStep: current.map { steps[$0] ?? false }))
            }
            current = []
        }
        cgPath.applyWithBlock { element in
            let item = element.pointee
            switch item.type {
            case .moveToPoint:
                finish()
                current.append(SIMD2(Float(item.points[0].x), Float(item.points[0].y)))
            case .addLineToPoint:
                current.append(SIMD2(Float(item.points[0].x), Float(item.points[0].y)))
            case .addQuadCurveToPoint:
                current.append(SIMD2(Float(item.points[1].x), Float(item.points[1].y)))
            case .addCurveToPoint:
                current.append(SIMD2(Float(item.points[2].x), Float(item.points[2].y)))
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
