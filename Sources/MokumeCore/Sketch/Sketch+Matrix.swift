// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 直接呼べる描画のうち、行列と、積んで戻す操作。
extension Sketch {
    /// 与えた変換を、いまの変換の後に重ねる。
    ///
    /// 渡す ``Transform`` は ``Transform/identity`` から積み上げて作る。積む順も向きも
    /// ``translate(_:_:)`` や ``rotate(_:)`` を並べて呼ぶのと同じで、**結果も同じ**に
    /// なる — 違うのは、その一連の変換を**値として持てる**ことである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     square(145, 95, 110)
    ///     var moved = Transform.identity
    ///     moved.translate(x: 200, y: 150)
    ///     moved.rotate(by: 0.6)
    ///     applyMatrix(moved)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     square(-55, -55, 110)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の正方形に、同じ中心で右へ傾いた橙色の正方形が重なっている -->
    ///     ![灰色の枠の正方形に、同じ中心で右へ傾いた橙色の正方形が重なっている](https://i.gyazo.com/7484af7f1a5af1537e130f5f933b1dc6.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **値として持てると、同じ変換を何度も重ねられる。** 移動・回転・縮小を 1 つに
    /// まとめた `step` を作り、図形を描くたびに重ねると、同じ間隔で少しずつ倒れて
    /// 小さくなる並びになる。呼び出しを並べる書き方では、この「1 段ぶんの変換」を
    /// 名前で指せない:
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(120, 215)
    ///     var step = Transform.identity
    ///     step.translate(x: 46, y: -34)
    ///     step.rotate(by: 0.3)
    ///     step.scale(x: 0.86, y: 0.86)
    ///     noStroke()
    ///     for i in 0..<6 {
    ///         fill(.display(red: 0.35 + Float(i) * 0.10, green: 0.78 - Float(i) * 0.07, blue: 0.95))
    ///         square(-30, -30, 60)
    ///         applyMatrix(step)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左下から右へ、少しずつ小さく傾きながら弧を描いて並ぶ 6 つの正方形。色は水色から桃色へ移る -->
    ///     ![左下から右へ、少しずつ小さく傾きながら弧を描いて並ぶ 6 つの正方形。色は水色から桃色へ移る](https://i.gyazo.com/bc8d997966f7fbd6f39178b8c396c8dd.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=9c067b7f
    // shot: 2 snippet=ad0cc1bf
    public func applyMatrix(_ matrix: Transform) { canvas.applyMatrix(matrix) }

    /// 積み重ねた変換を捨てて、何も変換しない状態へ戻す。
    ///
    /// 積んである変換 (``pushMatrix()``) は捨てないので、戻す先は残る。
    ///
    /// **どれだけ重ねていても 1 回で戻る。** 下の例は原点を動かして回した後に呼んで
    /// いるので、最後の四角は面の左上を原点とする素の座標で描かれる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(200, 150)
    ///     rotate(0.5)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     square(-50, -50, 100)
    ///     resetMatrix()
    ///     fill(89, 191, 242)
    ///     square(20, 20, 70)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 中央に傾いた橙色の正方形があり、左上の隅にまっすぐな水色の正方形がある -->
    ///     ![中央に傾いた橙色の正方形があり、左上の隅にまっすぐな水色の正方形がある](https://i.gyazo.com/e6c7f75fd4d027176b3fe66b47fdbfa9.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=a95c28ee
    public func resetMatrix() { canvas.resetMatrix() }

    /// いまの変換を積んでおく。
    ///
    /// ``popMatrix()`` と対で使う。**挟んだ中で何を掛けても、外へ出れば元に戻る** ので、
    /// 図形ごとに変換を掛けたいときに前の状態を数えなくて済む。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(200, 150)
    ///     noStroke()
    ///     pushMatrix()
    ///     rotate(0.79)
    ///     fill(242, 115, 64)
    ///     square(-55, -55, 110)
    ///     popMatrix()
    ///     fill(89, 191, 242)
    ///     square(-30, -30, 60)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 45 度傾いた橙色の正方形の中央に、傾いていない水色の小さな正方形が重なっている | symmetric=xy -->
    ///     ![45 度傾いた橙色の正方形の中央に、傾いていない水色の小さな正方形が重なっている](https://i.gyazo.com/4377b69fad78187ce978235c3118b202.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **積むのは何段でもよい。** 段ごとに戻る先が別々に残る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     translate(90, 150)
    ///     pushMatrix()
    ///     translate(110, 0)
    ///     pushMatrix()
    ///     translate(110, 0)
    ///     fill(242, 217, 89)
    ///     square(-30, -30, 60)
    ///     popMatrix()
    ///     fill(140, 153, 178)
    ///     square(-30, -30, 60)
    ///     popMatrix()
    ///     fill(242, 115, 64)
    ///     square(-30, -30, 60)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙・灰・黄の同じ大きさの正方形が、左から等間隔に 3 つ並んでいる | symmetric=y -->
    ///     ![橙・灰・黄の同じ大きさの正方形が、左から等間隔に 3 つ並んでいる](https://i.gyazo.com/782c849f1510bab910e10317a0b8c128.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 積んだ変換も**フレームを越えない**。フレームの頭で空に戻るので、戻し忘れても次のフレームへは残らない。
    // shot: 1 snippet=ec08da66
    // shot: 2 snippet=f32daf1c
    public func pushMatrix() { canvas.pushMatrix() }

