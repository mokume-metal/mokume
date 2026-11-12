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
    ///
    /// `act` は各フレームの `supply()` の前に、フレームの番号 (0 から) で呼ぶ (鳴っている最中・止めた後の操作)。
    private func heard(
        frames: Int = 12, notices: NoticeLog = NoticeLog(),
        act: (Int) -> Void = { _ in },
        _ setUp: (SynthStage) -> Void
    ) throws -> Stereo {
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        let stage = SynthStage(owner: nil, flow: flow, now: { 0 }, warn: { notices.append($0) })
        let player = try #require(RackPlayer(flow: flow, rack: stage.rack))
        defer { player.leave() }
        stage.pace = .speaker(player)
        setUp(stage)
        var result = Stereo()
        for frame in 0..<frames {
            act(frame)
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

    @Test("Noise の 3 引数の形の 2 つ目はこれまでどおりオフセットで、中央のまま波形が上へずれる")
    func noiseTakesTheOffsetSecondOfThree() throws {
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

    // MARK: - 省いた値は保つ (#3719 の 2026-11-13 の決定 1)

    /// 省いた値を保つかを見る組。`prepare` が先に決めた値を、`call` の形が省く。
    private struct Kept {
        var label: String
        /// 先に決めておく値 (省かれる値)。
        var prepare: (SynthSource) -> Void
        /// 省いた形の呼び出し (鳴らす形・決めるだけの形)。
        var call: (SynthSource) -> Void
        /// 左へ寄せたままなら `true` (右が無音)。
        var keepsLeft: Bool
        /// オフセット 0.3 を保つなら `true` (平均が上へずれる)。
        var keepsOffset: Bool
    }

    private static let kept: [Kept] = [
        Kept(
            label: "noise.pan(-1) の後の play(amp)", prepare: { $0.pan(-1) },
            call: { ($0 as? Noise)?.play(0.5) }, keepsLeft: true, keepsOffset: false),
        Kept(
            label: "noise.pan(-1) の後の play(amp, at:)", prepare: { $0.pan(-1) },
            call: { ($0 as? Noise)?.play(0.5, at: 0) }, keepsLeft: true, keepsOffset: false),
        Kept(
            label: "noise.pan(-1) の後の set(amp)", prepare: { $0.pan(-1) },
            call: { ($0 as? Noise)?.set(0.5); $0.play() }, keepsLeft: true, keepsOffset: false),
        Kept(
            label: "noise.add(0.3) の後の play(amp, pos)", prepare: { $0.add(0.3) },
            call: { ($0 as? Noise)?.play(0.2, -1) }, keepsLeft: true, keepsOffset: true),
        Kept(
            label: "noise.add(0.3) の後の play(amp, pos, at:)", prepare: { $0.add(0.3) },
            call: { ($0 as? Noise)?.play(0.2, -1, at: 0) }, keepsLeft: true, keepsOffset: true),
        Kept(
            label: "noise.add(0.3) の後の set(amp, pos)", prepare: { $0.add(0.3) },
            call: { ($0 as? Noise)?.set(0.2, -1); $0.play() }, keepsLeft: true, keepsOffset: true),
        Kept(
            label: "osc.pan(-1) の後の play(freq, amp)", prepare: { $0.pan(-1) },
            call: { ($0 as? Oscillator)?.play(440, 0.5) }, keepsLeft: true, keepsOffset: false),
        Kept(
            label: "osc.pan(-1) の後の play(freq, amp, at:)", prepare: { $0.pan(-1) },
            call: { ($0 as? Oscillator)?.play(440, 0.5, at: 0) }, keepsLeft: true, keepsOffset: false),
        Kept(
            label: "osc.pan(-1) の後の play(freq, amp, add)", prepare: { $0.pan(-1) },
            call: { ($0 as? Oscillator)?.play(440, 0.5, 0.3) }, keepsLeft: true, keepsOffset: true),
        Kept(
            label: "osc.pan(-1) の後の play(freq, amp, add, at:)", prepare: { $0.pan(-1) },
            call: { ($0 as? Oscillator)?.play(440, 0.5, 0.3, at: 0) }, keepsLeft: true, keepsOffset: true),
        Kept(
            label: "osc.pan(-1) の後の set(freq, amp)", prepare: { $0.pan(-1) },
            call: { ($0 as? Oscillator)?.set(440, 0.5); $0.play() }, keepsLeft: true, keepsOffset: false),
        Kept(
            label: "osc.add(0.3) の後の set(freq, amp, pos)", prepare: { $0.add(0.3) },
            call: { ($0 as? Oscillator)?.set(440, 0.5, -1); $0.play() }, keepsLeft: true, keepsOffset: true),
    ]

    /// 左へ寄せたまま・オフセットを保ったままかを、寄り切った最後のフレームで見る。
    private func expectKept(_ sound: Stereo, _ form: Kept, _ when: String) {
        let left = lastFrame(sound.left)
        let right = loudest(lastFrame(sound.right))
        if form.keepsLeft {
            #expect(right < 1e-6, "\(form.label) (\(when)): 右 \(right)")
            #expect(loudest(left) > 0.1, "\(form.label) (\(when)): 左 \(loudest(left))")
        }
        if form.keepsOffset {
            #expect(mean(left) > 0.2, "\(form.label) (\(when)): 平均 \(mean(left))")
        } else {
            #expect(abs(mean(left)) < 0.05, "\(form.label) (\(when)): 平均 \(mean(left))")
        }
    }

    private func source(_ form: Kept, _ stage: SynthStage) -> SynthSource {
        form.label.hasPrefix("noise") ? WhiteNoise(stage: stage) : SinOsc(stage: stage)
    }

    @Test("引数を省いた形は、省いた値 (定位・オフセット) を今のまま保つ。鳴らす前に決めた値", arguments: 0..<12)
    func omittedValuesAreKept(_ index: Int) throws {
        let form = Self.kept[index]
        let sound = try heard { stage in
            let made = source(form, stage)
            form.prepare(made)
            form.call(made)
        }
        expectKept(sound, form, "鳴らす前")
    }

    @Test("鳴っている最中と、止めた後に呼んでも、省いた値は今のまま保つ", arguments: 0..<12)
    func omittedValuesAreKeptWhilePlayingAndAfterStop(_ index: Int) throws {
        let form = Self.kept[index]
        // 鳴っている最中: 先に決めた値で鳴らしておき、6 フレーム目に省いた形を呼ぶ
        var playing: SynthSource?
        let during = try heard(
            frames: 18,
            act: { frame in
                if frame == 6, let playing { form.call(playing) }
            }
        ) { stage in
            let made = source(form, stage)
            form.prepare(made)
            made.play()
            playing = made
        }
        expectKept(during, form, "鳴っている最中")
        // 止めた後: 鳴らして止め、省いた形で鳴らし直す
        var stopped: SynthSource?
        let after = try heard(
            frames: 18,
            act: { frame in
                if frame == 4 { stopped?.stop() }
                if frame == 8, let stopped { form.call(stopped) }
            }
        ) { stage in
            let made = source(form, stage)
            form.prepare(made)
            made.play()
            stopped = made
        }
        expectKept(after, form, "止めた後")
    }

    @Test("作った直後に省いた形で鳴らすと、省いた値は既定 (オフセット 0・定位 中央) のまま")
    func omittedValuesStartAtTheDefaults() throws {
        let osc = try heard { SinOsc(stage: $0).play(440, 0.5) }
        #expect(mismatch(osc.left, osc.right) == nil, "中央なら左右は同じ")
        #expect(abs(mean(osc.left)) < 0.01, "平均 \(mean(osc.left))")
        let noise = try heard { WhiteNoise(stage: $0).play(0.5) }
        #expect(mismatch(noise.left, noise.right) == nil)
        // 引数なしの play() も、作った直後なら同じ既定で鳴る
        let bare = try heard { stage in
            let made = SinOsc(stage: stage)
            made.freq(440)
            made.amp(0.5)
            made.play()
        }
        #expect(mismatch(bare, osc) == nil)
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
            Delay(stage: stage).process(osc, 2, 0.25)
        }
        #expect(mismatch(ignored, untouched) == nil)
        #expect(nanNotices.lines.count == 1, "\(nanNotices.lines)")
    }

    // MARK: - 2 引数の Delay.process (#3719 の 2026-11-13 の決定 2)

    /// 440 Hz の正弦を鳴らして `route` でディレイへ通し、`frames` フレーム描かせる。
    private func delayed(
        frames: Int = 80, notices: NoticeLog = NoticeLog(),
        _ route: @escaping (Delay, SinOsc) -> Void
    ) throws -> Stereo {
        try heard(frames: frames, notices: notices) { stage in
            let osc = SinOsc(stage: stage)
            osc.play(440, 0.5)
            route(Delay(stage: stage), osc)
        }
    }

    @Test("Delay.process の 2 引数の形は、遅れも上限と同じ値にし、前に決めた遅れを上書きする")
    func twoArgumentProcessSetsTheDelayToTheMaximum() throws {
        let two = try delayed { $0.process($1, 1) }
        let same = try delayed { $0.process($1, 1, 1) }
        let quarter = try delayed { $0.process($1, 1, 0.25) }
        #expect(mismatch(two, same) == nil)
        #expect(mismatch(two, quarter) != nil, "前の振る舞い (既定の 0.25 秒のまま) と区別できる")
        // 先に time(_:) で決めた遅れも、2 引数の形が上書きする (手本と同じ)
        let overwritten = try delayed { delay, osc in
            delay.time(0.1)
            delay.process(osc, 1)
        }
        #expect(mismatch(overwritten, same) == nil)
        // 後に time(_:) を呼べば、上限より短い遅れにできる
        let shortened = try delayed { delay, osc in
            delay.process(osc, 1)
            delay.time(0.25)
        }
        #expect(mismatch(shortened, quarter) == nil)
    }

    @Test("Delay.process の 2 引数の上限は 0〜5 秒へ丸めて遅れもその値にし、数でない値は上限も遅れも変えない")
    func twoArgumentProcessClampsAndIgnores() throws {
        let notices = NoticeLog()
        let clamped = try delayed(frames: 30, notices: notices) { $0.process($1, 9) }
        let atFive = try delayed(frames: 30) { $0.process($1, 5, 5) }
        #expect(mismatch(clamped, atFive) == nil)
        #expect(notices.lines.count == 1, "\(notices.lines)")
        #expect(notices.lines.first?.hasPrefix("process() takes a maxDelayTime") == true, "\(notices.lines)")

        let nanNotices = NoticeLog()
        let ignored = try delayed(frames: 30, notices: nanNotices) { $0.process($1, .nan) }
        let plain = try delayed(frames: 30) { $0.process($1) }
        #expect(mismatch(ignored, plain) == nil)
        #expect(nanNotices.lines.count == 1, "\(nanNotices.lines)")
    }
}
