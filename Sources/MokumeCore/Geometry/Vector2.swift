// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 平面の点や向き・速さを表す、2 つの数の組。Processing の `PVector` に当たる。
///
/// 位置と速さを 1 つの値で持ち歩き、足し引きできる。数は `Float`・`Double`・`Int` の
/// どれでも渡せる ([ADR-0035])。
///
/// @Row {
///   @Column(size: 3) {
///     ```swift
///     background(23, 26, 31)
///     fill(242, 115, 64)
///     var position = Vector2(40, 250)
///     let velocity = Vector2(36, -22)
///     for _ in 0..<10 {
///         circle(position.x, position.y, 18)
///         position += velocity
///     }
///     ```
///   }
///   @Column {
///     <!-- shot: 左下から右上へ、等しい間隔で斜めに並ぶ 10 個の橙色の円 -->
///     ![左下から右上へ、等しい間隔で斜めに並ぶ 10 個の橙色の円](https://i.gyazo.com/d45aba0eca738a432b69d7d5692b76a6.png)
///     <!-- /shot -->
///   }
/// }
///
/// メンバーの名前は Swift の慣行に従う。Processing での名前とは次のように対応する。
///
/// | Processing | mokume |
/// | --- | --- |
/// | `new PVector(x, y)` | ``init(_:_:)`` |
/// | `v.add(w)` / `PVector.add(v, w)` | `v += w` / `v + w` |
/// | `v.sub(w)` | `v -= w` / `v - w` |
/// | `v.mult(n)` / `v.div(n)` | `v *= n` / `v / n` |
/// | `v.mag()` | ``length`` |
///
/// **隔離の外に置く** ([ADR-0010] 決定 1 の改訂)。通信の完了ハンドラのような main actor の
/// 外からも作れ、比べ、符号化できる。符号化の形は `{"x": …, "y": …}` である。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0035]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0035-numeric-reception.md
// shot: 1 snippet=c3124a0b
public nonisolated struct Vector2: Sendable, Hashable {
    /// SIMD との出入り口。Metal のシェーダへ渡すときなどに使う。
    ///
    /// 中身はこの SIMD の値で、``x``・``y`` はその成分を読み書きする。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     let corner = Vector2(60, 50)
    ///     let doubled = Vector2(corner.simd * 2)
    ///     circle(corner.x, corner.y, 40)
    ///     circle(doubled.x, doubled.y, 80)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左上に小さな円、その 2 倍の位置に 2 倍の大きさの円 -->
    ///     ![左上に小さな円、その 2 倍の位置に 2 倍の大きさの円](https://i.gyazo.com/33b8a5921d1ba11dc704e789ef1dbcfe.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=b804ff9a
    public var simd: SIMD2<Float>

    /// 横の成分。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     var point = Vector2(60, 150)
    ///     for _ in 0..<5 {
    ///         circle(point.x, point.y, 40)
    ///         point.x += 70
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中ほどの高さに、横一列に並ぶ 5 個の円 | symmetric=xy -->
    ///     ![中ほどの高さに、横一列に並ぶ 5 個の円](https://i.gyazo.com/81c3af4a6d25d35f2152ce1b1268c4ab.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=73089cbf
    public var x: Float {
        get { simd.x }
        set { simd.x = newValue }
    }

    /// 縦の成分。下向きが正である。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     var point = Vector2(200, 40)
    ///     for _ in 0..<4 {
    ///         circle(point.x, point.y, 40)
    ///         point.y += 70
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中央の列に、上から縦一列に並ぶ 4 個の円 | symmetric=x -->
    ///     ![中央の列に、上から縦一列に並ぶ 4 個の円](https://i.gyazo.com/3101d5a70df380a6a109a6d2fc9d9947.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=25ae9188
    public var y: Float {
        get { simd.y }
        set { simd.y = newValue }
    }

    /// 2 つの数から作る。
    ///
    /// 数は `Float`・`Double`・`Int` のどれでもよい。`Int` の変数もそのまま渡せる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     for col in 0..<6 {
    ///         let point = Vector2(col * 60 + 50, 150)
    ///         circle(point.x, point.y, 40)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 60 ずつ離れて横一列に並ぶ 6 個の円 | symmetric=xy -->
    ///     ![60 ずつ離れて横一列に並ぶ 6 個の円](https://i.gyazo.com/148215c304d355b9ab325cda2a192182.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=7a48090c
    public init(_ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        simd = SIMD2(x.asFloat, y.asFloat)
    }

    /// SIMD の値から作る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     let center = Vector2(SIMD2<Float>(200, 150))
    ///     circle(center.x, center.y, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 画面の中央に、直径 120 の円 | symmetric=xy -->
    ///     ![画面の中央に、直径 120 の円](https://i.gyazo.com/aa8fc445a01d367ad9247726734f9006.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=5af85501
    public init(_ simd: SIMD2<Float>) {
        self.simd = simd
    }

    /// 長さ。Processing の `mag()` に当たる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let arm = Vector2(120, 60)
    ///     stroke(242, 115, 64)
    ///     strokeWeight(3)
    ///     line(200, 150, 200 + arm.x, 150 + arm.y)
    ///     noFill()
    ///     stroke(89, 191, 242)
    ///     circle(200, 150, arm.length * 2)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     circle(200 + arm.x, 150 + arm.y, 24)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中心から右下へ伸びる橙色の線と先端の点、その先端を通る水色の円 -->
    ///     ![中心から右下へ伸びる橙色の線と先端の点、その先端を通る水色の円](https://i.gyazo.com/9148f5e699c5bb45bc94d76c6d6c7e7c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=26b58a86
    public var length: Float { (simd * simd).sum().squareRoot() }
}

