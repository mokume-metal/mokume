// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 同じ形を置く 1 か所ぶん。
///
/// **形の頂点は 1 組しか持たない。** 同じ形を 1 万個置いても、置き場へ載るのは頂点
/// 1 組と、ここに並ぶ 1 万個の「どこへ・どの色で」だけになる。頂点を置き場所の数だけ
/// 展開すると、球 1 万個で数十万の頂点になり、確保だけで 1 フレームが終わる。
///
/// 並びは `Drawing/Shaders/Shapes.metal` の同名の構造体と一致していなければならない
/// (``ShapeVertex`` と同じ理由で、大きさを ``expectedStride`` として持つ)。
struct SolidInstance {
    /// 形自身の座標を世界の座標へ移す行列。
    var matrix: simd_float4x4
    /// 面の向きを移す行列の 1 列目 (3x3 を 3 本の 4 成分で持つ)。
    ///
    /// **位置と同じ行列では移せない。** 軸ごとに違う倍率を掛けると、向きは逆向きに
    /// 効くためである (``Transform/normalMatrix``)。
    var normal0: SIMD4<Float>
    /// 面の向きを移す行列の 2 列目。
    var normal1: SIMD4<Float>
    /// 面の向きを移す行列の 3 列目。
    var normal2: SIMD4<Float>
    /// この置き場所の塗り。**頂点の色に掛かる。**
    ///
    /// 組み込みの形は頂点を白で持つので、掛けるとこの色になる。頂点ごとに色を
    /// 変えた形は白い置き場所を通るので、頂点の色がそのまま残る。**どちらも掛け算
    /// 1 本で通る**ので、色のために経路が 2 本に割れない。
    var color: SIMD4<Float>

    /// シェーダ側の構造体と一致すべき大きさ (バイト)。
    static let expectedStride = 128

    init(matrix: simd_float4x4, normalMatrix: simd_float3x3, color: LinearRGBA) {
        self.matrix = matrix
        normal0 = SIMD4(normalMatrix.columns.0, 0)
        normal1 = SIMD4(normalMatrix.columns.1, 0)
        normal2 = SIMD4(normalMatrix.columns.2, 0)
        self.color = SIMD4(color.red, color.green, color.blue, color.alpha)
    }

    /// 何も動かさない置き場所。
    ///
    /// **単位行列を掛けても値は 1 ビットも変わらない** (0 を掛けて足すだけなので)。
    /// だから、その場で並べた頂点・線と点・背景をこの置き場所へ通しても、絵は
    /// まったく変わらない — 経路を 2 本に割らずに済む。
    static let identity = SolidInstance(
        matrix: matrix_identity_float4x4,
        normalMatrix: matrix_identity_float3x3,
        color: LinearRGBA(premultipliedRed: 1, green: 1, blue: 1, alpha: 1))
}
