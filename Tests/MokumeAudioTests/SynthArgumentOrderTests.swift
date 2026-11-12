// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeAudio

/// 引数を省いた形が Processing Sound と同じ並びで読まれること (#3719)。
///
/// 手本の `noise.play(amp, pos)`・`noise.set(amp, pos)` の第 2 引数と `osc.set(freq, amp, pos)` の第 3 引数は
/// 定位、`delay.process(input, maxDelayTime, delayTime)` の第 3 引数は始めの遅れである。省いた形が `add`・
/// `feedback` に読まれると、警告なしに別の音になる。
///
/// スケッチを走らせず (GPU は要らない)、持ち主のいないステージを機材に出さない流れで鳴らし、左右の標本を
/// フレームごとに取る (固定の時計で書き出すのと同じく、何度回しても同じ標本になる)。
@Suite("合成した音: 手本と同じ引数の並び", .serialized)
struct SynthArgumentOrderTests {
    private static let perFrame = 800

    /// 持ち主のいないステージを機材に出さない流れで作り、`setUp` で音を鳴らして `frames` フレーム描かせる。
    private func heard(
        frames: Int = 12, notices: NoticeLog = NoticeLog(),
        _ setUp: (SynthStage) -> Void
    ) throws -> Stereo {
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        let stage = SynthStage(owner: nil, flow: flow, now: { 0 }, warn: { notices.append($0) })
        let player = try #require(RackPlayer(flow: flow, rack: stage.rack))
        defer { player.leave() }
        stage.pace = .speaker(player)
        setUp(stage)
        var result = Stereo()
        for _ in 0..<frames {
            stage.supply()
            let piece = try renderStereo(flow, Self.perFrame)
            result.left += piece.left
            result.right += piece.right
        }
        stage.close()
        return result
    }

    private func loudest(_ samples: [Float]) -> Float {
        samples.map { abs($0) }.max() ?? 0
    }

    /// 最後の 1 フレームぶんの標本。
    private func lastFrame(_ samples: [Float]) -> [Float] {
        Array(samples.suffix(Self.perFrame))
    }

    private func mean(_ samples: [Float]) -> Float {
        samples.reduce(0, +) / Float(max(samples.count, 1))
    }

    // MARK: - Noise

    /// 定位だけを渡す形と、オフセット 0 を挟んで定位を 3 つ目に渡す形の組。
    private static let noiseForms: [(label: String, short: (Noise) -> Void, full: (Noise) -> Void)] = [
        ("play(amp, pos)", { $0.play(0.5, -1) }, { $0.play(0.5, 0, -1) }),
        ("play(amp, pos, at:)", { $0.play(0.5, -1, at: 0) }, { $0.play(0.5, 0, -1, at: 0) }),
        ("set(amp, pos)", { $0.set(0.5, -1); $0.play() }, { $0.set(0.5, 0, -1); $0.play() }),
    ]

    @Test("Noise の 2 引数の形は第 2 引数を定位に読み、左へ寄せた音が 3 引数の形と標本まで一致する", arguments: 0..<3)
    func noiseTakesThePositionSecond(_ index: Int) throws {
        let form = Self.noiseForms[index]
        let short = try heard { form.short(WhiteNoise(stage: $0)) }
        let full = try heard { form.full(WhiteNoise(stage: $0)) }
        #expect(mismatch(short, full) == nil, "\(form.label)")
        // 左へ振り切ったので右は無音、左は鳴っている (前は振幅に -1 を足した中央の音で、右も鳴った)。
        // 定位は中央から 5 ミリ秒の時定数で寄るので、寄り切った最後のフレームを見る
        let right = loudest(lastFrame(short.right))
        #expect(right < 1e-6, "\(form.label): 右 \(right)")
        #expect(loudest(lastFrame(short.left)) > 0.1, "\(form.label): 左 \(loudest(short.left))")
    }

    @Test("Noise の 1 引数の形は定位を中央・オフセットを 0 に戻し、3 引数の形の 2 つ目はこれまでどおりオフセット")
    func noiseKeepsTheOtherForms() throws {
        // 1 引数: 前に決めた定位とオフセットは 0 に戻る
        let single = try heard { stage in
            let noise = WhiteNoise(stage: stage)
            noise.set(0.5, 0.3, -1)
            noise.play(0.5)
        }
        let center = try heard { WhiteNoise(stage: $0).play(0.5, 0, 0) }
        #expect(mismatch(single, center) == nil)
        #expect(mismatch(single.left, single.right) == nil, "中央なら左右は同じ")
        // 3 引数: 2 つ目はオフセット。中央のまま、波形が上へずれる
        let shifted = try heard { WhiteNoise(stage: $0).play(0.2, 0.3, 0) }
        #expect(mismatch(shifted.left, shifted.right) == nil)
        #expect(mean(shifted.left) > 0.1, "平均 \(mean(shifted.left))")
    }

