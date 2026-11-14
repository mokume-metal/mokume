// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 同じ形を置く 1 か所ぶん。
///
/// 置き場所を配列で渡すと、**置き場所の数だけ描き足す**形になる (描く回数は形で決まる —
/// ``SketchPart/shape(_:at:)``)。同じことを `push()` / `translate()` / `pop()` の繰り返しで書いても
/// **絵は 1 ビットも変わらない** — 経路が 1 本しかないためである。
///
/// ```swift
/// let leaf = createShape { box(6) }
/// var places: [Placement] = []
/// for _ in 0..<5000 {
///     places.append(Placement(x: random(width), y: random(height)))
/// }
/// shape(leaf, at: places)
/// ```
public struct Placement: Equatable, Sendable {
    /// 置く位置。
    public var x: Float
    public var y: Float
    public var z: Float
    /// 軸ごとの大きさの倍率。**既定は `Vector3(1, 1, 1)`** (どの軸も伸ばさない)。
    ///
    /// 高さだけ伸ばした箱 (棒グラフの街並み・音の柱) のように、軸ごとに大きさの違うものを
    /// まとめて置くのに使う。倍率は**形自身の軸**に掛かり、回転より先に効く (`transform` の順は
    /// 大きさ → 回転 → 位置) ので、回して置いた形も、回す前の軸に沿って伸びる。負の値は、その軸で
    /// 裏返す。軸のどれかが数でない値・無限の置き場所は置かれない (`shape(_:at:)` が 1 度だけ注意する)。
    ///
    /// どの軸にも同じ倍率なら、`init(x:y:z:scale:rotation:fill:)` に数を 1 つ渡す
    /// (`Placement(scale: 2)` は `Placement(scale: Vector3(2, 2, 2))` と等しい)。
    ///
    /// ```swift
    /// // 高さの違う 8 本の柱を、箱 1 つの形から置く
    /// background(23, 26, 31)
    /// lights()
    /// noStroke()
    /// fill(242, 115, 64)
    /// let unitBox = createShape { box(1) }
    /// var bars: [Placement] = []
    /// for i in 0..<8 {
    ///     let tall = 60 + Float(i) * 25
    ///     bars.append(Placement(x: 55 + Float(i) * 42, y: 280 - tall / 2, scale: Vector3(28, tall, 28)))
    /// }
    /// shape(unitBox, at: bars)
    /// ```
    public var scale: Vector3
    /// 各軸まわりの回転 (ラジアン)。**横 → 縦 → 奥行き**の順に掛かる。
    public var rotation: Vector3
    /// この置き場所の塗り。`nil` なら何も掛からず、記録した色のまま出る。
    ///
    /// 半透明の色を渡すと、不透明の線で記録した形の線も、直に半透明の線で描いたときと同じく、1 つの図形の
    /// 線全体を 1 回だけ混ぜる (`stroke(_:)` の説明・自己交差も 1 回・[#3580](https://github.com/mokume-metal/mokume/issues/3580))。
    ///
    /// **1 つの領域として引ける輪郭 (矩形・楕円・弧・辺の交差しない四角) を持つ形は、半透明の色で最初に置く
    /// フレームだけ、線の片の重なりを引く時間が余分にかかる。** 引いた結果は形に控えるので、同じ形を 2 回目
    /// 以降に置くときは余分にかからない。控えた結果は形が生きている間残り、重ねて積んだ頂点に加えて引いた頂点も
    /// 持つ。色を渡さない置き場所と不透明の色を渡す置き場所は引かないので、この費用を払わない。
    ///
    /// **ほかの輪郭は引かずに型板で 1 回にし、置いた図形 1 つにつき描く呼び出しが 2 本増える** (直に描く線と
    /// 同じ)。半透明の 4 点の折れ線を 2,000 個記録した形を半透明の色で置くと、1 フレームが約 2 ms 延びる
    /// (release・Apple M5。同じ 2,000 本を直に描くより軽い・ADR-0046 の段 6 の改訂)。
    public var fill: LinearRGBA?

