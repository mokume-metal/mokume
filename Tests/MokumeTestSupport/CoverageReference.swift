// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// **塗りの縁の被覆を、CPU で解析的に出す参照** (#3207 の提案 2・#3217)。
///
/// 本体に CPU のラスタライザは無く、被覆は GPU のシェーダが距離関数で出す (`mokume_pixelCdf`)。
/// 台帳 (`SceneLedgerTests`) は絵が動いたかしか見ないので、**絵が正しいか**を判定する物差しを
/// ここに置く。遅くても明らかに正しい式だけで書き、本体のシェーダの式は写さない (写すと同じ誤りを
/// 見逃す) — ただし ``halfPlaneArea(_:_:)`` は、縁を直線とみなした被覆の式 (`mokume_pixelCdf` の写し) を
/// 期待値に使う検査 (`PixelGridTests.arcBandEdgeError`) のために、そのままの形で持つ。
///
/// ## 座標
///
/// 画素 (x, y) は正方形 [x, x+1] × [y, y+1]。塗りの縁は整数の座標で画素の境目に乗る
/// (ADR-0039 決定 2) ので、`rect(10.5, 10.25, 20, 30)` の頂点をそのまま渡せば、画素 (10, 20) は 0.5 になる。
/// **線・輪郭・点は画面で +0.5 画素寄せる**ので、参照へ渡す前に同じだけ寄せること (塗りは寄せない)。
///
/// ## 約束の表
///
/// どの量を比べてよいかは経路ごとに違う (ADR-0039 決定 1〜3)。``CoverageTable`` が行ごとに持ち、
/// 表の外の組は比べない (拒んで名乗る)。
public nonisolated enum CoverageReference {
    // MARK: - 凸多角形

    /// 凸多角形と画素 (x, y) の正方形の重なりの面積 (厳密)。頂点の巻き方向は問わない。
    ///
    /// 画素の正方形の 4 辺で順に切り取り (Sutherland–Hodgman)、残った多角形の面積を靴紐の公式で出す。
    public static func polygonArea(_ polygon: [SIMD2<Double>], pixel x: Int, _ y: Int) -> Double {
        let (x0, y0) = (Double(x), Double(y))
        var points = polygon
        points = clip(points) { $0.x - x0 }
        points = clip(points) { x0 + 1 - $0.x }
        points = clip(points) { $0.y - y0 }
        points = clip(points) { y0 + 1 - $0.y }
        guard points.count >= 3 else { return 0 }
        var twice = 0.0
        for index in points.indices {
            let (a, b) = (points[index], points[(index + 1) % points.count])
            twice += a.x * b.y - b.x * a.y
        }
        return abs(twice) / 2
    }

    /// `inside` が 0 以上の側を残す。
    private static func clip(_ points: [SIMD2<Double>], inside: (SIMD2<Double>) -> Double) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = []
        for index in points.indices {
            let (a, b) = (points[index], points[(index + 1) % points.count])
            let (da, db) = (inside(a), inside(b))
            if da >= 0 { out.append(a) }
            if (da >= 0) != (db >= 0) {
                out.append(a + (b - a) * (da / (da - db)))
            }
        }
        return out
    }

    /// 中心 `center`・半幅 `half` の長方形を `angle` (ラジアン・`rotate` と同じ向き) だけ回した 4 頂点。
    public static func rotatedRect(
        center: SIMD2<Double>, half: SIMD2<Double>, angle: Double
    ) -> [SIMD2<Double>] {
        let (c, s) = (cos(angle), sin(angle))
        return [SIMD2(-1.0, -1.0), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)].map { corner in
            let local = corner * half
            return center + SIMD2(c * local.x - s * local.y, s * local.x + c * local.y)
        }
    }

    /// `width` × `height` の面の全画素 (行ごと) の、凸多角形の被覆。外接の箱の外は 0。
    public static func polygonCoverage(_ polygon: [SIMD2<Double>], width: Int, height: Int) -> [Double] {
        var out = [Double](repeating: 0, count: width * height)
        guard let box = pixelBox(polygon, width: width, height: height) else { return out }
        for y in box.y {
            for x in box.x { out[y * width + x] = polygonArea(polygon, pixel: x, y) }
        }
        return out
    }

    private static func pixelBox(
        _ points: [SIMD2<Double>], width: Int, height: Int
    ) -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
        guard let first = points.first else { return nil }
        let (low, high) = points.reduce((first, first)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
        let x0 = max(0, Int(low.x.rounded(.down))), x1 = min(width - 1, Int(high.x.rounded(.down)))
        let y0 = max(0, Int(low.y.rounded(.down))), y1 = min(height - 1, Int(high.y.rounded(.down)))
        guard x0 <= x1, y0 <= y1 else { return nil }
        return (x0...x1, y0...y1)
    }

    // MARK: - 円

    /// 円板と画素 (x, y) の正方形の重なりの面積。
    ///
    /// 画素を 4 つに割って細分する。正方形が円板に丸ごと入るか円板と重ならないとわかった所はそこで打ち切り、
    /// **境界の画素だけ**を深さ 7 (画素の 1/128) まで割る。末端は、その中心での円の接線を直線とみなした
    /// 半平面と末端の正方形の重なりを、厳密に数える (``halfPlaneArea(_:_:)``)。弧を直線とみなす誤差は
    /// 末端 1 つあたり `h³ / (8r)` (h = 1/128) で、半径 1 でも画素の 1e-6 に収まる。
    public static func circleArea(
        center: SIMD2<Double>, radius: Double, pixel x: Int, _ y: Int
    ) -> Double {
        circleCell(center: center, radius: radius, origin: SIMD2(Double(x), Double(y)), size: 1, depth: 0)
    }

    private static let circleDepth = 7

    private static func circleCell(
        center: SIMD2<Double>, radius: Double, origin: SIMD2<Double>, size: Double, depth: Int
    ) -> Double {
        let far = [origin, origin + SIMD2(size, 0), origin + SIMD2(0, size), origin + SIMD2(size, size)]
            .map { simd_distance($0, center) }.max()!
        if far <= radius { return size * size }
        let nearest = simd_distance(simd_clamp(center, origin, origin + SIMD2(size, size)), center)
        if nearest >= radius { return 0 }
        if depth == circleDepth {
            let middle = origin + SIMD2(size, size) / 2
            let distance = simd_distance(middle, center)
            guard distance > 1e-12 else { return size * size }
            // 円板の内 = 中心から (distance − radius) だけ外向きに進んだ点が 0 以下の側
            return halfPlaneArea((distance - radius) / size, (middle - center) / distance) * size * size
        }
        let half = size / 2
        var sum = 0.0
        for dy in 0..<2 {
            for dx in 0..<2 {
                sum += circleCell(
                    center: center, radius: radius, origin: origin + SIMD2(Double(dx), Double(dy)) * half,
                    size: half, depth: depth + 1)
            }
        }
        return sum
    }

    /// `width` × `height` の面の全画素 (行ごと) の、円板の被覆。外接の箱の外は 0。
    public static func circleCoverage(
        center: SIMD2<Double>, radius: Double, width: Int, height: Int
    ) -> [Double] {
        var out = [Double](repeating: 0, count: width * height)
        let corners = [center - SIMD2(repeating: radius), center + SIMD2(repeating: radius)]
        guard let box = pixelBox(corners, width: width, height: height) else { return out }
        for y in box.y {
            for x in box.x { out[y * width + x] = circleArea(center: center, radius: radius, pixel: x, y) }
        }
        return out
    }

    // MARK: - 本体の両端の遊び

    /// 本体が被覆の両端に持たせる遊び (`Shapes.metal` の `kFormSnap`・1/256)。
    public static let formSnap = 1.0 / 256

    /// 面積を、本体の被覆の写し方 (`c · (1 + 2/256) − 1/256`・0〜1 に clamp) で写した値。
    ///
    /// `Shapes.metal` の `mokume_formCoverage` (`saturate(mokume_pixelCdf(…) * (1.0 + 2.0 * kFormSnap) - kFormSnap)`・
    /// 1925〜1928 行付近) と同じ式で、**整数に置いた縁が 0 / 1 の境目に乗って、隣の画素が 1/255 染まる・塗り切った
    /// 画素が 254/255 になる** のを防ぐための設計である。面積そのものとは 0 / 1 に近い画素で最大 1/256 違う。
    /// 軸に沿う縁の比べに使い、面積の真値ではなく「本体が約束する値」を比べる。
    public static func snapped(_ area: Double) -> Double {
        min(1, max(0, area * (1 + 2 * formSnap) - formSnap))
    }

    // MARK: - 半平面・標本

    /// 半平面 `c + g · d ≤ 0` と、画素の正方形 [−0.5, 0.5]² の重なりの面積 (`mokume_pixelCdf` の写し・
    /// 64 bit・#2991)。
    public static func halfPlaneArea(_ c: Double, _ g: SIMD2<Double>) -> Double {
        let hi = max(abs(g.x), abs(g.y)), lo = min(abs(g.x), abs(g.y))
        if hi < 1e-12 { return c > 0 ? 0 : 1 }
        let s = 0.5 * (hi + lo), u = abs(c)
        if u >= s { return c > 0 ? 0 : 1 }
        // 軸に沿う縁 (短辺 0) は、幅 hi の線形の渡し
        if lo <= 1e-9 * hi { return min(1, max(0, 0.5 - c / hi)) }
        let k = 0.5 * (hi - lo), ramp = s - u
        let tail = u >= k ? ramp * ramp / (2 * lo * hi) : 0.5 - u / hi
        return c > 0 ? tail : 1 - tail
    }

    /// 画素 (x, y) の面積を、`samples` × `samples` の標本で数える。画素の 4 角と中心が同じ側なら標本を取らない。
    ///
    /// 凸でない形 (角丸・折れ目の輪郭の帯) の参照に使う。凸多角形と円は ``polygonArea(_:pixel:_:)``・
    /// ``circleArea(center:radius:pixel:_:)`` が厳密に出す。
    public static func sampledArea(
        _ x: Int, _ y: Int, samples: Int = 48, inside: (SIMD2<Float>) -> Bool
    ) -> Float {
        let origin = SIMD2(Float(x), Float(y))
        let probes = [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1), SIMD2(0.5, 0.5)]
        let hits = probes.map { inside(origin + $0) }
        if hits.allSatisfy({ $0 }) { return 1 }
        if !hits.contains(true) { return 0 }
        var hit = 0
        for sy in 0..<samples {
            for sx in 0..<samples {
                let sample = origin + SIMD2(
                    (Float(sx) + 0.5) / Float(samples), (Float(sy) + 0.5) / Float(samples))
                if inside(sample) { hit += 1 }
            }
        }
        return Float(hit) / Float(samples * samples)
    }
}

