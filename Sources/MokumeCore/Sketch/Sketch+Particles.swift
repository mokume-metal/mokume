// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 粒。
extension Sketch {
    /// 粒を用意する。**同時に持てる数をここで決める。**
    ///
    /// <!-- example: 文脈 var dust: Particles! -->
    /// ```swift
    /// func setup() {
    ///     dust = try? makeParticles(count: 20000)
    /// }
    /// ```
    ///
    /// ## 混ぜ方と塗りは、作った瞬間に決まる
    ///
    /// 粒の板は保持した形 (``createShape(_:)``) なので、**これを呼んだ瞬間の混ぜ方と塗りが
    /// 粒に焼き付く。** 塗りとは、貼った絵 (``texture(_:)-(Image)``) と当てた断片
    /// (``shader(_:)``) である。`draw()` で後から ``blendMode(_:)`` / `texture()` /
    /// `shader()` を呼んでも、粒には効かない — 貼ったまま・当てたまま ``particles(_:)`` を
    /// 呼んでも、粒は作った瞬間の塗りで出る。
    /// 色は焼き付かない — 粒ごとに ``emit(_:from:toward:rate:speed:life:size:color:)`` が渡す。
    ///
    /// **断片に渡した値も、作った瞬間のものが残る。** 作った後で断片の値を変えても、粒は
    /// 動かない (保持した形と同じ)。粒の塗りをフレームごとに動かすなら、作る前に断片と
    /// 数の並び (``numbers(_:)``) を置き、断片はその並びを読むように書く。粒が持ち歩くのは
    /// 並びそのものなので、作った後に並びへ書いた値 (``Numbers/set(_:at:)``) は次に描く粒に
    /// 出る。
    ///
    /// 加算で光らせるなら、作る前に混ぜ方を置く。作ったあとは戻してよい — 粒が持ち歩く
    /// のは作った瞬間の値で、外の状態は作る前と変わらない。下は同じ粒を出す 2 つの群で、
    /// 左は加算にしてから作り、右はふつうに作って `draw()` で加算にしたもの。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     var glow: Particles!
    ///     var flat: Particles!
    ///
    ///     func setup() {
    ///         blendMode(.add)
    ///         glow = try? makeParticles(count: 3000)
    ///         blendMode(.blend)
    ///         flat = try? makeParticles(count: 3000)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64, 90)
    ///         // 後から加算にしても、右の群には効かない
    ///         blendMode(.add)
    ///         emit(glow, from: .circle(110, 150, radius: 60),
    ///              rate: 1500, speed: 0...10, size: 12...12)
    ///         emit(flat, from: .circle(290, 150, radius: 60),
    ///              rate: 1500, speed: 0...10, size: 12...12)
    ///         particles(glow)
    ///         particles(flat)
    ///         blendMode(.blend)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 半透明の橙色の粒が 2 つの円盤に溜まっていく。左は重なるほど明るく黄色く光り、右は重なっても橙色より明るくならない | frames=30 -->
    ///     ![半透明の橙色の粒が 2 つの円盤に溜まっていく。左は重なるほど明るく黄色く光り、右は重なっても橙色より明るくならない](https://i.gyazo.com/e36721dbdd4a4b68a57915f83b598a88.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 枠は環状に回る
    ///
    /// 出した粒は空いている枠へ順に入り、末尾まで行くと先頭へ戻る。**まだ生きている粒を
    /// 上書きしたときは理由を知らせる** — 出す数 (`rate`) × 寿命 (`life`) がここで決めた
    /// 数より多いと起きるので、どれかを変える。
    ///
    /// 下は毎秒 600 個・寿命 1 秒の噴き口を 3 つ並べ、`count` だけを 100 / 300 / 900 と
    /// 変えたもの。生きている粒は 600 個まで増えるので、左の 2 つは枠が足りず、古い粒
    /// (柱の上のほう) から上書きされて消える。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     var jets: [Particles] = []
    ///
    ///     func setup() {
    ///         for count in [100, 300, 900] {
    ///             if let jet = try? makeParticles(count: count) {
    ///                 jets.append(jet)
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         let up = Heading.plane((-Float.pi * 0.53)...(-Float.pi * 0.47))
    ///         for (index, jet) in jets.enumerated() {
    ///             let x = Float(80 + 120 * index)
    ///             emit(jet, from: .point(x, 270), toward: up,
    ///                  rate: 600, speed: 200...200, life: 1...1, size: 3...3)
    ///             particles(jet)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 下から真上へ噴き上がる橙色の柱が 3 本。右ほど高く、左の 2 本は途中で切れて短い | frames=90 -->
    ///     ![下から真上へ噴き上がる橙色の柱が 3 本。右ほど高く、左の 2 本は途中で切れて短い](https://i.gyazo.com/dc98c4714ee07d04afdd30a33ee2583d.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 大きすぎる数・1 を割る数
    ///
    /// 置き場を取れない数は**確保の失敗として返る**。途中まで作って止まることはない。
    /// 0 以下は 1 粒へ丸めずに断る。
    ///
    /// - Throws: 置き場を取れないときと、`count` が 1 を割るとき
    ///   (``RenderFailure/invalidCount(_:)``) に ``RenderFailure``。
    // shot: 1 snippet=ed20505f
    // shot: 2 snippet=ee77bf99
    public func makeParticles(count: Int) throws(RenderFailure) -> Particles {
        try canvas.makeParticles(count: count)
    }

