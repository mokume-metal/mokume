// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 空間の点や向き・大きさを表す、3 つの数の組。視点の位置 (``Camera/eye``)・モデルの大きさ
/// (``Model/size``) のように、公開の面で 3 次元の値を渡すときの型である。
///
/// ``Vector2`` の 3 次元版で、数は `Float`・`Double`・`Int` のどれでも渡せる ([ADR-0035])。
/// 奥行き (`z`) は、視点に向かって手前が正である ([ADR-0021] 決定 1)。
///
/// ```swift
/// var view = currentCamera
/// view.eye = Vector3(200, 150, 500)
/// view.center = Vector3(200, 150, 0)
/// setCamera(view)
/// ```
///
/// 中身は `SIMD3<Float>` で、``simd`` と ``init(_:)-(SIMD3<Float>)`` で行き来できる。
///
/// **隔離の外に置く** ([ADR-0010] 決定 1 の改訂)。通信の完了ハンドラのような main actor の
/// 外からも作れ、比べ、符号化できる。符号化の形は `{"x": …, "y": …, "z": …}` である。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
/// [ADR-0035]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0035-numeric-reception.md
public nonisolated struct Vector3: Sendable, Hashable {
    /// SIMD との出入り口。Metal のシェーダへ渡すときなどに使う。
    ///
    /// 中身はこの SIMD の値で、``x``・``y``・``z`` はその成分を読み書きする。
    // shot: 撮れない 値の入れ物の出入り口で、描く結果が無い
    public var simd: SIMD3<Float>

    /// 横の成分。
    // shot: 撮れない 成分を読み書きするだけで、描く結果が無い
    public var x: Float {
        get { simd.x }
        set { simd.x = newValue }
    }

    /// 縦の成分。下向きが正である。
    // shot: 撮れない 成分を読み書きするだけで、描く結果が無い
    public var y: Float {
        get { simd.y }
        set { simd.y = newValue }
    }

    /// 奥行きの成分。視点に向かって手前が正である。
    // shot: 撮れない 成分を読み書きするだけで、描く結果が無い
    public var z: Float {
        get { simd.z }
        set { simd.z = newValue }
    }

    /// 3 つの数から作る。
    ///
    /// 数は `Float`・`Double`・`Int` のどれでもよい。`Int` の変数もそのまま渡せる。
    // shot: 撮れない 値を作るだけで、描く結果が無い
    public init(_ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible) {
        simd = SIMD3(x.asFloat, y.asFloat, z.asFloat)
    }

    /// SIMD の値から作る。
    // shot: 撮れない 値を作るだけで、描く結果が無い
    public init(_ simd: SIMD3<Float>) {
        self.simd = simd
    }
}

// MARK: - 配列リテラル

nonisolated extension Vector3: ExpressibleByArrayLiteral {
    /// 3 つの数の配列リテラルから作る (`[200, 150, 500]`)。
    ///
    /// 要素は数のリテラルに限る。`Int` の変数を混ぜるときは ``init(_:_:_:)`` で書く。
    /// **要素が 3 つでなければ止まる** — 書いた場所で必ず起きる誤りなので、その行で知らせる
    /// (``Vector2`` の配列リテラルと同じ)。
    // shot: 撮れない 値を作るだけで、描く結果が無い
    public init(arrayLiteral elements: Float...) {
        precondition(
            elements.count == 3,
            "A Vector3 literal needs exactly three numbers, like [200, 150, 500]. It had \(elements.count).")
        simd = SIMD3(elements[0], elements[1], elements[2])
    }
}

// MARK: - 符号化

nonisolated extension Vector3: Codable {
    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case z
    }

    /// `{"x": …, "y": …, "z": …}` の形から読む。
    // shot: 撮れない 符号化した値を読む口で、描くものが無い
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        simd = SIMD3(
            try container.decode(Float.self, forKey: .x),
            try container.decode(Float.self, forKey: .y),
            try container.decode(Float.self, forKey: .z))
    }

    /// `{"x": …, "y": …, "z": …}` の形へ書く。
    // shot: 撮れない 値を符号化する口で、描くものが無い
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(z, forKey: .z)
    }
}

// MARK: - 四則演算

