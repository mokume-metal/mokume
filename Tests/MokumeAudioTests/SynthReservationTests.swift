// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import Testing

@testable import MokumeAudio

/// 合成音の発音を、音の時計の秒で予約できること (#2465)。GPU は要らない。
///
/// 描くのは純粋な処理なので、ラックの出口の標本を標本単位で読む。**数は定数を写さず、数字で書く**
/// (#2285): 48 kHz で 0.125 秒 = 6000 標本、60 fps の 1 フレーム = 800 標本。
@Suite("合成した音: 発音の予約", .serialized)
struct SynthReservationTests {
    private static let rate = 48_000.0
    /// 0.125 秒 (120 BPM の 16 分音符) の標本の数。フレーム (800 標本) の整数倍ではない (7.5 フレーム)。
    private static let step = 6000

    private func makeRack() -> SynthRack { SynthRack(sampleRate: Self.rate) }

    /// `Env.play(osc, 0.002, 0.03, 0.7, 0.1)` と同じ操作 (値 4・包絡・鳴らす)。
    private func envelope(
        _ node: RackNode, at position: Int, freq: Float? = nil
    ) -> [SynthCommand] {
        let id = UInt8(node.id)
        func value(_ param: SynthParam, _ number: Float) -> SynthCommand {
            SynthCommand(
                op: .set, node: id, param: param, bits: UInt64(number.bitPattern), at: position)
        }
        var commands: [SynthCommand] = []
        if let freq { commands.append(value(.frequency, freq)) }
        commands += [
            value(.attack, 0.002), value(.sustain, 0.03), value(.level, 0.7), value(.release, 0.1),
            SynthCommand(op: .trigger, node: id, at: position),
            SynthCommand(op: .play, node: id, at: position),
        ]
        return commands
    }

    /// 三角波の音源 1 つ (鳴らさない・音量は既定)。
    private func makeVoice(_ rack: SynthRack) throws -> RackNode {
        try addSource(rack, .wave(.triangle), [.frequency: 440], playing: false)
    }

    /// 16 分音符で `count` 回、位置 `step × k` (k = 1…count) へ予約して、`pieces` の区切りで描かせる。
    private func reserved(count: Int = 16, pieces: [Int]) throws -> [Float] {
        let rack = makeRack()
        let voice = try makeVoice(rack)
        for k in 1...count {
            #expect(rack.postReservation(envelope(voice, at: Self.step * k)))
        }
        return render(rack, pieces: pieces).left
    }

    /// 区切り `size` の列で、`total` 標本ぶん (最後の区切りは端数)。
    private func pieces(of size: Int, total: Int) -> [Int] {
        var result = [Int](repeating: size, count: total / size)
        if total % size > 0 { result.append(total % size) }
        return result
    }

    /// 同じ音を、予約を使わず、`step` ごとの区切りの頭に**すぐ**鳴らして作る参照 (区切りの頭 = 予約の位置)。
    /// `source` なら、定位を掛ける前の音源の出口 (ステージの音の写しと同じもの) を返す。
    private func immediate(count: Int = 16, source: Bool = false) throws -> [Float] {
        let rack = makeRack()
        let voice = try makeVoice(rack)
        var heard: [Float] = []
        func piece() {
            if source {
                _ = render(rack, Self.step)
                heard += voice.meter.latest(Self.step)
            } else {
                heard += render(rack, Self.step).left
            }
        }
        piece()
        for _ in 1...count {
            for command in envelope(voice, at: 0) { rack.post(command) }
            piece()
        }
        return heard
    }

    private func firstSound(_ samples: [Float]) -> Int? {
        samples.firstIndex { $0 != 0 }
    }

    // MARK: - 条件 1: 標本の精度

