// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 模様の断片を、テクスチャのように形へ当てる。**絵は 1 枚も貼っていない。**
///
/// 同心円の断片は `in.uv` だけを見て描く。`texture()` で絵を貼っていなくても、断片を当てた形には
/// 形の中の位置が届く — 平面の図形は囲みの箱の 0…1、立体はメッシュの位置 (箱は面ごと・球は経緯)
/// ([#3797](https://github.com/mokume-metal/mokume/issues/3797))。だから同心円の中心は形の中心に留まり、
/// 形が動いても回っても付いてくる。
///
/// 上の段は平面の図形 (円・角丸の四角・楕円・三角形)、下の段は立体 (箱・球・円柱・輪)。左の円だけは
/// 既定の線を引いたままにしてある — 線は模様を読まず、塗りだけが模様になる。
final class PatternAndShape: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "pattern and shape")
    }

    /// 同心円。**`in.uv` から作るので、形の中に収まる。** 輪は時間で外へ流れる。
    private var rings: Shader?

    func setup() throws {
        rings = try createShader(
            """
            float4 paint(Fragment in, Values values) {
                float2 p = (in.uv - 0.5) * 2.0;
                float ring = step(0.5, fract(length(p) * 3.0 - in.time * 0.5));
                float3 tint = mix(values.base.rgb, values.mark.rgb, ring);
                return float4(tint * in.color.rgb, in.color.a);
            }
            """,
            values: [
                "base": .color(color(242, 115, 64)),
                "mark": .color(color(64, 52, 92)),
            ])
    }

    func draw() {
        background(23, 26, 31)
        fill(255)
        guard let rings else { return }
        shader(rings)

        // 上の段: 平面の図形。円は横へ揺れ、四角と三角形は回る
        stroke(250, 236, 214)
        strokeWeight(3)
        circle(150 + sin(time * 1.3) * 40, 150, 150)
        noStroke()
        push {
            translate(390, 150)
            rotate(time * 0.6)
            rect(-80, -55, 160, 110, 18)
        }
        ellipse(620, 150, 170, 110)
        push {
            translate(830, 160)
            rotate(-time * 0.8)
            triangle(-75, 60, 0, -75, 75, 60)
        }

        // 下の段: 立体。それぞれ回る
        for (index, x) in [Float(150), 390, 620, 830].enumerated() {
            push {
                translate(x, 390, 0)
                rotateX(0.5 + time * 0.4)
                rotateY(0.6 + time * 0.5 + Float(index))
                switch index {
                case 0: box(110)
                case 1: sphere(72)
                case 2: cylinder(55, 120)
                default: torus(58, 22)
                }
            }
        }
        resetShader()
    }
}