nonisolated extension Vector3 {
    /// 成分ごとに足す。視点の位置をずらすのに使う。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public static func + (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(lhs.simd + rhs.simd)
    }

    /// 成分ごとに引く。2 点の差は、片方からもう片方への向きと距離になる。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public static func - (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(lhs.simd - rhs.simd)
    }

    /// 向きを逆にする。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public static prefix func - (vector: Vector3) -> Vector3 {
        Vector3(-vector.simd)
    }

    /// 数を掛けて、向きを保ったまま長さを変える。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public static func * (lhs: Vector3, rhs: some ScalarConvertible) -> Vector3 {
        Vector3(lhs.simd * rhs.asFloat)
    }

    /// 数を前に置いて掛ける。`vector * scale` と同じ。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public static func * (lhs: some ScalarConvertible, rhs: Vector3) -> Vector3 {
        Vector3(lhs.asFloat * rhs.simd)
    }

    /// 数で割る。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public static func / (lhs: Vector3, rhs: some ScalarConvertible) -> Vector3 {
        Vector3(lhs.simd / rhs.asFloat)
    }

    /// 足して入れる。`eye += Vector3(0, 0, 10)` で視点を引く。
    // shot: 撮れない 値を書き換えるだけで、描く結果が無い
    public static func += (lhs: inout Vector3, rhs: Vector3) {
        lhs.simd += rhs.simd
    }

    /// 引いて入れる。
    // shot: 撮れない 値を書き換えるだけで、描く結果が無い
    public static func -= (lhs: inout Vector3, rhs: Vector3) {
        lhs.simd -= rhs.simd
    }

    /// 掛けて入れる。
    // shot: 撮れない 値を書き換えるだけで、描く結果が無い
    public static func *= (lhs: inout Vector3, rhs: some ScalarConvertible) {
        lhs.simd *= rhs.asFloat
    }

    /// 割って入れる。
    // shot: 撮れない 値を書き換えるだけで、描く結果が無い
    public static func /= (lhs: inout Vector3, rhs: some ScalarConvertible) {
        lhs.simd /= rhs.asFloat
    }
}

// MARK: - 中間の 2 乗が溢れる・潰れる値の逃げ道

nonisolated extension Vector3 {
    /// `value` の成分のうち、いちばん大きいものの指数。成分は有限で、少なくとも 1 つは 0 でないこと。
    private static func peakExponent(_ value: SIMD3<Float>) -> Int {
        Int(max(abs(value.x), abs(value.y), abs(value.z)).exponent)
    }

    /// `value` の長さ。関数の層の `mag(_:_:_:)`・`dist(_:_:_:_:_:_:)` が共有する、3 成分の長さを開く口
    /// (#3358)。
    ///
    /// **規則は ``Vector2/measuredLength(of:)`` と同じ 1 本** (#2935)。2 乗の和が `2^-100` 以上
    /// `2^100` 未満なら従来の式のまま開くので、`1, 2, 2` から 3 がちょうど返る。外 (2 乗が溢れる大きい値・
    /// 0 や非正規数に潰れる小さい値) は 2 の冪で寄せて測るので、有限の距離は有限で返り、**0 になるのは
    /// 0 ベクトルだけ**。結果が `Float` の範囲を越えるなら ∞ になる。数でない値・無限の値が混じるときは
    /// 2 乗の和をそのまま開く (扱いは呼ぶ側が決める)。
    static func measuredLength(of value: SIMD3<Float>) -> Float {
        let squared = (value * value).sum()
        if squared >= Vector2.safeSquaredLow && squared < Vector2.safeSquaredHigh {
            return squared.squareRoot()
        }
        return scaledLength(of: value)
    }

    /// 2 乗を作らずに測った長さ。大きいほうの成分の指数の分だけ 2 の冪で寄せてから 2 乗するので、
    /// 成分が有限なら溢れも潰れもしない。寄せるのも戻すのも丸めを足さない。
    ///
    /// 0 になるのは 0 ベクトルだけ。成分が有限でなければ 2 乗の和をそのまま開く。
    static func scaledLength(of value: SIMD3<Float>) -> Float {
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite else {
            return (value * value).sum().squareRoot()
        }
        guard value != .zero else { return 0 }
        let exponent = peakExponent(value)
        let unit = SIMD3(scalbn(value.x, -exponent), scalbn(value.y, -exponent), scalbn(value.z, -exponent))
        return scalbn((unit * unit).sum().squareRoot(), exponent)
    }
}

nonisolated extension Vector3 {
    /// 長さ 1 の向きを、2 乗を作らずに求める。成分が有限で、少なくとも 1 つは 0 でないこと。
    static func scaledDirection(of value: SIMD3<Float>) -> SIMD3<Float> {
        let exponent = peakExponent(value)
        let unit = SIMD3(scalbn(value.x, -exponent), scalbn(value.y, -exponent), scalbn(value.z, -exponent))
        return unit / (unit * unit).sum().squareRoot()
    }
}

// MARK: - 長さ・向き・幾何演算

