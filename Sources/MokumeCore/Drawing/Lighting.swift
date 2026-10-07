// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// この列に効く光が、置き場のどこから何個あるか。と、どこから見ているか。と、どの揺らぎで引くか。
///
/// 並びは `Drawing/Shaders/Common.metal` の同名の構造体と一致していなければならない
/// (``ShapeVertex`` と同じ理由で、`ShaderInterfaceTests` が反射と突き合わせる)。
///
/// **断片が列ごとに読む値の入れ物である。** 揺らぎの設定がここに居るのは光と関係があるからではなく、
/// 列ごとに断片へ届く値の置き場がこれだからで、口 (束ねる番号) を 1 つ増やさないためである ([#1855])。
///
/// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
struct Lighting {
    /// 置いた光の並び (``Light``) の、この列が読み始める位置。
    var offset: UInt32
    /// この列が読む光の数。
    var count: UInt32
    /// 16 バイト境界へ揃えるための詰め物。
    var padding: SIMD2<Float> = .zero
    /// 見ている場所。`w` が 1 なら xyz は**視点の位置** (透視)、0 なら xyz は
    /// **見ている側へ向かう一定の向き** (平行)。
    var viewer: SIMD4<Float>
    /// 世界をカメラの側へ移す行列 (``Camera/viewMatrix``)。
    ///
    /// 断片はこれで世界の向きを**視点から見た向き**へ移す (`Fragment` の `viewNormal`・
    /// [#847](https://github.com/mokume-metal/mokume/issues/847))。頂点段を通さず
    /// ここに置くのは、断片が読む「どこから見ているか」が既にこの構造体だからである。
    var view: simd_float4x4
    /// この列を引く揺らぎの種。**列が閉じた時点の設定**が入る (``Canvas/Batch/noise``・[#1855])。
    /// 整数のまま送る (`Float` を経由すると大きな種で丸めが起きる)。
    ///
    /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
    var noiseSeed: UInt32
    /// 重ねる枚数。
    var noiseOctaves: UInt32
    /// 1 枚ごとの弱まり。
    var noiseFalloff: Float
    /// 16 バイト境界へ揃えるための詰め物。
    var noisePadding: Float = 0
}