    @Test("16 分音符の予約は、立ち上がりがフレームの格子ではなく 6000 × k 標本の頭に来て、すぐ鳴らした音と標本まで一致する")
    func reservationsStartAtTheExactSample() throws {
        let total = Self.step * 17
        // フレーム (800 標本) の区切りで描かせる。6000 は 800 の倍数ではない (6400 の側へ寄らない)
        let heard = try reserved(pieces: pieces(of: 800, total: total))
        #expect(heard.count == total)
        #expect(heard.prefix(Self.step).allSatisfy { $0 == 0 }, "予約の位置より前は無音")
        let onset = try #require(firstSound(heard))
        #expect((6000...6001).contains(onset), "最初の立ち上がり: \(onset)")
        #expect(onset % 800 != 0)

        let reference = try immediate()
        #expect(mismatch(heard, reference) == nil)
        #expect(heard.map { abs($0) }.max() ?? 0 > 0.1, "全部 0 で一致していては意味が無い")

        // 2 回描いても同じ標本 (ADR-0025 の水準 2)
        let again = try reserved(pieces: pieces(of: 800, total: total))
        #expect(mismatch(again, heard) == nil)
    }

    // MARK: - 条件 2: 区切りによらない

    @Test("音の側の区切りが 512・441・128・4800 標本でも、予約した標本は変わらない")
    func theBlockSizeDoesNotMoveTheOnset() throws {
        let total = Self.step * 17
        let base = try reserved(pieces: pieces(of: 800, total: total))
        for size in [512, 441, 128, 4800, 1_000_000] {
            let heard = try reserved(pieces: pieces(of: size, total: total))
            #expect(mismatch(heard, base) == nil, "区切り \(size)")
        }
    }

    @Test("区切りの途中で予約が来ても (描かせている最中に頼んでも)、予約した標本から効く")
    func aReservationMadeWhileRenderingStartsAtItsSample() throws {
        let total = 20_000
        let rack = makeRack()
        let voice = try makeVoice(rack)
        // 441 標本ごとに描かせ、1323 標本を描いた後 (区切りの途中の位置 10000 へ) 予約する
        var heard: [Float] = []
        for index in 0..<(total / 441 + 1) {
            if index == 3 { for command in envelope(voice, at: 10_000) { rack.post(command) } }
            heard += render(rack, 441).left
        }
        let atStart = makeRack()
        let other = try makeVoice(atStart)
        for command in envelope(other, at: 10_000) { atStart.post(command) }
        let expected = render(atStart, pieces: pieces(of: 441, total: 441 * (total / 441 + 1))).left
        #expect(mismatch(heard, expected) == nil)
        #expect(try #require(firstSound(heard)) >= 10_000)
    }

    @Test("同じ位置の予約は頼んだ順に効き、位置の順に並べ替えて効く")
    func reservationsApplyInOrderOfPositionThenRequest() throws {
        func run(_ order: [(position: Int, freq: Float)]) throws -> [Float] {
            let rack = makeRack()
            let voice = try addSource(rack, .wave(.sine), [.amplitude: 0.5], playing: true)
            for entry in order {
                rack.postReservation([
                    SynthCommand(
                        op: .set, node: UInt8(voice.id), param: .frequency,
                        bits: UInt64(entry.freq.bitPattern), at: entry.position)
                ])
            }
            return render(rack, pieces: pieces(of: 441, total: 3000)).left
        }
        // 同じ位置は、後に頼んだ値が最後に残る
        let late = try run([(1000, 220), (1000, 880)])
        let early = try run([(1000, 880), (1000, 220)])
        #expect(mismatch(late, early) != nil)
        // 位置の順: 頼んだ順が逆でも、位置が先のほうが先に効く
        let sorted = try run([(1000, 220), (2000, 880)])
        let swapped = try run([(2000, 880), (1000, 220)])
        #expect(mismatch(sorted, swapped) == nil)
    }

    // MARK: - 条件 4: 過去

    @Test("今の位置より前の予約は、次に作る標本の頭で鳴らす")
    func aPastPositionPlaysAtTheNextSample() throws {
        let rack = makeRack()
        let voice = try makeVoice(rack)
        var heard = render(rack, 1000).left
        // 位置 500 は、もう過ぎている
        #expect(rack.postReservation(envelope(voice, at: 500)))
        heard += render(rack, 3000).left

        let reference = makeRack()
        let other = try makeVoice(reference)
        var expected = render(reference, 1000).left
        for command in envelope(other, at: 0) { reference.post(command) }
        expected += render(reference, 3000).left
        #expect(mismatch(heard, expected) == nil)
        #expect(try #require(firstSound(heard)) >= 1000)
    }

    // MARK: - 条件 5: 置き場