    /// 粒を出す。
    ///
    /// <!-- example: 文脈 var dust: Particles! -->
    /// ```swift
    /// func draw() {
    ///     emit(dust, from: .point(width / 2, 40), rate: 600, life: 1...2.5)
    ///     force(dust, .gravity(0, 90), .drag(0.4))
    ///     particles(dust)
    /// }
    /// ```
    ///
    /// ## 低いレートでも、長い目で見て頼んだ数が出る
    ///
    /// `rate` は**毎秒**の数で、1 フレームぶんに割ると端数が出る。端数は捨てずに繰り越す
    /// ので、毎秒 1 個未満でもいつかは出る。捨てる作りにすると、**低いレートで 1 個も
    /// 出ない**が起き、しかも 1 枚の絵では見えない。
    ///
    /// **1 つの粒へ何か所から出しても、それぞれが頼んだ数を出す。** 繰り越しは、その
    /// フレームで**何回目の呼び出しか**で分けて持つ — ループの 1 行から何度呼んでも
    /// 分かれる。そのため、呼ぶ順や回数がフレームごとに変わる (条件付きで出す噴き口が
    /// ある) と、1 個未満の端数が別の噴き口へ移ることがある。
    ///
    /// 下は 1 つの群へ 3 か所から、`rate` だけを 6 / 60 / 600 と変えて出したもの。毎秒 6 個は
    /// 60 fps で 1 フレームに 0.1 個だが、端数を繰り越すので 10 枚ごとに 1 個ずつ出る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     var dust: Particles!
    ///
    ///     func setup() {
    ///         dust = try? makeParticles(count: 2000)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         emit(dust, from: .point(70, 150), rate: 6)
    ///         emit(dust, from: .point(200, 150), rate: 60)
    ///         emit(dust, from: .point(330, 150), rate: 600)
    ///         particles(dust)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 3 か所から橙色の粒が広がる。右は数百粒、中は数十粒で、左もまばらながら 1 粒ずつ増えていく | frames=60 -->
    ///     ![3 か所から橙色の粒が広がる。右は数百粒、中は数十粒で、左もまばらながら 1 粒ずつ増えていく](https://i.gyazo.com/0b45ed9e65971837e4bfe67f6bc43cd7.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 出した粒は、次に進めるときから出る
    ///
    /// 出した粒は、その後の ``particles(_:)`` で 1 刻み進んで描かれる。``particles(_:)`` の後に
    /// 出した粒は、そのフレームには描かれず、次の呼び出しから出る ([#1687])。
    ///
    /// [#1687]: https://github.com/mokume-metal/mokume/issues/1687
    ///
    /// ## 出る場所と飛ぶ向きは別
    ///
    /// `from` が出る場所 (``Emitter``) を、`toward` が飛ぶ向き (``Heading``) を決める。形を
    /// 差し替えても向きは変わらない。`toward` を省くと、画面の面内のどの向きへも飛ぶ
    /// (`.plane(0...(2 * Float.pi))`) ので、視点を真横へ回すと粒は 1 本の線に並ぶ。1 点から
    /// 奥行きも含めた全方位へ吹き出させるなら `.sphere` を渡す — 視点を回しても
    /// (``orbitControl(_:_:_:)``)、どこから見ても丸く広がる。
    ///
    /// 下は飛ぶ向きを真上に揃えて、出る場所だけを点・線・円にしたもの。どの粒もまっすぐ
    /// 上へ飛び、横へは広がらない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     var dust: Particles!
    ///
    ///     func setup() {
    ///         dust = try? makeParticles(count: 2000)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         let up = Heading.plane((-Float.pi / 2)...(-Float.pi / 2))
    ///         emit(dust, from: .point(60, 260), toward: up,
    ///              rate: 200, speed: 80...80)
    ///         emit(dust, from: .line(120, 260, 220, 260), toward: up,
    ///              rate: 200, speed: 80...80)
    ///         emit(dust, from: .circle(310, 230, radius: 40), toward: up,
    ///              rate: 200, speed: 80...80)
    ///         particles(dust)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の粒が、左は 1 本の縦線、中は横に広い幕、右は円の幅の柱になって、どれも真上へ昇っていく | frames=60 -->
    ///     ![橙色の粒が、左は 1 本の縦線、中は横に広い幕、右は円の幅の柱になって、どれも真上へ昇っていく](https://i.gyazo.com/4ea36ecfd8e732ea68acbf9e1017a461.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 次は 1 点から出す 2 か所を、真横から見たもの。上の橙色は `toward` を省き、下の水色は
    /// `.sphere` を渡している。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     var dust: Particles!
    ///
    ///     func setup() {
    ///         dust = try? makeParticles(count: 2000)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         // 右の真横から見る
    ///         camera(500, 150, 0, 200, 150, 0, 0, 1, 0)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         emit(dust, from: .point(200, 70), rate: 300)
    ///         fill(89, 191, 242)
    ///         emit(dust, from: .point(200, 230), toward: .sphere, rate: 300)
    ///         particles(dust)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 真横から見ると、上の橙色の粒は縦 1 本の線に並び、下の水色の粒は丸く広がっていく | frames=60 symmetric=x -->
    ///     ![真横から見ると、上の橙色の粒は縦 1 本の線に並び、下の水色の粒は丸く広がっていく](https://i.gyazo.com/2c70d221f4cc955ca8d00fc0dbd728c1.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 何もかも幅で指定する
    ///
    /// `speed` / `life` / `size` と、面内の向き (`toward: .plane(…)`) の角度は幅で渡す。1 つに
    /// 決めたいときは `2...2` のように書く。`color` を省くと、そのときの塗りで出る。
    ///
    /// 下の 3 枚は、1 つの群へ 3 か所から出し、`speed` / `life` / `size` を 1 つずつ変えたもの。
    /// 速さを 1 つに決めると、1 秒たった最後の枚で円盤の半径が速さと同じ数になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     var dust: Particles!
    ///
    ///     func setup() {
    ///         dust = try? makeParticles(count: 2000)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         emit(dust, from: .point(60, 150), rate: 300, speed: 15...15)
    ///         emit(dust, from: .point(160, 150), rate: 300, speed: 30...30)
    ///         emit(dust, from: .point(300, 150), rate: 300, speed: 60...60)
    ///         particles(dust)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の粒の円盤が 3 つ広がっていく。左から右へ広がる速さが倍々で、右がいちばん大きい | frames=60 -->
    ///     ![橙色の粒の円盤が 3 つ広がっていく。左から右へ広がる速さが倍々で、右がいちばん大きい](https://i.gyazo.com/f90af94de214433322ff10d90317143b.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 寿命を 1 つに決めると、円盤は寿命のぶん広がったところで大きさを止める
    /// (寿命の尽きた粒から消える)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     var dust: Particles!
    ///
    ///     func setup() {
    ///         dust = try? makeParticles(count: 2000)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         emit(dust, from: .point(60, 150), rate: 300,
    ///              speed: 50...50, life: 0.25...0.25)
    ///         emit(dust, from: .point(160, 150), rate: 300,
    ///              speed: 50...50, life: 0.5...0.5)
    ///         emit(dust, from: .point(300, 150), rate: 300,
    ///              speed: 50...50, life: 1...1)
    ///         particles(dust)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の粒の円盤が 3 つ、同じ速さで広がり、左から順に小さいところで広がるのを止める。右は左の 4 倍の大きさで止まる | frames=90 -->
    ///     ![橙色の粒の円盤が 3 つ、同じ速さで広がり、左から順に小さいところで広がるのを止める。右は左の 4 倍の大きさで止まる](https://i.gyazo.com/99e44d2eb5d0e93a5fb9372d0ce049f5.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     var dust: Particles!
    ///
    ///     func setup() {
    ///         dust = try? makeParticles(count: 2000)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         emit(dust, from: .point(70, 150), rate: 30, size: 2...2)
    ///         emit(dust, from: .point(200, 150), rate: 30, size: 6...6)
    ///         emit(dust, from: .point(330, 150), rate: 30, size: 12...12)
    ///         particles(dust)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 3 か所から橙色の四角い粒が広がる。左は点のように小さく、中はその 3 倍、右はさらに倍の大きさ | frames=60 -->
    ///     ![3 か所から橙色の四角い粒が広がる。左は点のように小さく、中はその 3 倍、右はさらに倍の大きさ](https://i.gyazo.com/e78af632f6dde800ec61bd4597aa3da3.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **幅は Swift の `...` で作るので、端が数でない値 (NaN) か、下端が上端を越えると、
    /// `emit` に届く前に Swift がプロセスごと止める。** `speed: Float.nan...1` も
    /// `speed: 60...20` も、止まるのは幅を作る作者の行で、mokume は値を検められない
    /// (下の「数でない値・無限は、注意して出さない」はここに届かない)。無限の端は止まらずに
    /// 届き、その呼び出しで 1 個も出さない。
    ///
    /// 計算した値を端に使うときは、幅を作る前に値を確かめる (`if lo.isFinite && hi.isFinite
    /// && lo <= hi { … }`)。`min(a, b)...max(a, b)` は逆順は防ぐが NaN は防がない —
    /// `a` が NaN なら止まり、`b` が NaN なら黙って `a...a` になる。
    ///
    /// 出た粒の値は**種から決まる乱数** (``random()`` と同じ 1 本の流れ) で引くので、
    /// ``randomSeed(_:)`` を決めれば何度走らせても同じ粒が出る。
    ///
    /// ## 数でない値・無限は、注意して出さない
    ///
    /// `rate`・`from` の座標や半径・`color` の成分のどれかが数でない値 (NaN) か無限なら、
    /// また幅の端が無限なら、**その呼び出しでは 1 個も出さず**、どの引数だったかを 1 度
    /// だけ知らせる (幅の端の NaN は、上のとおり `emit` に届く前に止まる)。
    /// `color` を省いたときは塗りを見る。すでに生きている粒と、同じ粒へ出している他の
    /// 呼び出しには効かない。
    ///
    /// 値が有限でも、出る所が `Float` で表せないほど遠い粒 (中心と半径の和が溢れる円や球)
    /// は出さずに知らせる。
    ///
    /// ## 負の `rate`・`life`・`size`・半径は、注意して丸める
    ///
    /// どれも 0 以上の量である。負の `rate` は 0 (出さない) として、`life`・`size` は引いた
    /// 値の 0 より下を 0 として、`from` の円・球の負の半径は絶対値として扱い、引数ごとに
    /// 1 度だけ知らせる。
    // shot: 1 snippet=ea2ac744
    // shot: 2 snippet=96807c6d
    // shot: 3 snippet=45749861
    // shot: 4 snippet=d90706a7
    // shot: 5 snippet=52ae58cc
    // shot: 6 snippet=906d03c4
    public func emit(
        _ particles: Particles, from source: Emitter,
        toward heading: Heading = .plane(0...(2 * Float.pi)),
        rate: Float,
        speed: ClosedRange<Float> = 20...60,
        life: ClosedRange<Float> = 1...2,
        size: ClosedRange<Float> = 2...6,
        color: LinearRGBA? = nil
    ) {
        let runtime = Self.requireRuntime()
        canvas.emit(
            particles, from: source, toward: heading, rate: rate, speed: speed, life: life,
            size: size, color: color, using: &runtime.randomness)
    }

