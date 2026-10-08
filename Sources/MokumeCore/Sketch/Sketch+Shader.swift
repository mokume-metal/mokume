// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 利用者が書く塗り。
extension Sketch {
    /// 断片を読み込む。
    ///
    /// <!-- example: 文脈 var waves: Shader! -->
    /// ```swift
    /// // waves.metal
    /// // float4 paint(Fragment in, Values values) {
    /// //     float wave = 0.5 + 0.5 * sin(in.place.x * 20 + in.time * values.speed);
    /// //     return float4(values.tint.rgb * wave, 1);
    /// // }
    /// waves = try? loadShader(
    ///     "assets/waves.metal",
    ///     values: ["speed": 2, "tint": .color(color(255, 128, 51))])
    /// ```
    ///
    /// 文字列から作る ``makeShader(_:name:values:surfaces:)`` も、ここに書いた規約のまま書ける。
    /// 値・面・平面と立体・秒数を 1 つずつ動かした例と絵は、そちらにある。
    ///
    /// ## 書くのは「その画素の色」だけ
    ///
    /// 断片が用意するのは `paint` 1 本で、返すのはその画素の色である。下地との
    /// 混ぜ方 (``blendMode(_:)``) は書かなくてよい — 組み込みの塗りとまったく同じ
    /// 合成を通るので、**混ぜ方が断片によって食い違わない。**
    ///
    /// `Fragment` から読めるもの: 面の中の位置 (`position` は画素の中心・`place` は 0…1)・
    /// 読む面の位置 (`uv`)・図形の色 (`color`)・読んだ面の値 (`texel`)・秒数
    /// (`time`)・面の大きさ (`resolution`)。
    ///
    /// **`position` と `resolution` は、スケッチの座標と同じ出す画素で届く。**
    /// ``SketchSettings/pixelDensity`` を下げても、スケッチの座標で書いた値と比べられる。
    /// 細かさ 1 では `position` は整数 + 0.5 の値で、1 未満では描く画素の中心を出す画素へ
    /// 換算した値 (0.5 なら 1, 3, 5, …) になる。
    ///
    /// ## 渡す値は読み込むときに宣言する
    ///
    /// `values` に書いた名前が、断片から `values.名前` で読める。後から名前を増やすと
    /// 断片ごと組み直しになるので、**名前は読み込むときに決め、値だけを後から変える**
    /// (``Shader/set(_:_:)-(_,ShaderValue)``)。
    ///
    /// 渡せるのは **float 換算で 64 個まで** (色は 4 個ぶん・2 つ組は 2 個ぶん) — 値は列
    /// ごとに 1 区画へ載せるので、上限は動かせない。超えた宣言は読み込みの時点で断られる。
    ///
    /// ## 面も名前で渡せる
    ///
    /// `surfaces` に書いた名前が、断片から `surfaces.名前` で読める。**渡せるのは
    /// 読み込んだ絵と、自分で描いた面の両方**である。
    ///
    /// <!-- example: 文脈 var blended: Shader! -->
    /// ```swift
    /// // blended.metal
    /// // float4 paint(Fragment in, Values values, Surfaces surfaces) {
    /// //     float4 wood = mokume_sample(surfaces.grain, in.uv);
    /// //     float4 dirt = mokume_sample(surfaces.smudge, in.place);
    /// //     return float4(wood.rgb * mix(1.0, dirt.r, values.amount), wood.a);
    /// // }
    /// guard let bark = try? loadImage("assets/bark.png"),
    ///     let smudge = try? createGraphics(256, 256)
    /// else { return }
    /// blended = try? loadShader(
    ///     "assets/blended.metal",
    ///     values: ["amount": 0.7],
    ///     surfaces: ["grain": .image(bark), "smudge": .graphics(smudge)])
    /// ```
    ///
    /// **面を宣言した断片だけ、受け取るものが 1 つ増える。** 宣言していない断片は
    /// `paint(Fragment, Values)` のままで、書き換えなくてよい。
    ///
    /// 渡せるのは **4 枚まで** — 面は名前ごとに口を 1 つ使い、口の数は断片によらず
    /// 決まっている。超えた宣言は読み込みの時点で断られる。値と同じく、**名前は
    /// 読み込むときに決め、面だけを後から差し替える** (``Shader/set(_:_:)-(_,ShaderSurface)``)。
    ///
    /// ## 平面にも立体にも同じ断片が効く
    ///
    /// **書き分けは要らない。** `rect` にも `box` にも同じ断片が同じ規約で効く —
    /// 前置きの配り方も、渡す値も、置き場も同じである。立体では `Fragment` の
    /// `color` に**光と材質を通したあとの色**が入るので、`in.color` をそのまま
    /// 返せば組み込みの塗りと同じ絵になり、そこから変えていける。
    ///
    /// 断片が書けるのは**その画素の色だけ**で、頂点の落とし方は差し替えられない。
    /// まとめ描き (``shape(_:at:)``) は頂点の側の仕組みなので、**断片を使っても
    /// まとまり方は変わらない。**
    ///
    /// ## 保存したら差し替わる
    ///
    /// 在処のある断片は保存を拾って組み直される。**組み立てに失敗しても絵は消えない** —
    /// 前の断片がそのまま残り、失敗の理由は観測の警告に出る。平面と立体の両方が
    /// 組み上がってはじめて差し替わるので、片方だけ古い断片が効くことはない。
    ///
    /// - Throws: 見つからないとき・組み立てられないとき・値や面が多すぎるときに ``ShaderFailure``。
    // shot: 参照 makeShader(_:name:values:surfaces:)
    public func loadShader(
        _ path: String, values: [String: ShaderValue] = [:],
        surfaces: [String: ShaderSurface] = [:]
    ) throws(ShaderFailure) -> Shader {
        try canvas.loadShader(path, values: values, surfaces: surfaces)
    }

