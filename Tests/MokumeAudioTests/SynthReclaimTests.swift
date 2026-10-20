// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import Synchronization
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 手放して鳴り終えた音源の置き場が戻ること (#2763)。GPU は要らない。
///
/// **数は上限の定数を写さず、64 と書く** (#2285)。固定の時計で、ラックの出口の標本と置き場の数を読む。
@Suite("合成のラック: 手放した音源の置き場", .serialized)
struct SynthReclaimTests {
    private static let rate = 48_000.0
    /// 包絡 (0.005・0.05・0.6・0.3 秒) の長さ。立ち上がりから無音までの標本の数 (0.355 秒)。
    private static let hitLength = 17_040

    private func makeRack() -> SynthRack { SynthRack(sampleRate: Self.rate) }

    /// 包絡をかけて鳴らす (`Env.play(osc, 0.005, 0.05, 0.6, 0.3)` と同じ操作)。
    private func hit(_ rack: SynthRack, _ node: RackNode, freq: Float = 440) {
        rack.set(node.id, .frequency, freq)
        rack.set(node.id, .attack, 0.005)
        rack.set(node.id, .sustain, 0.05)
        rack.set(node.id, .level, 0.6)
        rack.set(node.id, .release, 0.3)
        rack.post(SynthCommand(op: .trigger, node: UInt8(node.id)))
        rack.post(SynthCommand(op: .play, node: UInt8(node.id)))
    }

    /// 音量 0 で鳴らし続ける音源を `count` 個足して、置き場を埋める (出口には何も出さない)。
    private func fill(_ rack: SynthRack, _ count: Int) throws {
        for _ in 0..<count { try addSource(rack, .wave(.sine), [.amplitude: 0]) }
    }

    private func peak(_ samples: [Float]) -> Float { samples.map { abs($0) }.max() ?? 0 }

    // MARK: - 返る・返らない

    @Test("手放して包絡が終わった音源の置き場は、終わってから戻り、次の音源が使う")
    func aReleasedEnvelopedSourceReturnsItsSlotWhenItEnds() throws {
        let rack = makeRack()
        try fill(rack, 63)
        let short = try #require(rack.addSource(.wave(.sine)))
        hit(rack, short)
        #expect(rack.addSource(.wave(.sine)) == nil)

        rack.release(short.id)
        // 包絡の途中 (0.29 秒) まで鳴っていて、置き場はまだ戻らない
        _ = render(rack, 14_000)
        let still = render(rack, 1_000)
        #expect(peak(still.left) > 0.01, "手放しても、鳴っている音は切らない")
        #expect(rack.addSource(.wave(.sine)) == nil)

        // 終わった後
        _ = render(rack, 4_000)
        #expect(peak(render(rack, 800).left) == 0)
        let next = try #require(rack.addSource(.wave(.sine)))
        #expect(next.id == short.id)
        // 次の 65 個目は、また作れない
        #expect(rack.addSource(.wave(.sine)) == nil)
    }

    @Test("鳴らしたまま手放した音源は鳴り続け、置き場は戻らない")
    func aPlayingSourceStaysAfterItIsReleased() throws {
        let rack = makeRack()
        try fill(rack, 63)
        let osc = try addSource(rack, .wave(.sine), [.frequency: 440, .amplitude: 0.5])
        rack.release(osc.id)
        _ = render(rack, 96_000)
        #expect(peak(render(rack, 1_000).left) > 0.3)
        #expect(rack.addSource(.wave(.sine)) == nil)
    }

    @Test("止めて手放した音源も、鳴らさずに手放した音源も、消えれば置き場が戻る")
    func stoppedOrNeverPlayedSourcesReturn() throws {
        let rack = makeRack()
        try fill(rack, 62)
        let stopped = try addSource(rack, .wave(.sine), [.amplitude: 0.5])
        let unplayed = try addSource(rack, .wave(.sine), [.amplitude: 0.5], playing: false)
        #expect(rack.addSource(.wave(.sine)) == nil)

        _ = render(rack, 1_000)
        rack.post(SynthCommand(op: .stop, node: UInt8(stopped.id)))
        rack.release(stopped.id)
        rack.release(unplayed.id)
        // 止めた音は約 5 ミリ秒の時定数で消え、1e-6 まで近づいたら 0 に揃う (約 3400 標本)
        _ = render(rack, 5_000)
        let first = try #require(rack.addSource(.wave(.sine)))
        let second = try #require(rack.addSource(.wave(.sine)))
        #expect(Set([first.id, second.id]) == Set([stopped.id, unplayed.id]))
        #expect(rack.addSource(.wave(.sine)) == nil)
    }

    @Test("エフェクトは手放しても返らず、置き場は埋まったまま")
    func effectsAreNeverReturned() throws {
        let rack = makeRack()
        try fill(rack, 63)
        let reverb = try #require(rack.addReverb())
        rack.release(reverb.id)
        _ = render(rack, 4_000)
        #expect(rack.addSource(.wave(.sine)) == nil)
    }

    // MARK: - 引き継がない

    @Test("返った置き場を使う次の音源は、前の音源の入力の繋がりも出口の写しも引き継がない")
    func aReusedSlotInheritsNothing() throws {
        let rack = makeRack()
        let first = try addSource(rack, .wave(.sine), playing: false)
        let filter = try #require(rack.addFilter(.lowPass))
        rack.set(filter.id, .cutoff, 200)
        connect(rack, filter, to: [first])
        hit(rack, first)
        rack.release(first.id)
        _ = render(rack, Self.hitLength + 4_000)
        #expect(peak(first.meter.latest(1024)) == 0)

        // 音の側が置き場を返した後、主スレッドが受け取る前に、古い繋がり (前の音源の番号を含む) を
        // 載せ直す — 次の音源の `activate` がそれを断つ
        rack.setInputs(filter.id, rack.inputs(of: filter.id))
        let next = try #require(rack.addSource(.wave(.sine)))
        #expect(next.id == first.id)
        #expect(next.meter !== first.meter)
        #expect(peak(next.meter.latest(1024)) == 0)
        #expect(rack.inputs(of: filter.id) == 0)

        rack.set(next.id, .frequency, 10_000)
        rack.set(next.id, .amplitude, 0.5)
        rack.post(SynthCommand(op: .play, node: UInt8(next.id)))
        let heard = render(rack, 4_000)
        // 繋がっていれば、200 Hz の低域通過で 10 kHz は消える。直に出ている
        #expect(peak(heard.left.suffix(1_000)) > 0.2)
        #expect(peak(filter.meter.latest(1024)) < 1e-3)
    }

    @Test("エフェクトの入力の音源が返っても、エフェクトの尾は切れず、返さない場合と標本まで同じ")
    func anEffectKeepsItsTailAfterItsSourceIsReturned() throws {
        func play(releasing: Bool) throws -> Stereo {
            let rack = makeRack()
            let source = try addSource(rack, .wave(.sine), playing: false)
            let reverb = try #require(rack.addReverb())
            rack.set(reverb.id, .room, 0.9)
            connect(rack, reverb, to: [source])
            hit(rack, source)
            if releasing { rack.release(source.id) }
            return render(rack, pieces: Array(repeating: 800, count: 75))
        }
        let returned = try play(releasing: true)
        let kept = try play(releasing: false)
        #expect(mismatch(returned, kept) == nil)
        // 音源が鳴り終えた後 (17040 標本以降) にも、尾が出ている
        #expect(peak(Array(returned.left[20_000..<30_000])) > 1e-4)
    }

    @Test("エフェクトの入力が全部返った後に新しい音源を通しても、エフェクトの尾は消えない")
    func aNewInputDoesNotResetAnArmedEffect() throws {
        func play(releasing: Bool) throws -> Stereo {
            let rack = makeRack()
            let first = try addSource(rack, .wave(.sine), playing: false)
            let delay = try #require(rack.addDelay())
            rack.set(delay.id, .time, 0.2)
            rack.set(delay.id, .feedback, 0.6)
            connect(rack, delay, to: [first])
            hit(rack, first)
            if releasing { rack.release(first.id) }
            var heard = render(rack, pieces: Array(repeating: 800, count: 25))
            // 1 つ目が鳴り終えた (20000 標本) 後に、2 つ目を通す
            let second = try addSource(rack, .wave(.triangle), playing: false)
            rack.setInputs(delay.id, rack.inputs(of: delay.id) | (1 << UInt64(second.id)))
            hit(rack, second, freq: 660)
            let more = render(rack, pieces: Array(repeating: 800, count: 25))
            heard.left += more.left
            heard.right += more.right
            return heard
        }
        let returned = try play(releasing: true)
        let kept = try play(releasing: false)
        #expect(mismatch(returned, kept) == nil)
        #expect(peak(Array(returned.left[20_000..<40_000])) > 1e-3)
    }

    @Test("ノイズの種は作った順で決まるので、置き場を使い回しても、同じ順に作れば同じ音になる")
    func noiseSeedsFollowTheCreationOrder() throws {
        // 1 つ目のノイズが返って、2 つ目がその置き場 (0 番) を使う
        let reused = makeRack()
        let first = try addSource(reused, .noise(.white), playing: false)
        hit(reused, first)
        reused.release(first.id)
        _ = render(reused, Self.hitLength + 2_000)
        let second = try #require(reused.addSource(.noise(.white)))
        #expect(second.id == first.id)
        reused.post(SynthCommand(op: .play, node: UInt8(second.id)))
        let heardReused = render(reused, 4_000)

        // 返さずに、2 つ目が 1 番を使う
        let fresh = makeRack()
        _ = try addSource(fresh, .noise(.white), playing: false)
        let other = try addSource(fresh, .noise(.white))
        #expect(other.id == 1)
        let heardFresh = render(fresh, 4_000)

        #expect(mismatch(heardReused, heardFresh) == nil)
        #expect(peak(heardReused.left) > 0.05)
    }

    @Test("返す番号は、受け取る前に何度返っても溢れず、番号ごとに 1 度ずつ置き場が戻る")
    func everySlotCanReturnAtOnce() throws {
        let rack = makeRack()
        var nodes: [RackNode] = []
        for _ in 0..<64 { nodes.append(try addSource(rack, .wave(.sine), playing: false)) }
        #expect(rack.addSource(.wave(.sine)) == nil)
        for node in nodes { rack.release(node.id) }
        _ = render(rack, 100)
        // 全部を一度に受け取って、また全部使える
        var ids: Set<Int> = []
        for _ in 0..<64 { ids.insert(try #require(rack.addSource(.wave(.sine))).id) }
        #expect(ids == Set(0..<64))
        #expect(rack.addSource(.wave(.sine)) == nil)
    }
}
