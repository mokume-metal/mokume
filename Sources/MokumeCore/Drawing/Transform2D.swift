// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 2D の座標変換。
///
/// 平行移動・回転・拡大縮小を 1 つの行列にまとめて持つ。図形の頂点はこれを掛けてから
/// 描画先の座標へ落ちる。
///
/// 掛ける向きは「あとから指定した変換ほど図形に近い」— `translate` してから `rotate`
/// すると、移動した先を中心に回る。順序を逆にすると原点で回してから移動することになり、
/// 見える結果がまったく変わる。
public struct Transform2D: Equatable, Sendable {
    /// 同次座標の 3x3 行列。3 行目は常に (0, 0, 1)。
    private(set) var matrix: simd_float3x3

    /// 何も変換しない状態。
    public static let identity = Transform2D(matrix: matrix_identity_float3x3)

    init(matrix: simd_float3x3) {
        self.matrix = matrix
    }

    /// 点をこの変換で移す。
    public func apply(x: Float, y: Float) -> SIMD2<Float> {
        let moved = matrix * SIMD3<Float>(x, y, 1)
        return SIMD2<Float>(moved.x, moved.y)
    }

    // MARK: - 積み重ね

    /// 平行移動を後から重ねる。
    public mutating func translate(x: Float, y: Float) {
        matrix = matrix * Self.translation(x: x, y: y)
    }

    /// 回転を後から重ねる。
    ///
    /// 縦軸が下向きなので、正の角度は画面の上で時計回りに見える。
    public mutating func rotate(by radians: Float) {
        matrix = matrix * Self.rotation(radians)
    }

    /// 拡大縮小を後から重ねる。
    public mutating func scale(x: Float, y: Float) {
        matrix = matrix * Self.scaling(x: x, y: y)
    }

    // MARK: - 部品

    static func translation(x: Float, y: Float) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(x, y, 1))
    }

    static func rotation(_ radians: Float) -> simd_float3x3 {
        let c = cos(radians)
        let s = sin(radians)
        return simd_float3x3(
            SIMD3<Float>(c, s, 0),
            SIMD3<Float>(-s, c, 0),
            SIMD3<Float>(0, 0, 1))
    }

    static func scaling(x: Float, y: Float) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(x, 0, 0),
            SIMD3<Float>(0, y, 0),
            SIMD3<Float>(0, 0, 1))
    }
}