nonisolated extension Vector3 {
    /// 長さ。Processing の `mag()` に当たる。
    ///
    /// 2 乗が溢れるほど大きい値も、潰れるほど小さい値も有限の長さで返り、**0 になるのは 0 ベクトル
    /// だけ**。``Vector2/length`` と同じ規則で、関数の ``mag(_:_:_:)``・``dist(_:_:_:_:_:_:)`` と同じ答えになる。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public var length: Float {
        Vector3.measuredLength(of: simd)
    }

    /// 向きを保ったまま、長さを 1 にした値。Processing の `normalize()` に当たる。
    ///
    /// 元の値は変わらない (新しい値を返す)。**長さが 0 の値 (0 ベクトルだけ) は、変えずに返す** —
    /// 向きが無いので 0 で割らず、数でない値を絵に流さない (``Vector2/normalized()`` と同じ)。
    /// 成分が小さいだけの値は 0 ベクトルではないので、2 乗が 0 に潰れるほど小さくても長さ 1 の向きを返す。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public func normalized() -> Vector3 {
        let magnitude = length
        guard magnitude > 0 else { return self }
        // 長さそのものが Float に収まらない (∞) か、非正規数に丸められる (約 1.2e-38 未満) だけの有限な値は、
        // 向きだけを寄せた成分から求める (``Vector2/normalized()`` と同じ)
        if magnitude == .infinity || magnitude < Float.leastNormalMagnitude,
            simd.x.isFinite, simd.y.isFinite, simd.z.isFinite
        {
            return Vector3(Vector3.scaledDirection(of: simd))
        }
        return Vector3(simd / magnitude)
    }

    /// 長さが `maximum` を越えないように縮めた値。Processing の `limit()` に当たる。
    ///
    /// 向きは保つ。長さが `maximum` 以下の値は変えずに返し、越えるときだけ長さを `maximum` にする。
    /// 元の値は変わらない (新しい値を返す)。**`maximum` が 0 以下なら `Vector3(0, 0, 0)` を返す**
    /// (数でない値も同じ。``Vector2/limited(to:)`` と同じで、Processing の `limit()` が負の上限で向きを
    /// 反転させるのとは違う)。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public func limited(to maximum: some ScalarConvertible) -> Vector3 {
        let limit = maximum.asFloat
        guard limit > 0 else { return Vector3(0, 0, 0) }
        let magnitude = length
        guard magnitude > limit else { return self }
        let limited = simd * limit / magnitude
        // 成分が有限なのに、長さが Float に収まらない・`simd * limit` が溢れる・潰れるときは、向きに上限を
        // 掛け直す (``Vector2/limited(to:)`` と同じ)。どれでもない値は上の式のまま通る
        let product = simd * limit
        func holds(_ result: Float, _ component: Float) -> Bool {
            component == 0 ? result == 0 : abs(result) >= Float.leastNormalMagnitude && result.isFinite
        }
        let componentsAreFinite = simd.x.isFinite && simd.y.isFinite && simd.z.isFinite
        let intermediateHolds = holds(product.x, simd.x) && holds(product.y, simd.y) && holds(product.z, simd.z)
        if componentsAreFinite && (magnitude == .infinity || !intermediateHolds) {
            return Vector3(Vector3.scaledDirection(of: simd) * limit)
        }
        return Vector3(limited)
    }

    /// 2 つの点の間の距離。Processing の `PVector.dist(v, w)` に当たる。
    ///
    /// ``length`` と同じ規則で測り、関数の層の ``dist(_:_:_:_:_:_:)`` と同じ値になる。
    /// **数でない値が混じれば数でない値のまま返る** (関数の `dist()` は 0 を返して注意する)。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public func distance(to other: Vector3) -> Float {
        (other - self).length
    }

    /// 内積。Processing の `dot()` に当たる。
    ///
    /// 同じ向きなら正、直角なら 0、反対向きなら負になり、長さを掛けた値になる。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public func dot(_ other: Vector3) -> Float {
        (simd * other.simd).sum()
    }

    /// 外積。Processing の `cross()` に当たる。
    ///
    /// 2 つの値のどちらにも直角な値で、長さは 2 つが作る平行四辺形の面積。**右手系** — 横 (`x`) の
    /// 正の向きから縦 (`y`) の正の向きへ回したときの法線を返すので、`Vector3(1, 0, 0).cross(Vector3(0, 1, 0))`
    /// は `Vector3(0, 0, 1)`、順を入れ替えると向きが反対になる。縦軸が下向き・奥行きが手前正の
    /// この面の座標でも、**数式として右手系の規則を守る** (画面上で見える向きは座標系に従う)。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public func cross(_ other: Vector3) -> Vector3 {
        let (a, b) = (simd, other.simd)
        return Vector3(SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x))
    }

    /// `target` へ向かう途中の値。`amount` が 0 なら自分、1 なら `target` がちょうど返る。
    /// Processing の `lerp()` に当たる。
    ///
    /// 成分ごとに、関数の層の ``lerp(_:_:_:)`` と同じ式で間を取る。**0…1 の外は締めない**。
    /// 元の値は変わらない (新しい値を返す)。
    // shot: 撮れない 値を返すだけで、描く結果が無い
    public func interpolated(to target: Vector3, amount: some ScalarConvertible) -> Vector3 {
        let amount = amount.asFloat
        return Vector3(
            SIMD3(
                interpolate(simd.x, target.simd.x, amount), interpolate(simd.y, target.simd.y, amount),
                interpolate(simd.z, target.simd.z, amount)))
    }
}
