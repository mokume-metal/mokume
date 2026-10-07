// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 乱数と揺らぎ。
extension Sketch {
    /// 0 以上 1 未満の値。**呼ぶたびに列が進む。**
    ///
    /// **種を決めなくても、走らせるたびに同じ列が出る。** 時刻から種を作らないため
    /// ([ADR-0001] 原則 2)。毎回ちがう絵が欲しければ、変わる値を ``randomSeed(_:)``
    /// へ渡す。
    ///
    /// 1 未満の値なので、割合と比べると「その割合で起きること」が書ける。下はマスごとに
    /// 1 回引き、`chance` より小さいマスだけを橙に塗ったもの。`chance` は左から 0.1・0.5・0.9。
    /// 引くたびに違う値なので、塗られるマスの割合は `chance` のまわりでぶれる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     randomSeed(42)
    ///     for chance: Float in [0.1, 0.5, 0.9] {
    ///         for row in 0..<19 {
    ///             for column in 0..<8 {
    ///                 if random() < chance {
    ///                     fill(242, 115, 64)
    ///                 } else {
    ///                     fill(50, 55, 64)
    ///                 }
    ///                 square(7 + column * 15, 8 + row * 15, 12)
    ///             }
    ///         }
    ///         translate(134, 0)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 3 つの格子。橙に塗られたマスが、左から右へ 1 割ほど・4 割ほど・9 割ほどと増えていく -->
    ///     ![3 つの格子。橙に塗られたマスが、左から右へ 1 割ほど・4 割ほど・9 割ほどと増えていく](https://i.gyazo.com/9fc75a34dd52c582a429cb6ff169ddfd.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
    // shot: 1 snippet=48c34437
    public func random() -> Float { Self.requireRuntime().randomness.unitValue() }

    /// 0 以上 `high` 未満の値。`high` が負なら `high` 以上 0 未満。
    ///
    /// 下は種を決めてから、200 個の点の位置を `random(width)` と `random(height)` で引いたもの。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     randomSeed(42)
    ///     for _ in 0..<200 {
    ///         circle(random(width), random(height), 6)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 面の全体に、200 個の橙の点がばらばらに散らばっている -->
    ///     ![面の全体に、200 個の橙の点がばらばらに散らばっている](https://i.gyazo.com/15698d5638e7af2dcb488c4b7aa99092.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// `high` を変えると、散らばる幅が変わる。下は中央の縦線から `random(high)` だけ横へ
    /// ずらした点を、上の段から `high` = 100・200・-200 で 40 個ずつ置いたもの。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(90)
    ///     line(200, 0, 200, height)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     randomSeed(42)
    ///     for high in [100, 200, -200] {
    ///         for _ in 0..<40 {
    ///             circle(200 + random(high), 20 + random(60), 6)
    ///         }
    ///         translate(0, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 3 段の点。上の段は中央の縦線から右へ 4 分の 1 まで、中段は右の端まで、下の段は中央の縦線から左の端まで散らばっている -->
    ///     ![3 段の点。上の段は中央の縦線から右へ 4 分の 1 まで、中段は右の端まで、下の段は中央の縦線から左の端まで散らばっている](https://i.gyazo.com/b462336633638ec5e91d824c83846b36.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=8fd1617a
    // shot: 2 snippet=59f8262e
    public func random(_ high: some ScalarConvertible) -> Float {
        let high = high.asFloat
        return Self.requireRuntime().randomness.value(from: 0, to: high)
    }

    /// `low` 以上 `high` 未満の値。**順序が逆でも受け取る。**
    ///
    /// 下は 4 段の点の横の位置を `random(low, high)` で引いたもの。上の段から
    /// (150, 250)・(50, 250)・(50, 350)・(350, 50) で、段ごとに下の端・上の端・順序を
    /// 1 つずつ変えている。細い縦線は左から 50・150・250・350 の位置。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     stroke(90)
    ///     for x in [50, 150, 250, 350] {
    ///         line(x, 0, x, height)
    ///     }
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     randomSeed(42)
    ///     for (low, high) in [(150, 250), (50, 250), (50, 350), (350, 50)] {
    ///         for _ in 0..<60 {
    ///             circle(random(low, high), random(15, 60), 6)
    ///         }
    ///         translate(0, 75)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 4 段の点。上の段は 2・3 本目の縦線の間に散らばり、2 段目は左へ 1 本目まで、3 段目は右へも 4 本目まで広がり、4 段目は 3 段目と同じく 1・4 本目の間に散らばる -->
    ///     ![4 段の点。上の段は 2・3 本目の縦線の間に散らばり、2 段目は左へ 1 本目まで、3 段目は右へも 4 本目まで広がり、4 段目は 3 段目と同じく 1・4 本目の間に散らばる](https://i.gyazo.com/766bceba5143fe50027d8dc10bc6ef4d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=ceae014f
    public func random(_ low: some ScalarConvertible, _ high: some ScalarConvertible) -> Float {
        let (low, high) = (low.asFloat, high.asFloat)
        return Self.requireRuntime().randomness.value(from: low, to: high)
    }

