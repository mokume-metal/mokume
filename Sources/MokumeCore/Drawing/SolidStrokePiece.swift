// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 立体の線の部品 1 つ (帯・円板・正方形・線の端の正方形・折れ目・網の点) の元。保持した形が、**置くときに帯を組み直す**
/// ために持つ ([#1547])。
///
/// 立体の線の帯は視点に合わせて組む — 向きは画面に写した線に、幅は画面の画素に合わせ、
/// 面に食われないよう目の側へ寄せる (`Canvas.strokeSolidRing`)。記録したときの視点で
/// 組んだ帯を頂点に焼いたまま置くと、回す・奥へ置く・拡大する・ずらすのどれでも、その場で
/// 描いた線と食い違う。そこで**頂点の並びは記録したまま**持ち、線の頂点がどの部品から
/// 来たかをここに覚えておく。置くときは置いた後の点と置く時点の視点で部品を組み直し、
/// その位置で頂点を上書きする (`Canvas.placeSolid(_:of:instances:)`)。
///
/// 頂点の並びと区間を記録したまま持つのは、塗りとの重ね順、添字の列、区間の畳み方を
/// 線のために変えないためである。組み直しても頂点の数は変わらない。
///
/// [#1547]: https://github.com/mokume-metal/mokume/issues/1547
struct SolidStrokePiece {
    /// 部品の形と、組み立ての元になる点 (形自身の座標)。
    enum Kind {
        /// 線分 1 本の帯。
        case band(SIMD3<Float>, SIMD3<Float>)
        /// 丸い端点と丸い角の円板。
        case disc(SIMD3<Float>)
        /// 向きの無い点の四角い端点の正方形 (画面の軸に沿う)。
        case square(SIMD3<Float>)
        /// 出っ張らせる線の端の正方形 (1 つ目の点に置き、2 つ目の点から離れる向きに沿う)。
        /// 向きが画面に写した線で決まるので、帯と同じく置く先で組み直す。
        ///
        /// `beyond` は 2 つ目の点の先の点 (線を 1 つ先へたどった点)。置く先で端の辺が画面で
        /// 潰れたら、その先の辺の向きで置く (#1893・潰れた辺の両端は画面で重なる)
        case endSquare(SIMD3<Float>, awayFrom: SIMD3<Float>, beyond: SIMD3<Float>?)
        /// 丸めない折れ目の形 (2 本の腕の向きで決まる・#1644)。向きが画面に写した線で決まるので、
        /// 置く先で組み直す。
        case join(Corner)
        /// 稜線の網の点 1 つ (#1889・#1893)。どの辺が画面で潰れるか、つまり画面で重なる点の群と
        /// そこへ集まる腕は置く先の視点で決まるので、記録の間は網の点ごとに 1 つ積み、置くときに
        /// 形を決める (``SolidStrokeNet``)
        case netPoint(NetPoint)
    }

    /// 丸めない折れ目の元。
    ///
    /// 腕は (出る点, 向こうの点) の対で、出る点は角と画面で重なる (その場で描いた周で、同じ位置の
    /// 点や画面で重なる点を飛ばしたとき・網の点の群のとき)。`beyond` は腕の向こうの点の、さらに
    /// 1 つ先の点 (記録した周だけが持つ)。置く先で腕が画面で潰れたら、出る点を向こうの点に、
    /// 向こうの点をその先へ送る (#1893)。先が無い (開いた周の端と重なる) なら、端の形が埋めるので
    /// 何も置かない。
    ///
    /// **2 本の腕が別の点から同じ向きに出れば 1 本と数え、端の形を置く** (``Canvas/screenCorner(arms:origins:isEnd:join:cap:)``)。
    struct Corner {
        var center: SIMD3<Float>
        var first: (origin: SIMD3<Float>, far: SIMD3<Float>)
        var second: (origin: SIMD3<Float>, far: SIMD3<Float>)
        var beyondFirst: SIMD3<Float>? = nil
        var beyondSecond: SIMD3<Float>? = nil
        /// 形 (`miter` / `bevel`)。**記録したときのものを持つ** — 輪郭の形は形の中で決まり、
        /// 置くときのスタイルは効かない (`Sketch/createShape(_:)`)
        var join: StrokeJoin
        /// 腕を 1 本と数えたときの端の形。記録したときのものを持つ
        var cap: StrokeCap
        /// 積む頂点の数の上限。記録した形はこの数に揃えて積む (端の円板を置きうる角は 48・
        /// ほかは 9)。置く先で枝が入れ替わっても頂点の数は記録と変わらない
        var capacity: Int

