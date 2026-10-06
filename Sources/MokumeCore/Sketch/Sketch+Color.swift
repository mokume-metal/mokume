// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Sketch {
    /// 下地を、素の数値で塗る。**目盛りは 0–255** ([ADR-0033] 決定 1)。
    ///
    /// 3 つなら赤・緑・青、4 つ目は不透明度。
    ///
    /// **不透明度は 0–255 に締める。色の成分は締めない** — 不透明度の 400 は 255 と、
    /// -100 は 0 と同じになる。成分の 255 を越える値は、白を越える明るさのまま残る
    /// ([ADR-0033] 決定 3 の改訂・決定 6)。
    ///
    /// 下は赤だけを 3 段に変えたもの。面を切り抜きで 3 つに割り、それぞれの中で塗り直して
    /// いる (切り抜きの中で呼ぶと、その中だけを置き換える)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     for (index, red) in [40, 140, 240].enumerated() {
    ///         clip(index * 134, 0, 134, height)
    ///         background(red, 60, 90)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 面が縦に 3 つに分かれ、左の紺から右の赤みの強い色へ、赤だけが増えていく | symmetric=y -->
    ///     ![面が縦に 3 つに分かれ、左の紺から右の赤みの強い色へ、赤だけが増えていく](https://i.gyazo.com/ae77341c6eac9992705d9fcd0d3809b8.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **不透明度は下地に重ならない。面をその色で置き換える** — 半透明の色なら、面が
    /// 半透明の色になり、前の絵は残らない。下は円を 3 つ描いた後、右半分だけを不透明度
    /// 128 の色で塗り直したもの — 右の円は透けて残らず、左の円だけが残る。残像の作り方、
    /// p5.js の `background(0, 20)` との違い、窓での見え方 (後ろは透けない) は
    /// ``background(_:_:)`` に書いた。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(15, 18, 23)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     for index in 0..<3 {
    ///         circle(80 + index * 120, 150, 100)
    ///     }
    ///     clip(200, 0, 200, height)
    ///     background(40, 90, 160, 128)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左半分には橙色の円が 1 つ半残り、右半分は円の跡の無い、半透明の一様な青になっている | symmetric=y -->
    ///     ![左半分には橙色の円が 1 つ半残り、右半分は円の跡の無い、半透明の一様な青になっている](https://i.gyazo.com/1009a12b4b5c7190af6d416f432456ae.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 色の値で塗る `background(_:)` と同じく、混ぜ方などの呼んだ時点の描き方は効かず、
    /// 切り抜きの中で呼べばその中だけを置き換える。
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    // shot: 1 snippet=3b229f0e
    // shot: 2 snippet=c017b8a7
    public func background(
        _ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible, _ alpha: some ScalarConvertible = 255
    ) {
        let (red, green, blue, alpha) = (red.asFloat, green.asFloat, blue.asFloat, alpha.asFloat)
        canvas.background(red, green, blue, alpha)
    }

    /// 下地を灰色で塗る。**目盛りは 0–255**、2 つ目は不透明度。
    ///
    /// **不透明度は 0–255 に締める。灰色の値は締めない。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     for (index, gray) in [24, 110, 220].enumerated() {
    ///         clip(index * 134, 0, 134, height)
    ///         background(gray)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 面が縦に 3 つに分かれ、左の黒に近い灰色から右の明るい灰色へ明るくなっていく | symmetric=y -->
    ///     ![面が縦に 3 つに分かれ、左の黒に近い灰色から右の明るい灰色へ明るくなっていく](https://i.gyazo.com/2e753a386b4a73f19ff66d68f7cb5f28.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **不透明度は下地に重ならない。面をその灰色で置き換える** — `background(0, 20)` は
    /// 面を不透明度 20 の黒 1 色にするので、前の絵は残らない。毎フレーム呼んでも
    /// 残像にはならない。下は右半分だけを `background(0, 20)` で塗り直したもの。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(230)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     for index in 0..<3 {
    ///         circle(80 + index * 120, 150, 100)
    ///     }
    ///     clip(200, 0, 200, height)
    ///     background(0, 20)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左半分は明るい灰色の上に橙色の円が 1 つ半、右半分は円の跡が無く、ほとんど透けた黒一色になっている | symmetric=y -->
    ///     ![左半分は明るい灰色の上に橙色の円が 1 つ半、右半分は円の跡が無く、ほとんど透けた黒一色になっている](https://i.gyazo.com/616c78e64517880dbad33f095ad33808.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **窓では、半透明の面の後ろは透けない。** 窓は面を黒の下地に重ねた色で出す —
    /// `background(0, 20)` は黒一色に、`background(255, 20)` は暗い灰色 (不透明度 20 の
    /// 白を黒に重ねた色) に見え、窓の後ろにある別の窓は見えない。上の絵の右半分が透けて
    /// 見えるのは、書き出した画像だからである。不透明度を保つのは画像・動画のほうで、
    /// 窓は保たない ([ADR-0023] 決定 4)。
    ///
    /// 色の値で塗る `background(_:)` と同じく、混ぜ方などの呼んだ時点の描き方は効かず、
    /// 切り抜きの中で呼べばその中だけを置き換える。
    ///
    /// 残像は、面と同じ大きさの四角を薄く重ねて作る。塗り直さないので、前の絵が
    /// 少しずつ暗くなりながら残る。
    ///
    /// ```swift
    /// if frameCount == 1 { background(0) }
    /// noStroke()
    /// fill(0, 20)
    /// rect(0, 0, width, height)   // 前の絵を少しだけ暗くする
    /// fill(255)
    /// circle(mouseX, mouseY, 20)
    /// ```
    ///
    /// - Note: **p5.js の `background(0, 20)` とは違い、残像にならない。** p5.js は前の絵の
    ///   上に薄い黒を重ねるが、こちらは面を置き換える。Processing は本体の面では不透明度を
    ///   使えない (`PGraphics` だけ)。手本に従うのは名前と引数の順序までで、画素の出方は
    ///   追わない ([ADR-0020] 決定 1)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    // shot: 1 snippet=724387cf
    // shot: 2 snippet=2e391461
    public func background(_ gray: some ScalarConvertible, _ alpha: some ScalarConvertible = 255) {
        let (gray, alpha) = (gray.asFloat, alpha.asFloat)
        canvas.background(gray, alpha)
    }

    /// これから描く図形の塗りを、素の数値で決める。**目盛りは 0–255**。
    ///
    /// 3 つなら赤・緑・青、4 つ目は不透明度。**塗りを止めていたら、呼んだ時点で
    /// 再び塗るようになる。**
    ///
    /// **不透明度は 0–255 に締める。色の成分は締めない** — 不透明度の 400 は 255 と、
    /// -100 は 0 と同じになる。成分の 255 を越える値は、白を越える明るさのまま残る
    /// ([ADR-0033] 決定 3 の改訂・決定 6)。
    ///
    /// 下は緑だけを 3 段に変えたもの。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(15, 18, 23)
    ///     noStroke()
    ///     for (index, green) in [0, 115, 230].enumerated() {
    ///         fill(242, green, 64)
    ///         circle(80 + index * 120, 150, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 円が 3 つ。左の赤から、橙、右の黄色へと緑だけが増えていく | symmetric=y -->
    ///     ![円が 3 つ。左の赤から、橙、右の黄色へと緑だけが増えていく](https://i.gyazo.com/ec13c127fc779396048a72e39dc561fa.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 4 つ目の不透明度を 255 / 128 / 32 と下げると、下に敷いた白い帯が透けて見えてくる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(15, 18, 23)
    ///     noStroke()
    ///     fill(240)
    ///     rect(0, 125, width, 50)
    ///     for (index, alpha) in [255, 128, 32].enumerated() {
    ///         fill(242, 115, 64, alpha)
    ///         circle(80 + index * 120, 150, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い横帯の上に橙色の円が 3 つ。左は帯を隠し、中央は帯が透け、右はほとんど見えない | symmetric=y -->
    ///     ![白い横帯の上に橙色の円が 3 つ。左は帯を隠し、中央は帯が透け、右はほとんど見えない](https://i.gyazo.com/aa8eb13640fd8f855088503bf550669b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 不透明度の範囲の外は締める — 400 は 255 と、-100 は 0 と同じ絵になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(15, 18, 23)
    ///     noStroke()
    ///     fill(240)
    ///     rect(0, 125, width, 50)
    ///     for (index, alpha) in [400, 255, -100].enumerated() {
    ///         fill(242, 115, 64, alpha)
    ///         circle(80 + index * 120, 150, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左と中央は同じ不透明な橙色の円で、右には円が無く白い帯がそのまま通っている | symmetric=y -->
    ///     ![左と中央は同じ不透明な橙色の円で、右には円が無く白い帯がそのまま通っている](https://i.gyazo.com/7a606b8c865ed8125c8ef0b24b5c6044.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 色の成分は締めない。下は同じ不透明度 128 で、赤を 255 と 510 にしたもの (右は比べる
    /// ための不透明な 255)。510 は 255 で止まらずに残るので、半分透けても不透明な 255 より明るく出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(15, 18, 23)
    ///     noStroke()
    ///     fill(255, 0, 0, 128)
    ///     circle(80, 150, 100)
    ///     fill(510, 0, 0, 128)
    ///     circle(200, 150, 100)
    ///     fill(255, 0, 0)
    ///     circle(320, 150, 100)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 赤い円が 3 つ。左は暗い赤、中央は右の不透明な赤よりも明るい | symmetric=y -->
    ///     ![赤い円が 3 つ。左は暗い赤、中央は右の不透明な赤よりも明るい](https://i.gyazo.com/f8c637a4557092581cb57f8037c2a50c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: `Int` の変数もそのまま渡せる (`fill(i, 0, 0)`)。
    ///   0–1 で書きたいときは ``LinearRGBA/display(red:green:blue:alpha:)`` を渡す。
    ///
    /// - Note: 塗りは**フレームを越える**。一度書けば、書き換えるまで残る。
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    // shot: 1 snippet=1cb50cc1
    // shot: 2 snippet=3cbdf982
    // shot: 3 snippet=dacf980c
    // shot: 4 snippet=7d92c52c
    public func fill(_ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible, _ alpha: some ScalarConvertible = 255) {
        let (red, green, blue, alpha) = (red.asFloat, green.asFloat, blue.asFloat, alpha.asFloat)
        canvas.fill(red, green, blue, alpha)
    }

    /// 塗りを灰色にする。**目盛りは 0–255**、2 つ目は不透明度。
    ///
    /// **不透明度は 0–255 に締める。灰色の値は締めない。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(15, 18, 23)
    ///     noStroke()
    ///     for (index, gray) in [60, 140, 230].enumerated() {
    ///         fill(gray)
    ///         circle(80 + index * 120, 150, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の円が 3 つ。左の暗い灰色から右の白に近い灰色へ明るくなっていく | symmetric=y -->
    ///     ![灰色の円が 3 つ。左の暗い灰色から右の白に近い灰色へ明るくなっていく](https://i.gyazo.com/ac14134bb41b594b0a9d431b973672fd.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(15, 18, 23)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     rect(0, 125, width, 50)
    ///     for (index, alpha) in [255, 128, 32].enumerated() {
    ///         fill(230, alpha)
    ///         circle(80 + index * 120, 150, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の横帯の上に明るい灰色の円が 3 つ。左は帯を隠し、中央は帯が透け、右はほとんど見えない | symmetric=y -->
    ///     ![橙色の横帯の上に明るい灰色の円が 3 つ。左は帯を隠し、中央は帯が透け、右はほとんど見えない](https://i.gyazo.com/2ba08133ccd20bd0f47dbf398ed0760f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 塗りは**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=40012a72
    // shot: 2 snippet=69804a28
    public func fill(_ gray: some ScalarConvertible, _ alpha: some ScalarConvertible = 255) {
        let (gray, alpha) = (gray.asFloat, alpha.asFloat)
        canvas.fill(gray, alpha)
    }

    /// 塗りを、色の値と不透明度で決める。**不透明度の目盛りは 0–255**。
    ///
    /// 色を変数に持ったまま、その色を薄めて塗りたいときに使う。**塗りを止めていたら、
    /// 呼んだ時点で再び塗るようになる。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     let ink = color(28, 28, 30)
    ///     background(240)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     rect(0, 125, width, 50)
    ///     for (index, alpha) in [255, 128, 32].enumerated() {
    ///         fill(ink, alpha)
    ///         circle(80 + index * 120, 150, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の横帯の上に黒い円が 3 つ。左は帯を隠し、中央は帯が透け、右はほとんど見えない | symmetric=y -->
    ///     ![橙色の横帯の上に黒い円が 3 つ。左は帯を隠し、中央は帯が透け、右はほとんど見えない](https://i.gyazo.com/89eab5f9bf84b88582f32d6d809bf024.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **不透明度は置き換えずに、色が元から持つ不透明度に掛ける** (手本の Processing と同じ)。
    /// `fill(c, 255)` は `c` のまま塗り、半透明の色を不透明にはしない — 不透明に塗りたいときは
    /// 不透明な色を渡す。`fill(color(230, 120, 40, 128), 128)` の不透明度は 64 あまりになる。
    ///
    /// 下は不透明度 128 の色を、左から 255 / 128 で薄めたもの (右は比べるための不透明な色)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     let half = color(28, 28, 30, 128)
    ///     background(240)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     rect(0, 125, width, 50)
    ///     fill(half, 255)
    ///     circle(80, 150, 100)
    ///     fill(half, 128)
    ///     circle(200, 150, 100)
    ///     fill(color(28, 28, 30), 255)
    ///     circle(320, 150, 100)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の横帯の上に円が 3 つ。左は帯が透ける灰色、中央はさらに薄く、右だけが帯を隠す黒 | symmetric=y -->
    ///     ![橙色の横帯の上に円が 3 つ。左は帯が透ける灰色、中央はさらに薄く、右だけが帯を隠す黒](https://i.gyazo.com/213d723115fabe2235fd87953b8e71bb.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **0–1 ではない。** `fill(c, 0.5)` はほぼ透明になる。0–1 の率で薄めたいときは
    /// `fill(c, rate * 255)` と書く。
    ///
    /// **範囲の外は締める。色の成分は締めない** — 不透明度の 400 は 255 と、-100 は 0 と同じに
    /// なる (掛ける率を 0–1 に締める)。成分の 255 を越える値は、白を越える明るさのまま残る
    /// ([ADR-0033] 決定 3 の改訂・決定 6)。不透明度か色の成分に数でない値・無限があれば受けず、塗りは
    /// 直前のまま残る。
    ///
    /// - Note: 塗りは**フレームを越える**。一度書けば、書き換えるまで残る。
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    // shot: 1 snippet=bdde8bba
    // shot: 2 snippet=676235a6
    public func fill(_ color: LinearRGBA, _ alpha: some ScalarConvertible) {
        canvas.fill(color, alpha.asFloat)
    }

    /// これから引く線の色を、素の数値で決める。**目盛りは 0–255**。
    ///
    /// 3 つなら赤・緑・青、4 つ目は不透明度。**線を止めていたら、呼んだ時点で
    /// 再び引くようになる。**
    ///
    /// **不透明度は 0–255 に締める。色の成分は締めない** — 不透明度の 400 は 255 と、
    /// -100 は 0 と同じになる。成分の 255 を越える値は、白を越える明るさのまま残る
    /// ([ADR-0033] 決定 3 の改訂・決定 6)。
    ///
    /// 下は緑だけを 3 段に変えたもの。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(15, 18, 23)
    ///     strokeWeight(16)
    ///     for (index, green) in [0, 115, 230].enumerated() {
    ///         stroke(242, green, 64)
    ///         line(40, 80 + index * 70, 360, 80 + index * 70)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 横線が 3 本。上の赤から、橙、下の黄色へと緑だけが増えていく | symmetric=x -->
    ///     ![横線が 3 本。上の赤から、橙、下の黄色へと緑だけが増えていく](https://i.gyazo.com/bb977f104a4460ffc66a2ea4829996f8.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 4 つ目の不透明度を 255 / 128 / 32 と下げると、線の下の白い帯が透けて見えてくる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(15, 18, 23)
    ///     noStroke()
    ///     fill(240)
    ///     rect(170, 0, 60, height)
    ///     strokeWeight(16)
    ///     for (index, alpha) in [255, 128, 32].enumerated() {
    ///         stroke(242, 115, 64, alpha)
    ///         line(40, 80 + index * 70, 360, 80 + index * 70)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い縦帯を橙色の横線が 3 本横切る。上の線は帯を隠し、中央は帯が透け、下はほとんど見えない | symmetric=x -->
    ///     ![白い縦帯を橙色の横線が 3 本横切る。上の線は帯を隠し、中央は帯が透け、下はほとんど見えない](https://i.gyazo.com/1f0956611b46359d1c5e0a96fe1d48ed.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 線の色は**フレームを越える**。一度書けば、書き換えるまで残る。
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    // shot: 1 snippet=c65d0ace
    // shot: 2 snippet=7ac96242
    public func stroke(_ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible, _ alpha: some ScalarConvertible = 255) {
        let (red, green, blue, alpha) = (red.asFloat, green.asFloat, blue.asFloat, alpha.asFloat)
        canvas.stroke(red, green, blue, alpha)
    }

    /// 線の色を灰色にする。**目盛りは 0–255**、2 つ目は不透明度。
    ///
    /// **不透明度は 0–255 に締める。灰色の値は締めない。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(15, 18, 23)
    ///     strokeWeight(16)
    ///     for (index, gray) in [60, 140, 230].enumerated() {
    ///         stroke(gray)
    ///         line(40, 80 + index * 70, 360, 80 + index * 70)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の横線が 3 本。上の暗い灰色から下の白に近い灰色へ明るくなっていく | symmetric=x -->
    ///     ![灰色の横線が 3 本。上の暗い灰色から下の白に近い灰色へ明るくなっていく](https://i.gyazo.com/df8854d899a2dd7ba6c19da9b85ae1f7.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(15, 18, 23)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     rect(170, 0, 60, height)
    ///     strokeWeight(16)
    ///     for (index, alpha) in [255, 128, 32].enumerated() {
    ///         stroke(230, alpha)
    ///         line(40, 80 + index * 70, 360, 80 + index * 70)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の縦帯を明るい灰色の横線が 3 本横切る。上の線は帯を隠し、中央は帯が透け、下はほとんど見えない | symmetric=x -->
    ///     ![橙色の縦帯を明るい灰色の横線が 3 本横切る。上の線は帯を隠し、中央は帯が透け、下はほとんど見えない](https://i.gyazo.com/ecee4d21dfea5d4d5f0742c795a020d9.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 線の色は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=c77eab1c
    // shot: 2 snippet=85a0c76b
    public func stroke(_ gray: some ScalarConvertible, _ alpha: some ScalarConvertible = 255) {
        let (gray, alpha) = (gray.asFloat, alpha.asFloat)
        canvas.stroke(gray, alpha)
    }

    /// 線の色を、色の値と不透明度で決める。**不透明度の目盛りは 0–255**。
    ///
    /// 色を変数に持ったまま、その色を薄めて引きたいときに使う。**線を止めていたら、
    /// 呼んだ時点で再び引くようになる。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     let ink = color(28, 28, 30)
    ///     background(240)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     rect(170, 0, 60, height)
    ///     strokeWeight(16)
    ///     for (index, alpha) in [255, 128, 32].enumerated() {
    ///         stroke(ink, alpha)
    ///         line(40, 80 + index * 70, 360, 80 + index * 70)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の縦帯を黒い横線が 3 本横切る。上の線は帯を隠し、中央は帯が透け、下はほとんど見えない | symmetric=x -->
    ///     ![橙色の縦帯を黒い横線が 3 本横切る。上の線は帯を隠し、中央は帯が透け、下はほとんど見えない](https://i.gyazo.com/1e2795cac6918728bac577de1df4874e.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **不透明度は置き換えずに、色が元から持つ不透明度に掛ける** (手本の Processing と同じ)。
    /// `stroke(c, 255)` は `c` のまま引き、半透明の色を不透明にはしない — 不透明に引きたいときは
    /// 不透明な色を渡す。
    ///
    /// **0–1 ではない。** `stroke(c, 0.5)` はほぼ透明になる。0–1 の率で薄めたいときは
    /// `stroke(c, rate * 255)` と書く。
    ///
    /// **範囲の外は締める。色の成分は締めない** — 不透明度の 400 は 255 と、-100 は 0 と同じに
    /// なる (掛ける率を 0–1 に締める)。成分の 255 を越える値は、白を越える明るさのまま残る
    /// ([ADR-0033] 決定 3 の改訂・決定 6)。不透明度か色の成分に数でない値・無限があれば受けず、線の
    /// 色は直前のまま残る。
    ///
    /// - Note: 線の色は**フレームを越える**。一度書けば、書き換えるまで残る。
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    // shot: 1 snippet=d86e117e
    public func stroke(_ color: LinearRGBA, _ alpha: some ScalarConvertible) {
        canvas.stroke(color, alpha.asFloat)
    }

    /// これから描く画像に掛ける色を、素の数値で決める。**目盛りは 0–255**。
    ///
    /// 4 つ目の不透明度を下げると、画像そのものが薄くなる。
    ///
    /// **不透明度は 0–255 に締める。色の成分は締めない** — 不透明度の 400 は 255 と、
    /// -100 は 0 と同じになる。成分の 255 を越える値は、白を越える明るさのまま残る
    /// ([ADR-0033] 決定 3 の改訂・決定 6)。
    ///
    /// 下は橙と紺の 2 色の絵に、赤だけを 255 / 140 / 30 と下げた色を掛けたもの。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<64 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         for (index, red) in [255, 140, 30].enumerated() {
    ///             tint(red, 255, 255)
    ///             image(tile, 20 + index * 125, 95, 110, 110)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ絵が 3 つ。左から右へ赤が抜け、上の橙色の帯が緑がかった暗い色へ変わっていく -->
    ///     ![同じ絵が 3 つ。左から右へ赤が抜け、上の橙色の帯が緑がかった暗い色へ変わっていく](https://i.gyazo.com/445a16adbbac308afdf77460d6ebe587.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<64 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         for (index, alpha) in [255, 128, 32].enumerated() {
    ///             tint(255, 255, 255, alpha)
    ///             image(tile, 20 + index * 125, 95, 110, 110)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ絵が 3 つ。左から右へ薄くなり、右はほとんど下地に沈んでいる -->
    ///     ![同じ絵が 3 つ。左から右へ薄くなり、右はほとんど下地に沈んでいる](https://i.gyazo.com/9a8cf82ab883ec560a818c0636e95a2a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 絵に掛ける色は**フレームを越える**。一度書けば、書き換えるまで残る。
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    // shot: 1 snippet=71ced307
    // shot: 2 snippet=51be46d6
    public func tint(_ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible, _ alpha: some ScalarConvertible = 255) {
        let (red, green, blue, alpha) = (red.asFloat, green.asFloat, blue.asFloat, alpha.asFloat)
        canvas.tint(red, green, blue, alpha)
    }

    /// 画像に掛ける色を灰色にする。**目盛りは 0–255**、2 つ目は不透明度。
    ///
    /// **不透明度は 0–255 に締める。灰色の値は締めない。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<64 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         for (index, gray) in [255, 150, 60].enumerated() {
    ///             tint(gray)
    ///             image(tile, 20 + index * 125, 95, 110, 110)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ絵が 3 つ。色みは変わらず、左から右へ暗くなっていく -->
    ///     ![同じ絵が 3 つ。色みは変わらず、左から右へ暗くなっていく](https://i.gyazo.com/58d6c621c2d123c1babf929da269318a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() {
    ///         tile = try! createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<64 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         for (index, alpha) in [255, 128, 32].enumerated() {
    ///             tint(255, alpha)
    ///             image(tile, 20 + index * 125, 95, 110, 110)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ絵が 3 つ。色みは変わらず、左から右へ薄くなり、右はほとんど下地に沈んでいる -->
    ///     ![同じ絵が 3 つ。色みは変わらず、左から右へ薄くなり、右はほとんど下地に沈んでいる](https://i.gyazo.com/9a8cf82ab883ec560a818c0636e95a2a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 絵に掛ける色は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=c4b369c6
    // shot: 2 snippet=2f7e5ef6
    public func tint(_ gray: some ScalarConvertible, _ alpha: some ScalarConvertible = 255) {
        let (gray, alpha) = (gray.asFloat, alpha.asFloat)
        canvas.tint(gray, alpha)
    }
}
