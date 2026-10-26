// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 同じ市松と明るい点へ、効果を単独または両順序で掛ける。
/// 左から無効果/custom/blur/custom→blur/blur→custom。前者は升の縁がぼけ、後者は
/// ぼけた入力を升の色へ取り直すので縁が鋭い。同じ面を5回描き直して置くため、後の
/// 書き換えが先に置いたパネルへ漏れていないことも分かる。
/// `--render /tmp/order --frames 120` は全例の連番を出す。60 fpsで2秒の同じ動きを比較する。
final class OrderAndEffects: Sketch {
    private var pad: Canvas!
    private var mosaic: EffectShader!
    var settings: SketchSettings { SketchSettings(width: 1200, height: 280, title: "order and effects") }

    func setup() throws {
        pad = try createGraphics(220, 180)
        mosaic = try makeEffect("""
            float4 effect(Pixel in, Values values) {
                float2 cells = float2(11.0, 9.0);
                return mokume_at(in, (floor(in.place * cells) + 0.5) / cells);
            }
            """, name: "mosaic")
    }

    func draw() {
        background(18)
        let looks: [(String, [Effect])] = [
            ("none", []), ("custom", [.custom(mosaic)]), ("blur", [.blur(radius: 5)]),
            ("custom > blur", [.custom(mosaic), .blur(radius: 5)]),
            ("blur > custom", [.blur(radius: 5), .custom(mosaic)]),
        ]
        for (index, look) in looks.enumerated() {
            draw(into: pad) {
                background(12)
                noStroke()
                for y in 0..<9 {
                    for x in 0..<11 {
                        fill((x + y) % 2 == 0 ? 35 : 125)
                        rect(x * 20, y * 20, 20, 20)
                    }
                }
                fill(255, 220, 30)
                circle(110 + 55 * sin(time * 2), 90, 26)
                fill(255)
                circle(40, 35, 8)
                effects(look.1)
            }
            image(pad, 10 + index * 240, 20)
            fill(235)
            textSize(16)
            text(look.0, 10 + index * 240, 230)
        }
        text("Same source; effect order is left to right. Later repaint must not replace earlier panels.", 10, 265)
    }
}