/// **約束を経路ごとの表で持つ** (#3217 の条件 3・ADR-0039 決定 1〜3)。
///
/// 縁の中間値が何を約束するかは、描く経路で違う。
///
/// - ``Route/distanceField`` (基本図形の距離関数の経路): 塗りの縁は解析的な被覆率で、斜めの縁・曲線は
///   画素の面積と一致する。線・輪郭・点は +0.5 画素寄せる。既定の丸い端と `point()` は線形の渡し
/// - ``Route/triangles`` (立体・任意形状・絵や断片を持つ基本図形の三角形の経路): 縁は AA なし。
///   **約束できるのは 50% の被覆で白黒にした形と、線形の被覆で重みを付けた重心まで**
///
/// 表の行は (図形・経路・比べる量・許容) で、参照を使う検査は行を引いてから比べる。行に無い組、
/// 経路が約束しない量の組は ``row(_:on:comparing:)`` が ``Refusal`` で拒む。**拒むのは約束の外を
/// 比べないためで、本体の不具合ではない** (AA なしは約束の内なので赤にしない)。
public nonisolated enum CoverageTable {
    /// 描く経路。
    public enum Route: String, Sendable, CaseIterable {
        case distanceField = "距離関数の経路"
        case triangles = "三角形の経路"
    }

    /// 参照と比べる量。
    public enum Quantity: String, Sendable, CaseIterable {
        /// 画素の正方形との重なりの面積。
        case area = "面積"
        /// 面積を、本体の両端の遊び (`kFormSnap`) で写した値。``CoverageReference/snapped(_:)``。
        case snappedArea = "面積 (kFormSnap で写した値)"
        /// 縁 1 本を幅 1 の線形に渡した値。
        case linearRamp = "線形の渡し"
        /// 縁を 50% の被覆で白黒にした形と、線形の被覆で重みを付けた重心。
        case halfToneAndCentroid = "50% の白黒と重心"
    }

    /// 参照を持つ図形。
    public enum Shape: String, Sendable, CaseIterable {
        case axisAlignedRect = "軸に沿う rect の塗り"
        case rotatedRect = "回した rect の塗り"
        case circle = "円の塗り"
    }

    /// 表の 1 行。
    public struct Row: Sendable {
        public let shape: Shape
        public let route: Route
        public let quantity: Quantity
        /// 画素ごとの差の許容 (0〜1 の被覆)。
        public let tolerance: Double
        /// 許容の根拠 (比べる検査の説明が引く)。
        public let basis: String
    }

    /// 拒む理由。`description` が名乗る文。
    public struct Refusal: Error, CustomStringConvertible, Sendable, Equatable {
        public let description: String
    }

    /// 経路が約束する量 (ADR-0039 決定 1〜3)。
    public static func promises(_ route: Route) -> [Quantity] {
        switch route {
        case .distanceField: [.area, .snappedArea, .linearRamp, .halfToneAndCentroid]
        case .triangles: [.halfToneAndCentroid]
        }
    }

    /// 表。許容は既存の検査の根拠のまま (`ExactEdgeCoverageTests`)。
    public static let rows: [Row] = [
        Row(
            shape: .axisAlignedRect, route: .distanceField, quantity: .snappedArea, tolerance: 1.0 / 255,
            basis: "軸に沿う縁は線形の渡しがそのまま面積だが、本体は両端に 1/256 の遊びを持たせて写す"
                + " (`Shapes.metal` の `kFormSnap`・`mokume_formCoverage` の 1925〜1928 行付近)。写した値と 1/255 以内"),
        Row(
            shape: .rotatedRect, route: .distanceField, quantity: .area, tolerance: 0.012,
            basis: "直線の斜めの縁は半平面との重なりの面積 (`mokume_pixelCdf`)。45° の rect で 0.012 (#2991)"),
        Row(
            shape: .circle, route: .distanceField, quantity: .area, tolerance: 0.02,
            basis: "曲線の縁は距離を直線とみなして数えるので、面積より明るく出る。差は半径に反比例し、半径 7 以上で 0.02 の内。7 未満は #3493"
                + " (半径 3 で 0.037・5 で 0.023・8 で 0.017・29 で 0.007。実測)。角丸・折れ目の既存の検査と同じ 0.02 (#2991)"),
    ]

    /// `shape` を `route` で描いたものを `quantity` で比べる行。無ければ理由を投げる。
    public static func row(_ shape: Shape, on route: Route, comparing quantity: Quantity) throws -> Row {
        guard promises(route).contains(quantity) else {
            throw Refusal(
                description: "[coverage] \(route.rawValue)の「\(shape.rawValue)」を「\(quantity.rawValue)」で比べる行は"
                    + "置けない: \(route.rawValue)が約束するのは \(promises(route).map(\.rawValue).joined(separator: "・")) まで"
                    + " (縁は AA なしで、約束の内・ADR-0039 決定 1・3)")
        }
        guard let row = rows.first(where: { $0.shape == shape && $0.route == route && $0.quantity == quantity })
        else {
            throw Refusal(
                description: "[coverage] \(route.rawValue)の「\(shape.rawValue)」を「\(quantity.rawValue)」で比べる行は"
                    + "表に無い (表の外は比べない)")
        }
        return row
    }
}
