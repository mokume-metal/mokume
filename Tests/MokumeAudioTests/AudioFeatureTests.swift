// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// `energy(from:to:)`・`waveform`・`isBeat` (#3137)。**機材も GPU も使わない。**
@Suite("音の解析: 帯域の大きさ・波形・拍")
struct AudioFeatureTests {
    // MARK: - 標本の作り方

    private static let rate = 48_000

    /// 周波数 `frequency` (Hz)・振幅 `amplitude` の正弦波。
    private static func tone(_ frequency: Float, amplitude: Float = 1, count: Int) -> [Float] {
        (0..<count).map { amplitude * sin(2 * .pi * frequency * Float($0) / Float(rate)) }
    }

    /// 無音の上に、`positions` の標本から 10 ms (480 標本)・-6 dBFS のクリックを置いた標本列。
    static func clicks(at positions: [Int], count: Int) -> [Float] {
        var stream = [Float](repeating: 0, count: count)
        for start in positions {
            for offset in 0..<480 where start + offset < count {
                // 1 kHz の余弦。立ち上がりの 1 標本目から 0.5 (-6 dBFS)
                stream[start + offset] = 0.5 * cos(2 * .pi * 1000 * Float(offset) / Float(rate))
            }
        }
        return stream
    }

    /// 種の決まった乱数の標本列 (-0.5〜0.5)。
    private static func noise(count: Int) -> [Float] {
        var state: UInt32 = 3_137_000
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: state)) / Float(Int32.max) * 0.5
        }
    }

    /// `stream` を、`ends` (区間の終わり。昇順) で区切った区間にして順に返す。
    private static func spans(of stream: [Float], endingAt ends: [Int]) -> [AudioSpan] {
        var covered = 0
        return ends.map { end in
            defer { covered = end }
            return span(of: stream, from: covered, to: end)
        }
    }

    /// `fps` の固定の時計のフレームの終わり。
    private static func frameEnds(fps: Int, upTo count: Int) -> [Int] {
        var ends: [Int] = []
        var frame = 1
        while true {
            let end = FrameSamples.start(ofFrame: frame, perSecond: fps, sampleRate: Double(rate))
            if end > count { break }
            ends.append(end)
            frame += 1
        }
        return ends
    }

    // MARK: - energy(from:to:)

    private func spectrumOf(_ stream: [Float], from: Int = 0, to: Int) -> [Float] {
        AudioAnalysis.analyze(span(of: stream, from: from, to: to)).spectrum
    }

    @Test("80 Hz・全振幅の正弦波は、energy(20, 140) が 1 に近い。無音は 0")
    func energyOfALowTone() {
        let spectrum = spectrumOf(Self.tone(80, count: 8000), from: 4000, to: 8000)
        let bass = AudioAnalysis.energy(of: spectrum, from: 20, to: 140, sampleRate: 48_000)
        // 80 Hz は帯域 1 (46.9 Hz) と 2 (93.8 Hz) の間に落ちる。Hann の窓で約 1.4 dB 目減りする
        #expect(bass.isNumber)
        #expect(bass.value > 0.9 && bass.value <= 1, "\(bass.value)")
        // 高い帯域には出ない
        let treble = AudioAnalysis.energy(of: spectrum, from: 4000, to: 8000, sampleRate: 48_000)
        #expect(treble.value == 0)
        // 帯域の真ん中にある全振幅の正弦波は、その帯域だけを見れば 1
        let centered = spectrumOf(Self.tone(46.875 * 21, count: 8000), from: 4000, to: 8000)
        #expect(
            abs(AudioAnalysis.energy(of: centered, from: 984, to: 985, sampleRate: 48_000).value - 1) < 1e-3)
        // 無音
        let silent = AudioAnalysis.analyze(span(of: [Float](repeating: 0, count: 4000), from: 0, to: 4000))
        #expect(AudioAnalysis.energy(of: silent.spectrum, from: 20, to: 140, sampleRate: 48_000).value == 0)
    }

    @Test("energy は、範囲に中心の入る帯域の振幅の平均を dB の固定範囲で写す。中心が入らなければ最も近い帯域")
    func energyAveragesTheBandsInTheRange() {
        // 帯域 k の振幅を k / 1000 にした作り物のスペクトル。帯域 k の真ん中は 46.875 k Hz
        let spectrum = (0..<512).map { Float($0) / 1000 }
        func level(_ amplitude: Float) -> Float { AudioAnalysis.level(AudioAnalysis.decibels(amplitude)) }
        // 100〜200 Hz には帯域 3 (140.6)・4 (187.5) が入る
        let two = AudioAnalysis.energy(of: spectrum, from: 100, to: 200, sampleRate: 48_000)
        #expect(abs(two.value - level(0.0035)) < 1e-6)
        // 50〜60 Hz は中心が入らない → 中点 55 Hz にいちばん近い帯域 1
        #expect(abs(AudioAnalysis.energy(of: spectrum, from: 50, to: 60, sampleRate: 48_000).value - level(0.001)) < 1e-6)
        // 逆順は入れ替える
        #expect(AudioAnalysis.energy(of: spectrum, from: 200, to: 100, sampleRate: 48_000) == two)
        // 下へはみ出す分は 0 Hz (帯域 0 = 直流) へ寄せる
        #expect(
            AudioAnalysis.energy(of: spectrum, from: -500, to: 60, sampleRate: 48_000).value
                == AudioAnalysis.energy(of: spectrum, from: 0, to: 60, sampleRate: 48_000).value)
        // 上へはみ出す分は標本化率の半分 (最後の帯域) へ寄せる (帯域 510・511 の平均)
        #expect(
            abs(AudioAnalysis.energy(of: spectrum, from: 23_900, to: 90_000, sampleRate: 48_000).value
                - level(0.5105)) < 1e-5)
    }

    @Test("energy: 範囲が全部外なら 0、数でない値・無限の値は 0 で数でないと名乗る、標本化率が分からなければ 0")
    func energyEdges() {
        let spectrum = [Float](repeating: 0.5, count: 512)
        func energy(_ low: Float, _ high: Float, rate: Float = 48_000) -> (value: Float, isNumber: Bool) {
            AudioAnalysis.energy(of: spectrum, from: low, to: high, sampleRate: rate)
        }
        #expect(energy(30_000, 40_000).value == 0 && energy(30_000, 40_000).isNumber)
        #expect(energy(-300, -10).value == 0)
        for bad: Float in [.nan, .infinity, -.infinity] {
            #expect(energy(bad, 100) == (0, false))
            #expect(energy(100, bad) == (0, false))
        }
        #expect(energy(20, 140, rate: 0) == (0, true))
        #expect(energy(20, 140, rate: .nan) == (0, true))
        #expect(energy(20, 140).value > 0.8)
    }

    // MARK: - 3 つの音源の口

    /// 動いている入り口。区間は検査が `send` で入れ、`supply()` で受け取る。
    private func makeAudioIn(warn: @escaping (String) -> Void = { _ in }) throws -> AudioIn {
        let audio = AudioIn(
            device: nil, name: "samples", source: SilentAudioSource(.running), owner: nil, warn: warn)
        try audio.open()
        return audio
    }

    @Test("AudioIn: energy は spectrum から、数でない値は 0 で 1 度だけ知らせる")
    func audioInEnergy() throws {
        var notices: [String] = []
        let audio = try makeAudioIn { notices.append($0) }
        // 標本化率は出どころが名乗る。標本列の出どころを使う
        let recorded = AudioIn(
            device: nil, name: "samples",
            source: RecordedSource(samples: Self.tone(80, count: 48_000), sampleRate: 48_000),
            owner: nil, warn: { notices.append($0) })
        try recorded.open()
        recorded.input.send(span(of: Self.tone(80, count: 8000), from: 4000, to: 8000))
        recorded.supply()
        #expect(recorded.sampleRate == 48_000)
        #expect(recorded.energy(from: 20, to: 140) > 0.9)
        #expect(recorded.energy(from: 4000, to: 8000) == 0)
        #expect(notices.isEmpty)
        // 標本化率が分からない (マイクが開く前) は 0
        #expect(audio.energy(from: 20, to: 140) == 0)
        #expect(recorded.energy(from: .nan, to: 100) == 0)
        #expect(recorded.energy(from: 0, to: .infinity) == 0)
        #expect(notices.count == 1, "1 度だけ知らせる: \(notices)")
        #expect(notices.first?.contains("not a number") == true)
    }

    @Test("SynthSound: energy は出口の音の帯域を返し、数でない値は 0 で 1 度だけ知らせる")
    func synthSoundEnergy() {
        var notices: [String] = []
        let stage = SynthStage(owner: nil, flow: nil, now: { 0 }, warn: { notices.append($0) })
        stage.pace = .frames(perSecond: 30, origin: 0)
        let osc = SinOsc(stage: stage)
        osc.play(80, 1)
        for frame in 0..<12 {
            stage.frame = frame
            stage.supply()
        }
        #expect(osc.sampleRate == 48_000)
        #expect(osc.energy(from: 20, to: 140) > 0.8, "\(osc.energy(from: 20, to: 140))")
        #expect(osc.energy(from: 4000, to: 8000) == 0)
        #expect(notices.isEmpty)
        #expect(osc.energy(from: .nan, to: 1) == 0 && osc.energy(from: 1, to: .nan) == 0)
        #expect(notices.count == 1)
        stage.close()
    }

    // MARK: - waveform

    @Test("AudioIn: waveform は区間の終わりの 1024 標本 (古い順)。足りなければ前を 0 で埋め、標本が進まなければ前のまま")
    func audioInWaveform() throws {
        let audio = try makeAudioIn()
        #expect(audio.waveform == [Float](repeating: 0, count: 1024), "何も鳴っていなければ 1024 個の 0")

        let stream = (0..<5000).map { Float($0 + 1) / 5000 }
        audio.input.send(span(of: stream, from: 0, to: 300))
        audio.supply()
        // 標本 0 より前 (724 個) は 0
        #expect(audio.waveform == [Float](repeating: 0, count: 724) + Array(stream[0..<300]))

        audio.input.send(span(of: stream, from: 300, to: 3000))
        audio.supply()
        #expect(audio.waveform == Array(stream[1976..<3000]))
        // 同じフレームに何度読んでも同じ (控えを返す)
        #expect(audio.waveform == Array(stream[1976..<3000]))

        // 標本が進まなかったフレームは前のまま
        audio.supply()
        #expect(audio.isNewFrame == false)
        #expect(audio.waveform == Array(stream[1976..<3000]))

        // 閉じると無音
        audio.close()
        #expect(audio.waveform == [Float](repeating: 0, count: 1024))
    }

    @Test("SynthSound: waveform は出口の標本そのもので、値を読んでも読まなくても変わらず、止まっていれば 0")
    func synthSoundWaveform() throws {
        let stage = SynthStage(owner: nil, flow: nil, now: { 0 }, warn: { _ in })
        stage.pace = .frames(perSecond: 60, origin: 0)
        let osc = SinOsc(stage: stage)
        #expect(osc.waveform == [Float](repeating: 0, count: 1024), "鳴らす前")
        osc.play(440, 0.5)
        for frame in 0..<6 {
            stage.frame = frame
            stage.supply()
        }
        let node = try #require(osc.node)
        let outlet = node.meter.latest(1024)
        #expect(outlet.map { abs($0) }.max() ?? 0 > 0.3)
        #expect(osc.waveform == outlet)
        // 解析を読んでも、波形は変わらない
        _ = osc.level
        #expect(osc.waveform == outlet)
        stage.close()
        #expect(osc.waveform == [Float](repeating: 0, count: 1024), "終わったら無音")
    }

    // MARK: - isBeat: 拍の検出

    /// 区間の列を順に処理して、拍の位置 (ブロックの終わりの通し番号) を全部集める。
    private func beatPositions(of stream: [Float], endingAt ends: [Int]) -> [Int] {
        var tracker = BeatTracker()
        var found: [Int] = []
        for span in Self.spans(of: stream, endingAt: ends) {
            _ = tracker.process(span)
            found += tracker.beats
        }
        return found
    }

    @Test("無音だけの標本列では、拍は 0")
    func silenceHasNoBeats() {
        let stream = [Float](repeating: 0, count: 5 * Self.rate)
        for fps in [60, 30, 24] {
            #expect(beatPositions(of: stream, endingAt: Self.frameEnds(fps: fps, upTo: stream.count)).isEmpty)
        }
    }

    @Test("ずっと同じ強さの音 (正弦波・雑音) には、拍が出ない")
    func steadySoundHasNoBeats() {
        let ends = Self.frameEnds(fps: 60, upTo: 4 * Self.rate)
        // 鳴り始めの立ち上がりは 1 回だけ拍になりうる。落ち着いた後 (1 秒より先) は出ない
        for stream in [Self.tone(220, amplitude: 0.5, count: 4 * Self.rate), Self.noise(count: 4 * Self.rate)] {
            let late = beatPositions(of: stream, endingAt: ends).filter { $0 > Self.rate }
            #expect(late.isEmpty, "\(late)")
        }
    }

    /// 0.5 秒ごと・10 ms・-6 dBFS のクリックを、ブロックの境目の上・手前・途中に振って置く。
    private static let clickStarts = [12_000, 36_511, 60_001, 84_479, 108_545, 132_000, 156_300, 180_700]

    @Test("0.5 秒ごとのクリック列で、拍の数がクリックの数と一致し、各拍が立ち上がりから hop 1 つ (512 標本) 以内にある")
    func clickTrainBeatsMatchTheClicks() {
        let stream = Self.clicks(at: Self.clickStarts, count: 5 * Self.rate)
        let beats = beatPositions(of: stream, endingAt: Self.frameEnds(fps: 60, upTo: stream.count))
        #expect(beats.count == Self.clickStarts.count, "\(beats)")
        for (start, beat) in zip(Self.clickStarts, beats) {
            // 拍の位置は見つけたブロックの先頭。立ち上がりから hop 1 つ以内
            #expect(abs(beat - start) <= AudioAnalysis.hop, "立ち上がり \(start) に拍 \(beat)")
        }
    }

    @Test("同じ標本列を 60・30・24 fps と届くチャンクの長さを変えて回しても、拍の位置と総数が一致する")
    func beatPositionsDoNotDependOnTheSupply() {
        let stream = Self.clicks(at: Self.clickStarts, count: 5 * Self.rate)
        let reference = beatPositions(of: stream, endingAt: Self.frameEnds(fps: 60, upTo: stream.count))
        #expect(reference.count == Self.clickStarts.count)
        for fps in [30, 24, 144] {
            #expect(
                beatPositions(of: stream, endingAt: Self.frameEnds(fps: fps, upTo: stream.count)) == reference,
                "\(fps) fps")
        }
        // 区間の終わりを不規則に振る (チャンクの長さがばらばら)
        var ends: [Int] = []
        var end = 0
        var step = 97
        while end + step < stream.count {
            end += step
            ends.append(end)
            step = step % 2999 + 311
        }
        #expect(beatPositions(of: stream, endingAt: ends) == reference, "不規則な区切り")
        // 1 回で全部
        #expect(beatPositions(of: stream, endingAt: [stream.count]) == reference)
    }

    @Test("標本を落とした (区間が続かない) ときは履歴を捨てて始め直し、落とした区間では拍を出さない")
    func aGapRestartsTheTracker() {
        let stream = Self.clicks(at: Self.clickStarts, count: 5 * Self.rate)
        var tracker = BeatTracker()
        var found: [Int] = []
        // 最初のクリック (12000) の手前まで、続けて処理する
        for span in Self.spans(of: stream, endingAt: [6000, 11_000]) {
            _ = tracker.process(span)
            found += tracker.beats
        }
        // 2 番目 (36511) と 3 番目 (60001) の間を、続かない区間で飛ばす。クリック 1・2 は落とした区間にある
        let jumped = span(of: stream, from: 59_000, to: 62_000)
        _ = tracker.process(jumped)
        found += tracker.beats
        #expect(found.isEmpty, "落とした区間で拍が出た: \(found)")
        // 途中からの始め直しは最初の 8 ブロックを出さない。3 番目のクリックは始め直してから 3 ブロック目 → 出ない
        #expect(tracker.beats.isEmpty)
        // 続けて処理すれば、次のクリック (84479) は拍になる
        _ = tracker.process(span(of: stream, from: 62_000, to: 90_000))
        #expect(tracker.beats.count == 1 && abs(tracker.beats[0] - 84_479) <= 512, "\(tracker.beats)")
    }

    // MARK: - isBeat: 流れの扱い (番号の連続・端数・数でない標本・低い fps)

    /// `fps` の固定の時計のフレームの終わりで区切った区間を、供給する側と同じく上限 (``AudioAnalysis/maxSpan``) で切って返す。
    private static func cappedSpans(of stream: [Float], fps: Int) -> [AudioSpan] {
        var covered = 0
        return frameEnds(fps: fps, upTo: stream.count).map { end in
            defer { covered = end }
            return span(of: stream, from: AudioAnalysis.limited(from: covered, to: end), to: end)
        }
    }

    @Test("標本の流れの終わりで、閉じていない端数のブロック (512 標本未満) にだけある立ち上がりも拍になる。終わった後は履歴を捨てて始め直す")
    func finishClosesTheFragment() {
        // 20 ブロックと 200 標本。クリックは端数のブロック [10240, 10440) の中で立ち上がる
        let count = 20 * 512 + 200
        let stream = Self.clicks(at: [10_250], count: count)
        var tracker = BeatTracker()
        let inSpan = tracker.process(span(of: stream, from: 0, to: count))
        #expect(!inSpan, "端数のブロックは区間では閉じない")
        let atEnd = tracker.finish()
        #expect(atEnd)
        #expect(tracker.beats.count == 1 && abs(tracker.beats[0] - 10_250) <= AudioAnalysis.hop, "\(tracker.beats)")
        // 端数が無ければ、終わっても何も出ない
        var whole = BeatTracker()
        _ = whole.process(span(of: [Float](repeating: 0, count: 5120), from: 0, to: 5120))
        let wholeEnd = whole.finish()
        #expect(!wholeEnd)
        // 終わった後は、続く番号でも履歴を捨てて始め直す (途中からの始め直しなので、すぐ後のクリックは出ない)
        var continued = tracker
        // (拍の直後に数えないブロックも捨てる。クリックは、それが過ぎた後、始め直しの 8 ブロックの内に置く)
        let more = Self.clicks(at: [count + 3_900], count: count + 6_000)
        let afterEnd = continued.process(span(of: more, from: count, to: count + 6_000))
        #expect(!afterEnd)
        // 頭から鳴らし直すと、最初の立ち上がりも拍になる
        let again = Self.clicks(at: [1_000], count: 4096)
        let replayed = tracker.process(span(of: again, from: 0, to: 4096))
        #expect(replayed)
    }

    @Test("数でない標本・無限の標本は 0 として数え、履歴に残さない (その後の拍を約 1 秒隠さない)")
    func nonFiniteSamplesCountAsZero() {
        var stream = Self.clicks(at: Self.clickStarts, count: 5 * Self.rate)
        var zeroed = stream
        // 最初のクリックの手前に、数でない標本と無限の標本の列を置く
        for index in 5000..<5600 {
            stream[index] = index % 3 == 0 ? .nan : (index % 3 == 1 ? .infinity : -.infinity)
            zeroed[index] = 0
        }
        let ends = Self.frameEnds(fps: 60, upTo: stream.count)
        let reference = beatPositions(of: zeroed, endingAt: ends)
        #expect(reference.count == Self.clickStarts.count)
        #expect(beatPositions(of: stream, endingAt: ends) == reference)
    }

    @Test("始まりの前が無音なら、状態をどの標本から作っても同じ拍になる (全くの無音は履歴に入れない)")
    func leadingSilenceDoesNotDependOnWhereTheTrackerStarted() {
        // 大きな音と小さな音を近く置く。小さな音が拍になるかは、履歴に何ブロック入っているかで決まる
        for quiet: Float in [0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4] {
            var stream = [Float](repeating: 0, count: 60_000)
            for index in 12_000..<13_536 { stream[index] = 0.5 * sin(Float(index) * 0.3) }
            for index in 19_000..<19_600 { stream[index] = quiet * sin(Float(index) * 0.3) }
            func beats(startingAt start: Int) -> [Int] {
                var tracker = BeatTracker(fresh: true)
                var found: [Int] = []
                var position = start
                while position < stream.count {
                    let end = min(position + 700, stream.count)
                    _ = tracker.process(span(of: stream, from: position, to: end))
                    found += tracker.beats
                    position = end
                }
                return found
            }
            let reference = beats(startingAt: 0)
            #expect(!reference.isEmpty)
            for start in [3000, 7001, 11_111] {
                #expect(beats(startingAt: start) == reference, "小さい音 \(quiet)・始まり \(start)")
            }
        }
    }

    @Test("番号を付け直しても流れが続くとき rebase(to:) を伝えると履歴は続き、伝えなければ捨てて始め直す")
    func rebaseKeepsTheHistory() {
        let stream = Self.clicks(at: Self.clickStarts, count: 5 * Self.rate)
        let offset = 20_000
        func run(rebase: Bool) -> [Int] {
            var tracker = BeatTracker()
            var found: [Int] = []
            // クリック 2 (36511) の手前まで、元の番号で続ける
            for piece in Self.spans(of: stream, endingAt: [12_000, 24_000, 36_000]) {
                _ = tracker.process(piece)
                found += tracker.beats
            }
            // 以後は番号を offset だけ付け直す (標本は同じ)
            if rebase { tracker.rebase(to: 36_000 - offset) }
            for (from, to) in [(36_000, 40_000), (40_000, 60_000)] {
                _ = tracker.process(span(from: from - offset, to: to - offset) { stream[$0 + offset] })
                found += tracker.beats
            }
            return found
        }
        let continued = run(rebase: true)
        // クリック 1 (12000)・クリック 2 (36511 → 付け直した番号で 16511)
        #expect(continued.count == 2 && abs(continued[1] - (36_511 - offset)) <= AudioAnalysis.hop, "\(continued)")
        // 伝えなければ、番号が飛んだ (標本を落とした) と見なして始め直し、直後のクリック 2 は見逃す
        #expect(run(rebase: false).count == 1)
    }

    @Test("低い fps (約 7.8 fps 未満) は、区間の上限で頭が落ちて履歴を捨て続ける: 取りこぼすことはあっても、偽の拍も重複も出ない")
    func belowTheSpanLimitBeatsAreMissedButNeverInvented() {
        let stream = Self.clicks(at: Self.clickStarts, count: 5 * Self.rate)
        let reference = beatPositions(of: stream, endingAt: Self.frameEnds(fps: 60, upTo: stream.count))
        #expect(reference.count == Self.clickStarts.count)
        func positions(fps: Int) -> [Int] {
            var tracker = BeatTracker()
            var found: [Int] = []
            for piece in Self.cappedSpans(of: stream, fps: fps) {
                _ = tracker.process(piece)
                found += tracker.beats
            }
            return found
        }
        // 7.8 fps より速ければ、区間の頭は落ちず、60 fps と同じ
        #expect(positions(fps: 10) == reference)
        // 5 fps は 1 フレームが 9600 標本で上限 (6144) を越える
        for fps in [5, 3] {
            let found = positions(fps: fps)
            #expect(found.count <= Self.clickStarts.count, "\(fps) fps: \(found)")
            #expect(found.count == Set(found).count, "重複: \(found)")
            for beat in found {
                #expect(
                    Self.clickStarts.contains { abs(beat - $0) <= AudioAnalysis.hop }, "\(fps) fps: 偽の拍 \(beat)")
            }
            // 同じ fps で 2 度回せば同じ (欠けるのは決まっている)
            #expect(positions(fps: fps) == found)
        }
    }

    // MARK: - isBeat: 音源の口

    @Test("AudioIn: isBeat は読まなくても毎フレーム進み、どのフレームから読み始めても、読む間隔を変えても、拍のフレームは同じ")
    func audioInBeatAdvancesWhetherOrNotRead() throws {
        let stream = Self.clicks(at: Self.clickStarts, count: 5 * Self.rate)
        let ends = Self.frameEnds(fps: 60, upTo: stream.count)
        let spans = Self.spans(of: stream, endingAt: ends)

        func run(readFrom first: Int?, every step: Int = 1) throws -> (flags: [Int], steps: Int) {
            let audio = try makeAudioIn()
            var flags: [Int] = []
            for (frame, span) in spans.enumerated() {
                audio.input.send(span)
                audio.supply()
                if let first, frame >= first, (frame - first) % step == 0, audio.isBeat { flags.append(frame) }
            }
            return (flags, audio.beatSteps)
        }
        let never = try run(readFrom: nil)
        #expect(never.steps == spans.count, "読まなくても、区間が届くたびに処理する")
        let every = try run(readFrom: 0)
        #expect(every.flags.count == Self.clickStarts.count, "\(every.flags)")
        #expect(every.steps == spans.count)
        // どのフレームから読み始めても、それ以後の拍のフレームは同じ。拍のフレームの直前・拍のフレーム自体から読んでも
        for first in every.flags + [every.flags[1] - 1, 40, 200] {
            #expect(
                try run(readFrom: first).flags == every.flags.filter { $0 >= first }, "\(first) フレーム目から読み始める")
        }
        let second = try run(readFrom: 0, every: 2)
        #expect(second.flags == every.flags.filter { $0 % 2 == 0 }, "読む間隔を変えても、拍の位置は同じ")
        let third = try run(readFrom: 0, every: 3)
        #expect(third.flags == every.flags.filter { $0 % 3 == 0 })
        // 拍があったフレームの次のフレームには、拍は無い (1 つのクリックを 2 度数えない)
        #expect(zip(every.flags, every.flags.dropFirst()).allSatisfy { $1 - $0 > 1 })
    }

    @Test("AudioIn: 空の区間のフレームには拍が無く、前のフレームの拍を持ち越さない (最初に読むフレームでも)")
    func audioInEmptyFrameHasNoBeat() throws {
        let stream = Self.clicks(at: Self.clickStarts, count: 5 * Self.rate)
        let audio = try makeAudioIn()
        // 最初のクリック (12000) のブロックを閉じる区間を、読まずに置く
        audio.input.send(span(of: stream, from: 0, to: 11_000))
        audio.supply()
        audio.input.send(span(of: stream, from: 11_000, to: 12_400))
        audio.supply()
        // 次のフレームは標本が進まない (空の区間)。ここで初めて読んでも、前の区間の拍は持ち越さない
        audio.input.send(span(of: stream, from: 12_400, to: 12_400))
        audio.supply()
        #expect(audio.isBeat == false)
    }

    @Test("AudioIn: 時刻を指定した観測の枚は、指定の秒で終わる区間の波形と拍を見せ、通常の続きの拍は動かさない")
    func audioInObservationShowsItsOwnBeatAndWaveform() throws {
        let stream = Self.clicks(at: Self.clickStarts, count: 5 * Self.rate)
        func observation(_ from: Int, _ to: Int) -> AudioSpan.Observation {
            let piece = span(of: stream, from: from, to: to)
            return AudioSpan.Observation(base: piece.base, samples: piece.samples, from: piece.from)
        }
        // 通常の続きだけを回した相手 (観測の枚が続きを動かさないことを見る)
        func recorded() throws -> AudioIn {
            let audio = AudioIn(
                device: nil, name: "samples", source: RecordedSource(samples: stream, sampleRate: 48_000),
                owner: nil, warn: { _ in })
            try audio.open()
            return audio
        }
        let plain = try recorded()
        let audio = try recorded()
        func send(_ from: Int, _ to: Int, observing seen: AudioSpan.Observation? = nil) {
            var piece = span(of: stream, from: from, to: to)
            plain.input.send(piece)
            plain.supply()
            piece.observation = seen
            audio.input.send(piece)
            audio.supply()
        }
        var end = 0
        while end + 800 <= 20_000 {
            send(end, end + 800)
            end += 800
        }
        // 通常の続き (20000..<20800) には拍が無いが、観測は最初のクリックの拍があった区間を見せる
        send(20_000, 20_800, observing: observation(11_500, 12_300))
        #expect(audio.isBeat && !plain.isBeat)
        #expect(audio.waveform == Array(stream[(12_300 - 1024)..<12_300]))
        // 帯域の大きさも、見せる区間 (クリックがある) のもの。通常の続きの区間は無音
        #expect(audio.energy(from: 0, to: 24_000) > 0 && plain.energy(from: 0, to: 24_000) == 0)
        // 次の通常の枚は、観測が無かったときと同じ (波形は通常の区間に戻り、拍は無い)
        send(20_800, 21_600)
        #expect(!audio.isBeat && audio.waveform == plain.waveform)
        // 拍の無い区間を見せる観測の枚は、通常の続きに拍 (2 つ目のクリック) があっても false
        end = 21_600
        while end + 800 < 36_000 {
            send(end, end + 800)
            end += 800
        }
        send(end, 37_000, observing: observation(15_000, 15_800))
        #expect(plain.isBeat, "通常の続きには拍がある")
        #expect(audio.isBeat == false)
        #expect(audio.beatSteps == plain.beatSteps, "観測の枚が続きの処理を増減しない")
        // 続きの拍の状態は動いていない: 次の拍 (3 つ目のクリック) は同じフレームに出る
        var flags: [Bool] = []
        end = 37_000
        while end + 800 <= 62_000 {
            send(end, end + 800)
            flags.append(audio.isBeat)
            #expect(audio.isBeat == plain.isBeat)
            end += 800
        }
        #expect(flags.filter { $0 }.count == 1)
    }

    @Test("SynthSound: 0.5 秒ごとの短い音は拍になり、30 fps でも 60 fps でも同じ数。読まなくても処理は進み、どのフレームから読み始めても同じ")
    func synthSoundBeats() {
        func run(fps: Int, readFrom: Int?) -> (frames: [Int], steps: Int) {
            let stage = SynthStage(owner: nil, flow: nil, now: { 0 }, warn: { _ in })
            stage.pace = .frames(perSecond: fps, origin: 0)
            let osc = SinOsc(stage: stage)
            osc.set(1000, 0.5)
            let env = Env()
            var frames: [Int] = []
            for frame in 0..<(fps * 4) {
                stage.frame = frame
                stage.supply()
                if let readFrom, frame >= readFrom, osc.isBeat { frames.append(frame) }
                // 0.5 秒ごとに 10 ms の音。最初は 0.5 秒目 (鳴らす前は無音)
                if (frame - fps / 2) % (fps / 2) == 0, frame >= fps / 2 {
                    env.play(osc, 0.001, 0.008, 1, 0.001)
                }
            }
            let steps = osc.beatSteps
            stage.close()
            return (frames, steps)
        }
        let slow = run(fps: 30, readFrom: 0)
        let fast = run(fps: 60, readFrom: 0)
        #expect(slow.frames.count == 7, "0.5 秒ごとに 7 つ鳴らした: \(slow.frames)")
        #expect(fast.frames.count == slow.frames.count)
        // 読まなくても処理は進む (鳴らし始めてから毎フレーム)
        #expect(run(fps: 30, readFrom: nil).steps > 0)
        // 最初の音の直後のフレームから読み始めても、最初の音が拍になる (後から読んでも履歴は同じ)
        for first in [slow.frames[0], slow.frames[0] + 1, 20] {
            #expect(
                run(fps: 30, readFrom: first).frames == slow.frames.filter { $0 >= first },
                "\(first) フレーム目から読み始める")
        }
    }
}