    /// どの軸にも同じ倍率で作る。`scale` は 3 つの軸に同じ値で入る (``scale`` は `Vector3(scale, scale, scale)`)。
    ///
    /// 軸ごとに変えるなら `init(x:y:z:scale:rotation:fill:)` の `Vector3` を受ける側を使う。
    public init(
        x: Float = 0, y: Float = 0, z: Float = 0, scale: Float = 1,
        rotation: Vector3 = Vector3(0, 0, 0), fill: LinearRGBA? = nil
    ) {
        self.init(x: x, y: y, z: z, scale: Vector3(scale, scale, scale), rotation: rotation, fill: fill)
    }

    /// 軸ごとの倍率で作る。
    ///
    /// `Placement(x: 100, y: 200, scale: Vector3(1, 4, 1))` で置いた形は、`push()` のあとに
    /// `translate(100, 200, 0)`・`scale(1, 4, 1)` を同じ順で書いて置いたものと同じ絵になる。
    public init(
        x: Float = 0, y: Float = 0, z: Float = 0, scale: Vector3,
        rotation: Vector3 = Vector3(0, 0, 0), fill: LinearRGBA? = nil
    ) {
        self.x = x
        self.y = y
        self.z = z
        self.scale = scale
        self.rotation = rotation
        self.fill = fill
    }

    /// 計算が書いた数の並びを、置き場所としてどう読むか (``SketchPart/shape(_:at:layout:)``)。
    public enum Layout: Sendable, Hashable {
        /// 3 つで 1 か所: 位置の x・y・z。**3×N 個の並びが N か所になる。**
        ///
        /// 倍率・回転・塗りは付けられない (大きさ 1・回さず・形に焼いた色のまま)。数でない値・無限を含む 1 か所は
        /// 置かれず、ほかは並びの順に置かれる (``Placement`` の `x`・`y`・`z` のどれかが数でない値・無限の
        /// 置き場所が置かれないのと同じ)。
        case position
        /// 6 つで 1 か所: 位置の x・y・z と、進む向きの x・y・z。**6×N 個の並びが N か所になる。**
        ///
        /// 形の **+x 軸を進む向きへ向け**、形の +y 軸は画面の面 (x と y の面) に留める (形を進む向きの軸まわりに
        /// ひねらない)。方位の分だけ奥行きの軸まわりに回し (``SketchPart/rotateZ(_:)``)、続けて仰角の分だけ
        /// 縦軸まわりに回す (``SketchPart/rotateY(_:)``) のと同じで、進む向きが画面の面の中なら、奥行きの軸まわりの
        /// 回転 1 つになる (向きの 0 が +x (右)、π/2 が +y (下)。``Heading/plane(_:)`` と同じ)。真上・真下
        /// (奥行きの軸に沿う向き) では方位を 0 とする。
        ///
        /// 向きの長さは問わない (速度をそのまま渡せる)。**長さ 0 の向きは回さずに置く。** 倍率・塗りは付けられない。
        /// 位置か向きに数でない値・無限を含む 1 か所は置かれず、ほかは並びの順に置かれる。回転は鏡映を作らない。
        case positionAndHeading

        /// 1 か所が使う数の個数。
        var stride: Int {
            switch self {
            case .position: 3
            case .positionAndHeading: 6
            }
        }

        /// 計算の入口に渡す読み方の番号。`Particles.metal` の「数の並びを置き場所として読む」と同じ番号。
        var kernelCode: UInt32 {
            switch self {
            case .position: 0
            case .positionAndHeading: 1
            }
        }
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
        if scale.x != 1 || scale.y != 1 || scale.z != 1 {
            built.scale(x: scale.x, y: scale.y, z: scale.z)
        }
        return built
    }

    /// 置ける値か。数でない値・無限を含む置き場所は置かない。**塗り (`fill`) の成分も見る** —
    /// 数でない塗りの置き場所を置くと、その形が数でない色で描かれる ([#1706])。
    ///
    /// [#1706]: https://github.com/mokume-metal/mokume/issues/1706
    var isUsable: Bool { hasFiniteGeometry && hasFiniteFill }

    /// 位置・倍率 (軸ごとの倍率も)・回転がどれも有限か。
    var hasFiniteGeometry: Bool {
        [x, y, z, scale.x, scale.y, scale.z, rotation.x, rotation.y, rotation.z]
            .allSatisfy(\.isFinite)
    }

    /// 塗りが無いか、塗りの 4 成分がどれも有限か。
    var hasFiniteFill: Bool { fill?.isFinite ?? true }
}
