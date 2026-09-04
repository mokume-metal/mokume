// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 走らせたまま動かせる値。**つまみを引いて絵が変わることを確かめるための参照スケッチ。**
///
/// 宣言した値は 1 つずつが**同じ 1 つの実体**で、窓のつまみ・外からの書き込み
/// (`.mokume/params/`)・保存 (`.mokume/state/params.json`) は、どれもそこへの入口である
/// ([ADR-0013] 決定 3)。だからここには登録も通知も保存の呼び出しも出てこない —
/// 書いてあるのは宣言と、値を読んで描く普通のコードだけである。
///
/// ## 触るための参照スケッチ
///
/// 他の参照スケッチと違って、これは**書き出した 1 枚には現れない**。書き出せるのは
/// つまみを触っていない状態の絵で、見たいのは「引いたら変わるか」だからである
/// ([PointerAndKeys] と同じ性質)。
///
/// 触ってみるには:
///
/// ```
/// swift run reference-sketches knobs-and-values
/// ```
///
/// 外から動かすには、走らせる前に区画を作ってから要求を置く (区画を見るのは起動の
/// 瞬間だけなので、後から作っても拾わない):
///
/// ```
/// mkdir -p .mokume/params
/// swift run reference-sketches knobs-and-values &
/// echo '{"id":"a1","values":[{"name":"size","type":"float","value":90}]}' > .mokume/params/request.json
/// ```
///
/// **窓のつまみが動く。** 窓は値の写しを持たず正典を読んでいるので、外から書いても
/// つまみのほうが追いつく。
///
/// ## 台帳には載せない
///
/// 代表シーンの台帳 ([ADR-0019] 決定 3) には入れない。つまみを外から動かすシーンは
/// そのままでは決定論の水準 2 を名乗らないためである ([ADR-0025] 決定 1 の「外から
/// 届く入力」)。**載せるなら記録した値で回す形にする必要があり、それはこの
/// スケッチの用途 (触って確かめる) と噛み合わない。**
///
/// [ADR-0013]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0013-parameter-model.md
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
final class KnobsAndValues: Sketch {
    var settings = SketchSettings(width: 1280, height: 1000, title: "knobs and values")

    /// 並びの数。範囲を書いたので、窓には刻みつきのスライダーが出る。
    @Param(1...12) var columns: Int = 6
    @Param(1...10) var rows: Int = 4

    /// 1 つぶんの大きさと、回る速さ。
    @Param(4...140) var size: Double = 56
    @Param(-2...2) var spin: Double = 0.35

    /// 塗るか、輪郭だけか。
    @Param var filled: Bool = true

    /// 何を並べるか。**候補を書いたので、窓では候補から選ぶ形になる** —
    /// 外から書くときも、候補の外は理由つきで断られる。
    ///
    /// 既定を `circle` にしていないのは、円は回しても同じに見えるからである。
    /// 既定の姿で ``spin`` が効かないと、そのつまみは壊れているように見える。
    @Param(choices: ["circle", "square", "triangle"]) var shape: String = "square"

    /// 色。作業空間の色をそのまま宣言できる。
    @Param var tint: LinearRGBA = color(250, 158, 61)

    /// 並び全体のずれ。組は成分ごとのスライダーになる。
    @Param(-1...1) var drift: SIMD2<Float> = SIMD2(0, 0)

    /// ばらつきの種。**範囲を書いていないので、窓につまみは出ない** ([ADR-0030] 決定 8)。
    /// 値は窓にも面にも出るし、外からは書ける — 引いて合わせる種類の値ではないので、
    /// これで足りる。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    @Param var seed: Int = 7

    func draw() {
        background(18, 20, 28)
        noiseSeed(seed)

        let stepX = width / Float(columns + 1)
        let stepY = height / Float(rows + 1)
        if filled { fill(tint) } else { noFill() }
        stroke(tint)
        strokeWeight(2)

        for row in 0..<rows {
            for column in 0..<columns {
                let x = stepX * Float(column + 1) + drift.x * stepX * 0.5
                let y = stepY * Float(row + 1) + drift.y * stepY * 0.5
                // 種でばらつく揺らぎ。同じ種なら同じ並びになる
                let jitter = noise(Float(column) * 0.6, Float(row) * 0.6) - 0.5
                push()
                translate(x, y)
                rotate(Float(spin) * time + jitter * 2)
                place(size: Float(size) * (0.7 + jitter))
                pop()
            }
        }
    }

    /// 選ばれた形を 1 つ置く。原点は中心。
    private func place(size extent: Float) {
        switch shape {
        case "square": square(0, 0, extent)
        case "triangle":
            let half = extent / 2
            triangle(0, -half, half, half, -half, half)
        default: circle(0, 0, extent)
        }
    }
}
