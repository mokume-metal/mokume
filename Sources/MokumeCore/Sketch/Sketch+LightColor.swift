// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Sketch {
    /// 全体を底上げする光を、素の数値で置く。**目盛りは 0–255** ([ADR-0033] 決定 1)。
    ///
    /// 0…1 で書く (1 を超える明るさも書ける) のは ``LinearRGBA`` を受ける同じ名前の口
    /// ``ambientLight(_:)-fvb5`` のほうで、ここへ `0.52` のように渡すと「255 分の 0.52」になり、
    /// ほぼ光が無くなる。
    ///
    /// 下は同じ球を、光の赤だけ 3 段に変えたもの (緑と青は 90 のまま)。向きを持たないので、
    /// どれも陰影の無い円板に見える。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     for (index, red) in [40, 140, 255].enumerated() {
    ///         noLights()
    ///         ambientLight(red, 90, 90)
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 球が 3 つ。どれも陰影の無い円板で、左の暗い茶色から右の赤へ、赤みだけが増えていく | symmetric=y -->
    ///     ![球が 3 つ。どれも陰影の無い円板で、左の暗い茶色から右の赤へ、赤みだけが増えていく](https://i.gyazo.com/47534af37c9f50e480b75dab2e8c3ec2.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 0…1 の値をここへ渡すと、ほぼ光が無くなる。下は左から `(0.52, 0.52, 0.53)`、同じ明るさを
    /// 0–255 で書いた `(133, 133, 135)`、0…1 の口へ表示の目盛りで渡した `.display(…)`。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     noLights()
    ///     ambientLight(0.52, 0.52, 0.53)
    ///     push()
    ///     translate(70, 150, 0)
    ///     sphere(55)
    ///     pop()
    ///     noLights()
    ///     ambientLight(133, 133, 135)
    ///     push()
    ///     translate(200, 150, 0)
    ///     sphere(55)
    ///     pop()
    ///     noLights()
    ///     ambientLight(.display(red: 0.52, green: 0.52, blue: 0.53))
    ///     push()
    ///     translate(330, 150, 0)
    ///     sphere(55)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左は下地より暗い真っ黒な円板、中央と右は同じ明るさの橙色の円板 | symmetric=y -->
    ///     ![左は下地より暗い真っ黒な円板、中央と右は同じ明るさの橙色の円板](https://i.gyazo.com/9ef87a4a83beb9bcf9f05bd693c94b42.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    // shot: 1 snippet=35d60dbe
    // shot: 2 snippet=674eb169
    public func ambientLight(_ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible) {
        let (red, green, blue) = (red.asFloat, green.asFloat, blue.asFloat)
        canvas.ambientLight(red, green, blue)
    }

    /// 全体を底上げする光を、灰色の明るさで置く。**目盛りは 0–255**。
    ///
    /// 0…1 で書く (1 を超える明るさも書ける) のは ``LinearRGBA`` を受ける同じ名前の口
    /// ``ambientLight(_:)-fvb5`` のほうで、ここへ `0.52` のように渡すと「255 分の 0.52」になり、
    /// ほぼ光が無くなる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     for (index, gray) in [40, 110, 230].enumerated() {
    ///         noLights()
    ///         ambientLight(gray)
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の円が 3 つ。左から右へ明るくなるが、どれも陰影が無く塗りつぶした円板に見える | symmetric=y -->
    ///     ![橙色の円が 3 つ。左から右へ明るくなるが、どれも陰影が無く塗りつぶした円板に見える](https://i.gyazo.com/b9f5131a5d7a61aa7c6792a3b22454df.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=463f0c89
    public func ambientLight(_ gray: some ScalarConvertible) {
        let gray = gray.asFloat
        canvas.ambientLight(gray)
    }

    /// 向きだけを持つ光を、素の数値で置く。**目盛りは 0–255**。
    ///
    /// 0…1 で書く (1 を超える明るさも書ける) のは ``LinearRGBA`` を受ける同じ名前の口
    /// ``directionalLight(_:_:_:_:)`` のほうで、ここへ `0.52` のように渡すと「255 分の 0.52」になり、
    /// ほぼ光が無くなる。
    ///
    /// 色の 3 つに続けて、光が**進む向き**を渡す。
    ///
    /// 下は同じ球を、光の青だけ 3 段に変えたもの (向きは 3 つとも同じ)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     for (index, blue) in [0, 128, 255].enumerated() {
    ///         noLights()
    ///         ambientLight(30)
    ///         directionalLight(255, 255, blue, 0.4, 0.5, -0.6)
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 球が 3 つ。どれも上の側が明るく下の側が暗い。明るい側は、左の青みの抜けた濃い橙から右の元の橙へ移っていく -->
    ///     ![球が 3 つ。どれも上の側が明るく下の側が暗い。明るい側は、左の青みの抜けた濃い橙から右の元の橙へ移っていく](https://i.gyazo.com/37dd8b9e267c28b8be2d1c8a795431ff.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 光には不透明度も灰色 1 つの形も無い — 手本が持たないためで、
    ///   「光の不透明度」が何を指すのかを説明できない ([ADR-0033] 決定 7)。
    ///
    /// - Note: **手本と同じ数を渡しても、同じ明るさは出ない。** 素の数値は表示の目盛りで
    ///   受け、**線形の値へ戻してから**面に掛け、表示の値へ戻して画面に出す
    ///   ([ADR-0011] 決定 1)。手本は表示の値のまま掛けるので、光が斜めに当たって弱まる
    ///   分も表示の値の上で効く。こちらはそれが線形の値の上で効くので、**斜めに光を受ける
    ///   面ほど手本より明るく出る**。数値形の光の口
    ///   (`ambientLight` / `directionalLight` / `pointLight` / `spotLight`) はどれもこの形で
    ///   受ける。手本に揃えないのは、手本に従うのが名前と引数の順序までだからである
    ///   ([ADR-0020] 決定 1)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    // shot: 1 snippet=746cf48b
    public func directionalLight(
        _ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible, _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible
    ) {
        let (red, green, blue, x, y, z) = (red.asFloat, green.asFloat, blue.asFloat, x.asFloat, y.asFloat, z.asFloat)
        canvas.directionalLight(red, green, blue, x, y, z)
    }

    /// 位置を持つ光を、素の数値で置く。**目盛りは 0–255**。
    ///
    /// 0…1 で書く (1 を超える明るさも書ける) のは ``LinearRGBA`` を受ける同じ名前の口
    /// ``pointLight(_:_:_:_:)`` のほうで、ここへ `0.52` のように渡すと「255 分の 0.52」になり、
    /// ほぼ光が無くなる。
    ///
    /// 下は同じ球を、それぞれの左上の手前に置いた光の明るさだけ 3 段に変えたもの。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     for (index, level) in [70, 150, 255].enumerated() {
    ///         let x = 70 + Float(index) * 130
    ///         noLights()
    ///         ambientLight(30)
    ///         pointLight(level, level, level, x - 50, 90, 120)
    ///         push()
    ///         translate(x, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 球が 3 つ。どれも上の側が明るく、その明るさが左から右へ強くなっていく -->
    ///     ![球が 3 つ。どれも上の側が明るく、その明るさが左から右へ強くなっていく](https://i.gyazo.com/39c3951160b1c5af99604c02f72278f3.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=b0b4f19a
    public func pointLight(
        _ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible, _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible
    ) {
        let (red, green, blue, x, y, z) = (red.asFloat, green.asFloat, blue.asFloat, x.asFloat, y.asFloat, z.asFloat)
        canvas.pointLight(red, green, blue, x, y, z)
    }

    /// 位置と向きと広がりを持つ光を、素の数値で置く。**目盛りは 0–255**。
    ///
    /// 0…1 で書く (1 を超える明るさも書ける) のは ``LinearRGBA`` を受ける同じ名前の口
    /// ``spotLight(_:_:_:_:_:_:_:angle:)`` のほうで、ここへ `0.52` のように渡すと「255 分の 0.52」になり、
    /// ほぼ光が無くなる。
    ///
    /// 色の 3 つ、光源の位置、光が進む向き、の順。`angle` は円錐の半頂角 (radian) で、
    /// 0…π/2 の外は ``spotLight(_:_:_:_:_:_:_:angle:)`` と同じく丸めて 1 度だけ知らせる。
    ///
    /// 下の 2 枚は、``spotLight(_:_:_:_:_:_:_:angle:)`` の狭い光と同じ場所・同じ角で、色だけを
    /// 255 と 120 にしたもの。輪の大きさは変わらず、明るさだけが変わる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     ambientLight(.linear(red: 0.12, green: 0.12, blue: 0.12))
    ///     spotLight(255, 255, 255, 160, 120, 200, 0, 0, -1, angle: Float.pi / 12)
    ///     push()
    ///     translate(200, 150, 0)
    ///     plane(360, 260)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 暗い橙色の面の左上寄りに、明るい小さな円が浮かんでいる -->
    ///     ![暗い橙色の面の左上寄りに、明るい小さな円が浮かんでいる](https://i.gyazo.com/8bb0b7eac83551d916aac2dae92977de.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     ambientLight(.linear(red: 0.12, green: 0.12, blue: 0.12))
    ///     spotLight(120, 120, 120, 160, 120, 200, 0, 0, -1, angle: Float.pi / 12)
    ///     push()
    ///     translate(200, 150, 0)
    ///     plane(360, 260)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ面の同じ場所に同じ大きさの円があるが、上の絵より暗い -->
    ///     ![同じ面の同じ場所に同じ大きさの円があるが、上の絵より暗い](https://i.gyazo.com/6c2a3c59bfc241e766c2d41cba835360.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=86836e88
    // shot: 2 snippet=c1634f5d
    public func spotLight(
        _ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible,
        _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible,
        _ directionX: some ScalarConvertible, _ directionY: some ScalarConvertible, _ directionZ: some ScalarConvertible,
        angle: some ScalarConvertible = Float.pi / 6
    ) {
        let (red, green, blue, x, y, z, directionX, directionY, directionZ, angle) = (red.asFloat, green.asFloat, blue.asFloat, x.asFloat, y.asFloat, z.asFloat, directionX.asFloat, directionY.asFloat, directionZ.asFloat, angle.asFloat)
        canvas.spotLight(
            red, green, blue, x, y, z, directionX, directionY, directionZ, angle: angle)
    }

    /// 面が光を受けたときに返す色を、素の数値で決める。**目盛りは 0–255**。
    ///
    /// 下は同じ球を、返す赤だけ 3 段に変えたもの (緑と青は 255 のまま)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     ortho()   // 3 つの球を同じ向きから見る
    ///     ambientLight(.linear(red: 0.10, green: 0.10, blue: 0.10))
    ///     directionalLight(.linear(red: 0.9, green: 0.9, blue: 0.9), -0.4, 0.5, -0.6)
    ///     fill(242, 115, 64)
    ///     noStroke()
    ///     for (index, red) in [255, 128, 25].enumerated() {
    ///         ambient(red, 255, 255)
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 球が 3 つ。左から右へ赤が抜けていき、陰の側ほど大きく変わって、右の球の陰はくすんだ緑みの暗い色になる -->
    ///     ![球が 3 つ。左から右へ赤が抜けていき、陰の側ほど大きく変わって、右の球の陰はくすんだ緑みの暗い色になる](https://i.gyazo.com/6cfa7a2feee0471cc4dc076ffbeb6098.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=7a515c10
    public func ambient(_ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible) {
        let (red, green, blue) = (red.asFloat, green.asFloat, blue.asFloat)
        canvas.ambient(red, green, blue)
    }

    /// 面が光を受けたときに返す色を、灰色の明るさで決める。**目盛りは 0–255**。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     ortho()   // 3 つの球を同じ向きから見る
    ///     ambientLight(.linear(red: 0.10, green: 0.10, blue: 0.10))
    ///     directionalLight(.linear(red: 0.9, green: 0.9, blue: 0.9), -0.4, 0.5, -0.6)
    ///     fill(242, 115, 64)
    ///     noStroke()
    ///     for (index, gray) in [255, 128, 25].enumerated() {
    ///         ambient(gray)
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の球が 3 つ。左から右へ明るい側も少し暗くなるが、陰の側はそれより大きく沈み、右の球の陰はほぼ黒い -->
    ///     ![橙色の球が 3 つ。左から右へ明るい側も少し暗くなるが、陰の側はそれより大きく沈み、右の球の陰はほぼ黒い](https://i.gyazo.com/777e843dcfe2c10041e9b1c0fb213dac.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=56ca5230
    public func ambient(_ gray: some ScalarConvertible) {
        let gray = gray.asFloat
        canvas.ambient(gray)
    }

    /// 面が自分で出す光を、素の数値で決める。**目盛りは 0–255**。
    ///
    /// 下は同じ球を、自ら出す光の青だけ 3 段に変えたもの (赤と緑は 0)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     ortho()   // 3 つの球を同じ向きから見る
    ///     ambientLight(.linear(red: 0.10, green: 0.10, blue: 0.10))
    ///     directionalLight(.linear(red: 0.9, green: 0.9, blue: 0.9), -0.4, 0.5, -0.6)
    ///     fill(242, 115, 64)
    ///     noStroke()
    ///     for (index, blue) in [0, 60, 160].enumerated() {
    ///         emissive(0, 0, blue)
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 球が 3 つ。左から右へ青みが足されていき、右の球は陰の側まで紫がかった青になる -->
    ///     ![球が 3 つ。左から右へ青みが足されていき、右の球は陰の側まで紫がかった青になる](https://i.gyazo.com/495a4a218cd582d2388c63291e255506.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=438a495e
    public func emissive(_ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible) {
        let (red, green, blue) = (red.asFloat, green.asFloat, blue.asFloat)
        canvas.emissive(red, green, blue)
    }

    /// 面が自分で出す光を、灰色の明るさで決める。**目盛りは 0–255**。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     ortho()   // 3 つの球を同じ向きから見る
    ///     ambientLight(.linear(red: 0.10, green: 0.10, blue: 0.10))
    ///     directionalLight(.linear(red: 0.9, green: 0.9, blue: 0.9), -0.4, 0.5, -0.6)
    ///     fill(242, 115, 64)
    ///     noStroke()
    ///     for (index, glow) in [0, 110, 200].enumerated() {
    ///         emissive(glow)
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の球が 3 つ。左から右へ陰の側が明るく持ち上がり、右の球は白っぽく陰影がごく浅い -->
    ///     ![橙色の球が 3 つ。左から右へ陰の側が明るく持ち上がり、右の球は白っぽく陰影がごく浅い](https://i.gyazo.com/96dc2ff6b833f9879770a8c915212767.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=53bc89e9
    public func emissive(_ gray: some ScalarConvertible) {
        let gray = gray.asFloat
        canvas.emissive(gray)
    }
}
