// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 保持した形の線を、引いて積んだ頂点にする素材と、その持ち方 (#1829・#1920)。

/// 引いて積む線の素材。**値だけで自己完結する** — 頂点にするのに Canvas の状態を読まない。
///
/// ``StrokeCarving`` が片 (凸多角形)・線に沿った位置・太さ・基本図形かを持つので、ここへ足すのは
/// 頂点にするための値 (記録のときの変換・色・読み取り位置・周の置き場所のずれ) だけである。
/// 引く処理が Canvas の状態を読まないので、いつ引いても結果は同じになる。
struct CarveRecipe {
    let carving: StrokeCarving
    /// ずらす前の周で引いた結果へ足す、置き場所のずれ (``Outline/unmoved``)。
    let offset: SIMD2<Float>
    /// 記録のときの変換。引いた結果の点へ掛ける。**半画素寄せは掛けない** (置くときに掛かる)。
    let transform: Transform
    let color: LinearRGBA
    let uv: SIMD2<Float>
    /// 片を描く画素の空間で組んだとき (細い線を補う・#1637)、引いた結果の点を形自身の座標へ
    /// 戻す 2x2。`nil` なら片は形自身の座標で組んである。
    var inverse: simd_float2x2? = nil

    /// 引いて、三角形の頂点にする。直に引いて積むとき (``Canvas/strokeOutline(_:)``) と同じ
    /// 座標系・同じ色・同じ扇の出し方。
    ///
    /// **扇の出し先を閉包で受けない。** 直に引いて積む経路と出し方が 2 通りになるが、
    /// 三角形ごとの呼び出しを閉包にすると、直に描く半透明の線が 7〜18% 遅くなった (実測)。
    func vertices() -> [ShapeVertex] { built().vertices }

    /// 引いた頂点と、被覆が 1 でない区間 (頂点の並びの中の番号・#1637)。細い線を広げた片
    /// だけが区間を持つ。区間は並びの順で、置く側が頂点を積んだ先の番号へずらして付ける。
    func built() -> (vertices: [ShapeVertex], coverage: [Canvas.CoverageSpan]) {
        var out: [ShapeVertex] = []
        var spans: [Canvas.CoverageSpan] = []
        let inverse = self.inverse ?? matrix_identity_float2x2
        let mapsBack = self.inverse != nil
        func place(_ point: SIMD2<Float>) -> SIMD2<Float> {
            let moved = (mapsBack ? inverse * point : point) + offset
            return transform.apply(x: moved.x, y: moved.y)
        }
        func emit(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) {
            out.append(ShapeVertex(position: a, uv: uv, color: color))
            out.append(ShapeVertex(position: b, uv: uv, color: color))
            out.append(ShapeVertex(position: c, uv: uv, color: color))
        }
        carving.carved { polygon, range, hub, coverage, _ in
            let start = out.count
            defer { Canvas.CoverageSpan.note(coverage, in: start..<out.count, to: &spans) }
            guard let hub else {
                let first = place(polygon[range.lowerBound])
                var previous = place(polygon[range.lowerBound + 1])
                for index in (range.lowerBound + 2)..<range.upperBound {
                    let current = place(polygon[index])
                    emit(first, previous, current)
                    previous = current
                }
                return
            }
            let center = place(hub)
            let first = place(polygon[range.lowerBound])
            var previous = first
            for index in (range.lowerBound + 1)..<range.upperBound {
                let current = place(polygon[index])
                emit(center, previous, current)
                previous = current
            }
            emit(center, previous, first)
        }
        return (out, spans)
    }
}