    /// 乱数の種。同じ種を置いてから同じ順に呼べば、いつでも同じ列が出る。
    ///
    /// 下は 3 つの枠の中で、種を置いてから 30 個の点の位置を引いたもの。種は左から 7・7・8。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     for seed in [7, 7, 8] {
    ///         fill(36, 40, 48)
    ///         rect(0, 0, 132, height)
    ///         fill(242, 115, 64)
    ///         randomSeed(seed)
    ///         for _ in 0..<30 {
    ///             circle(10 + random(112), 10 + random(280), 6)
    ///         }
    ///         translate(134, 0)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 3 つの枠に橙の点が 30 個ずつ。左と中央は点の並びがまったく同じで、右だけが違う -->
    ///     ![3 つの枠に橙の点が 30 個ずつ。左と中央は点の並びがまったく同じで、右だけが違う](https://i.gyazo.com/0aa3cef5628a9d449d7eb3fb01aa180f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **列は ``draw()`` を越えて進み続ける。** フレームの頭で戻したいなら、
    /// そのフレームの頭でこれを呼ぶ。
    ///
    /// **形の組み立て (``createShape(_:)``) の中で書いた種は、抜けると外へ残らない。** 中で書くと、
    /// そこから抜けるまでは中で決めた列で引き、抜けた後の列は**最初に書く直前**の状態から続く。
    /// 種を書く前に中で引いた分と、種を書かずに引いた分は、外で引いたのと同じく列を進める。
    // shot: 1 snippet=c29016d0
    public func randomSeed(_ seed: Int) { Self.requireRuntime().writeSeed(seed) }

    /// その座標の揺らぎ (0…1)。**近い座標には近い値**が返る、なめらかな乱れ。
    ///
    /// ``random()`` と違って列ではないので、**同じ座標には何度呼んでも同じ値**が
    /// 返る。フレームをまたいで安定した模様は、これで描く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     noiseSeed(3)
    ///     for x in stride(from: 0, to: width, by: 4) {
    ///         let y = noise(x * 0.01) * height
    ///         circle(x, y, 3)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左から右へ並んだ点が、なめらかに上下する 1 本の線をなしている -->
    ///     ![左から右へ並んだ点が、なめらかに上下する 1 本の線をなしている](https://i.gyazo.com/ff1b7ff05022fefcba1e5d6ce3817fde.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 3 つ目の座標 `z` も同じで、近い `z` には近い模様が返る。下は同じ `x`・`y` の範囲を、
    /// 左から `z` = 0・0.1・2 で塗ったもの。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     noiseSeed(3)
    ///     let side: Float = 132
    ///     for z in [0, 0.1, 2] {
    ///         for y in stride(from: 0, to: height, by: 4) {
    ///             for x in stride(from: 0, to: side, by: 4) {
    ///                 fill(noise(x * 0.02, y * 0.02, z) * 255)
    ///                 square(x, y, 4)
    ///             }
    ///         }
    ///         translate(side + 2, 0)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 雲のような濃淡の模様が 3 枚。左と中央はよく似ていて、右だけが別の模様 -->
    ///     ![雲のような濃淡の模様が 3 枚。左と中央はよく似ていて、右だけが別の模様](https://i.gyazo.com/82625fea9fcccd3871f4159e000a496c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **断片からも同じ値が引ける。** 利用者が書いた塗りの中で `mokume_noise(in, p)`
    /// と書くと、``noiseSeed(_:)`` で決めた同じ種の同じ揺らぎが出る — 面と立体で
    /// 同じ模様を出すのに、揺らぎを 2 つ別々に持たなくてよい。
    ///
    /// 断片では**傾き**も引ける (`mokume_noiseGradient(in, p)`)。揺らぎを高さとみた面の
    /// 向きを、隣を引いて差を取らずに作れる。傾きは断片の側にだけあり、ここには無い。
    ///
    /// 座標として扱えるのは ±1e6 くらいまで。それを超えると模様は破綻するが、
    /// 落ちはしない (数でない座標には 0 が返る)。
    // shot: 1 snippet=235577a7
    // shot: 2 snippet=e807b119
    public func noise(_ x: some ScalarConvertible, _ y: some ScalarConvertible = 0, _ z: some ScalarConvertible = 0) -> Float {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        return canvas.noise(x, y, z)
    }

