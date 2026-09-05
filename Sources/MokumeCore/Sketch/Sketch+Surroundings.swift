// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 周囲。
extension Sketch {
    /// 立体を取り巻く周囲を置く。**金属や艶のある面は、これが無いと絵にならない。**
    ///
    /// 周囲は上・地平・下の 3 色の帯で、資材は要らない。置くと 2 つのことが起きる:
    /// 面がその向きに応じて周囲の色を受け取り (上を向いた面は空の色、下を向いた面は
    /// 地面の色)、艶があれば反射の向きの色が映り込む。
    ///
    /// ```swift
    /// func draw() {
    ///     surroundings(.sky)
    ///     background(.sky)        // 背景にも出す (置くのと描くのは別)
    ///     metalness(1)
    ///     shininess(90)
    ///     push()
    ///     translate(width / 2, height / 2, 0)
    ///     sphere(120)
    ///     pop()
    /// }
    /// ```
    ///
    /// **他の設定は何も変わらない** — 底上げの光も露出も、置いたままである。周囲は
    /// 「もう 1 つ置いた光」として足されるだけなので、絵が変わった理由はいつも
    /// 呼び出した行から読める。
    ///
    /// 下は同じ金属の球を、備え付けの 3 つの周囲で照らしたもの。**光は 1 つも
    /// 置いていない** — 映っているのは周囲だけである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(15, 15, 18)
    ///     noStroke()
    ///     fill(230, 230, 230)
    ///     metalness(1)
    ///     shininess(90)
    ///     for (index, around) in [Surroundings.sky, .studio, .sunset].enumerated() {
    ///         surroundings(around)
    ///         push()
    ///         translate(70 + Float(index) * 130, 150, 0)
    ///         sphere(55)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 金属の球が 3 つ。左は青みがかり、中央は白っぽく、右は橙色を帯びている -->
    ///     ![金属の球が 3 つ。左は青みがかり、中央は白っぽく、右は橙色を帯びている](https://i.gyazo.com/323d13551c98f40083a134d04aa209c8.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 周囲は**フレームを越えない**。`draw()` の中で毎フレーム置く。
    // shot: 1 snippet=f1ee1778
    public func surroundings(_ surroundings: Surroundings) {
        canvas.surroundings(surroundings)
    }

    /// 周囲を背景として描く。いまの視点から見た周囲がそのまま出る。
    ///
    /// **置くのと描くのは別である。** ``surroundings(_:)`` を呼ばずにこれだけを呼べば
    /// 背景にだけ出て、映り込みには効かない。逆も同じ。片方を呼んだらもう片方も、
    /// という親切は入れていない。
    ///
    /// 背景と映り込みは**同じ 1 本の式から読む**ので、上下・左右がずれることはない。
    ///
    /// **別なので、食い違わせることもできる。** 下は背景に空を描きながら、映り込む
    /// 周囲には夕暮れを置いたもの — 背景は青いのに、球には橙が映る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     // 背景に描くのは空
    ///     background(.sky)
    ///     // 映り込むのは夕暮れ
    ///     surroundings(.sunset)
    ///     noStroke()
    ///     fill(230, 230, 230)
    ///     metalness(1)
    ///     shininess(90)
    ///     push()
    ///     translate(200, 150, 0)
    ///     sphere(105)
    ///     pop()
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 青白い空を背にした金属の球。球に映っているのは空ではなく、橙色の夕暮れ | symmetric=x -->
    ///     ![青白い空を背にした金属の球。球に映っているのは空ではなく、橙色の夕暮れ](https://i.gyazo.com/ee4bac5632737a4adabc740d6b5f06d6.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=0713ef18
    public func background(_ surroundings: Surroundings) {
        canvas.background(surroundings)
    }
}
