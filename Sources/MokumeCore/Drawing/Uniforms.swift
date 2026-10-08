// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// フレームを通して変わらない値 (時刻・面の大きさ・影)。
///
/// 並びは `Drawing/Shaders/Common.metal` の同名の構造体と一致していなければならない
/// (``ShapeVertex`` と同じ理由で、`ShaderInterfaceTests` が反射と突き合わせる)。
///
/// **揺らぎの設定はここに置かない** ([#1855])。描き切り 1 回に 1 つの値だと、置いた後に書き換えた
/// 設定で置いた図形まで引かれる (#1503 の約束が破れる) ので、書き換えるたびに面を描き切っていた。
/// 列が閉じた時点の値を列ごとに持たせる (``Lighting``)。
///
/// **置き場所は断片側の詰め方で決まる。** `resolution` は 8 バイト境界へ揃うので時刻の
/// 後ろに 4 バイト、4x4 の行列は 16 バイト境界へ揃うので縁の余裕の後ろに 12 バイトの
/// 詰め物が入る。Swift の `SIMD2<Float>` と `simd_float4x4` も同じ境界へ揃うので、
/// 欄を同じ順に並べれば詰め物の位置も一致する。
///
/// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
struct Uniforms {
    /// 走り出してからの秒数。
    var time: Float
    /// **出す画素**での面の大きさ。断片が受け取る位置 (`position`) も出す画素で渡す
    /// ([#1639])。割って出す 0…1 の位置がここと食い違うと面からはみ出す。
    ///
    /// [#1639]: https://github.com/mokume-metal/mokume/issues/1639
    var resolution: SIMD2<Float>
    /// 影の縁の破綻を抑える量。
    var shadowBias: Float
    /// 世界の座標を、光から見た切り取りの立方体へ落とす行列。
    var shadowMatrix: simd_float4x4
    /// x が 1 なら影が焼いてある。y は焼き付け先の 1 画素の大きさ (0…1 の尺度)。
    var shadowParams: SIMD4<Float>
    /// 描く画素 1 つが出す画素でいくらか (``Canvas/unitsPerDrawnPixel``)。断片はラスタの位置
    /// (描く画素) にこれを掛けて、出す画素の位置として渡す ([#1639])。**細かさ 1 ではちょうど 1**
    /// なので、位置は 1 ビットも変わらない。
    ///
    /// [#1639]: https://github.com/mokume-metal/mokume/issues/1639
    var unitsPerDrawnPixel: SIMD2<Float>
    /// 16 バイト境界へ揃えるための詰め物。
    var unitsPadding: SIMD2<Float> = .zero
}