// MARK: - 配列リテラル

nonisolated extension Vector2: ExpressibleByArrayLiteral {
    /// 2 つの数の配列リテラルから作る (`[300, 300]`)。
    ///
    /// 要素は数のリテラルに限る。`Int` の変数を混ぜるときは ``init(_:_:)`` で書く。
    /// **要素が 2 つでなければ止まる** — 書いた場所で必ず起きる誤りなので、その行で知らせる
    /// (`SIMD2` の配列リテラルと同じ)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     let corners: [Vector2] = [[100, 90], [300, 90], [200, 230]]
    ///     for corner in corners {
    ///         circle(corner.x, corner.y, 60)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 三角形の頂点の位置に置いた 3 個の円 | symmetric=x -->
    ///     ![三角形の頂点の位置に置いた 3 個の円](https://i.gyazo.com/e078d98d4c9a65d79d41fa79f6d6f7a1.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=2f2591aa
    public init(arrayLiteral elements: Float...) {
        precondition(
            elements.count == 2,
            "A Vector2 literal needs exactly two numbers, like [300, 300]. It had \(elements.count).")
        simd = SIMD2(elements[0], elements[1])
    }
}

// MARK: - 符号化

nonisolated extension Vector2: Codable {
    private enum CodingKeys: String, CodingKey {
        case x
        case y
    }

    /// `{"x": …, "y": …}` の形から読む。
    // shot: 撮れない 符号化した値を読む口で、描くものが無い
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        simd = SIMD2(
            try container.decode(Float.self, forKey: .x),
            try container.decode(Float.self, forKey: .y))
    }

    /// `{"x": …, "y": …}` の形へ書く。
    // shot: 撮れない 値を符号化する口で、描くものが無い
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
    }
}

// MARK: - 四則演算

