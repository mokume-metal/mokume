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

    // MARK: - isBeat: 音源の口

    @Test("AudioIn: isBeat は読んだフレームから状態を作り、読まなければ処理は 0 回。読む間隔を変えても拍のフレームは同じ")
    func audioInBeatReadsLazily() throws {
        let stream = Self.clicks(at: Self.clickStarts, count: 5 * Self.rate)
        let ends = Self.frameEnds(fps: 60, upTo: stream.count)
        let spans = Self.spans(of: stream, endingAt: ends)

        func run(readEvery step: Int?) throws -> (flags: [Int], steps: Int) {
            let audio = try makeAudioIn()
            var flags: [Int] = []
            for (frame, span) in spans.enumerated() {
                audio.input.send(span)
                audio.supply()
                if let step, frame % step == 0, audio.isBeat { flags.append(frame) }
            }
            return (flags, audio.beatSteps)
        }
        let never = try run(readEvery: nil)
        #expect(never.steps == 0, "一度も読まない音源は処理が 0 回")
        let every = try run(readEvery: 1)
        #expect(every.flags.count == Self.clickStarts.count, "\(every.flags)")
        #expect(every.steps == spans.count, "読み始めた後は毎フレームの区間を処理する")
        let second = try run(readEvery: 2)
        #expect(second.flags == every.flags.filter { $0 % 2 == 0 }, "読む間隔を変えても、拍の位置は同じ")
        #expect(second.steps == spans.count, "読まないフレームの区間も処理する")
        let third = try run(readEvery: 3)
        #expect(third.flags == every.flags.filter { $0 % 3 == 0 })
        // 拍があったフレームの次のフレームには、拍は無い (1 つのクリックを 2 度数えない)
        #expect(zip(every.flags, every.flags.dropFirst()).allSatisfy { $1 - $0 > 1 })
    }

    @Test("SynthSound: 0.5 秒ごとの短い音は拍になり、30 fps でも 60 fps でも同じ数で、読まなければ処理は 0 回")
    func synthSoundBeats() {
        func run(fps: Int, read: Bool) -> (beats: Int, steps: Int) {
            let stage = SynthStage(owner: nil, flow: nil, now: { 0 }, warn: { _ in })
            stage.pace = .frames(perSecond: fps, origin: 0)
            let osc = SinOsc(stage: stage)
            osc.set(1000, 0.5)
            let env = Env()
            var beats = 0
            for frame in 0..<(fps * 4) {
                stage.frame = frame
                stage.supply()
                if read, osc.isBeat { beats += 1 }
                // 0.5 秒ごとに 10 ms の音。最初は 0.5 秒目 (履歴が溜まってから)
                if (frame - fps / 2) % (fps / 2) == 0, frame >= fps / 2 {
                    env.play(osc, 0.001, 0.008, 1, 0.001)
                }
            }
            let steps = osc.beatSteps
            stage.close()
            return (beats, steps)
        }
        let slow = run(fps: 30, read: true)
        let fast = run(fps: 60, read: true)
        #expect(slow.beats == 7, "0.5 秒ごとに 7 つ鳴らした: \(slow.beats)")
        #expect(fast.beats == slow.beats)
        #expect(run(fps: 30, read: false).steps == 0)
        #expect(slow.steps > 0)
    }
}