    @Test("置き場が埋まったら、その予約をまとまりごと捨てて数え、置き場に入った予約だけが鳴る")
    func aFullStoreDropsWholeReservations() throws {
        // 1 回の予約は 6 操作。2048 ÷ 6 = 341 回で 2046 操作、残り 2 操作では次の 1 回が入らない
        func heard(requests: Int) throws -> (samples: [Float], dropped: Int) {
            let rack = makeRack()
            let voice = try makeVoice(rack)
            for k in 1...requests { rack.postReservation(envelope(voice, at: 10_000 + 20 * k)) }
            return (render(rack, pieces: pieces(of: 4096, total: 30_000)).left, rack.droppedReservations)
        }
        let over = try heard(requests: 400)
        let exact = try heard(requests: 341)
        #expect(over.dropped == 400 - 341)
        #expect(exact.dropped == 0)
        // 捨てた 59 回は、音にも値にも影響しない (一部だけ効いて、包絡の値だけ変わった音も無い)
        #expect(mismatch(over.samples, exact.samples) == nil)
        #expect(over.samples.map { abs($0) }.max() ?? 0 > 0.1)
    }

    @Test("効いて空いたぶんには、また予約できる")
    func firedReservationsFreeTheirRoom() throws {
        let rack = makeRack()
        let voice = try makeVoice(rack)
        for k in 1...341 { rack.postReservation(envelope(voice, at: 1000 + 10 * k)) }
        _ = render(rack, 5000)
        #expect(rack.droppedReservations == 0)
        // 全部が効いて空いた。もう 341 回予約しても、捨てられない
        for k in 1...341 { rack.postReservation(envelope(voice, at: 6000 + 10 * k)) }
        _ = render(rack, 5000)
        #expect(rack.droppedReservations == 0)
    }

    @Test("捨てるまとまりの続きが別の取り出しで届いても、そのまとまりだけを捨て、続く操作を取り違えない")
    func aDroppedReservationSplitAcrossDrainsSkipsOnlyItself() throws {
        let rack = makeRack()
        let voice = try makeVoice(rack)
        // 置き場を埋める (2046 操作。位置は遠く)
        for k in 1...341 { rack.postReservation(envelope(voice, at: 1_000_000 + k)) }
        _ = render(rack, 100)

        // まとまりの先頭と 2 つ目だけを載せて描かせ、残りを後から載せる (主スレッドが載せている最中に、
        // 音の側が取り出したときと同じ)
        var group = envelope(voice, at: 50_000)
        group[0].follow = UInt8(group.count - 1)
        rack.post(group[0])
        rack.post(group[1])
        _ = render(rack, 100)
        for command in group.dropFirst(2) { rack.post(command) }
        // 続く、まとまりでない操作 (すぐ鳴らす) は捨てられない
        rack.post(SynthCommand(op: .play, node: UInt8(voice.id)))
        _ = render(rack, 60_000)
        #expect(rack.droppedReservations == 1)
        // 鳴り続けている: 捨てたまとまりの包絡 (0.132 秒で終わる) は始まっていない
        #expect(render(rack, 2_000).left.map { abs($0) }.max() ?? 0 > 0.1)
    }

    // MARK: - 置き場を返さない

    @Test("先の予約を待つ音源は、手放しても予約の位置に着いて鳴り終えるまで置き場を返さない")
    func aSourceWithAReservationIsNotReturnedEarly() throws {
        let rack = makeRack()
        for _ in 0..<63 { try addSource(rack, .wave(.sine), [.amplitude: 0]) }
        let voice = try makeVoice(rack)
        rack.postReservation(envelope(voice, at: 20_000))
        // 鳴らさず手放す。ふつうなら、すぐ戻る (鳴っていない)
        rack.release(voice.id)
        _ = render(rack, 10_000)
        #expect(rack.addSource(.wave(.sine)) == nil, "予約が残っている間は、置き場を返さない")

        let heard = render(rack, 20_000).left
        #expect(try #require(firstSound(heard)) >= 10_000 && heard.map { abs($0) }.max() ?? 0 > 0.1)
        // 鳴り終えれば返る
        _ = render(rack, 10_000)
        let next = try #require(rack.addSource(.wave(.sine)))
        #expect(next.id == voice.id)
    }

    // MARK: - 音の時計 (ステージ)

