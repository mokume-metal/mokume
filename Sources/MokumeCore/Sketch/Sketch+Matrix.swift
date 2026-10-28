// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 直接呼べる描画のうち、行列と、積んで戻す操作。
extension SketchPart {
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
    ///     ![灰色の枠の正方形に、同じ中心で右へ傾いた橙色の正方形が重なっている](https://i.gyazo.com/0321ffd32c4b3427c7591ddf21530801.png)
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
    ///     ![左下から右へ、少しずつ小さく傾きながら弧を描いて並ぶ 6 つの正方形。色は水色から桃色へ移る](https://i.gyazo.com/4dcce38af24106b0e9d0f1cf7dbab4f1.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。`setup()` と止まっている間の入力のコールバックでも効き、その後に置いたものへ焼き付くが、呼び出しを抜けると戻る (`draw()` へは持ち越さない)。
    // shot: 1 snippet=9c067b7f
    // shot: 2 snippet=ad0cc1bf
    public func applyMatrix(_ matrix: Transform) { Self.liveCanvas()?.applyMatrix(matrix) }

    /// 積み重ねた変換を捨てて、何も変換しない状態へ戻す。
    ///
    /// 積んである変換 (``pushMatrix(fileID:line:)``) は捨てないので、戻す先は残る。
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
    ///     ![中央に傾いた橙色の正方形があり、左上の隅にまっすぐな水色の正方形がある](https://i.gyazo.com/d8e7dd66f1bb13b48214ce892ce55963.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 変換は**フレームを越えない**。`draw()` の中で毎フレーム書く。`setup()` と止まっている間の入力のコールバックでも効き、その後に置いたものへ焼き付くが、呼び出しを抜けると戻る (`draw()` へは持ち越さない)。
    // shot: 1 snippet=a95c28ee
    public func resetMatrix() { Self.liveCanvas()?.resetMatrix() }

    /// いまの変換を積んでおく。
    ///
    /// ``popMatrix(fileID:line:)`` と対で使う。**挟んだ中で何を掛けても、外へ出れば元に戻る** ので、
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
    ///     ![45 度傾いた橙色の正方形の中央に、傾いていない水色の小さな正方形が重なっている](https://i.gyazo.com/cf9ab55af58faad86e938f53f5152aa0.png)
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
    ///     ![橙・灰・黄の同じ大きさの正方形が、左から等間隔に 3 つ並んでいる](https://i.gyazo.com/f1e868c53ae8098c720cf8571b178cdf.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 積んだ変換も**フレームを越えない** (`setup()` と止まっている間の入力のコールバックでも積めるが、その呼び出しを抜けるときに戻す)。フレームの頭で空に戻るので、戻し忘れても次のフレームへは残らない。
    // shot: 1 snippet=ec08da66
    // shot: 2 snippet=f32daf1c
    public func pushMatrix(fileID: StaticString = #fileID, line: UInt = #line) {
        Self.liveCanvas(.act, "pushMatrix()")?.pushMatrix(fileID: fileID, line: line)
    }

    /// 積んでおいた変換へ戻す。
    ///
    /// 積んでいなければ何もせず、呼んだ行を名指して 1 度だけ注意する。
    ///
    /// **積んでいないときに呼んでも落ちない。** 何もせずそのまま進むので、対にし忘れた
    /// 場合は「戻らない」ことだけが起きる — 下の例は ``pushMatrix(fileID:line:)`` を呼んでいないので、
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
    ///     ![45 度傾いた橙色の正方形の中央に、同じく傾いた水色の小さな正方形が重なっている](https://i.gyazo.com/46a67b65366b6e8d8d4dfea6c9fad5b0.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 積んだ変換も**フレームを越えない** (`setup()` と止まっている間の入力のコールバックでも積めるが、その呼び出しを抜けるときに戻す)。フレームの頭で空に戻る。
    // shot: 1 snippet=2d914404
    public func popMatrix(fileID: StaticString = #fileID, line: UInt = #line) {
        Self.liveCanvas(.act, "popMatrix()")?.popMatrix(fileID: fileID, line: line)
    }

    /// 変換とスタイルの**両方**を積んでおく。
    ///
    /// 片方だけを積みたいときは ``pushMatrix(fileID:line:)`` / ``pushStyle(fileID:line:)`` を使う。
    ///
    /// 対の ``pop(fileID:line:)`` を通らないままフレームが終わると、`push()` を呼んだ行を名指して
    /// 1 度だけ注意する。部品の早期 `return` で対が崩れやすいときは、閉包で戻す ``push(_:)`` を使う。
    /// `fileID`・`line` はこの名指しのためのもので、書かずに呼ぶ (呼んだ場所が入る)。
    ///
    /// **``pushMatrix(fileID:line:)`` との違いは、色や線の太さも一緒に戻ること。** 下の例は挟んだ
    /// 中で原点も色も太さも変えているが、``pop(fileID:line:)`` の後の四角は**どれも元のまま**で
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
    ///     ![右に太い橙色の枠の正方形、左に細い灰色の枠の正方形が並んでいる](https://i.gyazo.com/5cfbbb0f82e6c730028ff1623bbdb849.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: **積んだ履歴はフレームを越えない** (`setup()` と止まっている間の入力のコールバックでも積めるが、その呼び出しを抜けるときに戻す)。 変換もスタイルも、積んだ事実は `draw()` の頭で
    ///   捨てられるので、``push(fileID:line:)`` と ``pop(fileID:line:)`` は同じフレームの中で釣り合わせる。
    ///   スタイルそのもの (塗り・線・混ぜ方) はフレームを越える (切り抜き・材質・影を落とす / 受ける
    ///   設定は、そのフレームの中だけ)。
    ///   ``pop(fileID:line:)`` を忘れると、``push(fileID:line:)`` の後に変えた塗りや混ぜ方が次のフレームへ持ち越される
    ///   (たとえば `push(); blendMode(.add)` のまま終えると、次のフレームの頭から
    ///   加算が効き続ける)。変換だけは頭で戻る。
    // shot: 1 snippet=2665a2c3
    public func push(fileID: StaticString = #fileID, line: UInt = #line) {
        Self.liveCanvas(.act, "push()")?.push(fileID: fileID, line: line)
    }

