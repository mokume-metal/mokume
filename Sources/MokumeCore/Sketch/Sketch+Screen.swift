// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 面の座標と空間の座標を行き来する。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Sketch {

    // MARK: - 空間 → 画面

    /// 点が、いまの変換でどこへ移るか (横)。
    ///
    /// 読んだ値は**面の座標**で、変換を戻した後の図形にそのまま使える。下は、回した枠の角
    /// `(90, 0)` に点を打ってその横の位置を読み、`pop()` の後に縦線を引いたもの。枠を回す
    /// 角度を 0・45 度・90 度と動かしても、線は角の点を通り続ける。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     // 枠を回す角度を 0・45 度・90 度と動かす
    ///     let angles: [Float] = [0, Float.pi / 4, Float.pi / 2]
    ///     for i in 0..<3 {
    ///         push()
    ///         translate(30 + i * 130, 40)
    ///         rotate(angles[i])
    ///         noFill()
    ///         stroke(89, 97, 115)
    ///         strokeWeight(2)
    ///         rect(0, 0, 90, 50)
    ///         // 枠の角 (90, 0) に点を打ち、その横の位置を読む
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         circle(90, 0, 10)
    ///         let x = screenX(90, 0)
    ///         pop()
    ///         // 読んだ値は面の座標なので、変換を戻した後に縦線で引ける
    ///         stroke(242, 115, 64)
    ///         strokeWeight(2)
    ///         line(x, 10, x, 290)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の長方形が 3 つ。左から右へ 0 度・45 度・90 度と回してあり、どれも枠の同じ角に打った橙色の点を、橙色の縦線が通っている -->
    ///     ![灰色の枠の長方形が 3 つ。左から右へ 0 度・45 度・90 度と回してあり、どれも枠の同じ角に打った橙色の点を、橙色の縦線が通っている](https://i.gyazo.com/c0db6e05a4b0f4d081b9eb858fbc7b57.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 引数の `x` と `y` も、1 つずつ動かすと読みが変わる。下は 30 度回した枠で、原点・`x` を
    /// 120 にした角・`y` も 80 にした角を読んだもの。`x` を動かすと線は右へ 104 ほど、`y` を
    /// 動かすと左へ 40 ほど移る (回した枠では、`y` の増える向きが左下を向く)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(60, 60)
    ///     rotate(Float.pi / 6)
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     rect(0, 0, 120, 80)
    ///     // 原点から、x だけ動かした角、y だけ動かした角
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     circle(0, 0, 12)
    ///     fill(89, 191, 242)
    ///     circle(120, 0, 12)
    ///     fill(242, 217, 89)
    ///     circle(120, 80, 12)
    ///     let first = screenX(0, 0)
    ///     let second = screenX(120, 0)
    ///     let third = screenX(120, 80)
    ///     // 読んだ値は面の座標なので、変換を捨てた後に縦線で引ける
    ///     resetMatrix()
    ///     stroke(242, 115, 64)
    ///     line(first, 10, first, 290)
    ///     stroke(89, 191, 242)
    ///     line(second, 10, second, 290)
    ///     stroke(242, 217, 89)
    ///     line(third, 10, third, 290)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 回した灰色の枠の 3 つの角に橙・水色・黄色の点があり、同じ色の縦線がそれぞれの点を通っている。橙の線の右に水色の線が離れ、黄色の線はそのあいだにある -->
    ///     ![回した灰色の枠の 3 つの角に橙・水色・黄色の点があり、同じ色の縦線がそれぞれの点を通っている。橙の線の右に水色の線が離れ、黄色の線はそのあいだにある](https://i.gyazo.com/4e65ed488899aa44d718e6466bffbec6.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **奥行きを渡さない形は視点を通さない。** 平面の図形が通る道と同じで、
    /// ``camera()`` をどう動かしてもこの値は変わらない。視点を通した位置が要るときは
    /// 奥行きまで渡す ``screenX(_:_:_:)`` を使う。
    ///
    /// 下は、視点を横へずらしながら箱を置いたもの。橙色の輪が奥行きを渡さない読みで、どの視点でも
    /// 中央から動かない。水色の点が奥行きまで渡す読みで、視点に従って箱の中心へ移る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     var flat: [(Float, Float)] = []
    ///     var solid: [(Float, Float)] = []
    ///     for i in 0..<3 {
    ///         // 視点を横へずらす (見ている先も一緒に動かす)
    ///         let shift = Float(i - 1) * 110
    ///         camera(200 + shift, 150, 300, 200 + shift, 150, 0, 0, 1, 0)
    ///         push()
    ///         translate(200, 150, 0)
    ///         fill(89, 97, 115)
    ///         box(60)
    ///         // 奥行きを渡さない読みは、視点を動かしても同じ
    ///         flat.append((screenX(0, 0), screenY(0, 0)))
    ///         // 奥行きまで渡す読みは、箱に付いてくる
    ///         solid.append((screenX(0, 0, 0), screenY(0, 0, 0)))
    ///         pop()
    ///     }
    ///     // 読んだ位置は面の座標なので、平面の図形で印にできる
    ///     for i in 0..<3 {
    ///         noFill()
    ///         stroke(242, 115, 64)
    ///         circle(flat[i].0, flat[i].1, 30 + Float(i) * 16)
    ///         noStroke()
    ///         fill(89, 191, 242)
    ///         circle(solid[i].0, solid[i].1, 12)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ大きさの灰色の箱が左・中央・右に 3 つ並び、どの箱にも中ほどに水色の点がある。中央の箱のまわりにだけ、橙色の輪が 3 重に重なっている | symmetric=xy -->
    ///     ![同じ大きさの灰色の箱が左・中央・右に 3 つ並び、どの箱にも中ほどに水色の点がある。中央の箱のまわりにだけ、橙色の輪が 3 重に重なっている](https://i.gyazo.com/297cb432e03696085381da928e1b4f1c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=7702f10a
    // shot: 2 snippet=9bbf7c9f
    // shot: 3 snippet=b4f7def8
    public func screenX(_ x: some ScalarConvertible, _ y: some ScalarConvertible) -> Float {
        let (x, y) = (x.asFloat, y.asFloat)
        return Self.drawingCanvas?.screenX(x, y) ?? 0
    }

    /// 点が、いまの変換でどこへ移るか (縦)。
    ///
    /// ``screenX(_:_:)`` の縦の読み。奥行きを渡さない形なので、こちらも視点を通さない。下は、回した
    /// 枠の角 `(90, 0)` に点を打ってその縦の位置を読み、`pop()` の後に横線を引いたもの。枠を回す
    /// 角度を 0・45 度・90 度と動かすと、線は角の点を通ったまま下へ移っていく。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     // 枠を回す角度を 0・45 度・90 度と動かす
    ///     let angles: [Float] = [0, Float.pi / 4, Float.pi / 2]
    ///     for i in 0..<3 {
    ///         push()
    ///         translate(30 + i * 130, 40)
    ///         rotate(angles[i])
    ///         noFill()
    ///         stroke(89, 97, 115)
    ///         strokeWeight(2)
    ///         rect(0, 0, 90, 50)
    ///         // 枠の角 (90, 0) に点を打ち、その縦の位置を読む
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         circle(90, 0, 10)
    ///         let y = screenY(90, 0)
    ///         pop()
    ///         // 読んだ値は面の座標なので、変換を戻した後に横線で引ける
    ///         stroke(242, 115, 64)
    ///         strokeWeight(2)
    ///         line(5 + i * 130, y, 125 + i * 130, y)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の枠の長方形が 3 つ。左から右へ 0 度・45 度・90 度と回してあり、どれも枠の同じ角に打った橙色の点を、橙色の横線が通っている -->
    ///     ![灰色の枠の長方形が 3 つ。左から右へ 0 度・45 度・90 度と回してあり、どれも枠の同じ角に打った橙色の点を、橙色の横線が通っている](https://i.gyazo.com/2ec48886c31bfff78238038533e21206.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 引数の `x` と `y` も、1 つずつ動かすと読みが変わる。下は 30 度回した枠で、原点・`x` を
    /// 120 にした角・`y` も 80 にした角を読んだもの。`x` を動かすと線は 60 ほど、`y` を動かすと
    /// さらに 69 ほど下へ移る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     translate(60, 60)
    ///     rotate(Float.pi / 6)
    ///     noFill()
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     rect(0, 0, 120, 80)
    ///     // 原点から、x だけ動かした角、y だけ動かした角
    ///     noStroke()
    ///     fill(242, 115, 64)
    ///     circle(0, 0, 12)
    ///     fill(89, 191, 242)
    ///     circle(120, 0, 12)
    ///     fill(242, 217, 89)
    ///     circle(120, 80, 12)
    ///     let first = screenY(0, 0)
    ///     let second = screenY(120, 0)
    ///     let third = screenY(120, 80)
    ///     // 読んだ値は面の座標なので、変換を捨てた後に横線で引ける
    ///     resetMatrix()
    ///     stroke(242, 115, 64)
    ///     line(10, first, 390, first)
    ///     stroke(89, 191, 242)
    ///     line(10, second, 390, second)
    ///     stroke(242, 217, 89)
    ///     line(10, third, 390, third)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 回した灰色の枠の 3 つの角に橙・水色・黄色の点があり、同じ色の横線がそれぞれの点を通っている。上から橙・水色・黄色の順に並ぶ -->
    ///     ![回した灰色の枠の 3 つの角に橙・水色・黄色の点があり、同じ色の横線がそれぞれの点を通っている。上から橙・水色・黄色の順に並ぶ](https://i.gyazo.com/0575044ec9d66fe8d2870e94ebd7e1a6.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=27c88e8f
    // shot: 2 snippet=d464e610
    public func screenY(_ x: some ScalarConvertible, _ y: some ScalarConvertible) -> Float {
        let (x, y) = (x.asFloat, y.asFloat)
        return Self.drawingCanvas?.screenY(x, y) ?? 0
    }

    /// 奥行きを持つ点が、いまの変換といまの視点でどこへ移るか (横)。
    ///
    /// 変換を積んだ状態でも視点を変えた状態でも、**実際に描かれる画素の位置**が返る。
    /// 立体に文字や印を重ねる、当たり判定を面の座標で書く、といった用途のためにある。
    ///
    /// 下は、傾けた箱 (`box(120)`) の中心から、座標を 1 つずつ 90 動かした 3 つの点 (手前へ
    /// `z`・左へ `x`・上へ `y`) に球を置き、`pop()` の後に読んだ横の位置へ縦線を引いたもの。
    /// 線は、箱の傾きと遠近を通した、球の中心を通る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     push()
    ///     translate(200, 150, 0)
    ///     rotateX(-0.5)
    ///     rotateY(0.6)
    ///     fill(89, 97, 115)
    ///     box(120)
    ///     // 座標を 1 つずつ動かした 3 点に球を置き、横の位置を読む
    ///     let points: [SIMD3<Float>] = [[0, 0, 90], [-90, 0, 0], [0, -90, 0]]
    ///     let colors: [SIMD3<Float>] = [[242, 115, 64], [89, 191, 242], [242, 217, 89]]
    ///     var xs: [Float] = []
    ///     for (i, p) in points.enumerated() {
    ///         push()
    ///         translate(p.x, p.y, p.z)
    ///         fill(colors[i].x, colors[i].y, colors[i].z)
    ///         sphere(8)
    ///         pop()
    ///         xs.append(screenX(p.x, p.y, p.z))
    ///     }
    ///     pop()
    ///     // 読んだ値は面の座標なので、変換を戻した後に縦線で引ける
    ///     strokeWeight(2)
    ///     for (i, x) in xs.enumerated() {
    ///         stroke(colors[i].x, colors[i].y, colors[i].z)
    ///         line(x, 10, x, 290)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 傾けた灰色の箱のまわりに橙・水色・黄色の球が 1 つずつ浮かび、同じ色の縦線がそれぞれの球の中心を通っている -->
    ///     ![傾けた灰色の箱のまわりに橙・水色・黄色の球が 1 つずつ浮かび、同じ色の縦線がそれぞれの球の中心を通っている](https://i.gyazo.com/ae6e98ae8bd69c7da1c1ec211dbc365f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=25260204
    public func screenX(_ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible) -> Float {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        return Self.drawingCanvas?.screenX(x, y, z) ?? 0
    }

    /// 奥行きを持つ点が、いまの変換といまの視点でどこへ移るか (縦)。
    ///
    /// ``screenX(_:_:_:)`` の縦の読み。下は同じ場面で、読んだ縦の位置へ横線を引いたもの。傾けた箱
    /// (`box(120)`) の中心から、座標を 1 つずつ 90 動かした 3 つの点に球を置く。線は球の中心を通る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     push()
    ///     translate(200, 150, 0)
    ///     rotateX(-0.5)
    ///     rotateY(0.6)
    ///     fill(89, 97, 115)
    ///     box(120)
    ///     // 座標を 1 つずつ動かした 3 点に球を置き、縦の位置を読む
    ///     let points: [SIMD3<Float>] = [[0, 0, 90], [-90, 0, 0], [0, -90, 0]]
    ///     let colors: [SIMD3<Float>] = [[242, 115, 64], [89, 191, 242], [242, 217, 89]]
    ///     var ys: [Float] = []
    ///     for (i, p) in points.enumerated() {
    ///         push()
    ///         translate(p.x, p.y, p.z)
    ///         fill(colors[i].x, colors[i].y, colors[i].z)
    ///         sphere(8)
    ///         pop()
    ///         ys.append(screenY(p.x, p.y, p.z))
    ///     }
    ///     pop()
    ///     // 読んだ値は面の座標なので、変換を戻した後に横線で引ける
    ///     strokeWeight(2)
    ///     for (i, y) in ys.enumerated() {
    ///         stroke(colors[i].x, colors[i].y, colors[i].z)
    ///         line(10, y, 390, y)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 傾けた灰色の箱のまわりに橙・水色・黄色の球が 1 つずつ浮かび、同じ色の横線がそれぞれの球の中心を通っている -->
    ///     ![傾けた灰色の箱のまわりに橙・水色・黄色の球が 1 つずつ浮かび、同じ色の横線がそれぞれの球の中心を通っている](https://i.gyazo.com/b937aa1adcf363b532b3a4eb555b8362.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=45110c8e
    public func screenY(_ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible) -> Float {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        return Self.drawingCanvas?.screenY(x, y, z) ?? 0
    }

    /// 奥行きを持つ点が、いまの視点でどれだけ奥にあるか。
    ///
    /// **0 が手前の面、1 が奥の面。** 面の上の位置ではなく、奥行きの面に書かれる値
    /// なので、大小を比べれば前後が分かる。
    ///
    /// 手前の面と奥の面は ``perspective(_:_:_:_:)`` が決める。下は距離 100 を手前の面、600 を奥の面
    /// にして、手前から奥へ置いた同じ大きさの球 3 つの奥行きを、0 から 1 の帯の上へ目盛りで置いた
    /// もの。奥の球ほど目盛りは帯の右へ寄る (橙 0.45・青 0.74・黄 0.87)。値は距離に比例せず、
    /// 手前ほど大きく動く。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     // 手前の面は距離 100、奥の面は距離 600
    ///     perspective(Float.pi / 3, width / height, 100, 600)
    ///     let xs: [Float] = [130, 200, 290]
    ///     let colors: [SIMD3<Float>] = [[242, 115, 64], [89, 191, 242], [242, 217, 89]]
    ///     var depths: [Float] = []
    ///     for i in 0..<3 {
    ///         push()
    ///         translate(xs[i], 110, 100 - Float(i) * 100)
    ///         fill(colors[i].x, colors[i].y, colors[i].z)
    ///         sphere(30)
    ///         depths.append(screenZ(0, 0, 0))
    ///         pop()
    ///     }
    ///     // 帯の左端が 0、右端が 1。球の奥行きを目盛りで置く
    ///     stroke(89, 97, 115)
    ///     strokeWeight(2)
    ///     line(20, 250, 380, 250)
    ///     noStroke()
    ///     for (i, depth) in depths.enumerated() {
    ///         fill(colors[i].x, colors[i].y, colors[i].z)
    ///         circle(20 + 360 * depth, 250, 14)
    ///     }
    ///     fill(217, 230, 255)
    ///     text("0", 14, 282)
    ///     text("1", 374, 282)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 手前の橙色から青、黄色の順に奥へ小さくなる 3 つの球。下の 0 から 1 の帯には、球と同じ色の目盛りが手前の橙色から奥の黄色へ右へ寄って並んでいる -->
    ///     ![手前の橙色から青、黄色の順に奥へ小さくなる 3 つの球。下の 0 から 1 の帯には、球と同じ色の目盛りが手前の橙色から奥の黄色へ右へ寄って並んでいる](https://i.gyazo.com/f787cbabe310bbe64fc17f62d23fe953.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// この値がそのまま ``spacePosition(screenX:screenY:depth:)`` の `depth` になる —
    /// 前向きの 3 本が、後ろ向きの入力を過不足なく作る。
    // shot: 1 snippet=1263b738
    public func screenZ(_ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible) -> Float {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        return Self.drawingCanvas?.screenZ(x, y, z) ?? 0
    }

    // MARK: - 画面 → 空間

    /// 面の位置が、いまの視点で空間のどこを指すか。
    ///
    /// 返るのは**いまの変換の中の座標**で、``screenX(_:_:_:)`` に渡す座標と同じ意味。
    /// だから前向きと後ろ向きは、変換を積んだ状態でも往復して元へ戻る。下は、傾けた箱 (変換を
    /// 積んである) のまわりの 3 点 (水色の球) を ``screenX(_:_:_:)`` / ``screenY(_:_:_:)`` /
    /// ``screenZ(_:_:_:)`` で面の位置と奥行きに写し、`spacePosition` で戻した点を橙色の枠で
    /// 囲んだもの。枠はどれも、水色の球を中心に収めている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     lights()
    ///     noStroke()
    ///     translate(200, 150, 0)
    ///     rotateX(-0.5)
    ///     rotateY(0.6)
    ///     fill(89, 97, 115)
    ///     box(120)
    ///     let points: [SIMD3<Float>] = [[0, 0, 90], [-90, 0, 0], [0, -90, 0]]
    ///     for p in points {
    ///         // 元の点に、青い球を置く
    ///         push()
    ///         translate(p.x, p.y, p.z)
    ///         fill(89, 191, 242)
    ///         sphere(5)
    ///         pop()
    ///         // 面の上の位置と奥行きに写してから戻した点を、橙色の枠で囲む
    ///         let q = spacePosition(
    ///             screenX: screenX(p.x, p.y, p.z),
    ///             screenY: screenY(p.x, p.y, p.z),
    ///             depth: screenZ(p.x, p.y, p.z))
    ///         push()
    ///         translate(q.x, q.y, q.z)
    ///         noFill()
    ///         stroke(242, 115, 64)
    ///         strokeWeight(2)
    ///         box(20)
    ///         pop()
    ///         noStroke()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 傾けた灰色の箱のまわりに水色の小さな球が 3 つあり、どの球も橙色の立方体の枠に囲まれて、枠の中心に収まっている -->
    ///     ![傾けた灰色の箱のまわりに水色の小さな球が 3 つあり、どの球も橙色の立方体の枠に囲まれて、枠の中心に収まっている](https://i.gyazo.com/0532fa80fbf9e6e61be6c8ea3d916321.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// `depth` は**どの奥行きの面へ戻すか**を決める (0 が手前の面、1 が奥の面)。
    /// 面 1 枚ぶんの位置からは空間の 1 点は決まらないので、戻し先を渡す側が選ぶ。
    /// 下は、指す位置を (270, 100) に決めたまま `depth` だけを 0.8・0.9・0.95 と動かして、戻した
    /// 点に同じ大きさの正方形 (`plane(50, 50)`) の枠を置いたもの。どの枠も指した位置を中心に
    /// 重なるが、`depth` が大きいほど奥へ置かれて小さく写る (一辺 104・55・30 画素ほど)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(23, 26, 31)
    ///     noFill()
    ///     strokeWeight(2)
    ///     // 指す位置は固定し、depth だけを 0.8・0.9・0.95 と動かす
    ///     let colors: [SIMD3<Float>] = [[242, 115, 64], [89, 191, 242], [242, 217, 89]]
    ///     for (i, depth) in [Float(0.8), 0.9, 0.95].enumerated() {
    ///         let p = spacePosition(screenX: 270, screenY: 100, depth: depth)
    ///         push()
    ///         translate(p.x, p.y, p.z)
    ///         stroke(colors[i].x, colors[i].y, colors[i].z)
    ///         plane(50, 50)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙・水色・黄色の正方形の枠が同じ中心に入れ子になっていて、外の橙から内の黄色へ小さくなっている -->
    ///     ![橙・水色・黄色の正方形の枠が同じ中心に入れ子になっていて、外の橙から内の黄色へ小さくなっている](https://i.gyazo.com/8b17a93039e1d7d174449bf65d45988d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 掴む・置くはたいてい「掴んだ物と同じ奥行き」なので、その物の
    /// ``screenZ(_:_:_:)`` を取って渡す:
    ///
    /// <!-- example: 文脈 var held = SIMD3<Float>(0, 0, 0) -->
    /// ```swift
    /// // 掴んだ物を、画面に沿って引きずる
    /// let depth = screenZ(held.x, held.y, held.z)
    /// let pointed = spacePosition(screenX: mouseX, screenY: mouseY, depth: depth)
    /// if isMousePressed { held = pointed }
    /// ```
    ///
    /// 平行投影でも透視投影でも同じように使える (式の違いは視点の側が持つ)。
    // shot: 1 snippet=e8bfd5e4
    // shot: 2 snippet=7cd7de68
    public func spacePosition(screenX: some ScalarConvertible, screenY: some ScalarConvertible, depth: some ScalarConvertible) -> SIMD3<Float> {
        let (screenX, screenY, depth) = (screenX.asFloat, screenY.asFloat, depth.asFloat)
        return Self.drawingCanvas?.spacePosition(screenX: screenX, screenY: screenY, depth: depth)
            ?? .zero
    }

    /// いま描いている面。走っていなければ `nil`。
    ///
    /// 座標を読むのに ``canvas`` を通さないのは、あちらが**走っていなければ止める**
    /// ためである。座標は読み取りなので決して落ちてはならず ([ADR-0020] 決定 5)、
    /// 初期化の中や後片付けの後から呼ばれうる — 入力を読む道 (``mouseX``) が
    /// 「走っていなければ空の状態」を返すのと同じ扱いにする。
    @MainActor
    private static var drawingCanvas: Canvas? { runningSketch?.canvas }
}
