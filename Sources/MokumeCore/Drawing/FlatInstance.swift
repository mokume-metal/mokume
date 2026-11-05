// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 平面の図形を置く 1 か所ぶん。
///
/// **形の頂点は 1 組しか持たない。** 同じ円を 1 万個置いても、置き場へ載るのは形自身の
/// 座標で組み立てた頂点 1 組と、ここに並ぶ 1 万個の「どこへ・どの色で」だけになる。
/// 円は半径ごとに数十の頂点へ展開されるので、置き場所の数だけ展開すると**組み立てだけで
/// フレームが終わる** (#424)。
///
/// 立体の ``SolidInstance`` と役割は同じだが、持つものが違う。平面は光を受けず面の向きも
/// 持たないので変換は 2x2 で足り、代わりに**色を 2 つ**持つ — 平面の図形は塗りと輪郭を
/// 1 つの雛形に含むためである (どちらを掛けるかは頂点の番号が決める。`Shapes.metal` の
/// `shapeVertexMain` を参照)。
///
/// 並びは `Drawing/Shaders/Shapes.metal` の同名の構造体と一致していなければならない
/// (``ShapeVertex`` と同じ理由で、`ShaderInterfaceTests` が反射と突き合わせる)。
struct FlatInstance {
    /// 形自身の座標を描画先の座標へ移す 2x2 (列 2 本を 4 成分に並べて持つ)。
    ///
    /// **輪郭の太さもここで拡大縮小される。** 帯は形自身の座標のまま雛形へ焼いてあり、
    /// 変換は最後に 1 度だけ掛かる — 畳まずに 1 つずつ置いたときとまったく同じ順序で
    /// ある (``Canvas/appendBand(_:_:half:)``)。
    var linear: SIMD4<Float>
    /// xy が置き場所の位置 (形自身の座標の原点を置く点)、zw が変換の平行移動 (#3555)。
    ///
    /// **位置は変換を掛ける前に足す。** 畳まずに置くときは、周を位置ぶんずらしてから
    /// (``Canvas/Outline/moved(by:)``) `Transform.placed` で移す。頂点段も同じ順 (位置を足す → 線形 →
    /// 平行移動) で置くので、畳んだ頂点は畳まずに置いた頂点と 1 ビットも違わない (`Shapes.metal` の
    /// `mokume_flatMove`・`mokume_flatPlace`)。位置を変換してから足す (`L·p + M·位置`) と、縁の頂点が
    /// 1 ulp 違い、縁の画素が畳むかどうかで入れ替わる。
    var offset: SIMD4<Float>
    /// この置き場所の塗り。**塗りの頂点の色に掛かる。**
    var fill: SIMD4<Float>
    /// この置き場所の輪郭。**輪郭の頂点の色に掛かる。**
    var stroke: SIMD4<Float>

    init(
        linear: SIMD4<Float>, anchor: SIMD2<Float>, translation: SIMD2<Float>, fill: LinearRGBA,
        stroke: LinearRGBA
    ) {
        self.linear = linear
        self.offset = SIMD4(anchor.x, anchor.y, translation.x, translation.y)
        self.fill = SIMD4(fill.red, fill.green, fill.blue, fill.alpha)
        self.stroke = SIMD4(stroke.red, stroke.green, stroke.blue, stroke.alpha)
    }

    /// 何も動かさない置き場所。
    ///
    /// **単位行列を掛けても、白を掛けても値は 1 ビットも変わらない。** だから字も画像も
    /// その場で並べた頂点も — 畳みようのないものすべてを — この置き場所へ通せる。
    /// 畳む経路と畳まない経路で頂点関数が 2 本に割れない (``SolidInstance/identity``)。
    static let identity = FlatInstance(
        linear: SIMD4(1, 0, 0, 1), anchor: SIMD2(0, 0), translation: SIMD2(0, 0),
        fill: LinearRGBA(premultipliedRed: 1, green: 1, blue: 1, alpha: 1),
        stroke: LinearRGBA(premultipliedRed: 1, green: 1, blue: 1, alpha: 1))
}
