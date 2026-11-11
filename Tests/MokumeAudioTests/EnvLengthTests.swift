// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeAudio

/// `Env.play` の長さが標本の数で表せないとき (#3951)。GPU は要らない。
///
/// 持ち主のいないステージを固定の時計 (60 fps) で回し、音源の出口の標本を読む。**数は定数を写さず、数字で書く**
/// (#2285): 48 kHz で 60 fps の 1 フレーム = 800 標本。`Float(1e15)` 秒は 4.8 × 10¹⁹ 標本で `Int` に収まらず、
/// `Float(1e14)` 秒は 1 区間なら収まるが 2 区間の合計で収まらない。
@Suite("合成した音: 標本の数で表せない包絡の長さ", .serialized)
struct EnvLengthTests {
    /// 1 区間で `Int` に収まらない長さと、2 区間の合計で収まらない長さ (立ち上がり・持続・余韻)。
    private static let tooLong: [(label: String, attack: Float, sustain: Float, release: Float)] = [
        ("立ち上がりが 1e15 秒", Float(1e15), 0.03, 0.1),
        ("持続が 1e15 秒", 0.002, Float(1e15), 0.1),
        ("余韻が 1e15 秒", 0.002, 0.03, Float(1e15)),
        ("立ち上がりと持続が 1e14 秒ずつ", Float(1e14), Float(1e14), 0),
    ]

    private func makeStage(_ notices: NoticeLog) -> SynthStage {
        let stage = SynthStage(owner: nil, flow: nil, now: { 0 }, warn: { notices.append($0) })
        stage.pace = .frames(perSecond: 60, origin: 0)
        return stage
    }

    /// フレーム `frames` を回し、音源ごとにそのフレームの出口の最大の振幅を集める。フレーム `f` で集めるのは
    /// `(f − 1) / 60`〜`f / 60` 秒の 800 標本 (0.5 秒の頭から鳴る音は、フレーム 31 で初めて聞こえる)。
    private func run(
        _ stage: SynthStage, _ frames: Range<Int>, _ sources: [SynthSource]
    ) -> [[Float]] {
        var peaks = Array(repeating: [Float](), count: sources.count)
        for frame in frames {
            stage.frame = frame
            stage.supply()
            for (index, source) in sources.enumerated() {
                let samples = source.node?.meter.latest(800) ?? []
                peaks[index].append(samples.map(abs).max() ?? 0)
            }
        }
        return peaks
    }

