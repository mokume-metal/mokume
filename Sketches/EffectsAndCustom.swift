// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 描き終えた絵に効果を掛ける。**組み込みの効果と自分で書いた効果を、同じ並びに入れる。**
///
/// **見どころは、6 枚が同じ 1 枚の描き場所から出ていること。** 効果は掛けた面の全体に
/// 掛かるので、画面へ掛けると違いを並べて読めない。そこで描き場所を 1 枚だけ作り、
/// 毎フレーム **6 回描き直して、そのたびに違う並びを掛けて置く** — 先に置いた絵は
/// 描き直しに引きずられないので、同じ場面に掛けた 6 つの効果が 1 枚の中で比べられる。
///
/// 左上から そのまま・ぼかし・反転・色抜き・明るさと対比と彩度・**自作のモザイク**。
/// 自作の効果は ``Sketch/makeEffect(_:name:values:)`` で書いた 1 本の断片で、組み込みと
/// 同じ ``Effect/custom(_:)`` の枠として並びへ入る。
///
/// 場面には効果ごとに崩れ方の違うものを並べてある — 細い格子はぼかしで消え、色の輪は
/// 色抜きで濃淡だけになり、白い芯と黒い点は反転で入れ替わる。時計はフレーム番号から
/// 導くので、**同じ番号のフレームは何度描いても同じ絵**になる。
final class EffectsAndCustom: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "effects and custom")

    /// 1 枚ぶんの大きさ。**6 枚とも同じ描き場所から出る**ので、寸法も 1 つ。
    private static let panel = (width: 288, height: 200)

    /// 描き直して使い回す 1 枚。
    private var stage: Canvas?
    /// 自分で書いた効果。格子の升ごとに真ん中の色で塗りつぶす。
    private var mosaic: EffectShader?

    func setup() {
        stage = try? createGraphics(Self.panel.width, Self.panel.height)

        // **書くのは `effect` 1 本だけ。** 前置きは自動で足され、`mokume_at` で
        // 入りの絵のほかの場所を読める。組み込みの効果も同じ規約で書いてある
        mosaic = try? makeEffect(
            """
            float4 effect(Pixel in, Values values) {
                // 升の大きさを 0…1 の位置へ直す。升の真ん中の色を読む
                float2 cell = values.cell / in.size;
                float2 centre = (floor(in.place / cell) + 0.5) * cell;
                float4 tint = mokume_at(in, centre);
                // 升の縁を少し落とす。**色を読む位置が升ごとに 1 つ**なのが、縁で分かる
                float2 inside = fract(in.place / cell);
                float seam = step(0.1, inside.x) * step(0.1, inside.y);
                return float4(tint.rgb * mix(0.55, 1.0, seam), tint.a);
            }
            """,
            name: "mosaic", values: ["cell": 12])
    }

    /// 6 枚に掛ける並び。**並びは値**なので、組み込みも自作も同じ形で書ける。
    private var looks: [(caption: String, effects: [Effect])] {
        var looks: [(caption: String, effects: [Effect])] = [
            ("そのまま", []),
            (".blur(radius: 6)", [.blur(radius: 6)]),
            (".invert()", [.invert()]),
            (".monochrome()", [.monochrome()]),
            (
                ".adjust(明るさ・対比・彩度)",
                [.adjust(brightness: 0.12, contrast: 0.6, saturation: 0.8)]
            ),
        ]
        if let mosaic { looks.append((".custom(モザイク)", [.custom(mosaic)])) }
        return looks
    }

    func draw() {
        guard let stage else { return }
        background(8, 10, 16)

        let gap = (x: Float(24), y: Float(60))
        textFont("Helvetica")
        textSize(16)
        textAlign(.center)
        for (index, look) in looks.enumerated() {
            let column = Float(index % 3)
            let row = Float(index / 3)
            let x = gap.x + column * (Float(Self.panel.width) + gap.x)
            let y = 24 + row * (Float(Self.panel.height) + gap.y)

            // **描き直すたびに並びを決め直す。** 効果はフレームを越えないので、
            // `beginDraw()` のたびに空へ戻る — 前の 1 枚に掛けた並びは残らない
            stage.beginDraw()
            paintScene(on: stage)
            stage.effects(look.effects)
            stage.endDraw()
            image(stage, x, y)

            fill(220, 226, 236)
            text(look.caption, x + Float(Self.panel.width) / 2, y + Float(Self.panel.height) + 24)
        }
    }

    /// 6 枚に共通の場面。**効果ごとに崩れるものを 1 つずつ置く。**
    private func paintScene(on canvas: Canvas) {
        let centre = (x: Float(Self.panel.width) / 2, y: Float(Self.panel.height) / 2)
        canvas.background(16, 22, 38)

        // 細い格子。**ぼかしがまず消すもの**で、モザイクでは升と干渉する
        canvas.stroke(255, 255, 255, 70)
        canvas.strokeWeight(1)
        for step in stride(from: 12, to: Self.panel.width, by: 24) {
            canvas.line(Float(step), 0, Float(step), Float(Self.panel.height))
        }
        for step in stride(from: 12, to: Self.panel.height, by: 24) {
            canvas.line(0, Float(step), Float(Self.panel.width), Float(step))
        }

        // 色の輪。**色抜きで濃淡だけになり、彩度で濃くなる**。回るので連番で動きが読める
        canvas.noStroke()
        for index in 0..<10 {
            let angle = Float(index) / 10 * 2 * Float.pi + time * 0.6
            canvas.fill(
                .display(
                    red: 0.5 + 0.45 * cos(angle),
                    green: 0.5 + 0.45 * cos(angle - 2.094),
                    blue: 0.5 + 0.45 * cos(angle + 2.094)))
            canvas.circle(centre.x + cos(angle) * 64, centre.y + sin(angle) * 64, 34)
        }

        // 白い芯と黒い点。**反転で明暗が入れ替わる**のがいちばん読める組み合わせ
        canvas.fill(250, 250, 245)
        canvas.circle(centre.x, centre.y, 44)
        canvas.fill(18, 18, 20)
        canvas.circle(centre.x, centre.y, 14)
    }
}
