// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 効果。
extension Sketch {
    /// このフレームの絵にかける効果を決める。
    ///
    /// 下は、描き終えた絵に、ぼかし → にじみ → 周辺減光の順で掛けたもの。にじむのは明るい
    /// ところ (白い円) だけで、橙の円と水色の四角はぼけるだけである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(51, 71, 102)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     circle(150, 150, 140)
    ///     fill(255)
    ///     circle(270, 110, 60)
    ///     fill(89, 191, 242)
    ///     rect(230, 190, 120, 50)
    ///     // 描き終えた絵に、並べた順で掛かる
    ///     effects([.blur(radius: 4), .bloom(amount: 0.6), .vignette(amount: 0.5)])
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 紺の地に、橙色の円・白い円・水色の四角。どれも縁がぼけ、白い円のまわりだけが明るくにじみ、四隅が暗く落ちている -->
    ///     ![紺の地に、橙色の円・白い円・水色の四角。どれも縁がぼけ、白い円のまわりだけが明るくにじみ、四隅が暗く落ちている](https://i.gyazo.com/5cf0f3dc7350ea56b6a6d26f96c27436.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 並びがそのまま順番
    ///
    /// 前から順にかかる。**並びは値なので、組み替えても差し替えても同じように効く** —
    /// 効果ごとの呼び出し口 (`blur()` のようなもの) は置いていない。置いた時点で
    /// 「並び」を持てなくなり、後から段を差し込む先が無くなるためである。
    ///
    /// 下は同じ場面に、周辺減光を 1 つだけ掛けたもの・周辺減光 → 反転の順で掛けたもの・
    /// 反転 → 周辺減光の順で掛けたもの。周辺減光だけなら四隅が暗くなる。後から反転すると、
    /// 暗くした四隅が反転されて明るくなる。先に反転すると、反転した絵の四隅が暗くなる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(140, 160, 191)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     circle(150, 150, 140)
    ///     fill(255)
    ///     circle(270, 110, 60)
    ///     fill(38, 46, 61)
    ///     rect(230, 190, 120, 50)
    ///     effects([.vignette(amount: 0.8)])
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 青灰色の地に、橙色の円・白い円・紺の四角。四隅だけが暗く落ちている -->
    ///     ![青灰色の地に、橙色の円・白い円・紺の四角。四隅だけが暗く落ちている](https://i.gyazo.com/309ecfa3ceb5b778ca04769d5f9ee335.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(140, 160, 191)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     circle(150, 150, 140)
    ///     fill(255)
    ///     circle(270, 110, 60)
    ///     fill(38, 46, 61)
    ///     rect(230, 190, 120, 50)
    ///     // 周辺減光の後に反転
    ///     effects([.vignette(amount: 0.8), .invert()])
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 色が反転した絵。ベージュの地に、水色の円・黒い円・白に近い四角があり、四隅だけが白っぽく明るい -->
    ///     ![色が反転した絵。ベージュの地に、水色の円・黒い円・白に近い四角があり、四隅だけが白っぽく明るい](https://i.gyazo.com/920a8f537b341bafb64444b82a516235.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(140, 160, 191)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     circle(150, 150, 140)
    ///     fill(255)
    ///     circle(270, 110, 60)
    ///     fill(38, 46, 61)
    ///     rect(230, 190, 120, 50)
    ///     // 反転の後に周辺減光
    ///     effects([.invert(), .vignette(amount: 0.8)])
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 色が反転した絵。ベージュの地に、水色の円・黒い円・白に近い四角があり、四隅だけが暗く落ちている -->
    ///     ![色が反転した絵。ベージュの地に、水色の円・黒い円・白に近い四角があり、四隅だけが暗く落ちている](https://i.gyazo.com/fd5dc8f28caf5c408ae56cb442a3107d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## フレームを越えない
    ///
    /// 光や視点と同じで、`draw()` のたびに書き直す。書かなかったフレームには
    /// 何もかからない (塗りや線のような**描き方**は逆に越える)。`setup()` や止まっている
    /// 間の入力のコールバックで書いた並びはどのフレームにも属さないので、警告して無視される。
    ///
    /// **効果のかかった絵も、次のフレームへは持ち越さない。** `background()` を 1 枚目だけ
    /// 呼んで描き足していくスケッチでも、次のフレームが描き足す先は効果を通す前の絵で、
    /// 効果はどのフレームにも 1 回ぶんだけかかる (重なって濃くなっていかない)。
    ///
    /// 下は、`background()` を 1 枚目だけ呼び、右へ動く円を描き足しながら、毎フレーム同じ
    /// ぼかしを掛けたもの。最初に描いた円の縁も、最後に描いた円の縁と同じ幅のぼけのままで、
    /// フレームを重ねても広がっていかない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     // 下地を塗るのは 1 枚目だけ。あとは前の絵に描き足していく
    ///     if frameCount == 1 {
    ///         background(23, 26, 31)
    ///     }
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     circle(40 + Float(frameCount) * 10, 150, 40)
    ///     effects([.blur(radius: 6)])
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の円が左から右へ描き足されて帯になっていく。帯の縁は、描き始めの左端も描き足した右端も同じ幅でぼけている | frames=30 symmetric=y -->
    ///     ![橙色の円が左から右へ描き足されて帯になっていく。帯の縁は、描き始めの左端も描き足した右端も同じ幅でぼけている](https://i.gyazo.com/8dd2690c0d22113d2e302f905c6bfe7e.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 数の意味
    ///
    /// **`amount` は 0…1 で、0 なら効かない。** 寸法は名前で示す (`radius` は画素)。
    /// 画素は座標や線の太さと同じ**出す画素**で、``SketchSettings/pixelDensity`` を下げても
    /// ぼけ・にじみの幅は変わらない。詳しくは ``Effect``。
    ///
    /// 数でない値 (NaN)・無限を持つ効果は掛けずに、初回だけ警告する (並びの他の効果は
    /// 掛かる)。`amount` は 0…1 の外なら端へ締める。
    ///
    /// ## 画素を読むときとの前後
    ///
    /// 効果はフレームの終わりに立つ段なので、``pixels`` のようにフレームの途中で読む
    /// 画素には**まだ効いていない**。次のフレームで読む画素も効果を通す前の絵である。
    /// 画面・書き出し・観測はいずれも効果を通した同じ 1 枚を受け取る (`draw()` の外で
    /// 読む画素も、この 1 枚である)。
    ///
    /// 下は、反転を頼んだ後に円の中の画素を ``get(_:_:)`` で読み、その色で右に四角を置いたもの。
    /// 読んだのは反転する前の橙色なので、四角も円と一緒にフレームの終わりで反転され、円と
    /// 同じ色に出る (読んだ値に反転が入っていれば、四角は 2 度反転されて橙色に戻る)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(140, 160, 191)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     circle(120, 150, 160)
    ///     effects([.invert()])
    ///     // 効果はフレームの終わりに掛かるので、ここで読む画素にはまだ効いていない
    ///     let picked = get(120, 150)
    ///     fill(picked)
    ///     rect(250, 90, 120, 120)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 色が反転したベージュの地に、左の水色の円と、右の同じ水色の四角が並んでいる | symmetric=y -->
    ///     ![色が反転したベージュの地に、左の水色の円と、右の同じ水色の四角が並んでいる](https://i.gyazo.com/e3f09ab492c8ee21ae7f148be5607632.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **止まっている間の入力のコールバックで変えたものは、次のフレームでは効果を通す前の絵の
    /// 上に載る。** 書いた画素も、置いた図形・絵・背景も、そのまま次のフレームへ持ち越され、
    /// 効果が焼き込まれることも消えることもない。縁のなめらかさ・半透明・足す混ぜ方のように
    /// 下地と混ざるものも、効果を通す前の絵と混ざる — 途中で ``get(_:_:)`` などに描き切らせた
    /// かどうかで、次のフレームの絵は変わらない (立体の前後も同じで、描き切らせた立体は、次の
    /// フレームで置いた立体と前後を比べられる)。止まっている間の画面 (窓)・
    /// 書き出し・観測には、効果を通した絵の上に変えた分が載って出る (コールバックを配った直後に、
    /// 書いた画素を描く先へ戻し、描く細かさ ``SketchSettings/pixelDensity`` を下げた面では出す
    /// 細かさへ広げ直す)。気を付けるのは 2 つである:
    ///
    /// - そこで読む画素は効果を通した絵なので、**読んだ値を元に書いた値には効果が入っている**
    ///   (たとえば読んだ色を少し明るくして書き戻すと、周辺減光の暗さごと次のフレームへ載る)
    /// - 書いた画素 (``set(_:_:_:)``・``pixels``) は値で見分ける。**効果を通した絵と同じ値
    ///   (同じビット) を書いた画素は、書かなかった扱いになる** — 読んだ値をそのまま書き戻すのと見分けられない
    ///   ためで、次のフレームではその画素は効果を通す前の値に戻る
    // shot: 1 snippet=b6efb968
    // shot: 2 snippet=d16153fb
    // shot: 3 snippet=7d97214f
    // shot: 4 snippet=d6f7db6c
    // shot: 5 snippet=4e94538e
    // shot: 6 snippet=d2be289c
    public func effects(_ effects: [Effect]) { canvas.effects(effects) }

