// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 列ごとに変わらないもの (描画先へ落とす行列・輪郭の頂点が始まる番号・立体の輪郭の寄せ)。
///
/// 並びは `Drawing/Shaders/Shapes.metal` の同名の構造体と一致していなければならない
/// (``ShapeVertex`` と同じ理由で、`ShaderInterfaceTests` が反射と突き合わせる)。
///
/// **平面と立体で読む欄が違う。** 平面は行列と番号を、立体は行列と寄せを読む。影の
/// 焼き付けも立体の頂点関数を通るので、寄せ 0 の値を書く。
struct FlatFrame {
    /// 描画先の座標へ落とす行列。**列が閉じた時点の見る位置**がそのまま入る。
    var projection: simd_float4x4
    /// 輪郭の頂点が始まる番号。**ここから後ろが輪郭**で、手前が塗りである。
    ///
    /// 色を塗り分けるのに加えて、**畳んだ雛形の輪郭を画面で半画素寄せる**のにも使う
    /// ([ADR-0039] 決定 2)。畳めない列は `UInt32.max` で、寄せは CPU の側で済んでいる。
    ///
    /// [ADR-0039]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0039-pixel-grid-and-edge-antialiasing.md
    var strokeStart: UInt32
    /// 立体の輪郭の頂点を画面で寄せる量 (切り取り座標。`Canvas.solidStrokeShift`)。
    var strokeShift: SIMD4<Float>
}