    // MARK: - Oscillator

    @Test("Oscillator.set の 3 引数の形は第 3 引数を定位に読み、左へ振れ、波形はずれない")
    func oscillatorSetTakesThePositionThird() throws {
        let short = try heard { stage in
            let osc = SinOsc(stage: stage)
            osc.set(440, 0.5, -1)
            osc.play()
        }
        let full = try heard { stage in
            let osc = SinOsc(stage: stage)
            osc.set(440, 0.5, 0, -1)
            osc.play()
        }
        #expect(mismatch(short, full) == nil)
        // 定位は中央から 5 ミリ秒の時定数で寄るので、寄り切った最後のフレームを見る
        let right = loudest(lastFrame(short.right))
        #expect(right < 1e-6, "右 \(right)")
        #expect(loudest(lastFrame(short.left)) > 0.4, "左 \(loudest(short.left))")
        // 波形は上下にずれない (前は -1 を足し、平均が -1 近くへ沈んだ)
        #expect(abs(mean(short.left)) < 0.01, "平均 \(mean(short.left))")
    }

    @Test("Oscillator.set の 2 引数の形は定位を中央・オフセットを 0 に戻す")
    func oscillatorSetWithTwoResets() throws {
        let two = try heard { stage in
            let osc = SinOsc(stage: stage)
            osc.set(440, 0.5, 0.3, -1)
            osc.set(440, 0.5)
            osc.play()
        }
        let center = try heard { SinOsc(stage: $0).play(440, 0.5) }
        #expect(mismatch(two, center) == nil)
        #expect(mismatch(two.left, two.right) == nil)
    }

    // MARK: - Delay

    @Test("Delay.process の第 3 引数は始めの遅れで、time(_:) で決めたのと同じ音になり、戻す割合には読まない")
    func delayTakesTheDelayTimeThird() throws {
        let notices = NoticeLog()
        let three = try heard(frames: 30, notices: notices) { stage in
            let osc = SinOsc(stage: stage)
            osc.play(440, 0.5)
            Delay(stage: stage).process(osc, 2, 0.1)
        }
        let timed = try heard(frames: 30) { stage in
            let osc = SinOsc(stage: stage)
            osc.play(440, 0.5)
            let delay = Delay(stage: stage)
            delay.process(osc, 2)
            delay.time(0.1)
        }
        let fedBack = try heard(frames: 30) { stage in
            let osc = SinOsc(stage: stage)
            osc.play(440, 0.5)
            let delay = Delay(stage: stage)
            delay.process(osc, 2)
            delay.feedback(0.1)
        }
        #expect(mismatch(three, timed) == nil)
        #expect(mismatch(three, fedBack) != nil, "戻す割合に読んだ音と区別できる")
        #expect(notices.lines.isEmpty, "\(notices.lines)")
    }

    @Test("Delay.process の遅れは、同じ呼び出しで決めた上限で丸めて 1 度だけ知らせ、数でない値は無視する")
    func delayTimeIsClampedToTheNewMaximum() throws {
        let clampedNotices = NoticeLog()
        let clamped = try heard(frames: 80, notices: clampedNotices) { stage in
            let osc = SinOsc(stage: stage)
            osc.play(440, 0.5)
            Delay(stage: stage).process(osc, 1, 3)
        }
        let atMaximum = try heard(frames: 80) { stage in
            let osc = SinOsc(stage: stage)
            osc.play(440, 0.5)
            let delay = Delay(stage: stage)
            delay.process(osc, 1)
            delay.time(1)
        }
        #expect(mismatch(clamped, atMaximum) == nil)
        #expect(clampedNotices.lines.count == 1, "\(clampedNotices.lines)")
        #expect(clampedNotices.lines.first?.contains("time()") == true, "\(clampedNotices.lines)")

        // NaN の遅れは無視し、既定の遅れ (0.25 秒) のまま
        let nanNotices = NoticeLog()
        let ignored = try heard(frames: 30, notices: nanNotices) { stage in
            let osc = SinOsc(stage: stage)
            osc.play(440, 0.5)
            Delay(stage: stage).process(osc, 2, .nan)
        }
        let untouched = try heard(frames: 30) { stage in
            let osc = SinOsc(stage: stage)
            osc.play(440, 0.5)
            Delay(stage: stage).process(osc, 2)
        }
        #expect(mismatch(ignored, untouched) == nil)
        #expect(nanNotices.lines.count == 1, "\(nanNotices.lines)")
    }
}