    /// 文字列から効果を作る。保存の拾い直しは効かない (在処が無いため)。
    ///
    /// 下は、縦の線を引いた絵を、行ごとに横へずらして読む効果。ずれは行の高さと秒数で決まる
    /// 正弦で、`values.depth` が振れ幅を決める。時間とともに揺れが上へ流れていく。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var ripple: EffectShader! -->
    ///     ```swift
    ///     func setup() {
    ///         ripple = try! makeEffect(
    ///             """
    ///             float4 effect(Pixel in, Values values) {
    ///                 float wave = sin(in.place.y * 60.0 + in.time * 4.0) * values.depth;
    ///                 return mokume_at(in, in.place + float2(wave, 0.0));
    ///             }
    ///             """,
    ///             values: ["depth": 0.01])
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         stroke(242, 115, 64)
    ///         strokeWeight(4)
    ///         for i in 0..<7 {
    ///             line(50 + i * 50, 20, 50 + i * 50, 280)
    ///         }
    ///         // 使うときは Effect.custom として並びへ入れる
    ///         effects([.custom(ripple)])
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 等間隔に並んだ 7 本の橙色の縦線が、どれも同じ形に細かく波打ち、その波が上へ流れていく | frames=60 -->
    ///     ![等間隔に並んだ 7 本の橙色の縦線が、どれも同じ形に細かく波打ち、その波が上へ流れていく](https://i.gyazo.com/71d57aa098ddbcd6c5140b23454d1990.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 渡す値を変えると、同じ断片のまま効き方が変わる。下は上と同じ絵の 1 枚目 (秒数 0) を、
    /// `depth` を 0.01 と 0.03 にして撮ったもの。0.03 では波の振れ幅が 3 倍になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var ripple: EffectShader! -->
    ///     ```swift
    ///     func setup() {
    ///         ripple = try! makeEffect(
    ///             """
    ///             float4 effect(Pixel in, Values values) {
    ///                 float wave = sin(in.place.y * 60.0 + in.time * 4.0) * values.depth;
    ///                 return mokume_at(in, in.place + float2(wave, 0.0));
    ///             }
    ///             """,
    ///             values: ["depth": 0.01])
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         stroke(242, 115, 64)
    ///         strokeWeight(4)
    ///         for i in 0..<7 {
    ///             line(50 + i * 50, 20, 50 + i * 50, 280)
    ///         }
    ///         effects([.custom(ripple)])
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 等間隔に並んだ 7 本の橙色の縦線が、どれも同じ形に小さく波打っている | symmetric=y -->
    ///     ![等間隔に並んだ 7 本の橙色の縦線が、どれも同じ形に小さく波打っている](https://i.gyazo.com/efafc0e64aa84ad0599f942385f1aef2.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var ripple: EffectShader! -->
    ///     ```swift
    ///     func setup() {
    ///         ripple = try! makeEffect(
    ///             """
    ///             float4 effect(Pixel in, Values values) {
    ///                 float wave = sin(in.place.y * 60.0 + in.time * 4.0) * values.depth;
    ///                 return mokume_at(in, in.place + float2(wave, 0.0));
    ///             }
    ///             """,
    ///             values: ["depth": 0.03])
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         stroke(242, 115, 64)
    ///         strokeWeight(4)
    ///         for i in 0..<7 {
    ///             line(50 + i * 50, 20, 50 + i * 50, 280)
    ///         }
    ///         effects([.custom(ripple)])
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 等間隔に並んだ 7 本の橙色の縦線が、どれも同じ形に大きく波打っている | symmetric=y -->
    ///     ![等間隔に並んだ 7 本の橙色の縦線が、どれも同じ形に大きく波打っている](https://i.gyazo.com/369838cb1441f641de4031f030e13770.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 平面・立体の塗りと同じ規約
    ///
    /// 前置きは自動で足されるので、書くのは `float4 effect(Pixel in, Values values)`
    /// 1 本だけ。`in.color` がこの画素、`mokume_at` でほかの場所を読める。渡した値は
    /// `values` から名前で引ける。**組み込みの効果も同じ規約で書いてある。**
    ///
    /// `in.position` (面の中の位置) と `in.size` (面の大きさ) は、スケッチの座標と同じ
    /// **出す画素**で届く。``SketchSettings/pixelDensity`` を下げても、位置で刻んだ模様は
    /// 同じ大きさのまま出る。細かさ 1 未満では、`in.position` は描く画素の中心を出す画素へ
    /// 換算した値 (0.5 なら 1, 3, 5, …) になる。
    ///
    /// 使うときは ``Effect/custom(_:)`` として並びへ入れる。
    ///
    /// - Throws: 組み立てられないときに ``ShaderFailure``。
    // shot: 1 snippet=51305187
    // shot: 2 snippet=6a15d68d
    // shot: 3 snippet=e53a59b0
    public func makeEffect(
        _ body: String, name: String = "effect", values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> EffectShader {
        try canvas.makeEffect(body, name: name, values: values)
    }

    /// ファイルから効果を読み込む。
    ///
    /// **保存したら差し替わる。** 組み立てに失敗しても絵は止まらない — 前の効果が
    /// そのまま残り、失敗の理由は観測の警告に出る。
    ///
    /// 書き方は文字列から作る ``makeEffect(_:name:values:)`` と同じで、例と絵はそちらにある。
    ///
    /// - Throws: 見つからないとき・組み立てられないときに ``ShaderFailure``。
    // shot: 参照 makeEffect(_:name:values:)
    public func loadEffect(
        _ path: String, values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> EffectShader {
        try canvas.loadEffect(path, values: values)
    }
}
