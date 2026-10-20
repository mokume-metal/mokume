// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import Synchronization
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 診断へ出た知らせ。
final class NoticeLog: Sendable {
    private let store = Mutex<[String]>([])
    func append(_ line: String) { store.withLock { $0.append(line) } }
    var lines: [String] { store.withLock { $0 } }
}

/// 作って捨てる書き方 (#2763)。スケッチを走らせず (GPU は要らない)、持ち主のいないステージを検査が
/// 回す: フレームごとに `supply()` を呼び、その後で `draw()` の代わりに音を作り、1 フレームぶんの標本を
/// 機材に出さない流れから取る。
///
/// **数は上限の定数を写さず、64 と書く** (#2285)。
@Suite("合成した音: 作って捨てる", .serialized)
struct SynthDiscardTests {
    private static let perFrame = 800
    /// 包絡 (0.005・0.05・0.6・0.3 秒) の長さ (標本)。
    private static let hitLength = 17_040

    /// 持ち主のいないステージを、機材に出さない流れで鳴らす形にして返す。
    private func makeStage(_ notices: NoticeLog) throws -> (SynthStage, SoundFlow, RackPlayer) {
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        let stage = SynthStage(
            owner: nil, flow: flow, now: { 0 },
            warn: { notices.append($0) })
        let player = try #require(RackPlayer(flow: flow, rack: stage.rack))
        stage.pace = .speaker(player)
        return (stage, flow, player)
    }

    /// 1 回の `draw()` で作って捨てる音。`osc` はこの関数が返ると手放される。
    private func hit(_ stage: SynthStage, _ env: Env, _ freq: Float) -> Bool {
        let osc = TriOsc(stage: stage)
        osc.freq(freq)
        env.play(osc, 0.005, 0.05, 0.6, 0.3)
        return osc.node != nil
    }

    /// 毎フレーム `hit(440)` を呼んで、出口の標本・音が作れた数・知らせ・同時に埋まった数の最大を返す。
    private func run(frames: Int = 600) throws -> (
        heard: Stereo, made: Int, notices: [String], peakOccupied: Int
    ) {
        let notices = NoticeLog()
        let (stage, flow, player) = try makeStage(notices)
        defer { player.leave() }
        let env = Env()
        var heard = Stereo()
        var made = 0
        var peakOccupied = 0
        for _ in 0..<frames {
            stage.supply()
            if hit(stage, env, 440) { made += 1 }
            peakOccupied = max(peakOccupied, stage.rack.occupiedCount)
            let piece = try renderStereo(flow, Self.perFrame)
            heard.left += piece.left
            heard.right += piece.right
        }
        stage.close()
        return (heard, made, notices.lines, peakOccupied)
    }

    /// 1 つだけ鳴らしたときの出口 (`length` 標本)。
    private func single(length: Int) throws -> Stereo {
        let rack = SynthRack(sampleRate: 48_000)
        let node = try #require(rack.addSource(.wave(.triangle)))
        rack.set(node.id, .frequency, 440)
        rack.set(node.id, .attack, 0.005)
        rack.set(node.id, .sustain, 0.05)
        rack.set(node.id, .level, 0.6)
        rack.set(node.id, .release, 0.3)
        rack.post(SynthCommand(op: .trigger, node: UInt8(node.id)))
        rack.post(SynthCommand(op: .play, node: UInt8(node.id)))
        return render(rack, length)
    }

    @Test("作って捨てる音を 600 フレーム続けても、毎回鳴り、上限を使い切らず、容量の知らせも出ない")
    func discardingEveryFrameNeverRunsOut() throws {
        let first = try run()
        #expect(first.made == 600, "作れなかった音がある")
        #expect(first.notices.isEmpty, "知らせ: \(first.notices)")
        // 同時に生きているのは、0.355 秒 × 60 ≈ 22 個と、返す番号を受け取るまでの数フレームぶん
        #expect(first.peakOccupied < 40, "同時に埋まった数: \(first.peakOccupied)")
        #expect(first.peakOccupied > 20)

        // 出口は、1 つずつ別に鳴らした音を、始めた標本の位置で足したものと一致する。
        // どの音も欠けず (変更前は 65 個目から欠ける)、立ち上がりが出口に出ている
        let one = try single(length: Self.hitLength + 1_000)
        let total = 600 * Self.perFrame
        var expected = [Float](repeating: 0, count: total)
        for frame in 0..<600 {
            let start = frame * Self.perFrame
            for index in 0..<min(one.left.count, total - start) {
                expected[start + index] += one.left[index]
            }
        }
        #expect(first.heard.left.count == total)
        let worst = zip(first.heard.left, expected).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-4, "最大の食い違い \(worst)")
        // 最後の音 (599 フレーム目) の立ち上がりも出ている
        let lastStart = 599 * Self.perFrame
        #expect(first.heard.left[lastStart..<(lastStart + 400)].map { abs($0) }.max() ?? 0 > 0.05)

        // 2 回回すと、1 標本まで一致する (ADR-0025 の水準 2)
        let second = try run()
        #expect(mismatch(first.heard, second.heard) == nil)
    }

    @Test("鳴らしたまま手放した音は数から外れず、64 個を越えると、作れない音は鳴らず、知らせは 1 度だけ")
    func playingSoundsLetGoOfStillCount() throws {
        let notices = NoticeLog()
        let (stage, flow, player) = try makeStage(notices)
        defer { player.leave() }

        // 包絡なしで鳴らしたまま手放した音は、鳴り続けて置き場を返さない
        func playAndDrop() {
            let osc = SinOsc(stage: stage)
            osc.play(440, 0.001)
        }
        for _ in 0..<64 { playAndDrop() }
        stage.supply()
        _ = try renderStereo(flow, 4_800)
        stage.supply()
        var extra: [TriOsc] = []
        for _ in 0..<3 {
            let osc = TriOsc(stage: stage)
            osc.play(330, 0.1)
            extra.append(osc)
        }
        #expect(extra.allSatisfy { $0.node == nil })
        #expect(notices.lines.count == 1)
        stage.close()
    }

    @Test("持ち続けた 65 個目は鳴らず、知らせは 1 度。1 つ手放して消えれば、その置き場を次の音が使える")
    func sixtyFiveHeldSoundsMakeTheLastOneSilent() throws {
        let notices = NoticeLog()
        let (stage, flow, player) = try makeStage(notices)
        defer { player.leave() }

        var held: [TriOsc] = []
        for _ in 0..<65 { held.append(TriOsc(stage: stage)) }
        #expect(held.prefix(64).allSatisfy { $0.node != nil })
        #expect(held[64].node == nil)
        #expect(notices.lines.count == 1)
        #expect(notices.lines.allSatisfy { $0.contains("64") })

        // 1 つ手放す (鳴らしていないので、すぐ戻る)
        held.removeFirst()
        stage.supply()
        _ = try renderStereo(flow, 800)
        stage.supply()
        let next = TriOsc(stage: stage)
        #expect(next.node != nil)
        #expect(TriOsc(stage: stage).node == nil)
        stage.close()
    }
}
