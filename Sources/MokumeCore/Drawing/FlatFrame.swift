// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 列ごとに変わらないもの (描画先へ落とす行列と、輪郭の頂点が始まる番号)。
///
/// 並びは `Drawing/Shaders/Shapes.metal` の同名の構造体と一致していなければならない
/// (``ShapeVertex`` と同じ理由で、`ShaderInterfaceTests` が反射と突き合わせる)。
///
/// **立体は先頭の行列だけを読む** (`solidVertexMain` の `viewProjection`)。後ろに欄を
/// 足しても立体には効かない。
struct FlatFrame {
    /// 描画先の座標へ落とす行列。**列が閉じた時点の見る位置**がそのまま入る。
    var projection: simd_float4x4
    /// 輪郭の頂点が始まる番号。**ここから後ろが輪郭**で、手前が塗りである。
    var strokeStart: UInt32
}
