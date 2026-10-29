// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 前のフレームの絵を断片から読んで、残像とフィードバックを書く。
///
/// **前の絵を、描き場所 2 枚の入れ替えなしで読める。** 断片の面に `.previousFrame` を渡すと、
/// その面が次のフレームへ持ち越す絵 (フレームの終わりの `effects()` を通す前の絵) が読める
/// ([#2456](https://github.com/mokume-metal/mokume/issues/2456))。
///
/// 左の絵は、**前の絵を少し回して、中心へ 2% 寄せて、4% 薄めて読む**もの。円は毎フレーム新しい位置に
/// 描き足すだけで、通った跡が渦を巻いて中心へ吸い込まれ、色が抜けていく。`background()` で先に消しても、
/// 前の絵は消す前のものが読める。
///
/// 右の絵は、**同じ断片に `effects([.invert()])` を足したもの**。画面に出る絵は反転しているが、次のフレームが
/// 読むのは反転する前の絵なので、跡の向きも濃さも左と同じに進む (反転を 2 度掛けしない)。
///
/// 確認: `--render /tmp/mokume-frames --frames 150` のこの例の連番を 60 fps で見る。左右とも円が楕円の軌道を
/// 回り、跡が渦を巻いて消える。右は白地に黒い跡で、左の色を反転した絵になる。最初のフレームは前の絵が透明なので、
/// 跡は無い。
final class EchoAndFeedback: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "echo and feedback")
    }

    private var echo: Shader?
    private var inverted: Canvas?
    private var plain: Canvas?

    /// 面の大きさ。2 枚を横に並べる。
    private static let panel = (width: 470, height: 500)

    func setup() throws {
        // **前の絵は、面ごとに決まる。** 同じ断片を 2 枚の描き場所へ当てても、それぞれの前の絵を読む
        echo = try createShader(
            """
            float4 paint(Fragment in, Values values, Surfaces surfaces) {
                float2 p = in.place - 0.5;
                float a = values.turn;
                p = float2x2(cos(a), -sin(a), sin(a), cos(a)) * p * values.shrink + 0.5;
                return mokume_sample(surfaces.last, p) * values.fade;
            }
            """,
            name: "echo",
            values: ["turn": 0.02, "shrink": 0.98, "fade": 0.96],
            surfaces: ["last": .previousFrame])
        plain = try createGraphics(Self.panel.width, Self.panel.height)
        inverted = try createGraphics(Self.panel.width, Self.panel.height)
    }

    func draw() {
        background(24, 26, 30)
        guard let echo, let plain, let inverted else { return }

        let angle = time * 2.1
        let hue = 0.5 + 0.5 * sin(time * 1.3)

        draw(into: plain) {
            feedback(echo, angle: angle, hue: hue)
        }
        draw(into: inverted) {
            feedback(echo, angle: angle, hue: hue)
            effects([.invert()])
        }
        image(plain, 5, 20)
        image(inverted, 485, 20)
    }

    /// 前の絵を読み直して描き、その上に円を 1 つ足す。**描き場所の中身は、毎フレーム消してから作り直す。**
    private func feedback(_ echo: Shader, angle: Float, hue: Float) {
        let w = Float(Self.panel.width)
        let h = Float(Self.panel.height)
        background(0)
        noStroke()
        shader(echo)
        rect(0, 0, w, h)
        resetShader()
        fill(255, 120 + 100 * hue, 60 + 150 * (1 - hue))
        circle(w * 0.5 + w * 0.34 * cos(angle), h * 0.5 + h * 0.34 * sin(angle * 1.3), 26)
    }
}