    @Test(
        "表せない長さの Env.play は、すぐの呼び出しも予約も全体を無視し、止まった音は鳴らず、理由を音ごとに 1 度知らせる",
        arguments: 0..<4)
    func anUncountableLengthIgnoresTheWholeCall(_ index: Int) {
        let input = Self.tooLong[index]
        let notices = NoticeLog()
        let stage = makeStage(notices)
        let now = SinOsc(stage: stage)
        let later = SinOsc(stage: stage)
        let env = Env()
        env.play(now, input.attack, input.sustain, 0.7, input.release)
        env.play(later, input.attack, input.sustain, 0.7, input.release, at: 0.1)
        // 2 度目は知らせない (音ごとに 1 度)
        env.play(now, input.attack, input.sustain, 0.7, input.release)
        #expect(!now.isPlaying && !later.isPlaying, "\(input.label)")
        let peaks = run(stage, 0..<30, [now, later])
        #expect(peaks.allSatisfy { $0.allSatisfy { $0 == 0 } }, "\(input.label): 鳴った")
        #expect(abs(stage.soundSeconds - 29.0 / 60) < 1e-9, "\(input.label): 拒んだ時刻 (0.1 秒) を過ぎても進む")
        #expect(stage.rack.droppedReservations == 0)
        stage.close()
        let lines = notices.lines
        #expect(lines.count == 2, "\(input.label): \(lines)")
        #expect(
            lines.allSatisfy { $0.hasPrefix("Env.play()") && $0.contains("samples") && $0.contains("ignored") },
            "\(lines)")
    }

    @Test(
        "表せない長さの Env.play は、鳴っている音の包絡を頭から始め直さず、先の予約もそのとおり効く",
        arguments: 0..<4)
    func anUncountableLengthLeavesThePlayingSoundAndReservations(_ index: Int) {
        let input = Self.tooLong[index]
        let notices = NoticeLog()
        let stage = makeStage(notices)
        let playing = SinOsc(stage: stage)
        let reserved = SinOsc(stage: stage)
        let env = Env()
        // 立ち上がり 0.01 秒・持続 0.5 秒・余韻 0.1 秒 (0.61 秒。フレーム 37 まで聞こえる)
        env.play(playing, 0.01, 0.5, 0.7, 0.1)
        // 0.5 秒に鳴り始め (フレーム 31 から)、0.61 秒に終わる (フレーム 38 まで)
        env.play(reserved, 0.01, 0.0, 0.7, 0.1, at: 0.5)
        let before = run(stage, 0..<6, [playing, reserved])
        // 鳴っている音へ、すぐと予約 (予約の時刻より前・後) で
        env.play(playing, input.attack, input.sustain, 0.7, input.release)
        env.play(playing, input.attack, input.sustain, 0.7, input.release, at: 0.2)
        env.play(reserved, input.attack, input.sustain, 0.7, input.release, at: 0.25)
        env.play(reserved, input.attack, input.sustain, 0.7, input.release, at: 0.75)
        #expect(playing.isPlaying && reserved.isPlaying)
        let after = run(stage, 6..<60, [playing, reserved])
        stage.close()
        let heard = zip(before, after).map { $0 + $1 }
        // もとの包絡のまま: 持続の間 (0.1〜0.5 秒) は 0.35 (音量 0.5 × 0.7) の高さで鳴り、0.61 秒より後は無音
        #expect(heard[0][6..<30].allSatisfy { $0 > 0.3 }, "\(input.label): \(heard[0][6..<30])")
        #expect(heard[0][38..<60].allSatisfy { $0 == 0 }, "\(input.label): 包絡が終わらない")
        // 予約は 0.5 秒の頭から鳴り、拒んだ予約 (0.75 秒) を過ぎても音は進んで、その後は無音
        #expect(heard[1][0...30].allSatisfy { $0 == 0 }, "\(input.label): 予約より前に鳴った")
        #expect(heard[1][31...32].allSatisfy { $0 > 0.3 }, "\(input.label): \(heard[1][28..<40])")
        #expect(heard[1][40..<60].allSatisfy { $0 == 0 }, "\(input.label)")
        #expect(abs(stage.soundSeconds - 59.0 / 60) < 1e-9)
        #expect(notices.lines.count == 2, "\(notices.lines)")
    }

    @Test("表せる長さはそのまま受ける: 48 kHz で 0.125 秒は 6000 標本、1e14 秒の 1 区間も受ける")
    func countableLengthsAreKept() {
        let shape = EnvelopeShape(
            attack: 0.125, sustain: 0.125, level: 1, release: 0.125, sampleRate: 48_000)
        #expect(shape.attack == 6000 && shape.sustain == 6000 && shape.release == 6000)
        #expect(shape.length == 18_000)
        #expect(
            EnvelopeShape.sampleCounts(
                attack: 0.125, sustain: 0.125, release: 0.125, sampleRate: 48_000)
                .map { [$0.attack, $0.sustain, $0.release] } == [6000, 6000, 6000])
        // 1 区間の 1e14 秒は収まる (4,800,000,018,087,936,000 標本)
        let one = EnvelopeShape.sampleCounts(
            attack: Float(1e14), sustain: 0, release: 0, sampleRate: 48_000)
        #expect(one?.attack == 4_800_000_018_087_936_000)
        #expect(
            EnvelopeShape.sampleCounts(
                attack: Float(1e14), sustain: Float(1e14), release: 0, sampleRate: 48_000) == nil)
        #expect(
            EnvelopeShape.sampleCounts(
                attack: 0, sustain: 0, release: Float(1e15), sampleRate: 48_000) == nil)

        // ステージ越しでも、通常の値は知らせずに鳴らす
        let notices = NoticeLog()
        let stage = makeStage(notices)
        let osc = SinOsc(stage: stage)
        Env().play(osc, 0.125, 0.125, 0.7, 0.125)
        #expect(osc.isPlaying)
        let peaks = run(stage, 0..<12, [osc])
        stage.close()
        #expect(peaks[0][8..<12].allSatisfy { $0 > 0.3 }, "\(peaks[0])")
        #expect(notices.lines.isEmpty, "\(notices.lines)")
    }

    /// 境目は標本の数で決まり、秒では決まらない。48 kHz の外 (44.1 kHz・96 kHz) でも、1 区間と合計のそれぞれで、
    /// 収まる最長の `Float` の秒とその 1 つ上 (`nextUp`) を確かめる。境目の秒は `Int.max ÷ sampleRate` から
    /// 下へたどって探す (定数を写さない)。
    @Test("44.1・48・96 kHz で、1 区間と合計のそれぞれ、収まる最長の秒は受け、その 1 つ上の Float は拒む", arguments: [44_100.0, 48_000, 96_000])
    func theBoundaryFollowsTheSampleRate(_ rate: Double) {
        func counts(_ attack: Float, _ sustain: Float) -> (attack: Int, sustain: Int, release: Int)? {
            EnvelopeShape.sampleCounts(attack: attack, sustain: sustain, release: 0, sampleRate: rate)
        }
        // 1 区間
        var one = Float(Double(Int.max) / rate)
        while counts(one, 0) == nil { one = one.nextDown }
        #expect(counts(one, 0) != nil && counts(one.nextUp, 0) == nil, "\(rate) Hz: \(one)")
        #expect(counts(0, one.nextUp) == nil, "持続でも同じ")
        // 合計: 2 区間とも単独では収まり、合計で越える
        var half = Float(Double(Int.max) / rate / 2)
        while counts(half, half) == nil { half = half.nextDown }
        let next = half.nextUp
        #expect(counts(next, 0) != nil && counts(0, next) != nil, "\(rate) Hz: 1 区間ずつなら収まる")
        #expect(counts(half, half) != nil && counts(next, next) == nil, "\(rate) Hz: \(half)")
        // 48 kHz で拒む 1e14 秒 + 1e14 秒は、44.1 kHz なら 8.82 × 10¹⁸ 標本で収まる
        #expect((counts(Float(1e14), Float(1e14)) != nil) == (rate < 46_000), "\(rate) Hz")
    }
}