    /// 持ち主のいないステージを固定の時計 (60 fps) で回す。
    private func makeStage(_ notices: NoticeLog = NoticeLog()) -> SynthStage {
        let stage = SynthStage(owner: nil, flow: nil, now: { 0 }, warn: { notices.append($0) })
        stage.pace = .frames(perSecond: 60, origin: 0)
        return stage
    }

    @Test("固定の時計 (60 fps) では、frameCount が 121 のフレーム (0 始まりの 120) で音の時計が 2.0 を返す")
    func theSoundClockFollowsTheFrames() {
        let stage = makeStage()
        let osc = SinOsc(stage: stage)
        #expect(stage.soundSeconds == 0, "setup() の中")
        for frame in 0...120 {
            stage.frame = frame
            stage.supply()
        }
        #expect(stage.soundSeconds == 2.0)
        #expect(osc.sampleRate == 48_000)
        stage.close()
    }

    @Test("ステージ越しの予約: 書き出しで、立ち上がりが 6000 × k 標本の頭に来る (すぐ鳴らした音と標本まで一致)")
    func reservingThroughTheApiLandsOnTheSample() {
        let stage = makeStage()
        let osc = TriOsc(stage: stage)
        let env = Env()
        for k in 1...16 { env.play(osc, 0.002, 0.03, 0.7, 0.1, at: 0.125 * Double(k)) }
        var heard: [Float] = []
        for frame in 0..<(Int(Double(Self.step * 17) / 800.0) + 1) {
            stage.frame = frame
            stage.supply()
            if frame > 0, let node = osc.node { heard += node.meter.latest(800) }
        }
        stage.close()
        #expect(heard.prefix(Self.step).allSatisfy { $0 == 0 })
        #expect((6000...6001).contains(firstSound(heard) ?? -1), "\(firstSound(heard) ?? -1)")
        #expect(heard.count >= 17 * Self.step - 800)
        // 参照はすぐ鳴らした音 (予約を使わない)。ステージが進めた長さまで比べる
        let reference = (try? immediate(source: true)) ?? []
        #expect(mismatch(Array(heard.prefix(16 * Self.step)), Array(reference.prefix(16 * Self.step))) == nil)
    }

    @Test("数でない値・無限の値の at は、呼び出し全体を無視して 1 度だけ知らせる (値も鳴らす操作も効かない)")
    func nonFiniteAtIsIgnoredOnceEverywhere() {
        let notices = NoticeLog()
        let stage = makeStage(notices)
        let osc = SinOsc(stage: stage)
        let env = Env()
        env.play(osc, 0.002, 0.03, 0.7, 0.1, at: .nan)
        env.play(osc, 0.002, 0.03, 0.7, 0.1, at: .infinity)
        osc.play(at: .nan)
        osc.play(440, 0.5, at: .infinity)
        let noise = WhiteNoise(stage: stage)
        noise.play(0.5, at: .nan)
        #expect(!osc.isPlaying && !noise.isPlaying)
        for frame in 0..<10 {
            stage.frame = frame
            stage.supply()
        }
        #expect(stage.rack.droppedReservations == 0)
        #expect(osc.peak == 0 && noise.peak == 0, "鳴っていない")
        stage.close()
        // 音ごと・呼び口ごとに 1 度 (osc の Env.play と play・noise の play)
        let lines = notices.lines
        #expect(lines.count == 3, "\(lines)")
        #expect(lines.allSatisfy { $0.contains("at:") && $0.contains("ignored") })
    }

    @Test("過去・負・0 の at は知らせず、すぐ鳴らす")
    func aPastAtIsPlayedNowWithoutANotice() {
        let notices = NoticeLog()
        let stage = makeStage(notices)
        let osc = SinOsc(stage: stage)
        osc.play(440, 0.5, at: -3)
        for frame in 0..<4 {
            stage.frame = frame
            stage.supply()
        }
        #expect(osc.peak > 0.1)
        osc.stop()
        for frame in 4..<12 {
            stage.frame = frame
            stage.supply()
        }
        // 過去 (今は 11 フレーム = 0.18 秒)
        osc.play(at: 0.05)
        for frame in 12..<16 {
            stage.frame = frame
            stage.supply()
        }
        #expect(osc.peak > 0.1)
        #expect(notices.lines.isEmpty)
        stage.close()
    }

