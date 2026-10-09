// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeAudio

/// 正弦波を合成する。`band` 番目の帯域の真ん中に来る周波数で、振幅は `amplitude`。
func sine(band: Int, amplitude: Float = 1, count: Int = AudioAnalysis.windowSize) -> [Float] {
    (0..<count).map { index in
        amplitude * sin(2 * .pi * Float(band) * Float(index) / Float(AudioAnalysis.windowSize))
    }
}

/// 音の解析 (ADR-0042 決定 6・#1978)。純粋な関数なので、機材も GPU も要らない。
@Suite("音の解析")
struct AudioAnalysisTests {
    @Test("全振幅の正弦波は、RMS が約 0.707、-3 dBFS、帯域の大きさが 1")
    func fullScaleSine() {
        let levels = AudioAnalysis.analyze(sine(band: 32))
        #expect(abs(levels.rms - Float(0.5).squareRoot()) < 1e-3)
        #expect(abs(levels.decibels - -3.0103) < 1e-2)
        #expect(abs(levels.level - (60 - 3.0103) / 60) < 1e-3)
        #expect(abs(levels.spectrum[32] - 1) < 1e-3)
        #expect(abs(levels.spectrumLevels[32] - 1) < 1e-3)
    }

    @Test("いちばん大きい帯域は、合成した周波数の帯域になる")
    func peakIsAtTheSynthesizedBand() {
        for band in [5, 100, 400] {
            let spectrum = AudioAnalysis.analyze(sine(band: band, amplitude: 0.25)).spectrum
            let peak = spectrum.indices.max { spectrum[$0] < spectrum[$1] }
            #expect(peak == band)
            #expect(abs(spectrum[band] - 0.25) < 1e-3)
        }
    }

    @Test("無音は -160 dB で、0〜1 の値はすべて 0 (∞ や NaN を出さない)")
    func silenceIsFloored() {
        let levels = AudioAnalysis.analyze(Array(repeating: 0, count: AudioAnalysis.windowSize))
        #expect(levels == .silence)
        #expect(levels.decibels == -160)
        #expect(levels.spectrum.count == 512)
    }

    @Test("dB は -60 で 0、0 で 1 へ線形に写り、外は丸める")
    func levelMapping() {
        #expect(AudioAnalysis.level(0) == 1)
        #expect(AudioAnalysis.level(-60) == 0)
        #expect(AudioAnalysis.level(-30) == 0.5)
        #expect(AudioAnalysis.level(-80) == 0)
        #expect(AudioAnalysis.level(6) == 1)
        #expect(AudioAnalysis.decibels(1) == 0)
        #expect(AudioAnalysis.decibels(0) == -160)
    }

    @Test("生の値は 0〜1 に飽和しない — 振幅を半分にすると RMS も半分になる")
    func rawValuesAreNotSaturated() {
        let loud = AudioAnalysis.analyze(sine(band: 10)).rms
        let half = AudioAnalysis.analyze(sine(band: 10, amplitude: 0.5)).rms
        #expect(abs(half / loud - 0.5) < 1e-3)
    }

    @Test("短い窓は前を 0 で埋め、長い窓は最後の 1024 を使う")
    func windowLength() {
        let short = Array(sine(band: 8).suffix(100))
        let padded = Array(repeating: Float(0), count: AudioAnalysis.windowSize - 100) + short
        #expect(AudioAnalysis.analyze(short) == AudioAnalysis.analyze(padded))
        let long = Array(repeating: Float(0.9), count: 500) + sine(band: 8)
        #expect(AudioAnalysis.analyze(long) == AudioAnalysis.analyze(sine(band: 8)))
    }

    // MARK: - 時刻の窓

    @Test("窓は時刻で終わる。始まりより前は 0、終わりより後は始まりへ戻る")
    func windowEndsAtTime() {
        // 標本 i の値は i + 1 (0 の埋めと見分けるため)
        let samples = (1...2000).map(Float.init)
        // 1 秒 = 1000 標本。0.5 秒で終わる窓は、最初の 500 標本が後ろに並び、前は 0
        let early = AudioAnalysis.window(of: samples, sampleRate: 1000, endingAt: 0.5)
        #expect(early.count == AudioAnalysis.windowSize)
        #expect(early.last == 500)
        #expect(early[AudioAnalysis.windowSize - 500] == 1)
        #expect(early[AudioAnalysis.windowSize - 501] == 0)
        // 2.5 秒は 2500 標本目まで。2000 を越えた分は始まりへ戻る
        let wrapped = AudioAnalysis.window(of: samples, sampleRate: 1000, endingAt: 2.5)
        #expect(wrapped.last == 500)
        #expect(wrapped[AudioAnalysis.windowSize - 500] == 1)
        #expect(wrapped[AudioAnalysis.windowSize - 501] == 2000)
    }

    /// **標本の間に落ちる時刻は、その時刻までに届いた標本で切る** (切り捨て)。上の検査は
    /// 積が整数になる時刻しか使わないので、丸めの向きはここで固める。AudioIn と SoundFile の
    /// 検査は期待値をこの関数で作るので、向きを取り違えても両辺が揃って動き、気付けない
    /// (#2283)。
    @Test("標本の間に落ちる時刻は、そこまでに届いた標本で終わる")
    func fractionalTimesEndAtTheLastArrivedSample() {
        let samples = (1...2000).map(Float.init)
        // 500.4 標本ぶん: 500 標本目までが届いている
        #expect(AudioAnalysis.window(of: samples, sampleRate: 1000, endingAt: 0.5004).last == 500)
        // 499.6 標本ぶん: 500 標本目はまだ届いていない
        #expect(AudioAnalysis.window(of: samples, sampleRate: 1000, endingAt: 0.4996).last == 499)
    }
}
