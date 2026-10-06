// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 立体の線 1 本 (周か稜線の網) の元。保持した形が、**置くときに線を組み直す**ために持つ
/// ([#1547])。
///
/// 立体の線の帯は視点に合わせて組む — 向きは画面に写した線に、幅は画面の画素に合わせ、
/// 面に食われないよう目の側へ寄せる (`Canvas.strokeSolidRing`)。記録したときの視点で
/// 組んだ帯を頂点に焼いたまま置くと、回す・奥へ置く・拡大する・ずらすのどれでも、その場で
/// 描いた線と食い違う。そこで線の頂点がどの区間に積まれたかと、**線の元 (点と繋がり・
/// 太さ・折れ目・端)** をここに覚えておく。置くときは元を置いた後の点へ移し、置く時点の
/// 視点で**その場の線と同じ手順で**組み直して、記録した区間の代わりに差し込む
/// (`Canvas.placeSolid(_:of:instances:)`)。
///
/// **線を丸ごと組み直すので、頂点の数は記録と違ってよい** (#1889・#1893)。どの辺が画面で
/// 潰れ、どの点が画面で重なって 1 点として形を置くかは置く先の視点で決まり、積む三角形の数も
/// それで変わる。部品ごとに数を揃えて上書きしていた頃は、潰れた辺の先を何段まで部品に持たせるか
/// と、端の円板 (48 頂点) を置く容量を記録の時点で決めねばならず、その場の線と食い違った。
/// 塗りとの重ね順と添字の列は変えない — 差し込むのは記録した区間のあった所である。
///
/// [#1547]: https://github.com/mokume-metal/mokume/issues/1547
struct SolidStrokePiece {
    /// 線の元。点は世界の座標 (記録した時点の変換を掛けたもの) で、置くときは置き場所の
    /// 行列を左から掛ける。
    enum Source {
        /// 頂点を並べた形の周 (`vertex(x, y, z)`)。形自身の座標と、曲線の刻みの点かどうかを持つ
        case ring(
            points: [SIMD3<Float>], shapePoints: [SIMD3<Float>], isClosed: Bool, curveSteps: [Bool])
        /// 組み込みの立体と読み込んだモデルの稜線。網は形自身の座標のまま共有し、`matrix` で移す
        case net(SolidEdges, matrix: simd_float4x4)

        func moved(by matrix: simd_float4x4) -> Source {
            switch self {
            case let .ring(points, shapePoints, isClosed, curveSteps):
                var moved: [SIMD3<Float>] = []
                moved.reserveCapacity(points.count)
                for point in points {
                    let placed = matrix * SIMD4(point, 1)
                    moved.append(SIMD3(placed.x, placed.y, placed.z))
                }
                return .ring(points: moved, shapePoints: shapePoints, isClosed: isClosed, curveSteps: curveSteps)
            case let .net(net, placement):
                return .net(net, matrix: matrix * placement)
            }
        }
    }

    var source: Source
    /// 組んだときの線の太さ (画面の画素)。帯の幅と目の側への寄せの両方が読む。
    var weight: Float
    /// 組んだときの折れ目と端。**記録したときのものを持つ** — 輪郭の形は形の中で決まり、
    /// 置くときのスタイルは効かない (`Sketch/createShape(_:)`)
    var join: StrokeJoin
    var cap: StrokeCap
    /// この線が記録の時点で積んだ頂点の区間の先頭 (形の立体の頂点の並びの番号)。
    var vertexStart: Int
    /// この線が記録の時点で積んだ頂点の数。**3 の倍数で、0 にはならない** — 記録した視点で何も
    /// 積まない線は覚えない (`Canvas.recordingSolidStroke`)
    var vertexCount: Int
    /// 積んだ頂点の三角形の巻き方を裏返してあるか。
    ///
    /// 鏡映する置き場所で頂点を焼いて積むと、三角形ごとに 2 点目と 3 点目が入れ替わる
    /// (`Canvas.appendPlacedSolidVertices`)。組み直した頂点も同じ並べ替えを通さないと、
    /// 外側の記録に入れ子で置いたとき巻き方が食い違う。
    var isReversed: Bool = false
    /// 点 1 つの線 (端点の形だけ) の部品か。置く面で細くなるなら、画面の軸に沿った正方形に
    /// して面積で被覆を決める (``Canvas/rebuiltSolidStroke(_:tinted:)``・#1637)。
    var isLonePoint: Bool = false
    /// 片の重なりを引いて積む線か ([#1561])。記録したときのスタイルで決める
    /// (``Canvas/solidStrokeOverlapsShow``)。記録の中で半透明の色を掛けて置き直した線も立てる。
    ///
    /// [#1561]: https://github.com/mokume-metal/mokume/issues/1561
    var carves: Bool = false
    /// 置き場所で半透明の色を掛けて置いたら、片の重なりを引いて積むか。記録したときの混ぜ方が
    /// `replace` なら、重ねても同じ色になるので引かない。
    var carvesWhenTinted: Bool = true

    /// 行列で移した線。頂点の並びの中での位置は変えない。
    func moved(by matrix: simd_float4x4) -> SolidStrokePiece {
        var piece = self
        piece.source = source.moved(by: matrix)
        return piece
    }
}

/// 保持した形の中で、**GPU で組める組み込み立体の線** 1 つ ([#1756])。
///
/// 記録の間も線は CPU の帯として頂点に焼く (``SolidStrokePiece``) が、組み込みの形の閉じた
/// 稜線を不透明・miter・通常の混ぜ方・絵も利用者の断片も無しで引いた線は、置くときに
/// その場で描いたときと同じ GPU の骨 (``SolidStrokeGeometry``) で組める。置くたびに帯を
/// CPU で組み直すと、球 30 個で 1 フレーム約 10 ms かかっていた。
///
/// **焼いた頂点は消さない** — 頂点の数 (``Shape/vertexCount``)・入れ子の記録・GPU で
/// 組めない置き方 (置き場所の色で透ける・骨を作れない) のために、今までどおり持つ。
/// GPU で組むときは、その区間の頂点を積まずに GPU の列で描く。
///
/// [#1756]: https://github.com/mokume-metal/mokume/issues/1756
struct RetainedGPUStroke {
    /// どの組み込みの形の稜線か (寸法を含む)。
    var source: Canvas.SolidSource
    /// 記録した時点の変換 (形自身の座標)。置くときは置き場所の行列を左から掛ける。
    var matrix: simd_float4x4
    /// 記録した線の太さ。置く時点の ``Canvas/strokeWeight(_:)`` は効かない。
    var weight: Float
    /// 記録した線の端の形。画面で重なる点の腕を 1 本と数えた角 (端) が読む (#1893)。
    var cap: StrokeCap
    /// 記録した線の色 (乗算済み)。置き場所の色は置くときに掛かる。
    var color: LinearRGBA
    /// 記録した時点の焼き場の白い区画。区間が記録した頁を束ねるので、いまの位置ではなくこれを読む。
    var uv: SIMD2<Float>
    /// 焼いた線の頂点の区間 (``Shape/solidVertices`` の番号)。
    var vertices: Range<Int>
}
