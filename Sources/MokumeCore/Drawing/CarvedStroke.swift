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

    /// 引いて、三角形の頂点にする。直に引いて積むとき (``Canvas/strokeOutline(_:)``) と同じ
    /// 座標系・同じ色・同じ扇の出し方。
    ///
    /// **扇の出し先を閉包で受けない。** 直に引いて積む経路と出し方が 2 通りになるが、
    /// 三角形ごとの呼び出しを閉包にすると、直に描く半透明の線が 7〜18% 遅くなった (実測)。
    func vertices() -> [ShapeVertex] {
        var out: [ShapeVertex] = []
        func place(_ point: SIMD2<Float>) -> SIMD2<Float> {
            let moved = point + offset
            return transform.apply(x: moved.x, y: moved.y)
        }
        func emit(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) {
            out.append(ShapeVertex(position: a, uv: uv, color: color))
            out.append(ShapeVertex(position: b, uv: uv, color: color))
            out.append(ShapeVertex(position: c, uv: uv, color: color))
        }
        carving.carved { polygon, range, hub in
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
        return out
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

    init(moving base: CarvedStroke, by matrix: simd_float4x4, tint: LinearRGBA?) {
        source = .moved(base, matrix, tint)
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
}