nonisolated extension Vector2 {
    /// 成分ごとに足す。位置に速さを足して次の位置を得る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     let start = Vector2(80, 80)
    ///     let step = Vector2(60, 35)
    ///     circle(start.x, start.y, 50)
    ///     let next = start + step
    ///     circle(next.x, next.y, 50)
    ///     let after = next + step
    ///     circle(after.x, after.y, 50)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左上から右下へ、同じ歩幅で並ぶ 3 個の円 -->
    ///     ![左上から右下へ、同じ歩幅で並ぶ 3 個の円](https://i.gyazo.com/7ca037c57ff9cdc7467692f17dea177e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=77dfc474
    public static func + (lhs: Vector2, rhs: Vector2) -> Vector2 {
        Vector2(lhs.simd + rhs.simd)
    }

    /// 成分ごとに引く。2 点の差は、片方からもう片方への向きと距離になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let from = Vector2(90, 220)
    ///     let to = Vector2(310, 80)
    ///     let gap = to - from
    ///     stroke(242, 115, 64)
    ///     strokeWeight(3)
    ///     line(from.x, from.y, from.x + gap.x, from.y + gap.y)
    ///     noStroke()
    ///     fill(89, 191, 242)
    ///     circle(from.x, from.y, 30)
    ///     circle(to.x, to.y, 30)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左下と右上の 2 つの水色の円を、橙色の線が結ぶ -->
    ///     ![左下と右上の 2 つの水色の円を、橙色の線が結ぶ](https://i.gyazo.com/e30b550999b7e27f6bdf38c25ebf4206.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=a14408e1
    public static func - (lhs: Vector2, rhs: Vector2) -> Vector2 {
        Vector2(lhs.simd - rhs.simd)
    }

    /// 向きを逆にする。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let arm = Vector2(130, -70)
    ///     let back = -arm
    ///     strokeWeight(3)
    ///     stroke(242, 115, 64)
    ///     line(200, 150, 200 + arm.x, 150 + arm.y)
    ///     stroke(89, 191, 242)
    ///     line(200, 150, 200 + back.x, 150 + back.y)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中心から右上へ伸びる橙色の線と、反対の左下へ伸びる水色の線 -->
    ///     ![中心から右上へ伸びる橙色の線と、反対の左下へ伸びる水色の線](https://i.gyazo.com/5e1dffb16d1c0a17bec063b6b6964fb1.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=5fc04afd
    public static prefix func - (vector: Vector2) -> Vector2 {
        Vector2(-vector.simd)
    }

    /// 数を掛けて、向きを保ったまま長さを変える。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     let step = Vector2(40, 22)
    ///     for i in 1...4 {
    ///         let point = step * i
    ///         circle(point.x + 20, point.y + 30, 12 * i)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左上から右下へ、離れるほど大きくなる 4 個の円 -->
    ///     ![左上から右下へ、離れるほど大きくなる 4 個の円](https://i.gyazo.com/e4ac61d19ee36e3480babd07fd6fea52.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=4df2ce9e
    public static func * (lhs: Vector2, rhs: some ScalarConvertible) -> Vector2 {
        Vector2(lhs.simd * rhs.asFloat)
    }

    /// 数を前に置いて掛ける。`vector * scale` と同じ。
    // shot: 参照 Vector2.*(_:_:) (Vector2, some ScalarConvertible)
    public static func * (lhs: some ScalarConvertible, rhs: Vector2) -> Vector2 {
        Vector2(lhs.asFloat * rhs.simd)
    }

    /// 数で割る。2 点の和を 2 で割ると、真ん中の点になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let a = Vector2(70, 230)
    ///     let b = Vector2(330, 70)
    ///     let middle = (a + b) / 2
    ///     fill(89, 191, 242)
    ///     circle(a.x, a.y, 30)
    ///     circle(b.x, b.y, 30)
    ///     fill(242, 115, 64)
    ///     circle(middle.x, middle.y, 50)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左下と右上の水色の円の、ちょうど真ん中に橙色の円 -->
    ///     ![左下と右上の水色の円の、ちょうど真ん中に橙色の円](https://i.gyazo.com/5a706f5d9015eb03db05215e1c449bf6.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=dd132798
    public static func / (lhs: Vector2, rhs: some ScalarConvertible) -> Vector2 {
        Vector2(lhs.simd / rhs.asFloat)
    }

    /// 足して入れる。`position += velocity` で位置を進める。
    // shot: 参照 Vector2.+(_:_:)
    public static func += (lhs: inout Vector2, rhs: Vector2) {
        lhs.simd += rhs.simd
    }

    /// 引いて入れる。
    // shot: 参照 Vector2.-(_:_:)
    public static func -= (lhs: inout Vector2, rhs: Vector2) {
        lhs.simd -= rhs.simd
    }

    /// 掛けて入れる。`velocity *= 0.98` で少しずつ遅くする。
    // shot: 参照 Vector2.*(_:_:) (Vector2, some ScalarConvertible)
    public static func *= (lhs: inout Vector2, rhs: some ScalarConvertible) {
        lhs.simd *= rhs.asFloat
    }

    /// 割って入れる。
    // shot: 参照 Vector2./(_:_:)
    public static func /= (lhs: inout Vector2, rhs: some ScalarConvertible) {
        lhs.simd /= rhs.asFloat
    }
}