    /// 文字列から断片を作る。保存の拾い直しは効かない (在処が無いため)。
    ///
    /// 書き方の規約 (書くのは `paint` 1 本・値と面は作るときに名前で宣言する・平面にも立体にも
    /// 同じ断片が効く) は ``loadShader(_:values:surfaces:)`` と同じである。下の例はどれも、
    /// 断片を `setup()` で 1 度だけ作り、`draw()` で ``shader(_:)`` を当ててから図形を置く。
    ///
    /// ## 値は名前を決めて渡し、後から変える
    ///
    /// 下は、縞の濃さを `values.amount` で決める断片で、値を 0・0.5・1 と変えながら同じ橙色の
    /// 四角を 3 つ置いたもの。0 では断片が図形の色 (`in.color`) をそのまま返すので、組み込みの
    /// 塗りと同じ一色になる。値を変えても、先に置いた四角は置いたときの値で描かれる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var stripes: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         // 16 画素ごとの縦縞。暗い側の濃さを values.amount で決める
    ///         stripes = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 float band = step(0.5, fract(in.position.x / 16.0));
    ///                 float shade = mix(1.0, 0.25, band * values.amount);
    ///                 return float4(in.color.rgb * shade, in.color.a);
    ///             }
    ///             """,
    ///             values: ["amount": 0])
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         shader(stripes)
    ///         // 名前は作るときに決めてあるので、値だけを変えて置いていく
    ///         let amounts: [Float] = [0, 0.5, 1]
    ///         for i in 0..<3 {
    ///             stripes.set("amount", .number(amounts[i]))
    ///             rect(30 + i * 125, 80, 90, 140)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ大きさの橙色の四角が 3 つ。左は一色で、中は淡い縦縞、右は濃い縦縞が入っている | symmetric=y -->
    ///     ![同じ大きさの橙色の四角が 3 つ。左は一色で、中は淡い縦縞、右は濃い縦縞が入っている](https://i.gyazo.com/5a77210c665bfd5bb8e39adf247936c0.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 平面にも立体にも
    ///
    /// 同じ断片を、左の四角 (`rect`) と、光を当てた右の箱 (`box`) に当てたもの。縞の間隔は
    /// どちらも同じ 16 画素で、箱では `in.color` に光を通した後の色が入るので、面ごとの明るさの
    /// 違いの上に同じ比で縞が乗る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var stripes: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         stripes = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 float band = step(0.5, fract(in.position.x / 16.0));
    ///                 return float4(in.color.rgb * mix(1.0, 0.25, band), in.color.a);
    ///             }
    ///             """)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         lights()
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         shader(stripes)
    ///         rect(30, 90, 120, 120)
    ///         // 立体では、光を通した後の色が in.color に入る
    ///         push()
    ///         translate(280, 150, 0)
    ///         rotateX(-0.5)
    ///         rotateY(0.6)
    ///         box(120)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左に橙色の四角、右に傾けた橙色の箱があり、どちらにも同じ間隔の縦縞が入っている。箱は面ごとに明るさが違い、その上に縞が乗っている -->
    ///     ![左に橙色の四角、右に傾けた橙色の箱があり、どちらにも同じ間隔の縦縞が入っている。箱は面ごとに明るさが違い、その上に縞が乗っている](https://i.gyazo.com/f730e945ac60e80ff6ed6bc14123e7a1.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 面を渡して読む
    ///
    /// `surfaces` には、自分で描いた面 (``ShaderSurface/graphics(_:)``) も、画素から作った絵や
    /// 読み込んだ絵 (``ShaderSurface/image(_:)``) も渡せる。下は同じ断片に、上の帯には 4 色の縦の
    /// 帯を描いた描き場所を、下の四角と円には市松の絵を渡したもの。断片は面の中の位置
    /// (`in.place`) で読むので、面いっぱいに広げた 1 枚を形の窓から覗いたように見え、市松は
    /// 四角と円にまたがって途切れずに続く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var fromCanvas: Shader! -->
    ///     <!-- example: 文脈 var fromImage: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         // 自分で描いた面: 4 色の縦の帯
    ///         let bands = try! createGraphics(100, 100)
    ///         bands.beginDraw()
    ///         bands.noStroke()
    ///         bands.fill(242, 115, 64)
    ///         bands.rect(0, 0, 25, 100)
    ///         bands.fill(242, 217, 89)
    ///         bands.rect(25, 0, 25, 100)
    ///         bands.fill(89, 191, 242)
    ///         bands.rect(50, 0, 25, 100)
    ///         bands.fill(140, 148, 166)
    ///         bands.rect(75, 0, 25, 100)
    ///         bands.endDraw()
    ///         // 画素から作った絵: 10 画素ごとの市松
    ///         let checks = try! createImage(80, 60)
    ///         for y in 0..<60 {
    ///             for x in 0..<80 {
    ///                 let odd = (x / 10 + y / 10) % 2 == 1
    ///                 checks.set(x, y, odd ? color(242, 217, 89) : color(51, 71, 102))
    ///             }
    ///         }
    ///         // 同じ断片に、面の名前を揃えて別々の面を渡す
    ///         let body = """
    ///             float4 paint(Fragment in, Values values, Surfaces surfaces) {
    ///                 return mokume_sample(surfaces.pattern, in.place);
    ///             }
    ///             """
    ///         fromCanvas = try! makeShader(body, surfaces: ["pattern": .graphics(bands)])
    ///         fromImage = try! makeShader(body, surfaces: ["pattern": .image(checks)])
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         shader(fromCanvas)
    ///         rect(20, 30, 360, 100)
    ///         shader(fromImage)
    ///         rect(20, 170, 160, 100)
    ///         circle(300, 220, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 上に横長の帯、下に四角と円。上の帯は左から橙・黄・水色・灰の 4 色に分かれ、下の四角と円には黄と紺の市松が入り、市松の升目は四角と円にまたがって揃っている -->
    ///     ![上に横長の帯、下に四角と円。上の帯は左から橙・黄・水色・灰の 4 色に分かれ、下の四角と円には黄と紺の市松が入り、市松の升目は四角と円にまたがって揃っている](https://i.gyazo.com/0eb28d2707fac7a75caf13c8a3d3c505.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 秒数で動かす
    ///
    /// `in.time` はスケッチが始まってからの秒数で、フレームごとに進む。下は縞を `in.time` で
    /// 右へ流す断片で、上の帯は `speed` を 6、下の帯は 12 にして置いたもの。下の縞は上の 2 倍の
    /// 速さで流れる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var waves: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         waves = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 float wave = sin(in.position.x * 0.15 - in.time * values.speed);
    ///                 return float4(in.color.rgb * (0.6 + 0.4 * wave), in.color.a);
    ///             }
    ///             """,
    ///             values: ["speed": 6])
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         shader(waves)
    ///         waves.set("speed", 6)
    ///         rect(30, 40, 340, 90)
    ///         waves.set("speed", 12)
    ///         rect(30, 170, 340, 90)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 上下 2 本の橙色の帯に縦縞があり、どちらの縞も右へ流れていく。下の帯の縞は上の帯の 2 倍の速さで流れる | frames=60 -->
    ///     ![上下 2 本の橙色の帯に縦縞があり、どちらの縞も右へ流れていく。下の帯の縞は上の帯の 2 倍の速さで流れる](https://i.gyazo.com/49128c7d94d853adcdfb0f1777603c8f.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Throws: 組み立てられないとき・値や面が多すぎるときに ``ShaderFailure``。
    // shot: 1 snippet=7a78b249
    // shot: 2 snippet=3bf5c822
    // shot: 3 snippet=cfc04917
    // shot: 4 snippet=fd4f4dea
    public func makeShader(
        _ body: String, name: String = "shader", values: [String: ShaderValue] = [:],
        surfaces: [String: ShaderSurface] = [:]
    ) throws(ShaderFailure) -> Shader {
        try canvas.makeShader(body, name: name, values: values, surfaces: surfaces)
    }