    /// 揺らぎの種。**断片にも同じ種が届く**ので、配線しなくてよい。
    ///
    /// 下は 3 段の山の形の、上の縁の高さを `noise(x * 0.01)` で引いたもの。種は上の段から
    /// 3・3・4。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     for seed in [3, 3, 4] {
    ///         noiseSeed(seed)
    ///         beginShape()
    ///         vertex(0, 95)
    ///         for x in stride(from: 0, through: width, by: 1) {
    ///             vertex(x, 10 + noise(x * 0.01) * 80)
    ///         }
    ///         vertex(width, 95)
    ///         endShape(.close)
    ///         translate(0, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 山並みのような橙の形が 3 段。上と中段はまったく同じ形で、下の段だけが違う形 -->
    ///     ![山並みのような橙の形が 3 段。上と中段はまったく同じ形で、下の段だけが違う形](https://i.gyazo.com/d2cd370e48d5fc81d1dfa7f0cf35f9b8.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 種はスケッチに 1 つである。描き場所 (``createGraphics(_:_:)``) の断片にも同じ種が
    /// 届き、描き場所の上で呼んでも (`pg.noiseSeed(_:)`) 同じ 1 つを書き換える。
    /// 置いた図形の断片は置いた時点の種で引くので、同じフレームの途中で決め直しても、
    /// それまでに置いたものの模様は動かない。決め直してもそこで描き切らないので、``loadPixels()``
    /// のような区切りにはならない (区切りより後の影が前の面に落ちない、といった割れは起きない)。
    /// 形の組み立て (``createShape(_:)``) の中で決め直してもよい。
    ///
    /// 乱数の種 (``randomSeed(_:)``) とは別に持つ。片方を決め直しても、もう片方の
    /// 模様は動かない。
    ///
    /// - Note: 揺らぎの種は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=3bc41d48
    public func noiseSeed(_ seed: Int) { canvas.noiseSeed(seed) }

    /// 揺らぎの細かさ — 重ねる枚数 `lod` と、1 枚ごとの弱まり `falloff`。
    ///
    /// 枚数を増やすほど細かい乱れが乗り、弱まりを大きくするほど細かいほうが目立つ。
    /// 既定は 4 枚・0.5。枚数は 1…16、弱まりは 0…1 で、外れた値は無視して知らせる。
    ///
    /// 下は同じ種の揺らぎで山の形の縁を引き、枚数だけを上の段から 1・4・8 と変えたもの
    /// (弱まりは既定の 0.5)。重ねた揺らぎは重みの合計で割って 0…1 に収めるので、1 枚だけの
    /// 上の段がいちばん大きく波打つ。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     noiseSeed(3)
    ///     for lod in [1, 4, 8] {
    ///         noiseDetail(lod, 0.5)
    ///         beginShape()
    ///         vertex(0, 95)
    ///         for x in stride(from: 0, through: width, by: 1) {
    ///             vertex(x, 10 + noise(x * 0.01) * 80)
    ///         }
    ///         vertex(width, 95)
    ///         endShape(.close)
    ///         translate(0, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 山並みのような橙の形が 3 段。上の段は大きくなだらかな波で、下の段ほど縁に細かい凹凸が増えていく -->
    ///     ![山並みのような橙の形が 3 段。上の段は大きくなだらかな波で、下の段ほど縁に細かい凹凸が増えていく](https://i.gyazo.com/8d5de2e17e916c90afdb0644addcb73b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 次は枚数を既定の 4 に置いたまま、弱まりを上の段から 0.25・0.5・0.75 と変えたもの。
    /// 中段はどちらの絵も既定の細かさなので、同じ形になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     noiseSeed(3)
    ///     for falloff in [0.25, 0.5, 0.75] {
    ///         noiseDetail(4, falloff)
    ///         beginShape()
    ///         vertex(0, 95)
    ///         for x in stride(from: 0, through: width, by: 1) {
    ///             vertex(x, 10 + noise(x * 0.01) * 80)
    ///         }
    ///         vertex(width, 95)
    ///         endShape(.close)
    ///         translate(0, 100)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 山並みのような橙の形が 3 段。下の段ほど大きな波が低くなり、縁の細かい凹凸が目立っていく -->
    ///     ![山並みのような橙の形が 3 段。下の段ほど大きな波が低くなり、縁の細かい凹凸が目立っていく](https://i.gyazo.com/605bef060a7589702b45e0aecc9915c8.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **断片にも同じ細かさが届く。** 種と同じくスケッチに 1 つで、描き場所
    /// (``createGraphics(_:_:)``) の断片にも届き、描き場所の上で呼んでも
    /// (`pg.noiseDetail(_:_:)`) 同じ 1 つを書き換える。置いた図形の断片は置いた時点の細かさで
    /// 引き、決め直してもそこで描き切らない (``noiseSeed(_:)`` と同じ)。
    ///
    /// - Note: 揺らぎの細かさは**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=feae6dd5
    // shot: 2 snippet=52f4861b
    public func noiseDetail(_ lod: Int, _ falloff: some ScalarConvertible = 0.5) {
        let falloff = falloff.asFloat
        canvas.noiseDetail(lod, falloff)
    }
}
