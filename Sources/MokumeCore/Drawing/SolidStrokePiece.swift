// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 立体の線の部品 1 つ (帯・円板・正方形・線の端の正方形) の元。保持した形が、**置くときに帯を組み直す**
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
        /// 四角い端点と削いだ角の正方形。
        case square(SIMD3<Float>)
        /// 出っ張らせる線の端の正方形 (1 つ目の点に置き、2 つ目の点から離れる向きに沿う)。
        /// 向きが画面に写した線で決まるので、帯と同じく置く先で組み直す
        case endSquare(SIMD3<Float>, awayFrom: SIMD3<Float>)
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
        case let .disc(center), let .square(center), let .endSquare(center, _): center
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
        case let .endSquare(center, from):
            piece.kind = .endSquare(move(center), awayFrom: move(from))
        }
        return piece
    }
}
