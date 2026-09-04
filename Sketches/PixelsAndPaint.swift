// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 画素の読み書きと、自分で書いた塗り。
final class PixelsAndPaint: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "pixels and paint")

    private var ripple: Shader?

    func setup() {
        // 断片は文字列からも作れる。書くのは「その画素の色」だけ
        ripple = try? makeShader(
            """
            float4 paint(Fragment in, Values values) {
                float2 centre = float2(0.5, 0.5);
                float distance = length(in.place - centre);
                float wave = 0.5 + 0.5 * sin(distance * values.density - in.time * 2.0);
                float3 colour = mix(values.deep.rgb, values.shallow.rgb, wave);
                return float4(colour, 1.0);
            }
            """,
            values: [
                "density": 60,
                "deep": .color(color(26, 38, 89)),
                "shallow": .color(color(153, 230, 242)),
            ])
    }

    func draw() {
        background(15, 18, 23)
        noStroke()

        // 左: 自分で書いた塗り
        if let ripple {
            shader(ripple)
            // **値は前のフレームのまま残る。** 毎フレーム決め直さないと、上の帯が
            // 下の帯の値で描かれる (前のフレームの終わりの値がそのまま効く)
            ripple.set("density", 60)
            ripple.set("shallow", .color(color(153, 230, 242)))
            rect(0, 0, 480, 400)
            // 値を変えると、そこで区切られる — 上に置いたものは変わらない
            ripple.set("density", 18)
            ripple.set("shallow", .color(color(242, 204, 102)))
            rect(0, 400, 480, 140)
            resetShader()
        }

        // 右: 組み込みの塗りで図形を置く
        fill(242, 115, 76)
        circle(700, 180, 220)
        fill(102, 204, 153, 191)
        rect(620, 200, 240, 200)

        // その上から、画素を読んで書き換える。**そのフレームでそこまでに描いたものが読める**
        for y in 0..<Int(height) {
            for x in 480..<Int(width) {
                // 右端へ行くほど、赤と青を入れ替えていく
                let mix = Float(x - 480) / (width - 480)
                let colour = pixels[x, y]
                pixels[x, y] = LinearRGBA(
                    premultipliedRed: colour.red * (1 - mix) + colour.blue * mix,
                    green: colour.green,
                    blue: colour.blue * (1 - mix) + colour.red * mix,
                    alpha: colour.alpha)
            }
        }

        // 読み書きのあとにも描ける
        fill(242, 242, 230)
        textFont("Helvetica")
        textSize(16)
        text("右半分は、描いてから画素を読んで書き換えたもの", 500, 500)
    }
}