    /// 積んでおいた変換とスタイルの両方へ戻す。
    ///
    /// 積んでいなければ何もせず、呼んだ行を名指して 1 度だけ注意する。
    ///
    /// **``push(fileID:line:)`` と対で使う。** 積んでいないときに呼んでも落ちず、何もせず進む (変換もスタイルも積んでいなかったときだけ、呼んだ行を名指して 1 度だけ注意する)。
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
    ///     ![灰・橙・水色の同じ大きさの正方形が、左から等間隔に 3 つ並んでいる](https://i.gyazo.com/69f9f7969cbf17ff00ecda6b0eba0649.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: **積んだ履歴はフレームを越えない** (`setup()` と止まっている間の入力のコールバックでも積めるが、その呼び出しを抜けるときに戻す)。 変換もスタイルも、積んだ事実は `draw()` の頭で
    ///   捨てられるので、``push(fileID:line:)`` と ``pop(fileID:line:)`` は同じフレームの中で釣り合わせる。
    ///   スタイルそのもの (塗り・線・混ぜ方) はフレームを越える (切り抜き・材質・影を落とす / 受ける
    ///   設定は、そのフレームの中だけ)。
    ///   ``push(fileID:line:)`` の後に変えた塗りや混ぜ方は、``pop(fileID:line:)`` を忘れると次のフレームへ持ち越される
    ///   (たとえば `push(); blendMode(.add)` のまま終えると、次のフレームの頭から加算が効き続ける)。
    ///   変換だけは頭で戻る。
    // shot: 1 snippet=45e99a0e
    public func pop(fileID: StaticString = #fileID, line: UInt = #line) {
        Self.liveCanvas(.act, "pop()")?.pop(fileID: fileID, line: line)
    }

    /// 閉包の間だけ変換とスタイルを積み、閉包を抜けたら戻す。
    ///
    /// **``push(fileID:line:)`` と ``pop(fileID:line:)`` の対を、閉包の範囲で書く形。** 閉包を抜けると、
    /// 途中で `return` しても投げても、積んだときの変換とスタイルへ戻る。手で対にすると、部品の
    /// 早期 `return` が `pop()` を飛ばし、後に描く図形へ移動や塗りが漏れる。下の例は真ん中の回で
    /// 描かずに抜けるが、下の段の円は 3 つとも同じ灰色で、同じ高さに並ぶ。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(140, 153, 178)
    ///     for i in 0..<3 {
    ///         push {
    ///             translate(80 + i * 120, 110)
    ///             fill(242, 115, 64)
    ///             guard i != 1 else { return }  // 真ん中は描かずに抜ける
    ///             square(-35, -35, 70)
    ///         }
    ///         // 抜け方によらず、移動と橙の塗りは戻っている
    ///         circle(80 + i * 120, 220, 40)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 上の段は左と右にだけ橙色の正方形があり、真ん中は空いている。下の段には灰色の円が 3 つ、同じ高さに等間隔で並ぶ | symmetric=x -->
    ///     ![上の段は左と右にだけ橙色の正方形があり、真ん中は空いている。下の段には灰色の円が 3 つ、同じ高さに等間隔で並ぶ](https://i.gyazo.com/89f86602b563b243ae1b3b1bf07da19e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 戻すのは ``push(fileID:line:)`` が積むものと同じ (変換とスタイル) で、光・視点・置いた図形は
    /// 戻らない。閉包が投げたら、戻してから同じエラーを呼び出し元へ投げ直す。閉包の中の積み降ろしは
    /// 閉包の中で閉じる — 中の余分な `pop()` は外で積んだ段を取らない。
    ///
    /// - Note: 描き場所の ``Canvas/draw(_:)`` とは役目が違う。あちらは描き場所の 1 フレームを開いて
    ///   閉じ、こちらはフレームを開かず、いま描いている面の状態を閉包の範囲で戻すだけである。描き場所の
    ///   `draw { }` の中でも、その描き場所の `push { }` として使える。`setup()` と止まっている間の入力の
    ///   コールバックの中でも、同じく閉包の範囲で変換とスタイルを戻す。
    // shot: 1 snippet=720a4372
    public func push(_ body: () throws -> Void) rethrows {
        guard let canvas = Self.liveCanvas(.act, "push()") else { return try body() }
        try canvas.push(body)
    }
}
