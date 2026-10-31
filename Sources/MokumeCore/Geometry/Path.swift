// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 線の道を値として持ち歩き、長さを測り、道の上の点を引き、内側かを問う。
///
/// ``SketchPart/createPath(_:)`` の中で ``SketchPart/beginShape(_:)`` から ``SketchPart/endShape(_:)`` まで
/// 並べた頂点を記録して作る。**記録するのは道の形だけ**で、色や線の太さなどの見た目は持たない。描くのは
/// ``SketchPart/shape(_:_:_:)-(Path,_,_)`` で、そのときの ``SketchPart/fill(_:)-(LinearRGBA)`` と
/// ``SketchPart/stroke(_:)-(LinearRGBA)`` に従う。値から作るなら ``init(_:)`` が円を道にする。
///
/// 道は**部分道**の並びである。`beginShape()` から `endShape()` までが 1 つ、`beginContour()` で置いた穴が
/// 1 つ、`createPath { }` の中で `beginShape()` を何度か呼べば、その数だけ部分道が増える。曲線は刻んだ折れ線で
/// 持つ。
///
/// - ``length`` と ``point(at:)`` は、部分道を並べた順に弧長で辿る。**開いた部分道は閉じる辺を数えない**
///   (`endShape(.close)` で閉じたものだけが、最後の点から最初の点へ戻る辺を数える)
/// - ``contains(_:)`` は、全部の部分道を**1 つの形**とみなし、回り数が 0 でない所を内側とする (画面で
///   `beginShape()` が塗る規則と同じ)。開いた部分道も閉じた形として扱う。穴を外周と逆回りに並べると
///   穴になり、同じ向きに並べると、そこは回り数 2 の所になって内側のままになる
///
/// 空の道 (頂点を置かなかった `createPath { }`) は、``length`` が 0、``contains(_:)`` は常に `false`、
/// ``point(at:)`` は原点を返す。読み取りで落ちることはない。
///
/// **SwiftUI の `Path` と名前が重なる。** SwiftUI を import したファイルでは、`Path` だけでは曖昧になる。
/// そのファイルでは `mokume.Path` と書く。
///
/// **隔離の外に置く** ([ADR-0010] 決定 1 の改訂)。長さを測り、点を引き、内側かを問うのは、どこからでもできる。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
public nonisolated struct Path: Sendable, Hashable {
    /// 部分道 1 つ。折れ線として持つ。
    struct Subpath: Sendable, Hashable {
        /// 頂点。形自身の座標 (``SketchPart/createPath(_:)`` の中の変換は焼き込み済み)。
        var points: [SIMD2<Float>]
        /// 最後の点から最初の点へ戻る辺を持つか。
        var isClosed: Bool
        /// 点ごとに、曲線が刻んだ点か (利用者が置いた点でなければ真)。描き直すとき、輪郭は刻みの継ぎ目に折れ目の形を
        /// 置かない。
        var isCurveStep: [Bool]

        /// 辺の始まりと終わりの点。閉じていれば最後の辺は最初の点へ戻る。
        func edges() -> [(SIMD2<Float>, SIMD2<Float>)] {
            guard points.count >= 2 else { return [] }
            var result: [(SIMD2<Float>, SIMD2<Float>)] = []
            result.reserveCapacity(points.count)
            for index in 1..<points.count { result.append((points[index - 1], points[index])) }
            if isClosed { result.append((points[points.count - 1], points[0])) }
            return result
        }
    }

    /// 部分道。記録した順。
    var subpaths: [Subpath]

    /// 空の道。
    init() { subpaths = [] }

    init(subpaths: [Subpath]) { self.subpaths = subpaths }

    /// 円を道にする。
    ///
    /// 中心から右の点を始点に、1 周する閉じた部分道 1 つになる。**円は折れ線に刻んで持つ**ので、
    /// ``length`` は円周より少し短い。刻みは、折れ線と円の隔たりが 0.02 と半径の 2000 分の 1 の小さいほう以下になる
    /// 細かさで、``length`` は円周より 0.02% (1.7×10⁻⁴) ほどしか短くならない (半径 10 なら 100 本で、
    /// 2π × 10 との差は 0.011 ほど)。半径が極端に大きく、刻みが上限の 2048 本に当たる円 (半径が 17000 ほどから先) では、
    /// 隔たりが 0.02 を越えうる。
    /// 半径が 0 以下か数でない円は、空の道になる。
    // shot: 撮れない 道を作る口で、描く結果が無い (描くのは shape(path)。作例は #3562 が持つ)
    public init(_ circle: Circle) {
        let radius = circle.radius
        let center = circle.center.simd
        guard radius > 0, radius.isFinite, center.x.isFinite, center.y.isFinite else {
            self.init()
            return
        }
        // 刻みは Double で求める。Float で `1 - 隔たり / 半径` を作ると、半径が 6.7e5 を越えたあたりで 1 に丸まり、
        // 8 角形に退化する
        let tolerance = min(0.02, Double(radius) / 2000)
        let ratio = max(-1, min(1, 1 - tolerance / Double(radius)))
        // `ratio` が 1 に丸まるのは、半径が 3.6e14 を越えて精度が尽きたとき (極めて細かく刻むべきとき) なので、
        // 倒す先は上限である
        let steps = ratio >= 1 ? 2048 : max(8, min(2048, Int((Double.pi / RuntimeMath.acos(ratio)).rounded(.up))))
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(steps)
        for step in 0..<steps {
            let angle = Float(step) / Float(steps) * 2 * Float.pi
            points.append(center + radius * SIMD2(RuntimeMath.cos(angle), RuntimeMath.sin(angle)))
        }
        self.init(subpaths: [
            Subpath(points: points, isClosed: true, isCurveStep: Array(repeating: true, count: steps))
        ])
    }

    /// 道の長さ。部分道の長さの和で、開いた部分道は閉じる辺を数えない。
    ///
    /// 空の道は 0。曲線は刻んだ折れ線の長さで測る。座標が Float に収まらないほど大きく、長さが Float を越えるときは無限に
    /// なる (``point(at:)`` は弧長を Double で辿るので、無限にならない)。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public var length: Float {
        var total: Double = 0
        for subpath in subpaths {
            for (from, to) in subpath.edges() { total += Self.distance(from, to) }
        }
        return Float(total)
    }

    /// 弧長で `t` (0…1) の所にある点。`0` が始点、`1` が終点で、部分道を並べた順に辿る。
    ///
    /// `t` が 0…1 の外なら端に締める。**数でない `t` は 0 として扱う** (始点を返す。落とさない)。空の道は原点を
    /// 返し、長さが 0 の道 (点が 1 つだけ・全部同じ所) は最初の点を返す。部分道の継ぎ目では、閉じていない部分道の
    /// 終点から次の部分道の始点へ飛ぶ — その間の辺は数えない。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public func point(at t: some ScalarConvertible) -> Vector2 {
        guard let first = subpaths.first(where: { !$0.points.isEmpty })?.points.first else { return Vector2(0, 0) }
        let given = t.asFloat
        let amount = given.isNaN ? 0 : min(max(given, 0), 1)
        // 弧長の歩みは Double のまま行う。`length` は Float に丸めるので、座標が ±3e38 級だと無限になり、
        // それで割ると始点を返してしまう
        var total: Double = 0
        for subpath in subpaths {
            for (from, to) in subpath.edges() { total += Self.distance(from, to) }
        }
        guard total > 0, total.isFinite else { return Vector2(first) }
        let target = Double(amount) * total
        var walked: Double = 0
        var last = first
        for subpath in subpaths {
            for (from, to) in subpath.edges() {
                let edge = Self.distance(from, to)
                last = to
                if edge > 0, walked + edge >= target {
                    let along = (target - walked) / edge
                    // 差も Double で取る (±3e38 の両端の差は Float に収まらない)
                    let x = Double(from.x) + (Double(to.x) - Double(from.x)) * along
                    let y = Double(from.y) + (Double(to.y) - Double(from.y)) * along
                    return Vector2(Float(x), Float(y))
                }
                walked += edge
            }
        }
        return Vector2(last)
    }

    /// `point` が道の内側にあるか。
    ///
    /// 全部の部分道を 1 つの形とみなし、回り数が 0 でない所を内側とする。開いた部分道は閉じた形として扱う。
    /// 辺の上は、どちらとも決めない。数でない点は `false`。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public func contains(_ point: Vector2) -> Bool {
        let probe = point.simd
        guard probe.x.isFinite, probe.y.isFinite else { return false }
        var winding = 0
        for subpath in subpaths {
            let points = subpath.points
            guard points.count >= 3 else { continue }
            var previous = points[points.count - 1]
            for current in points {
                // 点から右へ伸ばした半直線が、辺を上向き・下向きに横切る数で回り数を数える
                // 差と積は Double で取る (Float では座標が 1e19 級で inf - inf になり、辺を数え落とす)
                if previous.y <= probe.y {
                    if current.y > probe.y, Self.side(previous, current, probe) > 0 { winding += 1 }
                } else if current.y <= probe.y, Self.side(previous, current, probe) < 0 {
                    winding -= 1
                }
                previous = current
            }
        }
        return winding != 0
    }

    private static func distance(_ from: SIMD2<Float>, _ to: SIMD2<Float>) -> Double {
        let dx = Double(to.x) - Double(from.x)
        let dy = Double(to.y) - Double(from.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 辺 `a`→`b` の左にあれば正、右にあれば負。
    private static func side(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ p: SIMD2<Float>) -> Double {
        (Double(b.x) - Double(a.x)) * (Double(p.y) - Double(a.y))
            - (Double(p.x) - Double(a.x)) * (Double(b.y) - Double(a.y))
    }
}
