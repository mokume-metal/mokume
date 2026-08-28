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
    /// 面の向き (変換を適用済み)。
    ///
    /// **いまの塗りはこれを読まない。** 形が持っている情報なので頂点に載せておき、
    /// 光を当てる段でそのまま使う。
    var normal: SIMD3<Float>
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
    static let expectedStride = 64

    init(position: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>, color: LinearRGBA) {
        self.position = position
        self.normal = normal
        self.uv = uv
        self.color = SIMD4<Float>(color.red, color.green, color.blue, color.alpha)
    }
}