/// 不透明の線で記録した輪郭を、片の重なりを引いて積んだ頂点。
///
/// 保持した形は、置くときに半透明の色を掛けられる (``Placement/fill``)。不透明の線は記録のとき
/// 片を重ねたまま積む (``Canvas/strokeOverlapsShow``) ので、そのまま半透明にすると、重なった所
/// だけが濃くなる (#1829)。そこで引いて積んだ頂点を用意するのだが、**記録のたびに組むと、
/// 半透明の色を掛けない形にも時間とメモリを払わせる**。この箱は素材だけを持ち、
/// **最初に要るとき (半透明の色を掛けて置くとき) に組んで、箱の中に控える。** 2 回目以降は
/// 控えた頂点をそのまま使う。
///
/// 参照の箱にしてあるのは、形 (値型) を写しても、組み上がった頂点を共有するため。組 (`group`) や
/// 入れ子で区間を繋いでも、同じ輪郭は 1 度しか引かれない。
final class CarvedStroke {
    private enum Source {
        case recipe(CarveRecipe)
        /// 入れ子: 別の保持した形の中で置かれた輪郭。もとの頂点へ、置いたときの行列と色を掛ける。
        case moved(CarvedStroke, simd_float4x4, LinearRGBA?)
    }

    /// 組み終えたら手放す (持ち続けると、置いた後のメモリが引いた頂点の分と素材の分で二重になる)。
    private var source: Source?
    private var cache: [ShapeVertex]?

    init(recipe: CarveRecipe) { source = .recipe(recipe) }

    /// 別の保持した形の中で置かれた輪郭。もとの箱へ、置いたときの行列と色を掛ける。
    ///
    /// **元の箱が、まだ組んでいない派生なら、行列と色を合成して 1 段に畳む。** 畳まずに積むと、
    /// 再記録のたびに箱が 1 段ずつ積み重なる (`trail = createShape { shape(trail); 線を足す }` を
    /// 毎フレーム繰り返すと、k フレーム目には輪郭 j が長さ k − j の鎖になり、生きている箱が
    /// O(k²) 個になる)。畳めば、どの派生も素材の箱を直に指し、箱の数は輪郭の数のままである。
    init(moving base: CarvedStroke, by matrix: simd_float4x4, tint: LinearRGBA?) {
        if base.cache == nil, case .moved(let root, let inner, let innerTint)? = base.source {
            // 先に `inner` で移し、次に `matrix` で移す = 合成した行列で 1 度に移す
            source = .moved(root, matrix * inner, Self.combined(innerTint, tint))
        } else {
            source = .moved(base, matrix, tint)
        }
    }

    /// 先に `first`、次に `second` の色を掛けたのと同じ色。渡さなければ何も掛からない。
    private static func combined(_ first: LinearRGBA?, _ second: LinearRGBA?) -> LinearRGBA? {
        guard let first else { return second }
        guard let second else { return first }
        return LinearRGBA(
            premultipliedRed: first.red * second.red, green: first.green * second.green,
            blue: first.blue * second.blue, alpha: first.alpha * second.alpha)
    }

    /// 引いて積んだ頂点。最初に読んだときに組む。
    var vertices: [ShapeVertex] {
        if let cache { return cache }
        var built: [ShapeVertex] = []
        switch source {
        case .recipe(let recipe): built = recipe.vertices()
        case .moved(let base, let matrix, let tint):
            built = Canvas.moved(base.vertices, by: matrix, tint: tint)
        case nil: break
        }
        // 伸ばしたときの余りが 4 分の 1 を超えるなら、ちょうどの大きさへ写す
        if built.capacity - built.count > built.count / 4 {
            var exact: [ShapeVertex] = []
            exact.reserveCapacity(built.count)
            exact.append(contentsOf: built)
            built = exact
        }
        cache = built
        source = nil
        return built
    }

    /// 組み終えているか (検査用)。
    var isRealized: Bool { cache != nil }

    /// 箱の鎖の長さ (検査用)。素材そのものと組み終えた箱は 0、派生は元の箱の長さ + 1。
    /// 畳んでいれば、組む前の派生は 1 を超えない。
    var chainDepth: Int {
        guard case .moved(let base, _, _)? = source else { return 0 }
        return base.chainDepth + 1
    }
}
