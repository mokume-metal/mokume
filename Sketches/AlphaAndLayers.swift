// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 通常合成の透明な中間面を、同じ順で直接描いた絵と比べる。
///
/// 3組の背景は市松・黒・白。各組の左が直接、右が透明な createGraphics 経由。
/// 解像度・座標・順序・blendMode は同じで、効果・拡大縮小・面全体への追加alphaは無い。
/// 橙の円(A)と青の矩形(B)は順を逆にすれば色が変わる。同じ順の左右では、
/// 中間面だけに暗い縁や二重の薄まり、透明部の黒が出ないかを見る。
/// multiply 等の背景依存の合成に、この比較条件をそのまま広げない。
///
/// 下段は半透明線の接続部・自己交差・別々の線。接続部は一度の合成、線に沿って離れた
/// 部分の自己交差と別々の線の交差は重なるのが現行の約束 (#2209)。3D の並び替えは扱わない。
final class AlphaAndLayers: Sketch {
    private var pad: Canvas?
    private var feather: Image?
    private let wide = 170
    private let tall = 76

    var settings: SketchSettings {
        SketchSettings(width: 1200, height: 1060, title: "alpha and layers")
    }

    func setup() throws {
        pad = try createGraphics(wide, tall)
        let image = try createImage(32, 32)
        for y in 0..<32 {
            for x in 0..<32 {
                let radius = sqrt(pow(Float(x) - 15.5, 2) + pow(Float(y) - 15.5, 2))
                // LinearRGBA の非乗算色を渡す。Image が内部の形式へ変換する。
                image.set(x, y, .display(red: 1, green: 0.65, blue: 0.15,
                                        alpha: constrain((16 - radius) / 6, 0, 1)))
            }
        }
        feather = image
    }

    func draw() {
        background(35)
        noStroke()
        fill(235)
        textSize(16)
        text("blend | same resolution / order | no effects / no group alpha", 20, 25)
        for (backgroundIndex, label) in ["checker", "black", "white"].enumerated() {
            let left = Float(backgroundIndex * 400)
            fill(235)
            text(label, left + 20, 55)
            text("direct", left + 20, 80)
            text("transparent graphics", left + 210, 80)
            for (level, alpha) in [Float(0), 0.25, 0.5, 1].enumerated() {
                for reverse in 0..<2 {
                    let top = Float(100 + (level * 2 + reverse) * 100)
                    fill(235)
                    text("alpha \(alpha) | \(reverse == 0 ? "A > B" : "B > A")", left + 20, top + 12)
                    for column in 0..<2 {
                        push()
                        translate(left + (column == 0 ? 20 : 210), top + 18)
                        backing(backgroundIndex)
                        if column == 0 {
                            content(alpha, reverse: reverse == 1)
                        } else if let pad {
                            draw(into: pad) {
                                background(0, 0)
                                content(alpha, reverse: reverse == 1)
                            }
                            noTint()
                            image(pad, 0, 0)
                        }
                        pop()
                    }
                }
            }
        }
        joins()
    }

    private func backing(_ kind: Int) {
        noStroke()
        for y in stride(from: 0, to: tall, by: 16) {
            for x in stride(from: 0, to: wide, by: 16) {
                let gray = kind == 1 ? 0 : kind == 2 ? 255 : ((x / 16 + y / 16) % 2 == 0 ? 80 : 160)
                fill(gray)
                rect(x, y, min(16, wide - x), min(16, tall - y))
            }
        }
    }

    private func content(_ alpha: Float, reverse: Bool) {
        blendMode(.blend)
        noStroke()
        for item in reverse ? [1, 0] : [0, 1] {
            if item == 0 {
                fill(255, 128, 40, alpha * 255)
                circle(48, 31, 54)
            } else {
                fill(45, 150, 255, alpha * 255)
                rect(50, 14, 64, 42)
            }
        }
        if let feather {
            tint(255, alpha * 255)
            image(feather, 128, 8)
            noTint()
        }
        fill(255, 255, 255, alpha * 255)
        textSize(14)
        text("Aa / alpha", 20, 70)
    }

    private func joins() {
        noStroke()
        fill(230)
        textSize(16)
        text("stroke alpha 0.5: connected join (once)", 20, 940)
        text("self crossing (overlap)", 430, 940)
        text("separate lines (overlap)", 820, 940)
        noFill()
        stroke(255, 128, 40, 127.5)
        strokeWeight(14)
        strokeJoin(.round)
        beginShape()
        vertex(60, 1025)
        vertex(140, 970)
        vertex(220, 1025)
        endShape()
        beginShape()
        vertex(450, 975)
        vertex(580, 1025)
        vertex(450, 1025)
        vertex(580, 975)
        endShape()
        line(850, 975, 980, 1025)
        line(850, 1025, 980, 975)
    }
}
