// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// [試作・使い捨て] 引いて積んだ頂点を、記録のときには組まず、最初に要るときに組む (#1829 の案 L)。

/// 引いて積む線の素材。**値だけで自己完結する** — 組むのに Canvas の状態を読まない。
///
/// ``StrokeCarving`` が片 (凸多角形)・線に沿った位置・太さ・基本図形かを持つので、ここへ足すのは
/// 頂点にするための値 (記録のときの変換・色・読み取り位置・周の置き場所のずれ) だけである。
struct CarveRecipe {
    let carving: StrokeCarving
    /// ずらす前の周で引いた結果へ足す、置き場所のずれ (``Outline/unmoved``)。
    let offset: SIMD2<Float>
    /// 記録のときの変換。引いた結果の点へ掛ける。**半画素寄せは掛けない** (置くときに掛かる)。
    let transform: Transform
    let color: LinearRGBA
    let uv: SIMD2<Float>

    /// 引いて、三角形の頂点にする。重ねて積むときと同じ座標系・同じ色。
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

/// 引いて積んだ頂点。**最初に要るとき (半透明の色を掛けて置くとき) に組み、形の側に控える。**
///
/// 参照の箱にしてあるのは、形 (値型) を写しても、組み上がった頂点を共有するため。組 (`group`) や
/// 入れ子で区間を繋いでも、同じ輪郭は 1 度しか引かれない。
final class CarvedStroke {
    private enum Source {
        case recipe(CarveRecipe)
        /// 入れ子: 別の保持した形の中で置かれた輪郭。もとの頂点へ、置いたときの行列と色を掛ける。
        case moved(CarvedStroke, simd_float4x4, LinearRGBA?)
    }

    private let source: Source
    private var cache: [ShapeVertex]?

    init(recipe: CarveRecipe) { source = .recipe(recipe) }

    init(moving base: CarvedStroke, by matrix: simd_float4x4, tint: LinearRGBA?) {
        source = .moved(base, matrix, tint)
    }

    var vertices: [ShapeVertex] {
        if let cache { return cache }
        let built: [ShapeVertex]
        switch source {
        case .recipe(let recipe): built = recipe.vertices()
        case .moved(let base, let matrix, let tint):
            built = Canvas.moved(base.vertices, by: matrix, tint: tint)
        }
        cache = built
        return built
    }

    /// 組み終えているか (計測用)。
    var isRealized: Bool { cache != nil }

    /// 抱えている量 (バイト・計測用)。素材と、組み終えていれば頂点。
    var residentBytes: Int {
        var bytes = (cache?.capacity ?? 0) * MemoryLayout<ShapeVertex>.stride
        switch source {
        case .recipe(let recipe): bytes += recipe.carving.residentBytes
        case .moved(let base, _, _): bytes += base.residentBytes
        }
        return bytes
    }
}
