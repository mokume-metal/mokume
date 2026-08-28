// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 同じ形を置く 1 か所ぶん。
///
/// 置き場所を配列で渡すと、形の頂点は 1 度しか置かれず、**置き場所の数だけ描き足す**
/// 形になる。同じことを `push()` / `translate()` / `pop()` の繰り返しで書いても
/// **絵は 1 ビットも変わらない** — 経路が 1 本しかないためである。
///
/// ```swift
/// let leaf = createShape { box(6) }
/// var places: [Placement] = []
/// for _ in 0..<5000 {
///     places.append(Placement(x: .random(in: 0...width), y: .random(in: 0...height)))
/// }
/// shape(leaf, at: places)
/// ```
public struct Placement: Equatable, Sendable {
    /// 置く位置。
    public var x: Float
    public var y: Float
    public var z: Float
    /// 大きさの倍率。
    public var scale: Float
    /// 各軸まわりの回転 (ラジアン)。**横 → 縦 → 奥行き**の順に掛かる。
    public var rotation: SIMD3<Float>
    /// この置き場所の塗り。`nil` なら置いた時点の塗りで出る。
    public var fill: LinearRGBA?

    public init(
        x: Float = 0, y: Float = 0, z: Float = 0, scale: Float = 1,
        rotation: SIMD3<Float> = .zero, fill: LinearRGBA? = nil
    ) {
        self.x = x
        self.y = y
        self.z = z
        self.scale = scale
        self.rotation = rotation
        self.fill = fill
    }

    /// 置き場所を変換として組み立てる。
    ///
    /// 順序は**大きさ → 回転 → 位置**。`push()` / `translate()` / `rotateX()` /
    /// `scale()` を同じ順で書いたときと同じ行列になる。
    var transform: Transform {
        var built = Transform.identity
        built.translate(x: x, y: y, z: z)
        if rotation.x != 0 { built.rotateX(by: rotation.x) }
        if rotation.y != 0 { built.rotateY(by: rotation.y) }
        if rotation.z != 0 { built.rotateZ(by: rotation.z) }
        if scale != 1 { built.scale(x: scale, y: scale, z: scale) }
        return built
    }

    /// 置ける値か。数でない値・無限を含む置き場所は置かない。
    var isUsable: Bool {
        [x, y, z, scale, rotation.x, rotation.y, rotation.z].allSatisfy(\.isFinite)
    }
}
