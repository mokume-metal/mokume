// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 軸に沿った矩形を値として持ち歩き、描き、当たり判定する。
///
/// パドルやブロック・ボタンのように、場所と大きさを持つものを 1 つの値で表す。**基準点は
/// ラベルで名乗る** — 左上の角で作るなら ``init(left:top:width:height:fill:)``、中心で作るなら
/// ``init(center:width:height:fill:)`` と書く。``SketchPart/rectMode(_:)`` の影響を受けず、
/// 判定も ``draw()`` も値に書いたとおりの位置と大きさで働く ([ADR-0045] 決定 5)。
///
/// @Row {
///   @Column(size: 3) {
///     ```swift
///     background(23, 26, 31)
///     let palette = [color(239, 83, 80), color(242, 115, 64), color(250, 210, 80)]
///     for row in 0..<3 {
///         for col in 0..<8 {
///             let brick = Rect(
///                 left: 24 + col * 44, top: 40 + row * 20, width: 40, height: 14,
///                 fill: palette[row])
///             brick.draw()
///         }
///     }
///     fill(240)
///     Rect(center: Vector2(200, 260), width: 88, height: 10).draw()
///     ```
///   }
///   @Column {
///     <!-- shot: 上に赤・橙・黄の 3 段に並ぶブロック、下の中央に白いパドル | symmetric=x -->
///     ![上に赤・橙・黄の 3 段に並ぶブロック、下の中央に白いパドル](https://i.gyazo.com/683f81ce6d2347eeef03adfc2a0b5573.png)
///     <!-- /shot -->
///   }
/// }
///
/// **隔離の外に置く** ([ADR-0010] 決定 1 の改訂)。判定と移動はどこからでも呼べ、走っている
/// スケッチへ描く ``draw()`` だけが main actor に残る。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0045]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0045-game-direction.md
// shot: 1 snippet=6f1653fc
public nonisolated struct Rect: Sendable, Hashable, Codable {
    /// 左の辺の横の位置。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     var paddle = Rect(left: 40, top: 130, width: 100, height: 40)
    ///     paddle.draw()
    ///     paddle.left = 260
    ///     fill(89, 191, 242)
    ///     paddle.draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左に橙色の矩形、左の辺を 260 へ移した水色の矩形が右に | symmetric=y -->
    ///     ![左に橙色の矩形、左の辺を 260 へ移した水色の矩形が右に](https://i.gyazo.com/3e4fac6f129759c7fba53079c3839d33.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=4d0b540d
    public var left: Float
    /// 上の辺の縦の位置。下向きが正である。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     var bar = Rect(left: 100, top: 40, width: 200, height: 30)
    ///     for _ in 0..<4 {
    ///         bar.draw()
    ///         bar.top += 60
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 60 ずつ下へずれて縦に並ぶ 4 本の橙色の横長の矩形 | symmetric=x -->
    ///     ![60 ずつ下へずれて縦に並ぶ 4 本の橙色の横長の矩形](https://i.gyazo.com/97a5242698cee737f7d040be170ae137.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=2283b665
    public var top: Float
    /// 幅。0 以下の矩形は何も含まず、何とも当たらず、描いても何も出ない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     var gauge = Rect(left: 60, top: 60, width: 280, height: 30)
    ///     for _ in 0..<4 {
    ///         gauge.draw()
    ///         gauge.width -= 70
    ///         gauge.top += 50
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左端を揃え、下へ行くほど 70 ずつ短くなる 4 本の橙色の帯 -->
    ///     ![左端を揃え、下へ行くほど 70 ずつ短くなる 4 本の橙色の帯](https://i.gyazo.com/382e4a52ec0226cc033224cc2cf02c0d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=bc264ebb
    public var width: Float
    /// 高さ。0 以下の矩形は何も含まず、何とも当たらず、描いても何も出ない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     var bar = Rect(left: 40, top: 60, width: 40, height: 30)
    ///     for _ in 0..<6 {
    ///         bar.draw()
    ///         bar.left += 55
    ///         bar.height += 35
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 上端を揃え、右へ行くほど長く下へ伸びる 6 本の橙色の棒 -->
    ///     ![上端を揃え、右へ行くほど長く下へ伸びる 6 本の橙色の棒](https://i.gyazo.com/3fd38b9be44c16a2ff8d1d7351995343.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=9d853510
    public var height: Float
    /// この矩形の塗り。`nil` なら、描いた時点の ``SketchPart/fill(_:)`` に従う。
    ///
    /// 値が持つ塗りは、``SketchPart/noFill()`` の中でもその色で塗る。描いた後の塗りの状態は
    /// 呼ぶ前と同じである ([ADR-0045] 決定 6)。``Shape`` の色が形の中に焼き付くのと同じ規則で、
    /// 値が持つ見た目が優先する。輪郭は値に持たせず、いまの ``SketchPart/stroke(_:)`` に従う。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     stroke(240)
    ///     var brick = Rect(left: 50, top: 110, width: 130, height: 80)
    ///     brick.draw()
    ///     brick.fill = color(239, 83, 80)
    ///     brick.left = 220
    ///     brick.draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: noFill() の中で、左は塗りの無い白い枠だけ、右は値が持つ赤で塗った矩形 | symmetric=y -->
    ///     ![noFill() の中で、左は塗りの無い白い枠だけ、右は値が持つ赤で塗った矩形](https://i.gyazo.com/45b2d331c15c2d47fb9a4d36b8a20e94.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// [ADR-0045]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0045-game-direction.md
    // shot: 1 snippet=039f7c7e
    public var fill: LinearRGBA?

    /// 左上の角と、幅と高さから作る。
    ///
    /// ``SketchPart/rectMode(_:)`` が何であっても、`left` と `top` は左上の角である。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     let paddle = Rect(left: 80, top: 60, width: 240, height: 180)
    ///     paddle.draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左上 (80, 60) から 240x180 の橙色の矩形 | symmetric=xy -->
    ///     ![左上 (80, 60) から 240x180 の橙色の矩形](https://i.gyazo.com/c2ec99762a53734d02277ad9d2467055.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=f81c2d48
    public init(
        left: some ScalarConvertible, top: some ScalarConvertible,
        width: some ScalarConvertible, height: some ScalarConvertible, fill: LinearRGBA? = nil
    ) {
        self.left = left.asFloat
        self.top = top.asFloat
        self.width = width.asFloat
        self.height = height.asFloat
        self.fill = fill
    }

    /// 中心の点と、幅と高さから作る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let middle = Vector2(200, 150)
    ///     Rect(center: middle, width: 260, height: 160, fill: color(89, 191, 242)).draw()
    ///     Rect(center: middle, width: 120, height: 60, fill: color(242, 115, 64)).draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中央の水色の矩形の中に、同じ中心の橙色の小さな矩形 | symmetric=xy -->
    ///     ![中央の水色の矩形の中に、同じ中心の橙色の小さな矩形](https://i.gyazo.com/dd3ef58a3bd4d774802d32969d05b14f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=ce3dcac6
    public init(
        center: Vector2, width: some ScalarConvertible, height: some ScalarConvertible,
        fill: LinearRGBA? = nil
    ) {
        let (width, height) = (width.asFloat, height.asFloat)
        self.init(
            left: center.x - width / 2, top: center.y - height / 2, width: width, height: height,
            fill: fill)
    }

    /// 右の辺の横の位置 (`left + width`)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let wall = Rect(left: 40, top: 80, width: 150, height: 140, fill: color(242, 115, 64))
    ///     wall.draw()
    ///     Rect(left: wall.right, top: 120, width: 120, height: 60, fill: color(89, 191, 242)).draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の矩形の右の辺に、水色の矩形がぴったり接して並ぶ | symmetric=y -->
    ///     ![橙色の矩形の右の辺に、水色の矩形がぴったり接して並ぶ](https://i.gyazo.com/61aec37c22bf7219095af2d16b20e224.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=15e70745
    public var right: Float { left + width }

    /// 下の辺の縦の位置 (`top + height`)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let shelf = Rect(left: 60, top: 60, width: 280, height: 60, fill: color(242, 115, 64))
    ///     shelf.draw()
    ///     Rect(left: 140, top: shelf.bottom, width: 120, height: 100, fill: color(89, 191, 242)).draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の横長の矩形の下の辺から、水色の矩形がぶら下がる | symmetric=x -->
    ///     ![橙色の横長の矩形の下の辺から、水色の矩形がぶら下がる](https://i.gyazo.com/fbc94f398e1d8a6028632b4d4b34c384.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=86140f0b
    public var bottom: Float { top + height }

    /// 中心。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let button = Rect(left: 70, top: 90, width: 260, height: 120, fill: color(242, 115, 64))
    ///     button.draw()
    ///     fill(255)
    ///     circle(button.center.x, button.center.y, 30)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の矩形のちょうど中心に、白い小さな円 | symmetric=xy -->
    ///     ![橙色の矩形のちょうど中心に、白い小さな円](https://i.gyazo.com/1b8fcbee385f9343e524b6508faa156b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=a6e07d6a
    public var center: Vector2 { Vector2(left + width / 2, top + height / 2) }

    /// その場で動かす。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     fill(242, 115, 64)
    ///     var paddle = Rect(left: 20, top: 240, width: 70, height: 12)
    ///     for _ in 0..<5 {
    ///         paddle.draw()
    ///         paddle.move(by: Vector2(75, -45))
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左下から右上へ、階段のように並ぶ 5 本の橙色のパドル -->
    ///     ![左下から右上へ、階段のように並ぶ 5 本の橙色のパドル](https://i.gyazo.com/314b0af1c63c0ced490d911cafb7e552.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=14dd496c
    public mutating func move(by offset: Vector2) {
        left += offset.x
        top += offset.y
    }

    /// 動かした値を返す。元の値は変わらない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let card = Rect(left: 60, top: 70, width: 150, height: 110, fill: color(242, 115, 64))
    ///     let shadow = card.moved(by: Vector2(20, 20))
    ///     fill(10)
    ///     Rect(left: shadow.left, top: shadow.top, width: shadow.width, height: shadow.height).draw()
    ///     card.draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の矩形の右下に、20 ずつずれた黒い影 -->
    ///     ![橙色の矩形の右下に、20 ずつずれた黒い影](https://i.gyazo.com/55317cfddb3f31dd5e338655bf8a58f8.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=38b9027c
    public func moved(by offset: Vector2) -> Rect {
        var moved = self
        moved.move(by: offset)
        return moved
    }

    /// 矩形と重なるか。**辺が接するだけでも重なると数える。**
    ///
    /// 値どうしの計算で、描画の状態も座標変換も見ない ([ADR-0045] 決定 7)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let player = Rect(left: 150, top: 100, width: 100, height: 100)
    ///     for i in 0..<5 {
    ///         let block = Rect(left: 20 + i * 75, top: 170 - i % 2 * 120, width: 60, height: 60)
    ///         fill(player.intersects(block) ? color(239, 83, 80) : color(120))
    ///         block.draw()
    ///     }
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     player.draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中央の橙色の枠に重なるブロックだけが赤く、離れたブロックは灰色 | symmetric=x -->
    ///     ![中央の橙色の枠に重なるブロックだけが赤く、離れたブロックは灰色](https://i.gyazo.com/bdb81b0c2ac67fe8414f55c3f145c5fb.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// [ADR-0045]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0045-game-direction.md
    // shot: 1 snippet=396ecbb3
    public func intersects(_ other: Rect) -> Bool {
        guard hasArea, other.hasArea else { return false }
        return left <= other.right && other.left <= right
            && top <= other.bottom && other.top <= bottom
    }

    /// 円と重なるか。**縁が接するだけでも重なると数える。**
    ///
    /// 矩形の中で円の中心にいちばん近い点が、円の中にあるかで決める。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let brick = Rect(left: 120, top: 100, width: 160, height: 60)
    ///     for i in 0..<6 {
    ///         let ball = Circle(x: 50 + i * 60, y: 190, radius: 30)
    ///         fill(brick.intersects(ball) ? color(239, 83, 80) : color(120))
    ///         ball.draw()
    ///     }
    ///     fill(242, 115, 64)
    ///     brick.draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色のブロックの下に並ぶボールのうち、ブロックに触れるものだけが赤い | symmetric=x -->
    ///     ![橙色のブロックの下に並ぶボールのうち、ブロックに触れるものだけが赤い](https://i.gyazo.com/9ccea8246b448d2f2e6bbb69b64e9705.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=f97fa44c
    public func intersects(_ circle: Circle) -> Bool {
        guard hasArea, circle.radius > 0 else { return false }
        let nearest = SIMD2(
            min(max(circle.center.x, left), right), min(max(circle.center.y, top), bottom))
        let gap = circle.center.simd - nearest
        return (gap * gap).sum() <= circle.radius * circle.radius
    }

    /// 点を含むか。**辺の上の点も含むと数える。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     let button = Rect(left: 100, top: 90, width: 200, height: 120)
    ///     noFill()
    ///     stroke(242, 115, 64)
    ///     button.draw()
    ///     noStroke()
    ///     for i in 0..<12 {
    ///         let point = Vector2(30 + i * 30, 60 + i * 18)
    ///         fill(button.contains(point) ? color(239, 83, 80) : color(120))
    ///         circle(point.x, point.y, 10)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の枠の内側の点だけが赤く、外の点は灰色 -->
    ///     ![橙色の枠の内側の点だけが赤く、外の点は灰色](https://i.gyazo.com/5c5179e12e076aabe65abb2f12238144.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=c73a7177
    public func contains(_ point: Vector2) -> Bool {
        guard hasArea else { return false }
        return left <= point.x && point.x <= right && top <= point.y && point.y <= bottom
    }

    /// 走っているスケッチへ描く。
    ///
    /// 値の ``fill`` があればその色で、無ければ今の ``SketchPart/fill(_:)`` で塗り、輪郭は今の
    /// ``SketchPart/stroke(_:)`` に従う。``SketchPart/rectMode(_:)`` が何であっても、値の左上の
    /// 角と大きさのとおりに描く (警告もしない)。描いた後の塗りと描き方の状態は呼ぶ前と同じである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     rectMode(.center)
    ///     fill(89, 191, 242)
    ///     rect(10, 10, 120, 40)
    ///     fill(242, 115, 64)
    ///     Rect(left: 10, top: 10, width: 120, height: 40).draw()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左上の角に中心を置いた水色の矩形 (rectMode(.center) の rect()) と、左上 (10, 10) から描いた橙色の矩形 (値) -->
    ///     ![左上の角に中心を置いた水色の矩形 (rectMode(.center) の rect()) と、左上 (10, 10) から描いた橙色の矩形 (値)](https://i.gyazo.com/26b97fe9d971e669d033651858206cd1.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **呼べるのはスケッチが走っている間**で、外から呼ぶと 1 度だけ警告して何もしない。
    // shot: 1 snippet=19350776
    @MainActor
    public func draw() {
        guard let canvas = shapeValueCanvas("Rect.draw()") else { return }
        let saved = canvas.currentStyle
        defer { canvas.currentStyle = saved }
        if let fill { canvas.fill(fill) }
        canvas.rectMode(.corner)
        canvas.rect(left, top, width, height)
    }

    /// 幅と高さがどちらも正か。数でない幅・高さも偽になる。
    private var hasArea: Bool { width > 0 && height > 0 }
}

/// 値型の `draw()` が描く先。走っている実行の面で、外から呼ばれたら 1 度だけ警告して `nil` を返す。
///
/// 語彙 (``SketchPart``) が使う ``SketchPart/liveCanvas(_:_:)`` と同じ扱いである。値型は
/// `SketchPart` を名乗らないので、同じ控えへ自分の名前で言う。
@MainActor
func shapeValueCanvas(_ call: String) -> Canvas? {
    guard let runtime = runningSketch else {
        OutsideRun.log.warn(call, .act)
        return nil
    }
    return runtime.canvas
}