    /// これから描くものを、この断片で塗る。
    ///
    /// **溜めている図形はその場で区切られる**ので、これより前に置いた図形が
    /// 後から差し替わることはない。
    ///
    /// 下は、同じ橙色の四角を 3 つ置き、2 つ目の前に縦縞の断片を、3 つ目の前に格子の断片を
    /// 当てたもの。当てる前に置いた左の四角は組み込みの塗りのまま一色で、それぞれの四角は
    /// 置いた時点の断片で塗られる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var stripes: Shader! -->
    ///     <!-- example: 文脈 var checks: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         stripes = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 float band = step(0.5, fract(in.position.x / 16.0));
    ///                 return float4(in.color.rgb * mix(1.0, 0.25, band), in.color.a);
    ///             }
    ///             """)
    ///         checks = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 float2 cell = floor(in.position / 20.0);
    ///                 float odd = fmod(cell.x + cell.y, 2.0);
    ///                 return float4(in.color.rgb * mix(1.0, 0.25, odd), in.color.a);
    ///             }
    ///             """)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         rect(30, 80, 100, 140)
    ///         shader(stripes)
    ///         rect(150, 80, 100, 140)
    ///         shader(checks)
    ///         rect(270, 80, 100, 140)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ大きさの橙色の四角が 3 つ。左は一色、中は縦縞、右は市松の格子で塗られている | symmetric=y -->
    ///     ![同じ大きさの橙色の四角が 3 つ。左は一色、中は縦縞、右は市松の格子で塗られている](https://i.gyazo.com/703e3db2ac7585fde11e14ebd5640003.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 当てた断片は、``resetShader()`` か次の `shader(_:)` まで残る (下の Note)。下は、`setup()` で
    /// 1 度だけ当てた断片が、`draw()` で置いた四角と円を塗っているもの。`draw()` の中では断片に
    /// 触れていない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var stripes: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         stripes = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 float band = step(0.5, fract(in.position.x / 16.0));
    ///                 return float4(in.color.rgb * mix(1.0, 0.25, band), in.color.a);
    ///             }
    ///             """)
    ///         // 当てるのは 1 度だけ
    ///         shader(stripes)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         rect(50, 80, 120, 140)
    ///         fill(89, 191, 242)
    ///         circle(290, 150, 140)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左に橙色の四角、右に水色の円があり、どちらも縦縞で塗られている | symmetric=y -->
    ///     ![左に橙色の四角、右に水色の円があり、どちらも縦縞で塗られている](https://i.gyazo.com/465f126a31198c102e6b22deca558512.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 断片は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=2acc7397
    // shot: 2 snippet=dc7bbac5
    public func shader(_ shader: Shader) { canvas.shader(shader) }

    /// 組み込みの塗りへ戻す。
    ///
    /// 下は、同じ橙色の四角を、断片を当てる前・当てた後・戻した後に 1 つずつ置いたもの。戻した
    /// 後の右の四角は、当てる前の左の四角と同じ一色に戻る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var stripes: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         stripes = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 float band = step(0.5, fract(in.position.x / 16.0));
    ///                 return float4(in.color.rgb * mix(1.0, 0.25, band), in.color.a);
    ///             }
    ///             """)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         rect(30, 80, 100, 140)
    ///         shader(stripes)
    ///         rect(150, 80, 100, 140)
    ///         resetShader()
    ///         rect(270, 80, 100, 140)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ大きさの橙色の四角が 3 つ。左と右は同じ一色で、中だけが縦縞で塗られている | symmetric=y -->
    ///     ![同じ大きさの橙色の四角が 3 つ。左と右は同じ一色で、中だけが縦縞で塗られている](https://i.gyazo.com/9c2ba34208cab397eb97cf253d15536c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 断片は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=17f903d5
    public func resetShader() { canvas.resetShader() }
}
