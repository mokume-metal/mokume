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
    /// ([#1488])。座標と太さは出す画素で書かれ、描く画素への縮みは投影と見るウィンドウが持つので、
    /// この比を渡さないと、細かさを下げた面で縁の渡しが描く画素の一部に縮む。
    ///
    /// [#1488]: https://github.com/mokume-metal/mokume/issues/1488
    var unitsPerDrawnPixel: SIMD2<Float>
    /// 平面の頂点ごとの被覆 (``Canvas/coverageSpans``) を読むか。1 なら読み、0 なら 1 とする
    /// (#1637)。細い線を広げた頂点が無いフレームは 0 で、頂点関数は被覆の並びに触れない。
    var readsCoverage: UInt32 = 0
    /// 塗りの頂点を、置き場所ごとの記述 (``Canvas/ThinFillRecord``) から頂点段で広げるか。0 は広げない。
    /// 1 なら、輪郭の手前の頂点 (`strokeStart` より前) の `position` は「片の番号と角の番号」で、
    /// 片を頂点段が組む (#2208)。
    var thinFill: UInt32 = 0
    /// 塗りの頂点 (`strokeStart` より前) の読み取り位置を、``fillBox`` の箱から置き場所ごとに作るか (#3555)。
    /// 貼る絵のある雛形が 1 にする。0 は頂点の `uv` のまま。
    ///
    /// 畳まずに置くときは、置き場所ぶんずらした周の囲みの箱から読み取り位置を作る (``Canvas/boxUV(of:)``)。
    /// 雛形はずらす前の周で積むので、箱の幅の丸めが置き場所ごとに違いうる — 頂点段が位置を足した箱から
    /// 同じ順で作り直す。
    var fillUVFromBox: UInt32 = 0
    /// 塗りの貼る絵の読み取り位置を作る箱 (xy が下限・zw が上限。置き場所の位置を足す前の周の囲み)。
    /// ``fillUVFromBox`` が 1 のときだけ読む。
    var fillBox = SIMD4<Float>(repeating: 0)
    /// 畳んだ矩形の雛形の細い輪郭を、頂点段で置き場所ごとに広げるか (``Canvas/ThinFold/widensInVertexStage``・#3733)。
    /// 1 なら、`strokeStart` から後ろの頂点の `position` は額縁の片の角 (形自身の座標・置き場所の位置を足す前)、
    /// `uv` は角から広げる向き (各成分 −1・0・1) で、頂点段が置き場所の 2x2 から半幅と被覆を
    /// ``Canvas/thinRectFrame(_:placedBy:)`` と同じ式で求め、`(角 + 位置) + 半幅 × 向き` に置く (#3555)。0 は広げない。
    var thinStroke: UInt32 = 0
    /// x: 線の太さ (形自身の座標)・y: 1 に丸める描く画素の太さの下限 (``Canvas/roundedDrawnWeight(_:)``)・
    /// zw: 白い区画の読み取り位置 (輪郭の頂点の `uv` の代わりに断片へ渡す)。`thinStroke` が 1 のときだけ読む。
    var thinStrokeParams = SIMD4<Float>(repeating: 0)
}
