// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 立体の線 1 本の片を、画面で重なりを引いて積むための素材 ([#1561])。
///
/// 立体の線の片 (帯・円板・正方形・折れ目の形) は、視線に正対する平らな凸多角形として世界の
/// 座標で組む (`Canvas.buildSolidStroke`)。重ねたまま積むと、半透明の線では折れ目・端・稜の
/// 集まる点だけが 2〜3 回混ざって濃くなる。平面の線と同じ引き算 (``StrokeCarving``) を画面で行う:
///
/// - **切る**: 片を手前の面 (切り取り座標の z = 0) で切る。手前の面より手前は GPU も描かないので、
///   描く所は変わらない。切らずに写すと、目の近くの点が画面の遠くへ飛び、線 1 本で共有する
///   許容差が膨らんで切り口が粗くなる (#1561 の反証 2)。目の後ろへ回る点もここで落ちる
/// - **写す**: 片の周の点を視点の行列で切り取り座標へ写し、w で割って画面の画素の単位にする
///   (縦横の大きさの半分を掛ける。向きと原点は問わない — 引き算は相似な写像で変わらない)
/// - **引く**: 網として引く (``StrokeCarving/init(net:edges:lengths:weight:limit:)``)。線に沿った
///   隔たりは網の辺を辿った画面での道のりで測る。稜線の網の同じ点に集まる帯と形は互いに引き、
///   網を辿って太さより離れた稜 (奥行きの違う稜が画面で交わる所) は引かない (奥行きで決めることは下)
/// - **戻す**: 残りの点を、元の片の扇の三角形 (周の最初の点から) のうち点を含むもので、透視を
///   正した重心座標 (画面の重心座標を各点の w で割って揃える) で世界の点と形自身の座標へ戻す。
///   片は平らなので、視線と片の平面の交点と同じである
///
/// **奥行きで 2 つを決める** (#1561 の反証 1)。引き算は平面の道具で、どちらの片を残すかを奥行きで
/// 決めない。塗りのある形で、先に積んだ片が面の奥にあり、後の片が手前で見えている所を引くと、
/// その画素から線が消える。
///
/// - **手前の片を残す**: 片を奥行き (端の点の奥行き) の近い順に引き算へ渡す。後から渡す奥の片が、
///   先に渡した手前の片との重なりを引かれる。**積む順は元の順 (骨が片を置いた順) のまま**で、
///   引かない片どうし (奥行きの違う稜の交わり) が奥行きで隠れるかは今までと変わらない
/// - **奥行きの離れた片どうしは引かない**: 端の点を共有しない 2 つの片で、端の点の奥行きの差の
///   いちばん小さいものが、線を見ている側へ寄せる量 (太さ + 1 画素・`liftedTowardViewer`) を越える
///   なら、網を辿って太さ以内でも引かない。平行投影で正面を向けた箱の前後の稜のように、画面で
///   重なり網で繋がるが奥行きの違う稜は、別々の線と同じく重ねて混ぜる (手前の稜を先に積めば、
///   奥の稜は奥行きで隠れる)。端の点を共有する片 (1 点に集まる帯と点の形) は、その点で同じ奥行き
///   なので常に引く
///
/// **点は、その片の平面へ戻す。** 元の片の周の点はその点そのもの (引かなかった片は 1 ビットも
/// 変わらない)、新しい点 (切り口・継ぎ目に差し込んだ相手の点) は片の平面の上の点である。継ぎ目の
/// 点を隣の片の平面で戻した世界の点で共有すると、GPU が写し直したときの丸めは揃うが、細長い帯の
/// 扇の奥行きがその点に引かれて崩れ、塗りのある形で帯の内側の縁が面の奥へ潜って欠ける
/// (#1561 の反証 1 の検査で、縁に沿って 1 画素幅の欠け)。継ぎ目の点は両方の片で画面の同じ値から
/// 戻すので、写し直した位置の違いは単精度の丸めの幅に収まる。
///
/// 網の届く点の表が上限を越える線 (画面で小さく写る細かい網に太い線) は組まない (`init` が `nil`)。
/// 呼ぶ側は引かずに重ねて積む。
///
/// [#1561]: https://github.com/mokume-metal/mokume/issues/1561
nonisolated struct SolidStrokeCarving {
    /// 画面へ戻した頂点 (世界の点と形自身の座標)。
    typealias Vertex = (position: SIMD3<Float>, shape: SIMD3<Float>)

    /// 写し方と、奥行きの物差し。
    struct View {
        /// 世界を切り取り座標へ写す行列 (立体の列が使うもの)
        var viewProjection: simd_float4x4
        /// 画面の大きさ
        var width: Float
        var height: Float
        var eye: SIMD3<Float>
        var forward: SIMD3<Float>
        var isPerspective: Bool
        /// 1 画素の長さの係数。透視は `2 * tan(fov / 2)`、平行は `abs(bottom - top)`
        var pixelScale: Float
        /// 透視の手前の面の距離
        var near: Float

        /// 奥行き `depth` での、画面 1 画素ぶんの世界での長さ (``StrokeCamera/worldPerPixel(at:height:)``)。
        func worldPerPixel(atDepth depth: Float) -> Float {
            isPerspective ? pixelScale * max(depth, near) / height : pixelScale / height
        }
    }

    /// 足すのを待つ片 (骨が置いた順)。
    private struct Piece {
        /// 帯なら辺の添字、点に置いた形なら `nil`
        var band: Int?
        /// 端の点 (帯は辺の両端、点に置いた形は同じ点を 2 つ)
        var anchors: (Int, Int)
        /// 周の点の区間 (下の 4 つの並びの番号)
        var range: Range<Int>
        /// 形自身の座標がどの点でも同じか (点に置いた形)。同じなら戻すときに重心を求めない
        var uniform: Bool
        /// 引き算へ渡す順を決める奥行き (端の点の奥行きの平均)
        var depth: Float
        /// 形自身の座標がどの点でも同じ片の、戻すのに使う三角形 (最初の点と、この 2 つの点)。片は
        /// 平らなので、どの三角形からでも同じ平面へ戻る。周の 3 分の 1 ずつ離れた点を選ぶ
        var reference: (Int, Int)
    }

    private var carving: StrokeCarving
    private let view: View
    private let edges: [(Int, Int)]
    /// 網の点ごとの奥行き (視線に沿った距離)
    private let depths: [Float]
    /// 線を見ている側へ寄せる量 (画素)。奥行きの離れた片を見分ける閾値
    private let lift: Float
    private var pieces: [Piece] = []
    private var world: [SIMD3<Float>] = []
    private var shapes: [SIMD3<Float>] = []
    private var screen: [SIMD2<Float>] = []
    /// 周の点の切り取り座標の w (透視を正すのに使う。平行投影では 1)。
    private var clipW: [Float] = []

    /// - Parameters:
    ///   - points: 網の点 (世界の座標)
    ///   - edges: 網の辺。帯は ``addPiece(band:point:rim:shapes:)`` にこの添字で渡す
    ///   - weight: 線の太さ (画面の画素)
    /// - Returns: 網の届く点の表が上限を越えるなら `nil` (引かずに重ねて積む)
    init?(points: [SIMD3<Float>], edges: [(Int, Int)], weight: Float, view: View) {
        var projected: [SIMD2<Float>?] = []
        projected.reserveCapacity(points.count)
        var depths: [Float] = []
        depths.reserveCapacity(points.count)
        for point in points {
            projected.append(Self.project(point, view)?.screen)
            depths.append(dot(point - view.eye, view.forward))
        }
        // 網の辺の画面での長さ。どちらかの端が画面へ写せない (手前の面より手前) 辺は辿らない
        var lengths: [Float] = []
        lengths.reserveCapacity(edges.count)
        for (a, b) in edges {
            if let start = projected[a], let end = projected[b] {
                lengths.append(simd_distance(start, end))
            } else {
                lengths.append(.infinity)
            }
        }
        guard let carving = StrokeCarving(net: points.count, edges: edges, lengths: lengths, weight: weight)
        else { return nil }
        self.carving = carving
        self.view = view
        self.edges = edges
        self.depths = depths
        lift = weight + 1
    }

    /// 世界の点を画面 (画素の単位) へ写す。手前の面より手前・数でなくなる点は `nil`。
    private static func project(_ point: SIMD3<Float>, _ view: View) -> (screen: SIMD2<Float>, w: Float)? {
        let clip = view.viewProjection * SIMD4(point, 1)
        guard clip.z >= 0, clip.w > 0 else { return nil }
        let screen = SIMD2(clip.x, clip.y) / clip.w * SIMD2(view.width / 2, view.height / 2)
        guard screen.x.isFinite, screen.y.isFinite, clip.w.isFinite else { return nil }
        return (screen, clip.w)
    }

    /// 片を 1 つ足す。帯なら `band` に辺の添字を、点に置いた形なら `point` に点の添字を渡す。
    /// `rim` は凸多角形の周 (世界の座標)、`shapes` は周の点ごとの形自身の座標。
    ///
    /// 片は手前の面で切ってから写す。切った残りが面積を持たなければ、何も描かない片として足さない。
    ///
    /// - Returns: 足したか。**偽なら画面へ写せない片** (数でない座標) で、呼ぶ側が重ねたまま積む
    mutating func addPiece(
        band: Int? = nil, point: Int? = nil, rim: [SIMD3<Float>], shapes pieceShapes: [SIMD3<Float>]
    ) -> Bool {
        guard band != nil || point != nil else { return false }
        // 手前の面 (切り取り座標の z = 0) で切る。z は世界の点の 1 次式なので、辺の上で比で分ければよい
        let row = SIMD4(
            view.viewProjection.columns.0.z, view.viewProjection.columns.1.z,
            view.viewProjection.columns.2.z, view.viewProjection.columns.3.z)
        func height(_ point: SIMD3<Float>) -> Float { dot(row, SIMD4(point, 1)) }
        var corners = rim
        var cornerShapes = pieceShapes
        if rim.contains(where: { height($0) < 0 }) {
            corners.removeAll(keepingCapacity: true)
            cornerShapes.removeAll(keepingCapacity: true)
            var previous = rim.count - 1
            for current in rim.indices {
                let (from, to) = (height(rim[previous]), height(rim[current]))
                if (from < 0) != (to < 0) {
                    let t = from / (from - to)
                    corners.append(rim[previous] + (rim[current] - rim[previous]) * t)
                    cornerShapes.append(pieceShapes[previous] + (pieceShapes[current] - pieceShapes[previous]) * t)
                }
                if to >= 0 {
                    corners.append(rim[current])
                    cornerShapes.append(pieceShapes[current])
                }
                previous = current
            }
            guard corners.count >= 3 else { return true }
        }
        var projected: [(screen: SIMD2<Float>, w: Float)] = []
        projected.reserveCapacity(corners.count)
        for corner in corners {
            guard let placed = Self.project(corner, view) else { return false }
            projected.append(placed)
        }
        let anchors = band.map { edges[$0] } ?? (point!, point!)
        let start = world.count
        world.append(contentsOf: corners)
        shapes.append(contentsOf: cornerShapes)
        for placed in projected {
            screen.append(placed.screen)
            clipW.append(placed.w)
        }
        let count = world.count - start
        pieces.append(
            Piece(
                band: band, anchors: anchors, range: start..<world.count,
                uniform: cornerShapes.allSatisfy { $0 == cornerShapes[0] },
                depth: (depths[anchors.0] + depths[anchors.1]) / 2,
                reference: (start + max(1, count / 3), start + max(2, count * 2 / 3))))
        return true
    }

    /// 2 つの片 (足した順の番号) を引き合うか。端の点を共有すれば引き合う。共有しなければ、端の点の
    /// 奥行きの差のいちばん小さいものが、線を見ている側へ寄せる量以内のときだけ。
    private func relates(_ first: Int, _ second: Int) -> Bool {
        let (a, b) = (pieces[first].anchors, pieces[second].anchors)
        if a.0 == b.0 || a.0 == b.1 || a.1 == b.0 || a.1 == b.1 { return true }
        var nearest = Float.infinity
        var at: Float = 0
        for x in [a.0, a.1] {
            for y in [b.0, b.1] {
                let gap = abs(depths[x] - depths[y])
                if gap < nearest { (nearest, at) = (gap, max(depths[x], depths[y])) }
            }
        }
        return nearest <= lift * view.worldPerPixel(atDepth: at)
    }

    /// 引いた残りの三角形。頂点 (`lift` を通した位置と形自身の座標) と、頂点の番号の 3 つ組。**3 つ組の
    /// 順は片を足した順** (骨が置いた順) で、引き算へは手前の片から渡す。扇の割り方は
    /// ``StrokeCarving/carved(relates:_:)`` の要の選び方に従う。
    ///
    /// `lift` は線を見ている側へ寄せる (`liftedTowardViewer`)。扇の頂点は幾つかの三角形が分け合うので、
    /// 寄せるのは頂点ごとに 1 度だけにする。
    mutating func triangles(
        lift: (SIMD3<Float>) -> SIMD3<Float>
    ) -> (vertices: [Vertex], triangles: [SIMD3<Int32>]) {
        // 引き算へ渡す順: 奥行きの近い順 (等しければ足した順)
        let order = pieces.indices.sorted { (pieces[$0].depth, $0) < (pieces[$1].depth, $1) }
        var owners: [Int] = []
        owners.reserveCapacity(pieces.count)
        for index in order {
            let piece = pieces[index]
            let range = piece.range
            func build(_ polygon: inout [SIMD2<Float>]) {
                for slot in range { polygon.append(screen[slot]) }
            }
            let added =
                piece.band.map { carving.addBand(segment: $0, build) }
                ?? carving.addPoint(piece.anchors.0, build)
            if added != nil { owners.append(index) }
        }
        // 引いた残り: 頂点は残りの周ごとに 1 度だけ積み、三角形は番号で持つ
        var vertices: [Vertex] = []
        vertices.reserveCapacity(screen.count * 2)
        var found: [(piece: Int, corners: SIMD3<Int32>)] = []
        found.reserveCapacity(screen.count * 2)
        let carving = self.carving
        carving.carved(relates: { relates(owners[$0], owners[$1]) }) { polygon, range, hub, _, owner in
            let piece = owners[owner]
            let own = pieces[piece].range
            let base = Int32(vertices.count)
            // 元の片の周の点なら、その点そのもの。残りの周は元の周を順か逆順に辿ることが多いので、
            // 直前に見つけた点の隣から探す
            var hint = own.upperBound - 1
            for index in range {
                let point = polygon[index]
                var known: SIMD3<Float>?
                // 次の点・前の点・同じ点・残りの順に見る (どの点も 1 度ずつ)
                for step in 0..<own.count {
                    let offset = step == 0 ? 1 : (step == 1 ? own.count - 1 : (step == 2 ? 0 : step - 1))
                    let slot = own.lowerBound + (hint - own.lowerBound + offset) % own.count
                    if screen[slot] == point {
                        known = world[slot]
                        hint = slot
                        break
                    }
                }
                let (position, shape) = locate(point, in: piece, knowing: known)
                vertices.append((lift(position), shape))
            }
            let count = Int32(range.count)
            guard let hub else {
                for index in 2..<count {
                    found.append((piece, SIMD3(base, base + index - 1, base + index)))
                }
                return
            }
            let (hubPosition, hubShape) = locate(hub, in: piece, knowing: nil)
            let center = Int32(vertices.count)
            vertices.append((lift(hubPosition), hubShape))
            for index in 1..<count {
                found.append((piece, SIMD3(center, base + index - 1, base + index)))
            }
            found.append((piece, SIMD3(center, base + count - 1, base)))
        }
        // 片を足した順に並べ直す。引き算へ渡した順が足した順のまま (奥行きが揃った線) なら要らない
        guard order != Array(pieces.indices) else { return (vertices, found.map(\.corners)) }
        var starts = [Int](repeating: 0, count: pieces.count + 1)
        for entry in found { starts[entry.piece + 1] += 1 }
        for index in pieces.indices { starts[index + 1] += starts[index] }
        var slots = Array(starts.dropLast())
        var sorted = [SIMD3<Int32>](repeating: .zero, count: found.count)
        for entry in found {
            sorted[slots[entry.piece]] = entry.corners
            slots[entry.piece] += 1
        }
        return (vertices, sorted)
    }

    /// 画面の点 `point` を、片 `piece` の上の世界の点と形自身の座標へ戻す。世界の点が既に
    /// 決まっていれば (`known`)、形自身の座標だけを求める。
    private func locate(
        _ point: SIMD2<Float>, in piece: Int, knowing known: SIMD3<Float>?
    ) -> Vertex {
        let range = pieces[piece].range
        let uniform = pieces[piece].uniform
        if let known, uniform { return (known, shapes[range.lowerBound]) }
        let first = range.lowerBound
        let origin = screen[first]
        var best: (weights: SIMD3<Float>, second: Int) = (SIMD3(1, 0, 0), first)
        var bestScore = -Float.infinity
        // 形自身の座標が同じ片は、平面さえ分かればよい: 決めておいた 1 つの三角形で戻す。違う片
        // (帯) は、扇の三角形 (最初の点, k, k + 1) のうち、点をいちばん内に含むもの (重心座標の
        // 最小が最大) で戻す — 帯の形自身の座標は扇の三角形ごとに 1 次なので
        let candidates: StrideTo<Int> =
            uniform
            ? stride(from: pieces[piece].reference.0, to: pieces[piece].reference.0 + 1, by: 1)
            : stride(from: first + 1, to: range.upperBound - 1, by: 1)
        for second in candidates {
            let third = uniform ? pieces[piece].reference.1 : second + 1
            let u = screen[second] - origin
            let v = screen[third] - origin
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
        let (second, third) = (best.second, uniform ? pieces[piece].reference.1 : best.second + 1)
        var corrected = SIMD3(
            best.weights.x / clipW[first], best.weights.y / clipW[second],
            best.weights.z / clipW[third])
        let total = corrected.sum()
        if total != 0, total.isFinite { corrected /= total }
        let shape =
            uniform
            ? shapes[first]
            : shapes[first] * corrected.x + shapes[second] * corrected.y + shapes[third] * corrected.z
        if let known { return (known, shape) }
        let position = world[first] * corrected.x + world[second] * corrected.y + world[third] * corrected.z
        return (position, shape)
    }
}