    /// 粒に力を効かせる。
    ///
    /// <!-- example: 文脈 var dust: Particles! -->
    /// ```swift
    /// force(dust, .gravity(0, 90), .swirl(width / 2, height / 2, strength: 40), .drag(0.6))
    /// ```
    ///
    /// **積んだぶんが、次に進めるときにまとめて効く。** ``particles(_:)`` を呼ぶと空に
    /// なるので、毎フレーム書いてよい。1 回に効かせられるのは 8 個までで、超えたぶんは
    /// 理由を添えて捨てる。
    ///
    /// 下は同じ噴き口を 3 つ並べ、効かせる力だけを変えたもの。左は力なし、中は重力、右は
    /// 重力に横向きの重力 (風) を足している。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     var plain: Particles!
    ///     var falling: Particles!
    ///     var blown: Particles!
    ///
    ///     func setup() {
    ///         plain = try? makeParticles(count: 1000)
    ///         falling = try? makeParticles(count: 1000)
    ///         blown = try? makeParticles(count: 1000)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         let up = Heading.plane((-Float.pi * 0.55)...(-Float.pi * 0.45))
    ///         emit(plain, from: .point(70, 230), toward: up,
    ///              rate: 120, speed: 110...110)
    ///         emit(falling, from: .point(180, 230), toward: up,
    ///              rate: 120, speed: 110...110)
    ///         emit(blown, from: .point(280, 230), toward: up,
    ///              rate: 120, speed: 110...110)
    ///         force(falling, .gravity(0, 160))
    ///         force(blown, .gravity(0, 160), .gravity(80, 0))
    ///         particles(plain)
    ///         particles(falling)
    ///         particles(blown)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 3 つの噴き口から橙色の粒が真上へ出る。左はまっすぐ昇り続け、中は低い弧を描いて落ち、右は同じ弧が右へ流される | frames=90 -->
    ///     ![3 つの噴き口から橙色の粒が真上へ出る。左はまっすぐ昇り続け、中は低い弧を描いて落ち、右は同じ弧が右へ流される](https://i.gyazo.com/5ef417b6c5d92bdfc720cd38d4c309a8.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 積んだ力は 1 刻みで使い切られる。下の水色の群には 1 枚目にだけ重力を積んだので、
    /// 2 枚目からは効かずにまっすぐ飛ぶ。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     var every: Particles!
    ///     var once: Particles!
    ///
    ///     func setup() {
    ///         every = try? makeParticles(count: 1000)
    ///         once = try? makeParticles(count: 1000)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         let right = Heading.plane(0...0)
    ///         fill(242, 115, 64)
    ///         emit(every, from: .point(30, 50), toward: right,
    ///              rate: 120, speed: 150...150)
    ///         fill(89, 191, 242)
    ///         emit(once, from: .point(30, 210), toward: right,
    ///              rate: 120, speed: 150...150)
    ///         force(every, .gravity(0, 150))
    ///         if frameCount == 1 {
    ///             force(once, .gravity(0, 150))
    ///         }
    ///         particles(every)
    ///         particles(once)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左から右へ 2 本の粒の流れ。上の橙色は弧を描いて下へ曲がり、下の水色はまっすぐ横へ伸びる | frames=72 -->
    ///     ![左から右へ 2 本の粒の流れ。上の橙色は弧を描いて下へ曲がり、下の水色はまっすぐ横へ伸びる](https://i.gyazo.com/952d48468671afc269df94d188ef3917.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 引く力 (``Force/attract(_:_:_:strength:weakeningBeyond:)``) は強さを負にすると
    /// 押す力になる。読みやすさのために ``Force/repel(_:_:_:strength:weakeningBeyond:)`` も
    /// 置いてあるが、**計算は同じ 1 本**である。
    ///
    /// ## 数でない値・無限は、注意して効かせない
    ///
    /// 成分 (座標・`strength`・`amount`) のどれかが数でない値 (NaN) か無限の力は、**その力
    /// だけを積まず**、1 度だけ知らせる。同じ呼び出しに並べた他の力は今までどおり効き、
    /// すでに生きている粒も壊れない。弱まり始める距離 (`weakeningBeyond`) だけは扱いが
    /// 違い、力ごと断らずに距離を外して、弱まらない力として効かせる。減速 (``Force/drag(_:)``)
    /// の負の `amount` も、速さを増やしてしまうので同じく知らせて効かせない。
    ///
    /// 有限の力でも、足し合わせや積分が `Float` で溢れるほど大きければ、**溢れるフレームは
    /// 粒を動かさない** — 粒の位置と速度が数でなくなることは無い。
    // shot: 1 snippet=4426839e
    // shot: 2 snippet=878e959d
    public func force(_ particles: Particles, _ forces: Force...) {
        canvas.force(particles, forces)
    }