    @Test("置き場に入り切らない予約は捨てられ、1 度だけ知らせる")
    func overflowingReservationsAreNoticedOnce() {
        let notices = NoticeLog()
        let stage = makeStage(notices)
        let osc = SinOsc(stage: stage)
        let env = Env()
        for k in 1...400 { env.play(osc, 0.002, 0.03, 0.7, 0.1, at: 5 + 0.001 * Double(k)) }
        for frame in 0..<8 {
            stage.frame = frame
            stage.supply()
        }
        #expect(stage.rack.droppedReservations == 400 - 341)
        #expect(notices.lines.count == 1)
        #expect(notices.lines.first?.contains("reserved") == true)
        stage.close()
    }

    // MARK: - 実時間 (音の流れ)

    @Test("実際に鳴らす流れでも、流れの 1 度に描かせる長さ (512・441・128) によらず予約した標本から鳴り、音の時計は作った標本を数える")
    func throughTheOfflineFlowTheBlockSizeDoesNotMatter() throws {
        func heard(chunk: Int) throws -> (samples: [Float], seconds: Double) {
            let flow = try SoundFlow.offline(
                sampleRate: Self.rate, channels: 2, maximumFrames: 4096)
            let stage = SynthStage(owner: nil, flow: flow, now: { 0 }, warn: { _ in })
            let player = try #require(RackPlayer(flow: flow, rack: stage.rack))
            stage.pace = .speaker(player)
            defer { stage.close() }
            let osc = TriOsc(stage: stage)
            let env = Env()
            // 音の時計を読んで、次の拍の頭へ予約する (作例と同じ)。最初の拍は 0.125 秒
            env.play(osc, 0.002, 0.03, 0.7, 0.1, at: 0.125)
            let total = Self.step * 3
            var samples: [Float] = []
            var queued = false
            while samples.count < total {
                if !queued, samples.count >= chunk * 2 {
                    queued = true
                    let now = stage.soundSeconds
                    env.play(osc, 0.002, 0.03, 0.7, 0.1, at: (now / 0.125).rounded(.down) * 0.125 + 0.25)
                }
                samples += try renderStereo(flow, min(chunk, total - samples.count), chunk: chunk).left
            }
            return (samples, stage.soundSeconds)
        }
        let base = try heard(chunk: 512)
        #expect(base.seconds == 0.375, "作った標本の数 (18000) ÷ 48000")
        #expect((6000...6001).contains(firstSound(base.samples) ?? -1))
        for chunk in [441, 128] {
            let other = try heard(chunk: chunk)
            #expect(mismatch(other.samples, base.samples) == nil, "区切り \(chunk)")
            #expect(other.seconds == 0.375)
        }
    }

    // MARK: - stop() は予約を取り消す

    @Test("止めると、その音の先の予約は鳴らない。ほかの音の予約と、止めた後に頼んだ予約は残る")
    func stopCancelsTheFutureReservationsOfThatSource() throws {
        let rack = makeRack()
        let stopped = try makeVoice(rack)
        let other = try makeVoice(rack)
        rack.postReservation(envelope(stopped, at: 20_000))
        rack.postReservation(envelope(stopped, at: 30_000))
        rack.postReservation(envelope(other, at: 25_000))
        _ = render(rack, 1_000)
        rack.post(SynthCommand(op: .stop, node: UInt8(stopped.id)))
        // 止めた後の予約は取り消されない (頼んだ順)
        rack.postReservation(envelope(stopped, at: 40_000))
        _ = render(rack, 8_000)
        var heard: [Float] = []
        heard += render(rack, pieces: pieces(of: 441, total: 40_000)).left
        #expect(rack.droppedReservations == 0)

        // 参照: 取り消された 2 つは頼まなかった場合
        let reference = makeRack()
        let kept = try makeVoice(reference)
        let alone = try makeVoice(reference)
        reference.postReservation(envelope(alone, at: 25_000))
        reference.postReservation(envelope(kept, at: 40_000))
        _ = render(reference, 9_000)
        let expected = render(reference, pieces: pieces(of: 441, total: 40_000)).left
        #expect(mismatch(heard, expected) == nil)
        #expect(heard.map { abs($0) }.max() ?? 0 > 0.1)
    }

