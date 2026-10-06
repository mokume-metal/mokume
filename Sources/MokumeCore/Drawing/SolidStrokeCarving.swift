// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 立体の線 1 本の片を、画面で重なりを引いて積むための素材 ([#1561])。
///
/// 立体の線の片 (帯・円板・正方形・折れ目の形) は、視線に正対する平らな凸多角形として世界の
/// 座標で組む (`Canvas.buildSolidStroke`)。重ねたまま積むと、半透明の線では折れ目・端・稜の
/// 集まる点だけが 2〜3 回混ざって濃くなる。平面の線と同じ引き算 (``StrokeCarving``) を画面で行う:
///
/// - **写す**: 片の周の点を視点の行列で切り取り座標へ写し、w で割って画面の画素の単位にする
///   (縦横の大きさの半分を掛ける。向きと原点は問わない — 引き算は相似な写像で変わらない)
/// - **引く**: 網として引く (``StrokeCarving/init(net:edges:lengths:weight:)``)。線に沿った隔たりは
///   網の辺を辿った画面での道のりで測る。稜線の網の同じ点に集まる帯と形は互いに引き、網を辿って
///   太さより離れた稜 (奥行きの違う稜が画面で交わる所) は引かずに 2 回混ぜる
/// - **戻す**: 残りの点を、元の片の扇の三角形 (周の最初の点から) のうち点を含むもので、透視を
///   正した重心座標 (画面の重心座標を各点の w で割って揃える) で世界の点と形自身の座標へ戻す。
///   片は平らなので、視線と片の平面の交点と同じである
///
/// **画面で同じ点は、同じ世界の点へ戻す。** 片どうしの継ぎ目の点 (引き算が両方の片の周に同じ値で
/// 置く点) を片ごとの平面で戻すと、GPU が写し直したときに単精度の丸めで画面の位置がずれ、
/// 継ぎ目に画素の穴か重なりが出る。元の片の周の点はその点そのものを、新しい点は最初に戻した
/// 世界の点を使い回す。形自身の座標は片ごとに戻す (利用者の断片へ渡す値で、継ぎ目を割らない)。
///
/// 画面へ写せない片 (目の後ろへ回る点を持つ) は引かず、相手にも数えない
/// (``addPiece(band:point:rim:shapes:)`` が偽を返し、呼ぶ側が重ねたまま積む)。
///
/// [#1561]: https://github.com/mokume-metal/mokume/issues/1561
nonisolated struct SolidStrokeCarving {
    /// 画面へ戻した頂点 (世界の点と形自身の座標)。
    typealias Vertex = (position: SIMD3<Float>, shape: SIMD3<Float>)

    private var carving: StrokeCarving
    private let viewProjection: simd_float4x4
    /// 画面の大きさの半分。切り取り座標を w で割った値に掛けて画素の単位にする。
    private let halfSize: SIMD2<Float>
    /// 片ごと (``StrokeCarving`` の片の番号) の、周の点の区間 (下の 4 つの並びの番号)。
    private var ranges: [Range<Int>] = []
    /// 片の形自身の座標が、どの点でも同じか (点に置いた形)。同じなら戻すときに重心を求めない。
    private var uniform: [Bool] = []
    private var world: [SIMD3<Float>] = []
    private var shapes: [SIMD3<Float>] = []
    private var screen: [SIMD2<Float>] = []
    /// 周の点の切り取り座標の w (透視を正すのに使う。平行投影では 1)。
    private var depths: [Float] = []

    /// - Parameters:
    ///   - points: 網の点 (世界の座標)
    ///   - edges: 網の辺。帯は ``addPiece(band:point:rim:shapes:)`` にこの添字で渡す
    ///   - weight: 線の太さ (画面の画素)
    ///   - viewProjection: 世界を切り取り座標へ写す行列 (立体の列が使うもの)
    init(
        points: [SIMD3<Float>], edges: [(Int, Int)], weight: Float, viewProjection: simd_float4x4,
        width: Float, height: Float
    ) {
        self.viewProjection = viewProjection
        halfSize = SIMD2(width / 2, height / 2)
        var projected: [SIMD2<Float>?] = []
        projected.reserveCapacity(points.count)
        for point in points {
            projected.append(Self.project(point, by: viewProjection, halfSize: halfSize)?.screen)
        }
        // 網の辺の画面での長さ。どちらかの端が画面へ写せない辺は辿らない
        var lengths: [Float] = []
        lengths.reserveCapacity(edges.count)
        for (a, b) in edges {
            if let start = projected[a], let end = projected[b] {
                lengths.append(simd_distance(start, end))
            } else {
                lengths.append(.infinity)
            }
        }
        carving = StrokeCarving(net: points.count, edges: edges, lengths: lengths, weight: weight)
    }

    /// 世界の点を画面 (画素の単位) へ写す。目の後ろ・目と同じ奥行き・数でなくなる点は `nil`。
    private static func project(
        _ point: SIMD3<Float>, by matrix: simd_float4x4, halfSize: SIMD2<Float>
    ) -> (screen: SIMD2<Float>, w: Float)? {
        let clip = matrix * SIMD4(point, 1)
        guard clip.w > 0 else { return nil }
        let screen = SIMD2(clip.x, clip.y) / clip.w * halfSize
        guard screen.x.isFinite, screen.y.isFinite, clip.w.isFinite else { return nil }
        return (screen, clip.w)
    }

    /// 片を 1 つ足す。帯なら `band` に辺の添字を、点に置いた形なら `point` に点の添字を渡す。
    /// `rim` は凸多角形の周 (世界の座標)、`shapes` は周の点ごとの形自身の座標。
    ///
    /// - Returns: 足したか。**偽なら画面へ写せない片**で、呼ぶ側が重ねたまま積む。面積を持たない
    ///   片は、何も塗らないので足さずに真を返す
    mutating func addPiece(
        band: Int? = nil, point: Int? = nil, rim: [SIMD3<Float>], shapes pieceShapes: [SIMD3<Float>]
    ) -> Bool {
        var projected: [(screen: SIMD2<Float>, w: Float)] = []
        projected.reserveCapacity(rim.count)
        for corner in rim {
            guard let placed = Self.project(corner, by: viewProjection, halfSize: halfSize) else {
                return false
            }
            projected.append(placed)
        }
        func build(_ polygon: inout [SIMD2<Float>]) {
            for placed in projected { polygon.append(placed.screen) }
        }
        let index: Int?
        if let band {
            index = carving.addBand(segment: band, build)
        } else if let point {
            index = carving.addPoint(point, build)
        } else {
            index = nil
        }
        guard let index else { return true }
        assert(index == ranges.count, "a piece was added without its rim")
        let start = world.count
        world.append(contentsOf: rim)
        shapes.append(contentsOf: pieceShapes)
        for placed in projected {
            screen.append(placed.screen)
            depths.append(placed.w)
        }
        ranges.append(start..<world.count)
        uniform.append(pieceShapes.allSatisfy { $0 == pieceShapes[0] })
        return true
    }

    /// 引いた残りを三角形にして `triangle` へ渡す (片を足した順)。扇の割り方は ``StrokeCarving/carved(_:)``
    /// の要の選び方に従う。
    func emit(_ triangle: (_ a: Vertex, _ b: Vertex, _ c: Vertex) -> Void) {
        // 画面の点 → 世界の点。元の片の周の点を先に入れる (先に足した片の点が勝つ)
        var placed: [SIMD2<Float>: SIMD3<Float>] = [:]
        placed.reserveCapacity(screen.count)
        for index in screen.indices where placed[screen[index]] == nil {
            placed[screen[index]] = world[index]
        }
        var vertices: [Vertex] = []
        carving.carved { polygon, range, hub, _, piece in
            vertices.removeAll(keepingCapacity: true)
            for index in range {
                let point = polygon[index]
                let known = placed[point]
                let (position, shape) = locate(point, in: piece, knowing: known)
                if known == nil { placed[point] = position }
                vertices.append((position, shape))
            }
            guard let hub else {
                for index in 2..<vertices.count { triangle(vertices[0], vertices[index - 1], vertices[index]) }
                return
            }
            let center = locate(hub, in: piece, knowing: nil)
            for index in 1..<vertices.count { triangle(center, vertices[index - 1], vertices[index]) }
            triangle(center, vertices[vertices.count - 1], vertices[0])
        }
    }

    /// 画面の点 `point` を、片 `piece` の上の世界の点と形自身の座標へ戻す。世界の点が既に
    /// 決まっていれば (`known`)、形自身の座標だけを求める。
    private func locate(
        _ point: SIMD2<Float>, in piece: Int, knowing known: SIMD3<Float>?
    ) -> Vertex {
        let range = ranges[piece]
        if let known, uniform[piece] { return (known, shapes[range.lowerBound]) }
        // 扇の三角形 (最初の点, k, k + 1) のうち、点をいちばん内に含むもの (重心座標の最小が最大)
        let first = range.lowerBound
        let origin = screen[first]
        var best: (weights: SIMD3<Float>, second: Int) = (SIMD3(1, 0, 0), first)
        var bestScore = -Float.infinity
        for second in (first + 1)..<(range.upperBound - 1) {
            let u = screen[second] - origin
            let v = screen[second + 1] - origin
            let area = u.x * v.y - u.y * v.x
            guard area != 0, area.isFinite else { continue }
            let offset = point - origin
            let b = (offset.x * v.y - offset.y * v.x) / area
            let c = (u.x * offset.y - u.y * offset.x) / area
            let weights = SIMD3(1 - b - c, b, c)
            let score = weights.min()
            if score > bestScore {
                bestScore = score
                best = (weights, second)
            }
        }
        // 透視を正す: 画面の重心座標を各点の w で割って揃える
        let (second, third) = (best.second, best.second + 1)
        var corrected = SIMD3(
            best.weights.x / depths[first], best.weights.y / depths[second],
            best.weights.z / depths[third])
        let total = corrected.sum()
        if total != 0, total.isFinite { corrected /= total }
        let shape =
            uniform[piece]
            ? shapes[first]
            : shapes[first] * corrected.x + shapes[second] * corrected.y + shapes[third] * corrected.z
        if let known { return (known, shape) }
        let position = world[first] * corrected.x + world[second] * corrected.y + world[third] * corrected.z
        return (position, shape)
    }
}
