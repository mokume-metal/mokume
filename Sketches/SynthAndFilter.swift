// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 合成した音を鳴らさずに解析して、波形ごと・エフェクトごとの帯域を並べる。
///
/// **見どころは、同じ周波数の音が、波形とエフェクトで帯域の形を変えること。** 上の段は、同じ
/// 234.375 Hz (帯域 5 の真ん中) の波形で、左から正弦波 (1 本だけ。包絡で下がっていく途中)・
/// 矩形波 (奇数次だけ)・三角波にディレイを掛けた出口 (奇数次で急に細くなり、反響で櫛の形になる)・
/// のこぎり波にリバーブを掛けた出口 (全部の次数が並び、残響で隙間が埋まる)。下の段は、左から
/// 白色雑音そのもの・それを低域通過した音・帯域通過した音・ピンクノイズを高域通過した音である。
///
/// 音は `setup()` で作って鳴らすだけで、毎フレーム呼ぶ口は無い。**どの窓を解析するかはフレームの
/// 番号だけで決まる**ので、書き出すたびに同じ絵になる ([ADR-0028] 決定 7)。窓で動かすなら
/// 実際に鳴り、同じ絵が鳴りながら動く。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class SynthAndFilter: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "synth and filter")

    /// 1 枚のパネルに描く音と色。
    private struct Panel {
        var sound: SynthSound
        var red: Float
        var green: Float
        var blue: Float
    }

    /// 帯域を何本描くか (1〜54 本目。48 kHz で約 2.5 kHz まで)。
    private let bands = 54
    private var panels: [Panel] = []

    func setup() {
        let tone: Float = 234.375

        let sine = createSinOsc()
        let square = createSqrOsc()
        let triangle = createTriOsc()
        let saw = createSawOsc()
        let white = createWhiteNoise()
        let pink = createPinkNoise()
        let env = createEnv()
        let low = createLowPass()
        let high = createHighPass()
        let band = createBandPass()
        let reverb = createReverb()
        let delay = createDelay()

        sine.play(tone, 0.4)
        square.play(tone, 0.25)
        triangle.play(tone, 0.4)
        saw.play(tone, 0.25)
        white.play(0.3)
        pink.play(0.4)

        // 正弦波は 0.01 秒で立ち上がり、0.6 秒保ち、0.3 秒で下がる (45 フレーム目はその途中)
        env.play(sine, 0.01, 0.6, 0.8, 0.3)
        delay.process(triangle, 1, 0.5)
        delay.time(0.1)
        reverb.process(saw, 0.8, 0.4, 0.5)
        low.process(white, 800)
        band.process(white, 2000, 400)
        high.process(pink, 3000)

        panels = [
            Panel(sound: sine, red: 232, green: 170, blue: 92),
            Panel(sound: square, red: 120, green: 160, blue: 220),
            Panel(sound: delay, red: 150, green: 210, blue: 150),
            Panel(sound: reverb, red: 210, green: 140, blue: 200),
            Panel(sound: white, red: 200, green: 200, blue: 210),
            Panel(sound: low, red: 232, green: 120, blue: 100),
            Panel(sound: band, red: 120, green: 210, blue: 210),
            Panel(sound: high, red: 220, green: 200, blue: 110),
        ]
    }

    func draw() {
        background(18, 18, 24)
        noStroke()
        for (index, panel) in panels.enumerated() {
            let column = Float(index % 4)
            let row = Float(index / 4)
            let left = 24 + column * 232
            let bottom = 250 + row * 250
            // 地
            fill(30, 30, 38)
            rect(left, bottom - 220, 216, 220)
            // 帯域ごとの大きさ (0〜1 へ写した値)
            fill(panel.red, panel.green, panel.blue)
            let levels = panel.sound.spectrumLevels
            for band in 1...bands {
                let height = levels[band] * 216
                rect(left + Float(band - 1) * 4, bottom - 2 - height, 3, height)
            }
            // 全体の大きさ (左上の円)
            circle(left + 14, bottom - 206, 4 + panel.sound.level * 16)
        }
    }
}
