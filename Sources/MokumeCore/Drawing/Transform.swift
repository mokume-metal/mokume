// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 座標変換。
///
/// 平行移動・回転・拡大縮小を 1 つの行列にまとめて持つ。図形の頂点はこれを掛けてから
/// 描画先の座標へ落ちる。
///
/// 掛ける向きは「あとから指定した変換ほど図形に近い」— `translate` してから `rotate`
/// すると、移動した先を中心に回る。順序を逆にすると原点で回してから移動することになり、
/// 見える結果がまったく変わる。
///
/// ## 平面と立体で同じものを使う
///
/// 行列は 4x4 で、**平面の図形も立体も同じ状態を通る** ([ADR-0020] 決定 3)。平面の
/// 頂点は奥行き 0 として落ちるので、平面だけの操作 (`translate(x:y:)`・`rotate(by:)`・
/// `scale(x:y:)`・`shearX`・`shearY`) の結果は、奥行きを持たない行列で計算したときと
/// **1 ビットも変わらない** — 掛かる余分な項が厳密に 0 だからである。
///
/// 立体の操作 (`rotateX` など) を挟んだあとの平面の図形は、**遠近の掛からない形**で
/// 落ちる。平面は奥行きを持たない挿入レイヤーだからで、この扱いは [ADR-0021] 決定 2
/// が定める。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
public struct Transform: Equatable, Sendable {
    /// 同次座標の 4x4 行列。4 行目は変換を重ねる限り常に (0, 0, 0, 1)。
    private(set) var matrix: simd_float4x4

    /// 何も変換しない状態。
    public static let identity = Transform(matrix: matrix_identity_float4x4)

    init(matrix: simd_float4x4) {
        self.matrix = matrix
    }

    /// 点をこの変換で移す (奥行き 0 の面の上の点として)。
    public func apply(x: Float, y: Float) -> SIMD2<Float> {
        let moved = matrix * SIMD4<Float>(x, y, 0, 1)
        return SIMD2<Float>(moved.x, moved.y)
    }

    /// 奥行きを持つ点をこの変換で移す。
    public func apply(x: Float, y: Float, z: Float) -> SIMD3<Float> {
        let moved = matrix * SIMD4<Float>(x, y, z, 1)
        return SIMD3<Float>(moved.x, moved.y, moved.z)
    }

    /// 面の向きをこの変換で移す行列。
    ///
    /// 位置と同じ行列では移せない — 軸ごとに違う倍率を掛けると、面の向きは面に
    /// 垂直でなくなる。左上 3x3 の逆転置がその補正で、潰れた変換のときは
    /// 補正のしようが無いので左上 3x3 をそのまま返す。
    var normalMatrix: simd_float3x3 {
        let upper = simd_float3x3(
            SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
            SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
            SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
        let determinant = upper.determinant
        guard determinant.isFinite, abs(determinant) > .ulpOfOne else { return upper }
        return upper.inverse.transpose
    }

    // MARK: - 積み重ね

    /// 平行移動を後から重ねる。
    public mutating func translate(x: Float, y: Float) {
        translate(x: x, y: y, z: 0)
    }

    /// 奥行きを含む平行移動を後から重ねる。
    public mutating func translate(x: Float, y: Float, z: Float) {
        matrix = matrix * Self.translation(x: x, y: y, z: z)
    }

    /// 回転を後から重ねる (奥行きの軸まわり)。
    ///
    /// 縦軸が下向きなので、正の角度は画面の上で時計回りに見える。
    public mutating func rotate(by radians: Float) {
        matrix = matrix * Self.rotationZ(radians)
    }

    /// 横軸まわりの回転を後から重ねる。
    public mutating func rotateX(by radians: Float) {
        matrix = matrix * Self.rotationX(radians)
    }

    /// 縦軸まわりの回転を後から重ねる。
    public mutating func rotateY(by radians: Float) {
        matrix = matrix * Self.rotationY(radians)
    }

    /// 奥行きの軸まわりの回転を後から重ねる (``rotate(by:)`` と同じ)。
    public mutating func rotateZ(by radians: Float) {
        rotate(by: radians)
    }

    /// 拡大縮小を後から重ねる。
    public mutating func scale(x: Float, y: Float) {
        scale(x: x, y: y, z: 1)
    }

    /// 奥行きを含む拡大縮小を後から重ねる。
    public mutating func scale(x: Float, y: Float, z: Float) {
        matrix = matrix * Self.scaling(x: x, y: y, z: z)
    }

    /// 斜めに歪める (横方向) を後から重ねる。
    public mutating func shearX(by radians: Float) {
        matrix = matrix * Self.shearing(x: tan(radians), y: 0)
    }

    /// 斜めに歪める (縦方向) を後から重ねる。
    public mutating func shearY(by radians: Float) {
        matrix = matrix * Self.shearing(x: 0, y: tan(radians))
    }

    /// 与えた変換を後から重ねる。
    public mutating func concatenate(_ other: Transform) {
        matrix = matrix * other.matrix
    }

    /// 何も変換しない状態へ戻す。
    public mutating func reset() {
        matrix = matrix_identity_float4x4
    }

    /// この変換を打ち消す変換。
    ///
    /// 潰れた変換 (どこかの軸を 0 倍にしたもの) には打ち消しが無いので `nil` を返す。
    /// 公開していないのは、いま必要としているのが検査だけだからである — 窓から届く
    /// 座標を図形の座標へ移す用途が出たら、その形に合わせて公開を考える。
    var inverted: Transform? {
        let determinant = matrix.determinant
        guard determinant.isFinite, abs(determinant) > .ulpOfOne else { return nil }
        return Transform(matrix: matrix.inverse)
    }

    // MARK: - 部品

    static func shearing(x: Float, y: Float) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(1, y, 0, 0),
            SIMD4<Float>(x, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1))
    }

    static func translation(x: Float, y: Float, z: Float) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(x, y, z, 1))
    }

    static func rotationZ(_ radians: Float) -> simd_float4x4 {
        let c = cos(radians)
        let s = sin(radians)
        return simd_float4x4(
            SIMD4<Float>(c, s, 0, 0),
            SIMD4<Float>(-s, c, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1))
    }

    static func rotationX(_ radians: Float) -> simd_float4x4 {
        let c = cos(radians)
        let s = sin(radians)
        return simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1))
    }

    static func rotationY(_ radians: Float) -> simd_float4x4 {
        let c = cos(radians)
        let s = sin(radians)
        return simd_float4x4(
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1))
    }

    static func scaling(x: Float, y: Float, z: Float) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, 0),
            SIMD4<Float>(0, 0, 0, 1))
    }
}
