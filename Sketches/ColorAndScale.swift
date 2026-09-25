// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 色を作る口・読む口と、それぞれの目盛り。灰色 1 値の形と、光の色を数値で渡す口。
///
/// **同じ「赤」でも、口ごとに目盛りが違う。** 素の数値は 0–255、色相・彩度・明度は
/// 360 / 100 / 100、`LinearRGBA(straightRed:…)` は線形の 0…1。読み出しはどれも
/// 0–255 (と 360 / 100 / 100) へ戻して返すので、中段では**線形の 0.5 が 128 ではなく
/// 188 と読める**。下段の光も素の数値なら 0–255 で受ける。
///
/// **色相が回る。** 上段の帯は色相にそのまま時刻を足してあり、360 を越えても剰余を
/// 書かずに巻き戻る。
///
/// **2 色の間は線形で混ざる。** 灰色の段の右の帯は、同じ青と黄の間を 2 通りに混ぜて
/// 並べたもの。上の `lerpColor` は線形の光の量で混ぜ、下は 0–255 の数を成分ごとに
/// `lerp` で混ぜた (手本の `lerpColor` と同じ) もの。真ん中の色は上のほうが明るく、
/// 下は灰色へ沈む。
final class ColorAndScale: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "color and scale")

    /// 色を掛けて置く絵。**毎フレーム透明で消す**ので、置いた先で下地が透けて見える。
    private var pad: Canvas?

    /// 混ぜる 2 色。0–255 の数でも持っておき、手本の混ぜ方 (数のまま混ぜる) と並べる。
    private let cool = (red: Float(30), green: Float(60), blue: Float(220))
    private let warm = (red: Float(255), green: Float(210), blue: Float(40))

    /// 読み出す色。作り方がそれぞれ違う。
    private var samples: [(name: String, color: LinearRGBA)] {
        [
            ("hex: 0xFFCC00", color(hex: 0xFF_CC00)),
            // 上位バイトは落ちる — 手本の習慣で不透明度を付けても同じ色
            ("hex: 0xFFFFCC00", color(hex: 0xFFFF_CC00)),
            ("hue: 200", color(hue: 200, saturation: 70, brightness: 90)),
            ("gray: 128", color(128)),
            // 線形の 0.5 は「光の量が半分」で、画面の中くらいの灰色 (128) より明るい
            ("linear 0.5", LinearRGBA(straightRed: 0.5, green: 0.5, blue: 0.5)),
            // 乗算していない成分と不透明度から作る。成分は作業空間 (Display P3) の値なので、
            // sRGB の目盛りで読むと 255 を超える — 読み出しは丸めない
            ("alpha: 0.5", LinearRGBA(straightRed: 0.9, green: 0.25, blue: 0.05, alpha: 0.5)),
            // 不透明度が 0 の色は、どの成分も 0 と読める
            ("transparent", .transparent),
        ]
    }

    func setup() {
        pad = try? createGraphics(120, 120)
    }

    func draw() {
        // 灰色 1 値の下地
        background(20)
        textSize(13)

        // 上段 — 色相・彩度・明度で作る。**色相は巻き戻る**ので時刻をそのまま足す
        noStroke()
        fill(170)
        text("color(hue:saturation:brightness:)", 40, 36)
        for index in 0..<14 {
            fill(color(hue: Float(index) * 26 + time * 40, saturation: 80, brightness: 95))
            rect(40 + index * 63, 48, 56, 48)
        }

        // 灰色の段。塗りも線も 1 値で書ける
        fill(170)
        text("fill(gray) / stroke(gray)", 40, 124)
        stroke(110)
        strokeWeight(2)
        for index in 0..<11 {
            fill(Float(index) * 25.5)
            rect(40 + index * 38, 134, 34, 30)
        }

        // 灰色の段の右 — 2 色の間を取る。上は線形の光の量で、下は 0–255 の数のまま混ぜる
        noStroke()
        fill(170)
        text("lerpColor (top) / lerp of 0-255 values (bottom)", 506, 124)
        let from = color(cool.red, cool.green, cool.blue)
        let to = color(warm.red, warm.green, warm.blue)
        for index in 0..<11 {
            let amount = Float(index) / 10
            let x = 506 + index * 38
            fill(lerpColor(from, to, amount))
            rect(x, 134, 34, 15)
            fill(
                lerp(cool.red, warm.red, amount), lerp(cool.green, warm.green, amount),
                lerp(cool.blue, warm.blue, amount))
            rect(x, 149, 34, 15)
        }

        // 中段 — 読み出し。**不透明度が見えるよう、明暗 2 段の下敷きに置く**
        noStroke()
        fill(170)
        text("red / green / blue / alpha / hue / saturation / brightness", 40, 200)
        for (index, sample) in samples.enumerated() {
            let x = 40 + index * 128
            fill(64)
            rect(x, 212, 72, 32)
            fill(200)
            rect(x, 244, 72, 32)
            fill(sample.color)
            rect(x + 12, 220, 48, 48)

            fill(210)
            text(sample.name, x, 296)
            fill(150)
            for (line, reading) in readings(of: sample.color).enumerated() {
                text(reading, x, 314 + line * 17)
            }
        }

        // 下段左 — 絵に色を掛ける。灰色 1 値と、線形の 0…1 で作った色
        fill(170)
        text("tint(gray) / tint(LinearRGBA)", 40, 388)
        fill(46)
        rect(40, 400, 440, 60)
        if let pad {
            pad.beginDraw()
            pad.background(.transparent)
            pad.noStroke()
            for index in 0..<8 {
                let around = Float(index) / 8 * 2 * .pi + time
                pad.fill(color(hue: Float(index) * 45, saturation: 75, brightness: 100))
                pad.circle(60 + cos(around) * 36, 60 + sin(around) * 36, 34)
            }
            pad.endDraw()

            image(pad, 40, 400)
            tint(120)
            image(pad, 200, 400)
            tint(LinearRGBA(straightRed: 0.2, green: 0.55, blue: 1))
            image(pad, 360, 400)
            noTint()
        }

        // 下段右 — 光の色を数値で渡す。**目盛りは塗りと同じ 0–255**
        fill(170)
        text("ambientLight(gray) / directionalLight / pointLight / spotLight", 540, 388)
        let lit: [(name: String, place: (ColorAndScale, Float, Float) -> Void)] = [
            ("ambient 96", { sketch, _, _ in sketch.ambientLight(96) }),
            ("directional", { sketch, _, _ in
                sketch.ambientLight(56)
                sketch.directionalLight(255, 236, 200, -0.5, 0.7, -0.5)
            }),
            ("point", { sketch, x, y in
                sketch.ambientLight(56)
                sketch.pointLight(90, 150, 255, x - 60, y - 60, 90)
            }),
            ("spot", { sketch, x, y in
                sketch.ambientLight(56)
                sketch.spotLight(255, 90, 100, x, y - 150, 150, 0, 1, -1, angle: 0.22)
            }),
        ]
        // **平行投影で写す。** 既定の透視投影では、面の中心から離れた球ほど横へ引き伸ばされる
        ortho()
        textAlign(.center)
        for (index, entry) in lit.enumerated() {
            let x = Float(590 + index * 104)
            let y: Float = 452
            // **1 つずつ光を置き直す。** 取り除くと列が閉じるので、先の球は先の光のまま残る
            noLights()
            entry.place(self, x, y)
            fill(230)
            push()
            translate(x, y, 0)
            sphere(40)
            pop()
            fill(150)
            text(entry.name, x, 516)
        }
        textAlign(.left)
        noLights()
    }

    /// 読み出した成分を文字にする。0–255 と 360 / 100 / 100 の目盛りのまま、丸めて出す。
    private func readings(of sample: LinearRGBA) -> [String] {
        func rounded(_ value: Float) -> Int { Int(value.rounded()) }
        return [
            "rgb \(rounded(red(sample))) \(rounded(green(sample))) \(rounded(blue(sample)))",
            "a \(rounded(alpha(sample)))",
            "hsb \(rounded(hue(sample))) \(rounded(saturation(sample))) \(rounded(brightness(sample)))",
        ]
    }
}
