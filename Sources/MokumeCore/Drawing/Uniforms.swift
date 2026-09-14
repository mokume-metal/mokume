// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// フレームを通して変わらない値 (時刻・面の大きさ・影・揺らぎ)。
///
/// 並びは `Drawing/Shaders/Common.metal` の同名の構造体と一致していなければならない
/// (``ShapeVertex`` と同じ理由で、`ShaderInterfaceTests` が反射と突き合わせる)。
///
/// **置き場所は断片側の詰め方で決まる。** `resolution` は 8 バイト境界へ揃うので時刻の
/// 後ろに 4 バイト、4x4 の行列は 16 バイト境界へ揃うので縁の余裕の後ろに 12 バイトの
/// 詰め物が入る。Swift の `SIMD2<Float>` と `simd_float4x4` も同じ境界へ揃うので、
/// 欄を同じ順に並べれば詰め物の位置も一致する。
struct Uniforms {
    /// 走り出してからの秒数。
    var time: Float
    /// **実際に刻む画素**での面の大きさ。断片が受け取る位置 (`position`) がその数で
    /// 来るので、割って出す 0…1 の位置がここと食い違うと面からはみ出す。
    var resolution: SIMD2<Float>
    /// 影の縁の破綻を抑える量。
    var shadowBias: Float
    /// 世界の座標を、光から見た切り取りの立方体へ落とす行列。
    var shadowMatrix: simd_float4x4
    /// x が 1 なら影が焼いてある。y は焼き付け先の 1 画素の大きさ (0…1 の尺度)。
    var shadowParams: SIMD4<Float>
    /// 揺らぎの種。**整数のまま送る** (`Float` を経由すると大きな種で丸めが起きる)。
    var noiseSeed: UInt32
    /// 重ねる枚数。
    var noiseOctaves: UInt32
    /// 1 枚ごとの弱まり。
    var noiseFalloff: Float
    /// 16 バイト境界へ揃えるための詰め物。
    var noisePadding: Float = 0
}
