// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 保持した形。
extension Sketch {
    /// 形を組み立てて保持する。**毎フレーム組み立て直さずに済む。**
    ///
    /// <!-- example: 文脈 var leaf: Shape! -->
    /// ```swift
    /// func setup() {
    ///     leaf = createShape {
    ///         noStroke()
    ///         fill(102, 204, 89)
    ///         beginShape()
    ///         vertex(0, -20)
    ///         bezierVertex(14, -14, 14, 14, 0, 20)
    ///         bezierVertex(-14, 14, -14, -14, 0, -20)
    ///         endShape(.close)
    ///     }
    /// }
    ///
    /// func draw() {
    ///     for i in 0..<2000 { shape(leaf, Float(i % 50) * 8 + 10, Float(i / 50) * 8 + 10) }
    /// }
    /// ```
    ///
    /// ## 色は形の中に焼き付く
    ///
    /// 中で呼んだ ``fill(_:)`` や ``stroke(_:)`` は、組み立てた時点で頂点の色になる。
    /// **だから塗りや輪郭は形の中で決める** — 置くときに外から ``fill(_:)`` を変えても
    /// 形の色は変わらない。組み立てるコードを読めば何色になるかが分かり、置く側の
    /// コードを読んでも分からない、という形にしてある。
    ///
    /// **焼き付くのは色だけではない。** 組み立ての間に効いていた ``shader(_:)`` と、
    /// そのとき渡していた値・面・数の並びも形が持ち歩く。置く前に ``resetShader()``
    /// しても、別の断片へ切り替えても、形は記録した塗りで出る。
    ///
    /// 置く場所は別で、``translate(_:_:)`` や ``rotate(_:)`` は置くときに効く。
    /// 色は形のもので、場所は置き方のもの、という切り分けである。
    ///
    /// ## 座標は形自身のもの
    ///
    /// 組み立ての間、変換は畳まれている。どこで組み立てても同じ形になり、
    /// ``shape(_:_:_:)`` の与える位置がそのまま形の原点になる。
    ///
    /// ## 組にしても描く回数は増えない
    ///
    /// ``Shape/group(_:)`` と `+` は形を**1 本の頂点の並びへ畳む**。子の一覧を持って
    /// 1 つずつ描く作りではないので、「保持にしたのに速くならない」が起きない。
    public func createShape(_ body: () -> Void) -> Shape { canvas.createShape(body) }

    /// 保持した形を、**置き場所ぶんだけまとめて置く**。
    ///
    /// 同じ形をたくさん置くときは、これがいちばん速い。形の頂点は 1 度しか置かれず、
    /// 置き場所の数だけ描き足される — 1 万個置いても**描く回数は 1 回**になる。
    ///
    /// ```swift
    /// let grain = createShape { box(6) }
    /// var places: [Placement] = []
    /// for _ in 0..<5000 {
    ///     places.append(
    ///         Placement(
    ///             x: random(width), y: random(height),
    ///             rotation: SIMD3(0, random(2 * .pi), 0)))
    /// }
    /// shape(grain, at: places)
    /// ```
    ///
    /// **1 つずつ置いたときと同じ絵になる。** `push()` / `translate()` / `pop()` の
    /// 繰り返しで書いても、まとめて渡しても、経路は 1 本しかない。
    ///
    /// ``Placement/fill`` を渡すと、その置き場所の色に**掛かる** (渡さなければ何も
    /// 掛からない)。
    public func shape(_ shape: Shape, at placements: [Placement]) {
        canvas.shape(shape, at: placements)
    }

    /// 保持した形を置く。
    ///
    /// 色は形が持っているものが使われ、置く場所といまの変換が効く。
    ///
    /// **たくさん置くときは shape(_:at:) を使う。** こちらは 1 回ごとに頂点を
    /// 置き直すので、置く数だけ描く回数が増える。
    public func shape(_ shape: Shape, _ x: Float = 0, _ y: Float = 0) {
        canvas.shape(shape, x, y)
    }
}