    /// 粒を 1 フレーム進めて描く。
    ///
    /// **呼ばなければ進まない。** 進めるのと描くのを分けていないのは、「進めたのに
    /// 描いていない粒」と「描いたのに進んでいない粒」という 2 つの状態を作らないため。
    ///
    /// ## 寿命が尽きた粒は描かれない
    ///
    /// 描く個数は GPU が数える。生きている粒だけを枠の番号順に詰めて描くので、枠を
    /// 大きく取っても、払うのは生きている粒のぶんだけである。
    ///
    /// 時計をフレーム番号から導く走らせ方 (ヘッドレスの書き出し) では、**寿命 `life` 秒の粒は
    /// ⌊`life` × fps⌋ 枚描かれる** (毎フレーム 1 回呼ぶとき)。**出したフレームを 1 枚目**として
    /// ⌊`life` × fps⌋ 枚目まで描かれ、その次の枚には描かれない — 24 fps の `life: 1...1` なら
    /// 1〜24 枚目に描かれ、25 枚目で消える。60 fps の `life: 1...1` なら 60 枚、60 fps の
    /// `life: 0.25...0.25` なら 15 枚。
    /// 枚数は `life` と fps の比だけで決まり、fps によって 1 枚ずれることは無い。`life` は
    /// 書いた 10 進の値ではなく `Float` の値そのもので数えるので、`0.05` (`Float` では 0.05
    /// よりわずかに大きい) は 60 fps で 3 枚になる。枚数で数えるのは 2^24 − 1 枚 (60 fps で
    /// 約 77 時間) までで、それより長い寿命はそこで尽きる。
    ///
    /// **1 つの群は、1 つの時計の面で進める。** 寿命の数え方は時計で違い、フレーム番号の時計では
    /// 枚数、実時間の時計では秒で持つ。スケッチの本体と描き場所 (``createGraphics(_:_:)``) は
    /// 同じ時計を読むので気にしなくてよいが、直に作った面 (`Canvas(target:gpu:)`) は自分の時計
    /// (秒の刻み) を持つ。フレーム番号の時計で出した粒をそういう面で進めると、寿命が fps 倍ほど
    /// 長くなる (逆なら短くなる)。
    ///
    /// ## 1 回で進むのは 1 フレームぶん
    ///
    /// 進む量は ``deltaTime`` で決まる。時計をフレーム番号から導く走らせ方 (ヘッドレスの
    /// 書き出し) なら刻みが一定なので、**同じ入力から何度走らせても同じ動き**が出る。
    ///
    /// 積んだ力を足し合わせた加速度で**先に速度を**進め、減速を掛けてから、**その速度で
    /// 位置を**進め、寿命を 1 フレームぶん (``deltaTime``) 減らす。フレーム番号から導く時計では、
    /// 寿命は単精度の ``deltaTime`` を引き続けずに枚数で数える (上の ⌊`life` × fps⌋)。
    /// 力の式と進め方は ``Force`` にある。
    ///
    /// ## 同じフレームに何度呼んでも、呼ぶたびに進んで描かれる
    ///
    /// 1 フレームに同じ群を 2 回呼べば 2 刻み進み、それぞれの呼び出しが**呼んだ時点の変換**で
    /// 描く。それまでに積んだ力は、その呼び出しの 1 刻みに効く。描き場所
    /// (``createGraphics(_:_:)``) と本体で 1 つの群を使い分けても、どちらの面にも呼んだ時点の
    /// 変換で出て、群は**呼んだ順に**、呼んだ回数だけ進む。本体で先に呼んで描き場所で後に呼べば、
    /// 本体は 1 刻み後・描き場所は 2 刻み後の状態を描く (描き場所が先に描き切られても同じ)。
    ///
    /// 同じ雲を 2 か所に置くために 2 回呼ぶと、粒は 2 倍の速さで動き、寿命も 2 倍の速さで
    /// 減る。2 刻みとも同じフレーム番号で進むので、``Force/wander(strength:)`` の揺れは 2 刻みとも
    /// 同じ向きになる (別々のフレームを 2 つ進めたのとは動きが違う)。番号は**本体のフレームの番号**で、
    /// 描き場所で呼んでも同じである — 描き場所を何フレーム目から描き始めたか・描かなかった
    /// フレームがあるかに依らず、同じ本体のフレームの中なら本体の呼び出しと同じ向きに揺れる
    /// ([#1909](https://github.com/mokume-metal/mokume/issues/1909))。
    ///
    /// 下の左は毎フレーム 1 回呼ぶ群、右の 2 つは同じ群を 2 か所に置くために 2 回呼んだもの。
    /// どちらも同じ速さ・寿命 1 秒で出している。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     var once: Particles!
    ///     var twice: Particles!
    ///
    ///     func setup() {
    ///         once = try? makeParticles(count: 1000)
    ///         twice = try? makeParticles(count: 1000)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         emit(once, from: .point(110, 150), rate: 300,
    ///              speed: 60...60, life: 1...1)
    ///         particles(once)
    ///         fill(89, 191, 242)
    ///         emit(twice, from: .point(0, 0), rate: 300,
    ///              speed: 60...60, life: 1...1)
    ///         // 同じ群を 2 か所に置く。呼ぶたびに 1 刻み進む
    ///         push()
    ///         translate(290, 80)
    ///         particles(twice)
    ///         pop()
    ///         push()
    ///         translate(290, 220)
    ///         particles(twice)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左の橙色の円盤 1 つと、右の水色の円盤 2 つが広がる。水色は橙色の倍の速さで広がって先に止まり、粒もまばら | frames=75 -->
    ///     ![左の橙色の円盤 1 つと、右の水色の円盤 2 つが広がる。水色は橙色の倍の速さで広がって先に止まり、粒もまばら](https://i.gyazo.com/4c4d31ea679ecc3530a358791b0a91d9.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 呼び出しごとに分かれるのは、積んだ力と、置き場所・描く引数である。**2 回の呼び出しの
    /// 間で ``emit(_:from:toward:rate:speed:life:size:color:)`` した粒は、2 回目の雲から出る** — 出した粒は、
    /// 呼んだ順に効く ([#1687])。置き場所は呼んだ回数の最多まで群が持ち
    /// 続けるので、大きな群を 1 フレームに K 回置くと、置き場所の確保も K 倍になる。
    ///
    /// [#1687]: https://github.com/mokume-metal/mokume/issues/1687
    ///
    /// ## 粒は、どこから見ても画面に正対する
    ///
    /// 粒 1 つは四角い板で、**板は常に画面の面と平行に置かれる。** ``orbitControl(_:_:_:)``
    /// や ``camera(_:_:_:_:_:_:_:_:_:)`` で視点を真横へ回しても、``rotateY(_:)`` で雲ごと
    /// 回しても、粒は横を向いて痩せない。
    ///
    /// 位置には変換がそのまま効く。変換から板が受け取るのは**倍率だけ**で、回転は板の向きに
    /// 効かない — 平面で ``rotate(_:)`` してから描いても、粒の位置は回るが四角は傾かない。
    ///
    /// 下は斜めに並べた 3 つの粒を、面内で回した枠・縦の軸で回した枠・2 倍に拡げた枠の
    /// 中に描いたもの (同じ群を 3 回呼んでいる。速さが 0 なので刻みが進んでも動かない)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     var dots: Particles!
    ///
    ///     func setup() {
    ///         dots = try? makeParticles(count: 100)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         for d in [Float(-25), 0, 25] {
    ///             emit(dots, from: .point(d, d), rate: 60,
    ///                  speed: 0...0, size: 12...12)
    ///         }
    ///         noFill()
    ///         stroke(89, 191, 242)
    ///         push()
    ///         translate(75, 150)
    ///         rotate(0.6)
    ///         square(-40, -40, 80)
    ///         particles(dots)
    ///         pop()
    ///         push()
    ///         translate(185, 150)
    ///         rotateY(1.2)
    ///         square(-40, -40, 80)
    ///         particles(dots)
    ///         pop()
    ///         push()
    ///         translate(305, 150)
    ///         scale(2, 2)
    ///         square(-40, -40, 80)
    ///         particles(dots)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 水色の枠が 3 つ。左は傾き、中は縦に細く、右は 2 倍に大きい。枠の中の橙色の四角い粒は 3 つずつで、どれも傾かず痩せず、右だけが 2 倍の大きさ -->
    ///     ![水色の枠が 3 つ。左は傾き、中は縦に細く、右は 2 倍に大きい。枠の中の橙色の四角い粒は 3 つずつで、どれも傾かず痩せず、右だけが 2 倍の大きさ](https://i.gyazo.com/310068f9460e5cf42e5f9e344f47ff7c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=07f084f9
    // shot: 2 snippet=468ad272
    public func particles(_ particles: Particles) { canvas.particles(particles) }
}
