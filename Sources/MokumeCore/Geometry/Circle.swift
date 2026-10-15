// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 円を値として持ち歩き、描き、当たり判定する。
///
/// ボールや敵のように、位置と大きさを持って動き回るものを 1 つの値で表す。**常に中心と
/// 半径で表す** — ``SketchPart/ellipseMode(_:)`` の影響を受けず、判定も ``draw()`` も値に
/// 書いたとおりの位置と大きさで働く ([ADR-0045] 決定 5)。
///
/// @Row {
///   @Column(size: 3) {
///     ```swift
///     background(23, 26, 31)
///     let ball = Circle(x: 150, y: 150, radius: 60)
///     let enemy = Circle(x: 250, y: 140, radius: 50)
///     if ball.intersects(enemy) {
///         fill(239, 83, 80)
///     } else {
///         fill(242, 115, 64)
///     }
///     ball.draw()
///     enemy.draw()
///     ```
///   }
///   @Column {
///     <!-- shot: 重なり合う 2 つの赤い円 (当たっているので赤で塗る) -->
///     ![重なり合う 2 つの赤い円 (当たっているので赤で塗る)](https://i.gyazo.com/23b2df7e8cfded7f1ae4305ea1e70d93.png)
///     <!-- /shot -->
///   }
/// }
///
/// 見た目は ``fill`` で値に持たせられる。持たせない値は、描いた時点の ``SketchPart/fill(_:)``
/// に従う。
///
/// **隔離の外に置く** ([ADR-0010] 決定 1 の改訂)。判定と移動はどこからでも呼べ、走っている
/// スケッチへ描く ``draw()`` だけが main actor に残る。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0045]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0045-game-direction.md
// shot: 1 snippet=47e0e978
public nonisolated struct Circle: Sendable, Hashable, Codable {
    /// 中心。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     var ball = Circle(x: 120, y: 190, radius: 30)
    ///     fill(120)
    ///     ball.draw()
    ///     ball.center = Vector2(280, 110)
    ///     fill(242, 115, 64)
    ///     ball.draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左下の灰色の円と、中心を (280, 110) へ移して描いた橙色の円 -->
    ///     ![左下の灰色の円と、中心を (280, 110) へ移して描いた橙色の円](https://i.gyazo.com/1a033c3c5a33b9277de0730b410857f4.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=96046a28
    public var center: Vector2
    /// 半径。0 以下の円は何も含まず、何とも当たらず、描いても何も出ない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     var ring = Circle(x: 200, y: 150, radius: 120)
    ///     for i in 0..<4 {
    ///         fill(i % 2 == 0 ? color(242, 115, 64) : color(23, 26, 31))
    ///         ring.draw()
    ///         ring.radius -= 30
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中心を共有して半径が 30 ずつ小さくなる、橙色と下地の色の同心円 | symmetric=xy -->
    ///     ![中心を共有して半径が 30 ずつ小さくなる、橙色と下地の色の同心円](https://i.gyazo.com/e01120e970abd4f2432feda3dd53dcce.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=36d281b2
    public var radius: Float
    /// この円の塗り。`nil` なら、描いた時点の ``SketchPart/fill(_:)`` に従う。
    ///
    /// 値が持つ塗りは、``SketchPart/noFill()`` の中でもその色で塗る。描いた後の塗りの状態は
    /// 呼ぶ前と同じである ([ADR-0045] 決定 6)。``Shape`` の色が形の中に焼き付くのと同じ規則で、
    /// 値が持つ見た目が優先する。輪郭は値に持たせず、いまの ``SketchPart/stroke(_:)`` に従う。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     var coin = Circle(x: 130, y: 150, radius: 60)
    ///     coin.draw()
    ///     coin.fill = color(250, 210, 80)
    ///     coin.move(by: Vector2(140, 0))
    ///     coin.draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左に今の塗りの橙色の円、右に値が持つ黄色の円 | symmetric=y -->
    ///     ![左に今の塗りの橙色の円、右に値が持つ黄色の円](https://i.gyazo.com/6652bf249f82a913145603033efe2723.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// [ADR-0045]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0045-game-direction.md
    // shot: 1 snippet=ab23b5b0
    public var fill: LinearRGBA?

    /// 中心の座標と半径から作る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     let ball = Circle(x: 200, y: 150, radius: 80)
    ///     ball.draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 画面の中央に、半径 80 の橙色の円 | symmetric=xy -->
    ///     ![画面の中央に、半径 80 の橙色の円](https://i.gyazo.com/317de77f2b2ae9704cd049ad1ffccbae.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=dc046896
    public init(
        x: some ScalarConvertible, y: some ScalarConvertible, radius: some ScalarConvertible,
        fill: LinearRGBA? = nil
    ) {
        self.init(center: Vector2(x, y), radius: radius, fill: fill)
    }

    /// 中心の座標と直径から作る。``SketchPart/circle(_:_:_:)`` と同じく直径で書きたいときに使う。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     circle(120, 150, 100)
    ///     let same = Circle(x: 280, y: 150, diameter: 100)
    ///     same.draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ大きさの橙色の円が 2 つ横に並ぶ (左は circle()、右は値) | symmetric=xy -->
    ///     ![同じ大きさの橙色の円が 2 つ横に並ぶ (左は circle()、右は値)](https://i.gyazo.com/eba759ec388ff785cb6fe1343ef2943d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=28dcde00
    public init(
        x: some ScalarConvertible, y: some ScalarConvertible, diameter: some ScalarConvertible,
        fill: LinearRGBA? = nil
    ) {
        self.init(center: Vector2(x, y), radius: diameter.asFloat / 2, fill: fill)
    }

    /// 中心の点と半径から作る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let middle = Vector2(200, 150)
    ///     Circle(center: middle, radius: 110, fill: color(89, 191, 242)).draw()
    ///     Circle(center: middle, radius: 50, fill: color(242, 115, 64)).draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中央の水色の大きな円の中に、同じ中心の橙色の小さな円 | symmetric=xy -->
    ///     ![中央の水色の大きな円の中に、同じ中心の橙色の小さな円](https://i.gyazo.com/72776f07f28287513c9c2a07db05f2dd.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=f796decc
    public init(center: Vector2, radius: some ScalarConvertible, fill: LinearRGBA? = nil) {
        self.center = center
        self.radius = radius.asFloat
        self.fill = fill
    }

    /// 直径 (半径の 2 倍)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let ball = Circle(x: 200, y: 150, radius: 70)
    ///     fill(242, 115, 64)
    ///     ball.draw()
    ///     fill(89, 191, 242)
    ///     rect(ball.center.x - ball.diameter / 2, 240, ball.diameter, 12)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中央の円の下に、円の直径と同じ幅の水色の帯 | symmetric=x -->
    ///     ![中央の円の下に、円の直径と同じ幅の水色の帯](https://i.gyazo.com/7067b6ff55bbf4fa60a63a2a5adeda93.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=bfdaee26
    public var diameter: Float { radius * 2 }

    /// その場で動かす。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     var ball = Circle(x: 60, y: 230, radius: 20)
    ///     for _ in 0..<6 {
    ///         ball.draw()
    ///         ball.move(by: Vector2(56, -34))
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左下から右上へ、同じ歩幅で並ぶ 6 個の円 -->
    ///     ![左下から右上へ、同じ歩幅で並ぶ 6 個の円](https://i.gyazo.com/bac943dd1cc289ea63ea0cbcc7df8e0f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=3be96cdd
    public mutating func move(by offset: Vector2) {
        center += offset
    }

    /// 動かした値を返す。元の値は変わらない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let ball = Circle(x: 140, y: 150, radius: 50, fill: color(242, 115, 64))
    ///     let ghost = ball.moved(by: Vector2(120, 0))
    ///     ball.draw()
    ///     fill(89, 191, 242, 120)
    ///     noStroke()
    ///     Circle(center: ghost.center, radius: ghost.radius).draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左に橙色の円、右へずらした位置に半透明の水色の円 | symmetric=y -->
    ///     ![左に橙色の円、右へずらした位置に半透明の水色の円](https://i.gyazo.com/e7cac8663d934e1d9b327a1b70094573.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=6725408e
    public func moved(by offset: Vector2) -> Circle {
        var moved = self
        moved.move(by: offset)
        return moved
    }

    /// 円と重なるか。**縁が接するだけでも重なると数える。**
    ///
    /// 値どうしの計算で、描画の状態も座標変換も見ない ([ADR-0045] 決定 7)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let player = Circle(x: 200, y: 150, radius: 50)
    ///     for i in 0..<5 {
    ///         let enemy = Circle(x: 50 + i * 75, y: 70, radius: 30)
    ///         let near = Circle(x: 50 + i * 75, y: 150, radius: 30)
    ///         fill(player.intersects(near) ? color(239, 83, 80) : color(120))
    ///         near.draw()
    ///         fill(player.intersects(enemy) ? color(239, 83, 80) : color(120))
    ///         enemy.draw()
    ///     }
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     player.draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中央の橙色の輪に重なる円だけが赤く、離れた円は灰色 | symmetric=x -->
    ///     ![中央の橙色の輪に重なる円だけが赤く、離れた円は灰色](https://i.gyazo.com/54bf47911e3fd930df01dba6e911acc1.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// [ADR-0045]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0045-game-direction.md
    // shot: 1 snippet=1e548539
    public func intersects(_ other: Circle) -> Bool {
        guard radius > 0, other.radius > 0 else { return false }
        let gap = other.center.simd - center.simd
        let reach = radius + other.radius
        return (gap * gap).sum() <= reach * reach
    }

    /// 矩形と重なるか。**縁が接するだけでも重なると数える。**
    ///
    /// 矩形の側から円との重なりを問うたときと同じ答えを返す。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let paddle = Rect(left: 120, top: 200, width: 160, height: 20)
    ///     for i in 0..<5 {
    ///         let ball = Circle(x: 60 + i * 70, y: 175 + i % 2 * 10, radius: 18)
    ///         fill(ball.intersects(paddle) ? color(239, 83, 80) : color(120))
    ///         ball.draw()
    ///     }
    ///     fill(242, 115, 64)
    ///     paddle.draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色のパドルの上に並ぶ 5 つのボールのうち、パドルに触れるものだけが赤い | symmetric=x -->
    ///     ![橙色のパドルの上に並ぶ 5 つのボールのうち、パドルに触れるものだけが赤い](https://i.gyazo.com/cade313ab2b5079f9714ba330cc37c39.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=b8445cdd
    public func intersects(_ rect: Rect) -> Bool {
        rect.intersects(self)
    }

    /// 点を含むか。**縁の上の点も含むと数える。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let target = Circle(x: 200, y: 150, radius: 100)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     target.draw()
    ///     noStroke()
    ///     for i in 0..<12 {
    ///         let point = Vector2(30 + i * 30, 90 + i * 10)
    ///         fill(target.contains(point) ? color(239, 83, 80) : color(120))
    ///         circle(point.x, point.y, 10)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の輪の内側の点だけが赤く、外の点は灰色 -->
    ///     ![橙色の輪の内側の点だけが赤く、外の点は灰色](https://i.gyazo.com/85936f22a356e99af0b6cbbc58baeb6c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=b0e78c11
    public func contains(_ point: Vector2) -> Bool {
        guard radius > 0 else { return false }
        let gap = point.simd - center.simd
        return (gap * gap).sum() <= radius * radius
    }

    /// 走っているスケッチへ描く。
    ///
    /// 値の ``fill`` があればその色で、無ければ今の ``SketchPart/fill(_:)`` で塗り、輪郭は今の
    /// ``SketchPart/stroke(_:)`` に従う。``SketchPart/ellipseMode(_:)`` が何であっても、値の
    /// 中心と半径のとおりに描く (警告もしない)。描いた後の塗りと描き方の状態は呼ぶ前と同じである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     ellipseMode(.corner)
    ///     fill(242, 115, 64)
    ///     Circle(x: 200, y: 150, radius: 60).draw()
    ///     fill(89, 191, 242)
    ///     circle(200, 150, 40)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中央の橙色の円 (値) と、その右下へずれた水色の小さな円 (ellipseMode(.corner) の circle()) -->
    ///     ![中央の橙色の円 (値) と、その右下へずれた水色の小さな円 (ellipseMode(.corner) の circle())](https://i.gyazo.com/cb73a3580a7acf86a4c4549e86f366ed.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **呼べるのはスケッチが走っている間**で、外から呼ぶと 1 度だけ警告して何もしない。
    // shot: 1 snippet=37aafde8
    @MainActor
    public func draw() {
        guard let canvas = shapeValueCanvas("Circle.draw()") else { return }
        let saved = canvas.currentStyle
        defer { canvas.currentStyle = saved }
        if let fill { canvas.fill(fill) }
        canvas.ellipseMode(.center)
        canvas.circle(center.x, center.y, diameter)
    }
}
