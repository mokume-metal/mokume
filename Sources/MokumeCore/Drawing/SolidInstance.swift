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
/// (``ShapeVertex`` と同じ理由で、`ShaderInterfaceTests` が反射と突き合わせる)。
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

    init(matrix: simd_float4x4, normalMatrix: simd_float3x3, color: LinearRGBA) {
        self.matrix = matrix
        normal0 = SIMD4(normalMatrix.columns.0, 0)
        normal1 = SIMD4(normalMatrix.columns.1, 0)
        normal2 = SIMD4(normalMatrix.columns.2, 0)
        self.color = SIMD4(color.red, color.green, color.blue, color.alpha)
    }

    /// この置き場所へ置いた頂点を、**頂点関数より先に CPU で**作る。
    ///
    /// 保持する形を記録している間は、置き場所を持ち歩けない — 記録するのは頂点と区間
    /// だけである (``Canvas/recordingShape``)。そこで置き場所の変換と色を頂点へ焼き、
    /// 何も動かさない置き場所で描く ([#1297])。
    ///
    /// **頂点関数 (`solidVertexMain`) が置き場所に対して行う計算と同じ式にする** — 位置と
    /// 向きに行列を掛け、色を掛ける。向きは揃え直さない (揃えるのは断片の側で、置いてから
    /// 描いたときと同じ値を渡すため)。**形自身の座標と向きは触らない** — 利用者の断片へ
    /// 渡すのはそちらで、置き場所を通していない値である (#367)。
    ///
    /// [#1297]: https://github.com/mokume-metal/mokume/issues/1297
    func placing(_ vertex: SolidVertex) -> SolidVertex {
        var placed = vertex
        let world = matrix * SIMD4(vertex.position, 1)
        placed.position = SIMD3(world.x, world.y, world.z)
        func upper(_ column: SIMD4<Float>) -> SIMD3<Float> { SIMD3(column.x, column.y, column.z) }
        let normalMatrix = simd_float3x3(upper(normal0), upper(normal1), upper(normal2))
        let normal = upper(vertex.normal)
        // `w` は「形から求めた向きか」の印で、向きではない (``SolidVertex/normal``)
        placed.normal = SIMD4(normalMatrix * normal, vertex.normal.w)
        placed.color = vertex.color * color
        return placed
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