    @Test("止めて取り消された予約の節は、置き場を返す")
    func aCancelledReservationReturnsItsSlot() throws {
        let rack = makeRack()
        for _ in 0..<63 { try addSource(rack, .wave(.sine), [.amplitude: 0]) }
        let voice = try makeVoice(rack)
        rack.postReservation(envelope(voice, at: 500_000))
        rack.release(voice.id)
        _ = render(rack, 1_000)
        #expect(rack.addSource(.wave(.sine)) == nil, "予約が残っている間は返さない")
        rack.post(SynthCommand(op: .stop, node: UInt8(voice.id)))
        _ = render(rack, 1_000)
        let next = try #require(rack.addSource(.wave(.sine)))
        #expect(next.id == voice.id)
    }

    @Test("ステージ越し: 予約中の音に stop() を呼ぶと、予約した時刻に着いても鳴らない (すぐ鳴らす音は止まる)")
    func stopThroughTheApiCancelsTheReservation() {
        let stage = makeStage()
        let osc = TriOsc(stage: stage)
        let env = Env()
        env.play(osc, 0.002, 0.03, 0.7, 0.1, at: 0.125)
        osc.play(at: 0.25)
        osc.stop()
        #expect(!osc.isPlaying)
        var peak: Float = 0
        for frame in 0..<60 {
            stage.frame = frame
            stage.supply()
            peak = max(peak, osc.peak)
        }
        stage.close()
        #expect(peak == 0, "取り消された予約は鳴らない: \(peak)")
    }

    // MARK: - 予約のまとまりは 1 度に公開する

    @Test("まとまりを載せている最中に音の側が取り出しても、先頭だけが予約され続きが即時に効く、ということは起きない")
    func aReservationGroupIsPublishedAtOnce() throws {
        func run(interrupt: Bool) throws -> [Float] {
            let rack = makeRack()
            let voice = try addSource(rack, .wave(.sine), [.amplitude: 0.5])
            var heard = render(rack, 500).left
            var group = [
                SynthCommand(
                    op: .set, node: UInt8(voice.id), param: .frequency,
                    bits: UInt64(Float(880).bitPattern), at: 1000),
                SynthCommand(
                    op: .set, node: UInt8(voice.id), param: .amplitude,
                    bits: UInt64(Float(0.1).bitPattern), at: 1000),
            ]
            if interrupt {
                // 2 つ目を載せる直前に、音の側が 2000 標本ぶん取り出して描く (位置 1000 を過ぎる)
                var fired = false
                rack.observePost = { command in
                    guard command.param == .amplitude, !fired else { return }
                    fired = true
                    heard += render(rack, 1500).left
                }
                rack.postReservation(group)
                rack.observePost = nil
                heard += render(rack, 3000).left
            } else {
                // 参照: 描いた後に、まとまり全体を (位置はもう過ぎている) 載せる
                heard += render(rack, 1500).left
                group[0].follow = 0
                rack.postReservation(group)
                heard += render(rack, 3000).left
            }
            return heard
        }
        let interrupted = try run(interrupt: true)
        let reference = try run(interrupt: false)
        #expect(mismatch(interrupted, reference) == nil)
        #expect(interrupted.count == 5000)
    }

    @Test("控えに回ったまとまりも、全部が入る空きができてから 1 度に載る")
    func aHeldGroupIsPublishedAtOnce() throws {
        let rack = makeRack()
        let voice = try makeVoice(rack)
        // 列をほぼ埋める (音の側は動かない)。4096 の列に、節を足した 2 個と合わせて 4093 個 (空きは 3 個で、6 個のまとまりは入らない)
        for _ in 0..<4_091 { rack.set(voice.id, .frequency, 440) }
        #expect(rack.heldCount == 0)
        var seen: [Int] = []
        rack.observePost = { _ in seen.append(1) }
        // 6 個のまとまりは入らない → 控える (1 個も載らない)
        #expect(rack.postReservation(envelope(voice, at: 50_000)))
        #expect(rack.heldCount == 6)
        rack.retryHeld()
        #expect(seen.isEmpty && rack.heldCount == 6, "空きが足りない間は、一部も載せない")
        // 音の側が取り出して空きができれば、全部が載る
        _ = render(rack, 100)
        rack.retryHeld()
        #expect(rack.heldCount == 0)
        #expect(seen.count == 6)
    }

