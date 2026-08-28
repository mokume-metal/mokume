// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 置いた光 1 つぶん。
///
/// 並びは `Drawing/Shaders/Common.metal` の同名の構造体と一致していなければならない
/// (``ShapeVertex`` と同じ理由で、大きさを ``expectedStride`` として持つ)。
///
/// ## 明るさの単位
///
/// **色そのものが線形の明るさの倍率である。** 強さを表す数を別に持たない — 拡散の
/// 式が変われば同じ数が違う明るさになるので、**式によって意味が変わる数**を利用者へ
/// 渡さないためである。`1.0` は「その光を正面から受けた白い面が白として出る」明るさで、
/// それより明るい光は 1 を超える色で書く (作業空間は 1.0 超を切り捨てない・[ADR-0011] 決定 1)。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
struct Light {
    /// 光の種類。数はシェーダ側の定数と対応する。
    enum Kind: UInt32 {
        /// 全体を底上げする光。向きを持たない。
        case ambient = 0
        /// 向きだけを持つ光 (無限に遠い光源)。
        case directional = 1
        /// 位置を持つ光。
        case point = 2
        /// 位置と向きと広がりを持つ光。
        case spot = 3
    }

    /// 色 (線形・明るさの倍率) と、種類。
    var colorAndKind: SIMD4<Float>
    /// 世界の座標での位置 (点光源とスポット)。
    var position: SIMD4<Float>
    /// 光が**進む向き**と、広がりの外側の余弦 (スポット)。
    var directionAndCone: SIMD4<Float>

    /// シェーダ側の構造体と一致すべき大きさ (バイト)。
    static let expectedStride = 48

    init(
        kind: Kind, color: LinearRGBA, position: SIMD3<Float> = .zero,
        direction: SIMD3<Float> = SIMD3(0, 1, 0), coneCosine: Float = -1
    ) {
        // 光は面へ足すものなので、アルファは持ち込まない (乗算済みの成分をそのまま使う)
        colorAndKind = SIMD4(color.red, color.green, color.blue, Float(kind.rawValue))
        self.position = SIMD4(position, 0)
        directionAndCone = SIMD4(direction, coneCosine)
    }
}
