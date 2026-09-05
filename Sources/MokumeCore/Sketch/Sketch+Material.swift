// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 表面の質感。
extension Sketch {
    /// 艶の鋭さ。**0 なら艶を出さない** (既定)。
    ///
    /// 数が大きいほど艶は小さく鋭くなり、小さいほど広くぼやける — 粗い表面ほど
    /// 小さい数になる。
    ///
    /// ```swift
    /// func draw() {
    ///     lights()
    ///     fill(230, 217, 204)
    ///     shininess(64)        // 磨いた面
    ///     push()
    ///     translate(width / 2, height / 2, 0)
    ///     sphere(120)
    ///     pop()
    /// }
    /// ```
    ///
    /// 下は同じ球を、艶の鋭さだけ変えて 3 つ描いたもの。**光の当たる側に白い点が
    /// 現れ、数を上げるほど小さく強くなる。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     fill(242, 115, 64)
    ///     noStroke()
    ///     for (index, amount) in [Float(0), 16, 128].enumerated() {
    ///         shininess(amount)
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の球が 3 つ。左は艶が無く、中央は広くぼやけた白い光沢、右は小さく鋭い光沢が乗っている -->
    ///     ![橙色の球が 3 つ。左は艶が無く、中央は広くぼやけた白い光沢、右は小さく鋭い光沢が乗っている](https://i.gyazo.com/be1ce514b17b5130287aa42a7943faca.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 材質は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    ///   **光を 1 つも置かなければ立体は塗り 1 色で出る**ので、材質はどれも効かない
    ///   (書いてあれば警告が出る)。
    // shot: 1 snippet=d8f1f5d4
    public func shininess(_ amount: Float) { canvas.shininess(amount) }

    /// 金属らしさ。`0` が非金属 (既定)、`1` が金属。
    ///
    /// 金属は拡散を持たず、**周りを映すことでしか見えない**。映す先になるのは
    /// ``surroundings(_:)`` で置いた周囲で、それが無ければ ``ambientLight(_:)-fvb5`` で
    /// 置いた底上げの光を一様な周りとして映す。**どちらも置かずに金属を上げると、
    /// 艶だけが残って暗くなる** (このとき警告が出る)。
    ///
    /// 艶の色も変わる。非金属の艶は光の色のまま白く出るが、金属の艶は塗りの色に
    /// 染まる。
    ///
    /// 下は同じ球を、金属らしさだけ変えて 3 つ描いたもの。光は 1 つも置かず、
    /// ``surroundings(_:)`` だけを置いている。**上げるほど周囲の映り込みが強くなり、
    /// その色は塗りに染まる** — 上下の明暗の差が開き、全体が塗りの色みへ寄っていく。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(15, 15, 18)
    ///     surroundings(.studio)
    ///     noStroke()
    ///     fill(230, 184, 115)
    ///     shininess(90)
    ///     for (index, amount) in [Float(0), 0.5, 1].enumerated() {
    ///         metalness(amount)
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 球が 3 つ。右へ行くほど上下の明暗の差がはっきりし、色みも濃い黄土色へ寄っていく -->
    ///     ![球が 3 つ。右へ行くほど上下の明暗の差がはっきりし、色みも濃い黄土色へ寄っていく](https://i.gyazo.com/29e5163ee3334c81b0922480653348c6.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 材質は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=06e03582
    public func metalness(_ amount: Float) { canvas.metalness(amount) }

    /// 周りの光 (``ambientLight(_:)-fvb5``) をどれだけ返すか。既定は白 = 全部返す。
    ///
    /// 灰色を渡すとその分だけ返さなくなる — **物陰のように、周りの光が届きにくい
    /// ところを表す**のに使う。塗りに掛かるので、白は何も変えない。
    ///
    /// ```swift
    /// ambient(76, 76, 76)   // 周りの光を 3 割だけ返す
    /// ```
    ///
    /// **動くのはほとんど暗い側である。** 下は同じ球を、返す量だけ変えて 3 つ描いた
    /// もの — 陰の側が 6 分の 1 まで落ちるあいだ、直接の光が当たっている側は 1 割ほど
    /// しか下がらない。結果として**陰影は深くなる**。``emissive(_:)-uyuh`` とはここが逆に
    /// なる (あちらは陰影を浅くする)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     ambientLight(.linear(red: 0.45, green: 0.45, blue: 0.45))
    ///     directionalLight(.linear(red: 0.9, green: 0.9, blue: 0.9), -0.4, 0.5, -0.6)
    ///     fill(242, 115, 64)
    ///     noStroke()
    ///     for (index, level) in [Float(1), 0.5, 0.1].enumerated() {
    ///         ambient(.display(red: level, green: level, blue: level))
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の球が 3 つ。明るい側はほとんど変わらないまま、陰の側が左から右へ暗く沈んでいく -->
    ///     ![橙色の球が 3 つ。明るい側はほとんど変わらないまま、陰の側が左から右へ暗く沈んでいく](https://i.gyazo.com/3bfd3f8f6df201f6c998b7a9395fed2d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 材質は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=14b30e32
    public func ambient(_ color: LinearRGBA) { canvas.ambient(color) }

    /// 自ら出す光。光が当たっていない側にも同じだけ出る。
    ///
    /// **周りを照らしはしない** — その面が明るく見えるだけで、ほかの立体には届かない。
    /// 明かりそのものを描きたいときは、同じ場所に ``pointLight(_:_:_:_:)`` も置く。
    ///
    /// **足されるのは明暗を問わず同じ量である。** 下は同じ球を、自ら出す光だけ変えて
    /// 3 つ描いたもの — 同じ量でも暗いところほど見た目の変化は大きいので、**陰影は
    /// 浅くなっていく**。``ambient(_:)-9anin`` とはここが逆になる (あちらは陰影を深くする)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     ambientLight(.linear(red: 0.10, green: 0.10, blue: 0.10))
    ///     directionalLight(.linear(red: 0.9, green: 0.9, blue: 0.9), -0.4, 0.5, -0.6)
    ///     fill(242, 115, 64)
    ///     noStroke()
    ///     for (index, glow) in [Float(0), 0.15, 0.4].enumerated() {
    ///         emissive(.display(red: glow, green: glow, blue: glow))
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の球が 3 つ。左から右へ、陰の側から先に明るくなり、陰影が浅く平らになっていく -->
    ///     ![橙色の球が 3 つ。左から右へ、陰の側から先に明るくなり、陰影が浅く平らになっていく](https://i.gyazo.com/b381c5a8f93ead6e14161fbfa647ae77.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 材質は**フレームを越えない**。`draw()` の中で毎フレーム書く。
    // shot: 1 snippet=c69f18e1
    public func emissive(_ color: LinearRGBA) { canvas.emissive(color) }
}
