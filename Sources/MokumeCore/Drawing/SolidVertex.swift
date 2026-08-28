// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 立体を組み立てる頂点。
///
/// 並びは `Drawing/Shaders/Solids.metal` の同名の構造体と一致していなければならない。
/// 食い違うと絵が壊れるだけで、コンパイルは通ってしまう — ずれを起動時に見つけられる
/// よう、大きさを ``expectedStride`` として持ち、検査で突き合わせる
/// (``ShapeVertex`` と同じ理由・同じ手当て)。
struct SolidVertex {
    /// 描画先の座標 (変換を適用済み・奥行きを持つ)。
    var position: SIMD3<Float>
    /// 面の向き (変換を適用済み) と、**その向きを形から求めたか**。
    ///
    /// `xyz` が向き、`w` が 1 なら形から求めた向きである。求めた向きは、その面が
    /// 裏を向いていれば見えている側へ裏返して光を当てる (両面) — 頂点を並べる向き
    /// (巻き方) で絵が真っ黒になるのを避けるためである。`w` が 0 なら**書かれた
    /// 向き**なので、裏返さずそのまま使う。書いた指定が黙って覆されない。
    ///
    /// 長さを持たない向き (ゼロ) は「光を受けない」という意味で、立体の線と点が
    /// これに当たる。
    var normal: SIMD4<Float>
    /// 字形を焼いた面の中で、どこを読むか。
    ///
    /// 立体は面の**白い区画**を指す — 白を掛けても色は変わらないので、平面と同じ
    /// 塗りをそのまま通せる (``GlyphAtlas``)。
    var uv: SIMD2<Float>
    /// 色 — 線形・アルファ乗算済み ([ADR-0011] 決定 4)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    var color: SIMD4<Float>

    /// シェーダ側の構造体と一致すべき大きさ (バイト)。
    ///
    /// `float3` は 16 バイト境界に揃うので位置と向きで 32 バイト、読み取り位置が
    /// 8 バイト、色が 16 バイト境界へ揃うため 8 バイトの詰め物が入って 64 バイトになる。
    /// (向きの 4 つ目の成分は、`float3` に元から入っていた詰め物に収まる。)
    static let expectedStride = 64

    init(
        position: SIMD3<Float>, normal: SIMD3<Float>, isDerived: Bool = false,
        uv: SIMD2<Float>, color: LinearRGBA
    ) {
        self.position = position
        self.normal = SIMD4<Float>(normal, isDerived ? 1 : 0)
        self.uv = uv
        self.color = SIMD4<Float>(color.red, color.green, color.blue, color.alpha)
    }
}