    // MARK: - 予約の順序 (降順に頼んでも同じ)

    @Test("降順に頼んだ予約は、昇順に頼んだ予約と標本まで同じで、同じ位置は頼んだ順")
    func descendingReservationsMatchAscending() throws {
        func run(_ positions: [Int]) throws -> [Float] {
            let rack = makeRack()
            let voice = try makeVoice(rack)
            for position in positions { rack.postReservation(envelope(voice, at: position)) }
            #expect(rack.droppedReservations == 0)
            return render(rack, pieces: pieces(of: 512, total: 120_000)).left
        }
        let ascending = (1...341).map { 5_000 + 250 * $0 }
        let descending = Array(ascending.reversed())
        let shuffled = ascending.enumerated().map { ($0.offset * 97) % 341 }.map { ascending[$0] }
        #expect(Set(shuffled).count == 341)
        let base = try run(ascending)
        #expect(base.map { abs($0) }.max() ?? 0 > 0.1)
        #expect(mismatch(try run(descending), base) == nil)
        #expect(mismatch(try run(shuffled), base) == nil)
    }

    @Test("同じ位置の予約は、ヒープに入れても頼んだ順に効く")
    func samePositionKeepsTheRequestOrderInTheHeap() throws {
        func run(_ freqs: [Float]) throws -> [Float] {
            let rack = makeRack()
            let voice = try addSource(rack, .wave(.sine), [.amplitude: 0.5], playing: true)
            // 間に別の位置を挟んで、ヒープの形を崩す
            for (index, freq) in freqs.enumerated() {
                rack.postReservation([
                    SynthCommand(
                        op: .set, node: UInt8(voice.id), param: .frequency,
                        bits: UInt64(freq.bitPattern), at: 1000)
                ])
                rack.postReservation([
                    SynthCommand(
                        op: .set, node: UInt8(voice.id), param: .offset, bits: 0,
                        at: 2000 + 10 * ((index * 7) % 5))
                ])
            }
            return render(rack, 3000).left
        }
        // 最後に頼んだ周波数が残る: 20 個の中で最後が 880 なら、880 だけを頼んだときと同じ
        let many = try run((0..<20).map { Float(200 + $0 * 10) } + [880])
        let last = try run([880])
        #expect(mismatch(Array(many.suffix(1000)), Array(last.suffix(1000))) == nil)
    }

    // MARK: - 公開の口の互換

    @Test("at: を足す前の公開の口は、そのまま残る (引数なしの play()・値つきの play・Env.play と、その関数参照)")
    func theOldSignaturesRemain() {
        let stage = makeStage()
        let osc = SinOsc(stage: stage)
        let noise = WhiteNoise(stage: stage)
        let env = Env()
        let plain: () -> Void = osc.play
        let voice: (Float, Float, Float, Float) -> Void = osc.play
        let hiss: (Float, Float, Float) -> Void = noise.play
        let shape: (SynthSource, Float, Float, Float, Float) -> Void = env.play
        plain()
        voice(440, 0.5, 0, 0)
        hiss(0.2, 0, 0)
        shape(osc, 0.01, 0.1, 0.5, 0.1)
        osc.play()
        osc.play(440, 0.5)
        noise.play(0.2)
        env.play(osc, 0.01, 0.1, 0.5, 0.1)
        for frame in 0..<4 {
            stage.frame = frame
            stage.supply()
        }
        #expect(osc.isPlaying && noise.isPlaying)
        #expect(osc.peak > 0.01)
        stage.close()
    }

    @Test("長く動かしても標本に揃う: 1 時間後の 1 標本ぶんの差が位置に出る (倍精度)")
    func longTimesStayOnTheSample() {
        let stage = makeStage()
        #expect(stage.samplePosition(ofSeconds: 3600) == 172_800_000)
        #expect(stage.samplePosition(ofSeconds: 3600 + 1.0 / 48_000) == 172_800_001)
        #expect(stage.samplePosition(ofSeconds: -1) == 0)
        #expect(stage.samplePosition(ofSeconds: .infinity) == nil)
        stage.close()
    }
}
