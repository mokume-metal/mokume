// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeAudio

/// `BrownNoise` (#3718)。持ち主のいないステージを固定の時計 (60 fps) で回すので、GPU も音の機材も要らない。
@Suite("合成した音: ブラウンノイズ", .serialized)
struct BrownNoiseTests {
    /// 持ち主のいないステージを固定の時計 (60 fps) で回す。
    private func makeStage(_ notices: NoticeLog = NoticeLog()) -> SynthStage {
        let stage = SynthStage(owner: nil, flow: nil, now: { 0 }, warn: { notices.append($0) })
        stage.pace = .frames(perSecond: 60, origin: 0)
        return stage
    }

    /// 帯域ごとの値を、`frames` フレームぶん平均する。
    private struct Averaged {
        var spectrum = [Float](repeating: 0, count: 512)
        var spectrumLevels = [Float](repeating: 0, count: 512)

        func mean(_ values: [Float], _ bands: ClosedRange<Int>) -> Float {
            values[bands].reduce(0, +) / Float(bands.count)
        }
    }

    /// 白・ピンク・ブラウンを同じ音量で鳴らし、2 フレーム目から `frames` フレームぶんの帯域の値を平均する。
    private func heard(frames: Int = 60) -> [String: Averaged] {
        let stage = makeStage()
        let sounds: [(String, Noise)] = [
            ("white", WhiteNoise(stage: stage)), ("pink", PinkNoise(stage: stage)),
            ("brown", BrownNoise(stage: stage)),
        ]
        for (_, sound) in sounds { sound.play(0.5) }
        var result: [String: Averaged] = [:]
        for frame in 0...frames {
            stage.frame = frame
            stage.supply()
            guard frame > 1 else { continue }
            for (name, sound) in sounds {
                var entry = result[name] ?? Averaged()
                for band in 0..<512 {
                    entry.spectrum[band] += sound.spectrum[band] / Float(frames - 1)
                    entry.spectrumLevels[band] += sound.spectrumLevels[band] / Float(frames - 1)
                }
                result[name] = entry
            }
        }
        stage.close()
        return result
    }

    @Test("低い帯域 (1〜8) が高い帯域 (256 以降) よりはるかに強く、その差はピンクノイズより大きい")
    func brownLeansLowerThanPink() throws {
        let averaged = heard()
        let brown = try #require(averaged["brown"])
        let pink = try #require(averaged["pink"])
        let white = try #require(averaged["white"])
        let low = 1...8
        let high = 256...511
        // 0〜1 へ写した値で、低域の平均が高域の平均より十分大きい
        let brownLow = brown.mean(brown.spectrumLevels, low)
        let brownHigh = brown.mean(brown.spectrumLevels, high)
        #expect(brownLow - brownHigh > 0.4, "低域 \(brownLow)・高域 \(brownHigh)")
        // 振幅の比で、ブラウンの傾きはピンクより急で、ピンクは白より急
        let ratio = { (sound: Averaged) in sound.mean(sound.spectrum, low) / sound.mean(sound.spectrum, high) }
        #expect(ratio(brown) > ratio(pink) * 4, "brown \(ratio(brown))・pink \(ratio(pink))")
        #expect(ratio(pink) > ratio(white) * 2, "pink \(ratio(pink))・white \(ratio(white))")
    }

    @Test("同じ順に作れば、何度鳴らしても同じ標本になる")
    func brownIsRepeatable() {
        func take() -> [Float] {
            let stage = makeStage()
            let noise = BrownNoise(stage: stage)
            noise.play(0.3)
            var samples: [Float] = []
            for frame in 0..<10 {
                stage.frame = frame
                stage.supply()
                samples += noise.waveform
            }
            stage.close()
            return samples
        }
        let first = take()
        #expect(first == take())
        #expect(first.contains { $0 != 0 }, "鳴っていない")
        // 音量 0.3 の範囲に収まる
        #expect(first.allSatisfy { abs($0) <= 0.3 })
    }

    @Test("amp・pan・play・set・stop は Noise と同じに効き、範囲の外は丸めて 1 度だけ知らせる")
    func brownTakesTheNoiseCalls() {
        let notices = NoticeLog()
        let stage = makeStage(notices)
        let noise = BrownNoise(stage: stage)
        noise.set(0.2, 0, -1)
        #expect(!noise.isPlaying)
        noise.play(0.3, 0, 0.5)
        #expect(noise.isPlaying)
        noise.amp(2)
        noise.amp(3)
        noise.pan(.nan)
        #expect(notices.lines.count == 2, "\(notices.lines)")
        #expect(notices.lines.allSatisfy { $0.contains("BrownNoise") })
        var peaks: [Float] = []
        for frame in 0..<8 {
            stage.frame = frame
            stage.supply()
            peaks.append(noise.peak)
        }
        #expect(peaks.last ?? 0 > 0.3, "音量 1 へ丸めて鳴っている: \(peaks)")
        noise.stop()
        #expect(!noise.isPlaying)
        for frame in 8..<16 {
            stage.frame = frame
            stage.supply()
        }
        #expect(noise.peak == 0)
        stage.close()
    }
}
