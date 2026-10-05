// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 音を鳴らさずに解析して、大きさと帯域を描く。
///
/// **見どころは、左の 2 本の目盛りの差。** 左の目盛りは生の `rms` (振幅のまま) で、
/// 右の目盛りは同じ音を dB で 0〜1 に写した `level` である。生の振幅は普通の音量では
/// 小さいところに留まり、全振幅の正弦波でも 0.707 までしか届かない。`level` は
/// -60〜0 dBFS を目盛りいっぱいに使う。円の大きさは `level` で、右の帯は帯域ごとの
/// `spectrumLevels` である。
///
/// 音はマイクではなく、`setup()` で合成した 2 秒の標本列を `createAudioIn(samples:)` で
/// 流している。**どの窓を解析するかはフレームの時刻だけで決まる**ので、書き出すたびに
/// 同じ絵になる ([ADR-0028] 決定 7)。マイクで動かすなら、作る 1 行を `createAudioIn()` に
/// 替えるだけでよい。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class SoundAndLevel: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "sound and level")

    /// 1 秒あたりの標本の数。
    private static let rate: Float = 48_000
    /// 帯域を何本描くか (1〜64 本目。48 kHz で約 3 kHz まで)。
    private let bands = 64

    private var sound: AudioIn?

    func setup() {
        sound = try? createAudioIn(samples: Self.phrase(), sampleRate: Self.rate)
    }

    func draw() {
        background(18, 18, 24)
        noStroke()
        guard let sound else { return }

        // 左: 円の大きさは 0〜1 へ写した値
        fill(232, 170, 92)
        circle(220, 270, 60 + sound.level * 300)

        // 中: 生の値と、0〜1 へ写した値を同じ高さの目盛りで並べる
        meter(x: 440, value: sound.rms, red: 120, green: 160, blue: 220)
        meter(x: 480, value: sound.level, red: 232, green: 170, blue: 92)

        // 右: 帯域ごとの大きさ (0〜1 へ写した値)。帯域 k の真ん中は k × 48000 ÷ 1024 Hz
        let levels = sound.spectrumLevels
        for band in 1...bands {
            let height = levels[band] * 380
            fill(lerp(120, 232, Float(band) / Float(bands)), 160, lerp(220, 92, Float(band) / Float(bands)))
            rect(540 + Float(band - 1) * 6, 460 - height, 4, height)
        }
    }

    /// 縦の目盛り 1 本。下から `value` (0〜1) の高さまで塗る。
    private func meter(x: Float, value: Float, red: Float, green: Float, blue: Float) {
        fill(40, 40, 48)
        rect(x, 80, 24, 380)
        fill(red, green, blue)
        let height = constrain(value, 0, 1) * 380
        rect(x, 460 - height, 24, height)
    }

    /// 2 秒の合成した音。半秒ごとの低い拍と、2 秒かけてふくらむ倍音の多い和音と、
    /// 1 秒に 3 度揺れる高い音を重ねる。
    private static func phrase() -> [Float] {
        (0..<Int(rate * 2)).map { index in
            let t = Float(index) / rate
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let fade = 1 - beat / 0.5
            let kick = sin(2 * .pi * 55 * beat) * fade * fade * fade * fade * 0.7
            var chord: Float = 0
            for harmonic in 1...8 {
                chord += sin(2 * .pi * 234.375 * Float(harmonic) * t) / Float(harmonic)
            }
            let swell = 0.5 - 0.5 * cos(2 * .pi * t / 2)
            let shimmer = sin(2 * .pi * 2250 * t) * (0.5 + 0.5 * sin(2 * .pi * 3 * t)) * 0.05
            return kick + chord * 0.12 * swell + shimmer
        }
    }
}
