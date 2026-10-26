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

    // MARK: - 標本列の時刻

    @Test("時刻までに届いた標本の数は、標本の間に落ちる時刻を切り捨てる。負の時刻は 0")
    func samplesArrivedByATimeRoundDown() {
        // 1 秒 = 1000 標本
        #expect(RecordedSource.index(at: 0.5, sampleRate: 1000) == 500)
        // 500.4 標本ぶん: 500 標本目までが届いている
        #expect(RecordedSource.index(at: 0.5004, sampleRate: 1000) == 500)
        // 499.6 標本ぶん: 500 標本目はまだ届いていない
        #expect(RecordedSource.index(at: 0.4996, sampleRate: 1000) == 499)
        #expect(RecordedSource.index(at: -1, sampleRate: 1000) == 0)
    }

    // MARK: - 遅らせた解析と、使い回す変換 (#2379)

    /// 解析の入力にする区間。無音・正弦波・インパルス・固定乱数 (種が決まっているので何度作っても同じ)。
    /// 区間の始まりも、窓の格子の境界の上・途中・履歴が標本 0 に届かない所を混ぜる。
    static var probeSpans: [(name: String, span: AudioSpan)] {
        var state: UInt32 = 20_261_022
        let noise = (0..<3000).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: state)) / Float(Int32.max) * 0.5
        }
        var impulse = [Float](repeating: 0, count: 3000)
        impulse[1500] = 1
        return [
            ("無音", span(of: [Float](repeating: 0, count: 3000), from: 700, to: 2900)),
            ("正弦波", span(of: sine(band: 40, amplitude: 0.5, count: 3000), from: 1024, to: 2600)),
            ("インパルス", span(of: impulse, from: 1000, to: 2100)),
            ("固定乱数", span(of: noise, from: 100, to: 2800)),
            ("始まり", span(of: noise, from: 0, to: 800)),
        ]
    }

    @Test("使い回す変換の解析は、毎回作る変換の解析と、区間を替えて繰り返してもビット一致する")
    func sharedTransformMatchesTheFreshOne() {
        let spans = Self.probeSpans.map(\.span)
        for _ in 0..<3 {
            for span in spans {
                #expect(AudioAnalyzer.shared.analyze(span) == AudioAnalysis.analyze(span))
            }
        }
    }

    /// **解析は読まれたときだけ、1 回だけ。区間は置いたときのもの** (``DeferredLevels``)。
    @Test("遅らせた解析は、読まれたときに 1 回だけ、最後に置かれた区間を解く")
    func deferredLevelsSolveOnceOnReadFromTheLatestSpan() {
        var deferred = DeferredLevels()
        let first = Self.probeSpans[1].span
        let second = Self.probeSpans[3].span

        // 読まれる前は何も解かない。区間を置き換えても同じ
        deferred.hold(first)
        deferred.hold(second)
        #expect(deferred.analyses == 0)

        // 読むと最後の区間を解き (毎フレーム解析したのとビット一致)、同じ区間を何度読んでも解析は 1 回
        let solved = deferred.levels()
        #expect(solved == AudioAnalysis.analyze(second))
        #expect(deferred.levels() == solved)
        #expect(deferred.analyses == 1)

        // 次の区間を置いて、読まれなければ解かない
        deferred.hold(first)
        #expect(deferred.analyses == 1)
        #expect(deferred.levels() == AudioAnalysis.analyze(first))
        #expect(deferred.analyses == 2)
    }

    @Test("空の区間は置き換えず、前の値 (解かれていない区間も) をそのまま保つ")
    func emptySpanKeepsThePreviousValue() {
        var deferred = DeferredLevels()
        let loud = Self.probeSpans[1].span
        let empty = AudioSpan(base: 0, samples: Array(repeating: 0, count: 2000), from: 2000)
        #expect(empty.isEmpty)

        // 解かれていない区間は、空の区間を置いても残り、読まれたときに解かれる
        deferred.hold(loud)
        deferred.hold(empty)
        #expect(deferred.levels() == AudioAnalysis.analyze(loud))
        // 解いた後も、空の区間は値を変えない
        deferred.hold(empty)
        #expect(deferred.levels() == AudioAnalysis.analyze(loud))
        #expect(deferred.analyses == 1)
    }

    // MARK: - 作業領域の再利用 (#3086)

    @Test("使い回す作業領域で解析した値は、毎回作る参照の値とビット一致する (前の区間の値を持ち越さない)")
    func reusedScratchMatchesTheReference() {
        let analyzer = AudioAnalyzer()
        // 大きな値の後に無音・インパルスが来ても、前の区間が残らない順で、2 周する
        let probes = Self.probeSpans
        for probe in probes + probes.reversed() + probes {
            let reference = AudioAnalysis.analyze(probe.span)
            let reused = analyzer.analyze(probe.span)
            #expect(reused == reference, "\(probe.name)")
        }
        #expect(analyzer.analyses == 15)
    }

    @Test("保存した前フレームの値は、次の解析で変わらない")
    func savedLevelsAreIndependentOfTheNextAnalysis() {
        let analyzer = AudioAnalyzer()
        let loud = Self.probeSpans[3].span
        let first = analyzer.analyze(loud)
        let saved = first
        let expected = AudioAnalysis.analyze(loud)
        // 別の区間を解析しても、保存した値の配列は書き換わらない
        for probe in Self.probeSpans { _ = analyzer.analyze(probe.span) }
        #expect(first.spectrum == expected.spectrum)
        #expect(first.spectrumLevels == expected.spectrumLevels)
        #expect(saved == expected)
        // 続けて解析した 2 つの値は別の配列になる (片方を書き換えても他方に響かず、どちらも参照の値)
        let tone = Self.probeSpans[1].span
        var second = analyzer.analyze(loud)
        let third = analyzer.analyze(tone)
        #expect(second == expected)
        #expect(third == AudioAnalysis.analyze(tone))
        second.spectrum[0] += 1
        #expect(third == AudioAnalysis.analyze(tone))
        #expect(analyzer.analyze(loud) == expected)
    }

    @Test("無音にすると、置かれていた区間を解かずに捨て、無音を返す")
    func silencingDropsTheHeldSpan() {
        var deferred = DeferredLevels()
        #expect(deferred.levels() == .silence)
        deferred.hold(Self.probeSpans[1].span)
        deferred.silence()
        #expect(deferred.levels() == .silence)
        #expect(deferred.analyses == 0)
    }
}

/// 標本の流れ `sample` (通し番号から標本を返す) の通し番号 `from`..<`to` を、解析する区間にする
/// (供給する側と同じ履歴を添える)。
func span(from: Int, to: Int, sample: (Int) -> Float) -> AudioSpan {
    let first = AudioAnalysis.firstNeeded(from: from)
    return AudioSpan(base: first, samples: (first..<to).map(sample), from: from)
}

/// 標本列 `samples` の通し番号 `from`..<`to` を、解析する区間にする。`loops` なら終わりから頭へ戻って続ける。
func span(of samples: [Float], from: Int, to: Int, loops: Bool = false) -> AudioSpan {
    span(from: from, to: to) { loops ? samples[$0 % samples.count] : samples[$0] }
}
