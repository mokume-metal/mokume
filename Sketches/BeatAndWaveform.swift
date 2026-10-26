// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 低音で円が脈打ち、拍ごとに背景が光り、下に波形が流れる。
///
/// 音を読む 3 つの口を 1 本で使う。円の大きさは `energy(from: 20, to: 140)` (20〜140 Hz の帯域の大きさ。
/// 帯域の番号を自分で割り出さない)、背景は `isBeat` (そのフレームの区間に拍があったか) で光らせて 0.9 倍ずつ
/// 戻し、下の線は `waveform` (区間の終わりの 1024 標本) である。
///
/// 音は `setup()` で合成した 4 秒の標本列を `createAudioIn(samples:)` で流している。拍は標本を hop ごとの
/// 固定のブロックで順に見て決めるので、**書き出すたびに、fps を変えても、同じ標本の位置で光る**
/// ([ADR-0042] 決定 6 の改訂)。マイクで動かすなら、作る 1 行を `createAudioIn()` に替えるだけでよい。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
final class BeatAndWaveform: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "beat and waveform")
    }

    /// 1 秒あたりの標本の数。
    private static let rate: Float = 48_000

    private var song: AudioIn?
    /// 拍で 1 に戻り、フレームごとに 0.9 倍ずつ消える光。
    private var flash: Float = 0

    func setup() {
        song = try? createAudioIn(samples: Self.pattern(), sampleRate: Self.rate)
    }

    func draw() {
        guard let song else { return }
        if song.isBeat { flash = 1 }
        flash *= 0.9
        background(30 + flash * 200, 30, 40)

        // 低音の脈動: 円の大きさ
        noStroke()
        fill(232, 170, 92)
        circle(width / 2, height * 0.4, 100 + song.energy(from: 20, to: 140) * 300)

        // 下に波形が流れる
        noFill()
        stroke(255)
        beginShape()
        for (index, sample) in song.waveform.enumerated() {
            vertex(Float(index) / 1024 * width, height * 0.8 + sample * 100)
        }
        endShape()
    }

    /// 4 秒の合成した音。0.5 秒ごとの低い拍 (55 Hz の正弦波を減衰させたもの) と、拍の間の小さな高い刻み。
    private static func pattern() -> [Float] {
        var state: UInt32 = 20_261_025
        return (0..<Int(rate * 4)).map { index in
            let t = Float(index) / rate
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let fade = 1 - beat / 0.5
            let kick = sin(2 * .pi * 55 * beat) * fade * fade * fade * fade * 0.8
            // 拍と拍の真ん中に、10 ms の雑音の刻み
            let tick: Float = (beat > 0.25 && beat < 0.26) ? 1 : 0
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = Float(Int32(bitPattern: state)) / Float(Int32.max)
            return kick + noise * tick * 0.05
        }
    }
}