        func moved(by move: (SIMD3<Float>) -> SIMD3<Float>) -> Corner {
            var corner = self
            corner.center = move(center)
            corner.first = (move(first.origin), move(first.far))
            corner.second = (move(second.origin), move(second.far))
            corner.beyondFirst = beyondFirst.map(move)
            corner.beyondSecond = beyondSecond.map(move)
            return corner
        }
    }

    /// 稜線の網の点 1 つ。網は形自身の座標のまま共有し、置いた後の点は `matrix` で移して求める。
    struct NetPoint {
        var net: SolidStrokeNet
        var index: Int
        /// 網の点を、置いた後の点へ移す行列 (記録した時点の変換に、置き場所を左から掛けたもの)。
        var matrix: simd_float4x4
        var join: StrokeJoin
        var cap: StrokeCap
        /// 積む頂点の数の上限 (``Corner/capacity`` と同じ)。
        var capacity: Int

        /// 網の点 `index` を置いた後の点。
        func placed(_ index: Int) -> SIMD3<Float> {
            let moved = matrix * SIMD4(net.points[index], 1)
            return SIMD3(moved.x, moved.y, moved.z)
        }
    }

    var kind: Kind
    /// 組んだときの線の太さ (画面の画素)。帯の幅と目の側への寄せの両方が読む。
    var weight: Float
    /// この部品が積んだ頂点の区間の先頭 (形の立体の頂点の並びの番号)。
    var vertexStart: Int
    /// この部品が積んだ頂点の数。**3 の倍数** — 部品は三角形を丸ごと積む。
    var vertexCount: Int
    /// 積んだ頂点の三角形の巻き方を裏返してあるか。
    ///
    /// 鏡映する置き場所で頂点を焼いて積むと、三角形ごとに 2 点目と 3 点目が入れ替わる
    /// (`Canvas.appendPlacedSolidVertices`)。組み直した位置も同じ並べ替えを通さないと、
    /// 頂点の形自身の座標と位置が別の角を指す。
    var isReversed: Bool = false

    /// 組み直すと何も積まないときに、頂点を畳む先の点。
    var anchor: SIMD3<Float> {
        switch kind {
        case let .band(start, _): start
        case let .disc(center), let .square(center), let .endSquare(center, _, _): center
        case let .join(corner): corner.center
        case let .netPoint(point): point.placed(point.index)
        }
    }

    /// 行列で移した部品。頂点の並びの中での位置は変えない。
    func moved(by matrix: simd_float4x4) -> SolidStrokePiece {
        func move(_ point: SIMD3<Float>) -> SIMD3<Float> {
            let moved = matrix * SIMD4(point, 1)
            return SIMD3(moved.x, moved.y, moved.z)
        }
        var piece = self
        switch kind {
        case let .band(start, end): piece.kind = .band(move(start), move(end))
        case let .disc(center): piece.kind = .disc(move(center))
        case let .square(center): piece.kind = .square(move(center))
        case let .endSquare(center, from, beyond):
            piece.kind = .endSquare(move(center), awayFrom: move(from), beyond: beyond.map(move))
        case let .join(corner):
            piece.kind = .join(corner.moved(by: move))
        case var .netPoint(point):
            point.matrix = matrix * point.matrix
            piece.kind = .netPoint(point)
        }
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
