// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 図形を組み立てる頂点。
///
/// 並びは `Drawing/Shaders/Shapes.metal` の同名の構造体と一致していなければならない。
/// 食い違うと絵が壊れるだけで、コンパイルは通ってしまう — ずれを起動時に見つけられる
/// よう、大きさを ``expectedStride`` として持ち、検査で突き合わせる。
struct ShapeVertex {
    /// 描画先の座標 (変換を適用済み)。
    var position: SIMD2<Float>
    /// 色 — 線形・アルファ乗算済み ([ADR-0011] 決定 4)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    var color: SIMD4<Float>

    /// シェーダ側の構造体と一致すべき大きさ (バイト)。
    ///
    /// `float2` は 8 バイト境界に、`float4` は 16 バイト境界に揃うので、
    /// 位置の後ろに 8 バイトの詰め物が入り、全体で 32 バイトになる。
    static let expectedStride = 32

    init(position: SIMD2<Float>, color: LinearRGBA) {
        self.position = position
        self.color = SIMD4<Float>(color.red, color.green, color.blue, color.alpha)
    }
}
