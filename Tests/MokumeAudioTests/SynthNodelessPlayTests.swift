// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeAudio

/// 節を持てなかった合成音と、閉じたステージの合成音の ``SynthSource/isPlaying`` (#3964)。GPU は要らない。
///
/// 持ち主のいないステージを固定の時計 (60 fps) で回す。**数は上限の定数を写さず、64 と書く** (#2285)。
@Suite("合成した音: 鳴らせない音の isPlaying", .serialized)
struct SynthNodelessPlayTests {
    private func makeStage(_ notices: NoticeLog) -> SynthStage {
        let stage = SynthStage(owner: nil, flow: nil, now: { 0 }, warn: { notices.append($0) })
        stage.pace = .frames(perSecond: 60, origin: 0)
        return stage
    }

    private func supply(_ stage: SynthStage, _ frames: Range<Int>) {
        for frame in frames {
            stage.frame = frame
            stage.supply()
        }
    }

    /// 鳴らす API を 1 つずつ。`at:` の形は 0.05 秒 (3 フレーム) 先へ予約する。
    private static let plays: [(label: String, play: (SynthSource) -> Void)] = [
        ("play()", { $0.play() }),
        ("play(at:)", { $0.play(at: 0.05) }),
        ("Oscillator.play(_:_:)", { ($0 as? Oscillator)?.play(440, 0.5) }),
        ("Oscillator.play(_:_:at:)", { ($0 as? Oscillator)?.play(440, 0.5, at: 0.05) }),
        ("Noise.play(_:)", { ($0 as? Noise)?.play(0.5) }),
        ("Noise.play(_:at:)", { ($0 as? Noise)?.play(0.5, at: 0.05) }),
        ("Env.play", { Env().play($0, 0.01, 0.2, 0.7, 0.1) }),
        ("Env.play(at:)", { Env().play($0, 0.01, 0.2, 0.7, 0.1, at: 0.05) }),
    ]

    /// 置き場 (64) を埋めて、65 個目の音源を作る。`noise` ならノイズ、でなければ正弦波。
    private func fill(_ stage: SynthStage, noise: Bool) -> (held: [SinOsc], extra: SynthSource) {
        let held = (0..<64).map { _ in SinOsc(stage: stage) }
        let extra: SynthSource = noise ? WhiteNoise(stage: stage) : SinOsc(stage: stage)
        return (held, extra)
    }

    @Test("置き場が埋まって節を持てなかった 65 個目は、どの鳴らす API の後も isPlaying が false で、同じ時点で無音", arguments: 0..<8)
    func aNodelessSourceDoesNotClaimToPlay(_ index: Int) {
        let call = Self.plays[index]
        let notices = NoticeLog()
        let stage = makeStage(notices)
        let (held, extra) = fill(stage, noise: call.label.hasPrefix("Noise"))
        #expect(held.allSatisfy { $0.node != nil })
        #expect(extra.node == nil)
        call.play(extra)
        #expect(!extra.isPlaying, "\(call.label)")
        // 予約の時刻 (0.05 秒) を過ぎるまで回し、同じ時点の isPlaying と音を見る
        supply(stage, 0..<8)
        #expect(!extra.isPlaying && extra.peak == 0, "\(call.label): \(extra.peak)")
        // 解析を始める印 (isActive) も立てない (呼ぶ側が isPlaying だけ戻して isActive を立てる退行を見る)
        #expect(!extra.isActive, "\(call.label)")
        // stop() の後も false
        extra.stop()
        #expect(!extra.isPlaying && !extra.isActive)
        stage.close()
        // 置き場が埋まった知らせは、これまでどおり 1 度だけで、文面も同じ
        #expect(notices.lines.count == 1, "\(notices.lines)")
        #expect(notices.lines.first?.hasPrefix("No more synthesized sounds can be created: a sketch holds at most 64 ") == true)
    }

    @Test("節を持つ 64 個目までは、これまでどおり isPlaying が true になって鳴る", arguments: 0..<8)
    func aSourceWithANodeStillPlays(_ index: Int) {
        let call = Self.plays[index]
        let notices = NoticeLog()
        let stage = makeStage(notices)
        let isNoise = call.label.hasPrefix("Noise")
        let held = (0..<63).map { _ in SinOsc(stage: stage) }
        let last: SynthSource = isNoise ? WhiteNoise(stage: stage) : SinOsc(stage: stage)
        #expect(last.node != nil && held.count == 63)
        call.play(last)
        #expect(last.isPlaying && last.isActive, "\(call.label)")
        supply(stage, 0..<8)
        #expect(last.isPlaying && last.peak > 0.1, "\(call.label): \(last.peak)")
        stage.close()
        #expect(notices.lines.isEmpty, "\(notices.lines)")
    }

    @Test("ステージが閉じた後の鳴らす API は、isPlaying を変えない (止まっていた音は false のまま)", arguments: 0..<8)
    func playingAfterTheStageClosedDoesNotClaimToPlay(_ index: Int) {
        let call = Self.plays[index]
        let notices = NoticeLog()
        let stage = makeStage(notices)
        let source: SynthSource =
            call.label.hasPrefix("Noise") ? WhiteNoise(stage: stage) : SinOsc(stage: stage)
        supply(stage, 0..<2)
        stage.close()
        let before = stage.rack.rendered
        call.play(source)
        #expect(!source.isPlaying && !source.isActive, "\(call.label)")
        #expect(source.peak == 0)
        #expect(stage.rack.rendered == before)
        #expect(notices.lines.isEmpty, "\(notices.lines)")
    }

    @Test("閉じる前に鳴らしていた音の isPlaying は、閉じた後も true のまま (stop() で false)")
    func aSoundPlayingWhenTheStageClosedKeepsItsFlag() {
        let stage = makeStage(NoticeLog())
        let osc = SinOsc(stage: stage)
        osc.play()
        supply(stage, 0..<2)
        stage.close()
        #expect(osc.isPlaying)
        osc.stop()
        #expect(!osc.isPlaying)
    }
}