    /// 積んでおいた変換へ戻す。積んでいなければ何もしない。
    ///
    /// **積んでいないときに呼んでも落ちない。** 何もせずそのまま進むので、対にし忘れた
    /// 場合は「戻らない」ことだけが起きる — 下の例は ``pushMatrix()`` を呼んでいないので、
    /// 2 つ目の四角も回した座標系のまま描かれる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(200, 150)
    ///     rotate(0.79)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     square(-55, -55, 110)
    ///     popMatrix()
    ///     fill(89, 191, 242)
    ///     square(-30, -30, 60)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 45 度傾いた橙色の正方形の中央に、同じく傾いた水色の小さな正方形が重なっている | symmetric=xy -->
    ///     ![45 度傾いた橙色の正方形の中央に、同じく傾いた水色の小さな正方形が重なっている](https://i.gyazo.com/d2415bfd8c77364c26ad07011a41e26c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 積んだ変換も**フレームを越えない**。フレームの頭で空に戻る。
    // shot: 1 snippet=2d914404
    public func popMatrix() { canvas.popMatrix() }

    /// 変換とスタイルの**両方**を積んでおく。
    ///
    /// 片方だけを積みたいときは ``pushMatrix()`` / ``pushStyle()`` を使う。
    ///
    /// **``pushMatrix()`` との違いは、色や線の太さも一緒に戻ること。** 下の例は挟んだ
    /// 中で原点も色も太さも変えているが、``pop()`` の後の四角は**どれも元のまま**で
    /// 描かれる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     stroke(140, 153, 178)
    ///     strokeWeight(3)
    ///     translate(110, 150)
    ///     push()
    ///     translate(180, 0)
    ///     stroke(242, 115, 64)
    ///     strokeWeight(12)
    ///     square(-45, -45, 90)
    ///     pop()
    ///     square(-45, -45, 90)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 右に太い橙色の枠の正方形、左に細い灰色の枠の正方形が並んでいる | symmetric=y -->
    ///     ![右に太い橙色の枠の正方形、左に細い灰色の枠の正方形が並んでいる](https://i.gyazo.com/3315f71280d99820f19ae0e5a01401ee.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 積んだ**変換**はフレームを越えない — フレームの頭で空に戻る。
    // shot: 1 snippet=2665a2c3
    public func push() { canvas.push() }

    /// 積んでおいた変換とスタイルの両方へ戻す。積んでいなければ何もしない。
    ///
    /// **``push()`` と対で使う。** 積んでいないときに呼んでも落ちず、何もせず進む。
    /// 下の例は 2 段積んで 2 段戻しているので、3 つの四角がそれぞれ別の段の状態で
    /// 描かれる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     translate(80, 150)
    ///     fill(140, 153, 178)
    ///     push()
    ///     translate(120, 0)
    ///     fill(242, 115, 64)
    ///     push()
    ///     translate(120, 0)
    ///     fill(89, 191, 242)
    ///     square(-35, -35, 70)
    ///     pop()
    ///     square(-35, -35, 70)
    ///     pop()
    ///     square(-35, -35, 70)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰・橙・水色の同じ大きさの正方形が、左から等間隔に 3 つ並んでいる | symmetric=y -->
    ///     ![灰・橙・水色の同じ大きさの正方形が、左から等間隔に 3 つ並んでいる](https://i.gyazo.com/8cde6942eb1b51e484e0a87fd113a1ad.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 積んだ**変換**はフレームを越えない — フレームの頭で空に戻る。
    // shot: 1 snippet=45e99a0e
    public func pop() { canvas.pop() }
}
