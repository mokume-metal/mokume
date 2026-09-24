// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 列ごとに変わらないもの (描画先へ落とす行列・輪郭の頂点が始まる番号・立体の輪郭の寄せ)。
///
/// 並びは `Drawing/Shaders/Shapes.metal` の同名の構造体と一致していなければならない
/// (``ShapeVertex`` と同じ理由で、`ShaderInterfaceTests` が反射と突き合わせる)。
///
/// **平面と立体で読む欄が違う。** 平面は行列と番号を、立体は行列と寄せを、基本図形は
/// 行列と描く画素の大きさを読む。影の焼き付けも立体の頂点関数を通るので、寄せ 0 の値を書く。
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
    /// 描く画素 1 つが描画先の座標でいくらか (x, y)。**細かさ 1 ならちょうど 1。**
    ///
    /// 基本図形の頂点関数 (`formVertexMain`) が、縁の被覆を描く画素で測るために読む
    /// ([#1488])。座標と太さは出す画素で書かれ、描く画素への縮みは投影と見る窓が持つので、
    /// この比を渡さないと、細かさを下げた面で縁の渡しが描く画素の一部に縮む。
    ///
    /// [#1488]: https://github.com/mokume-metal/mokume/issues/1488
    var unitsPerDrawnPixel: SIMD2<Float>
}
