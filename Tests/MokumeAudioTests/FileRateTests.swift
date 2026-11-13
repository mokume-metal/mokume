// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import Testing

@testable import MokumeAudio

/// 速さ (#3473): 錨から位置を導く式・読み方・主スレッドと音の側の受け渡し。GPU も機材も要らない (音の側は機材に
/// 出さない流れとラックを直に回す)。
@Suite("速さ (錨・読み方・受け渡し)", .serialized)
struct FileRateTests {
    /// 位置ごとに違う、なめらかでない標本列 (補間が効いているかが値で読める)。
    private static func wobble(_ count: Int) -> [Float] {
        (0..<count).map { 0.6 * Float(sin(Double($0) * 0.031)) + 0.3 * Float(($0 * 37) % 101) / 101 }
    }

    // MARK: - 再生位置 (主スレッドの数え方)

    @Test("速さ 2 で 48000 標本経つと位置は 96000 進み、そこで 0.5 に替えても跳ばずに半分の速さで進む。番号は鳴った数、包絡は経った数")
    func playheadFollowsTheRate() {
        var head = Playhead(length: 500_000)
        head.play(looping: false)
        head.setRate(2, kernel: nil, at: 0)
        #expect(head.position(after: 48_000) == 96_000)
        head.setRate(0.5, kernel: nil, at: 48_000)
        #expect(head.position(after: 48_000) == 96_000, "替えた点で跳ばない")
        #expect(head.position(after: 96_000) == 120_000)
        // 番号は始まりの位置 + 鳴った標本の数、包絡の数は経った数
        #expect(head.number(after: 96_000) == 96_000)
        #expect(head.heard(after: 96_000) == 96_000)
        // 同じ速さを同じ点で頼み直しても変わらない
        head.setRate(0.5, kernel: nil, at: 96_000)
        #expect(head.position(after: 144_000) == 144_000)
    }

    @Test("速さ 0 の間は位置も番号も進まず、終わりにも着かない。包絡の数 (経った数) は進む")
    func playheadHoldsAtZero() {
        var head = Playhead(length: 1000)
        head.play(looping: false)
        head.setRate(0, kernel: nil, at: 300)
        #expect(head.position(after: 300) == 300)
        #expect(head.position(after: 50_000) == 300)
        #expect(head.number(after: 50_000) == 300)
        #expect(head.heard(after: 50_000) == 50_000)
        #expect(!head.hasEnded(after: 50_000))
        #expect(head.endingElapsed == nil)
        // 動き出すと、止まった位置から
        head.setRate(1, kernel: nil, at: 50_000)
        #expect(head.position(after: 50_100) == 400)
        #expect(head.number(after: 50_100) == 400)
    }

    @Test("1 度だけを速さ 2 で鳴らすと、経った数 500 (長さの半分) で終わり、番号・包絡の数はそこで止まる。ループは折り返して続く")
    func playheadEndsAndWrapsAtRateTwo() {
        var head = Playhead(length: 1000)
        head.play(looping: false)
        head.setRate(2, kernel: nil, at: 0)
        #expect(head.endingElapsed == 500)
        #expect(!head.hasEnded(after: 499))
        #expect(head.hasEnded(after: 500))
        #expect(head.number(after: 800) == 500)
        #expect(head.heard(after: 800) == 500)
        #expect(head.position(after: 800) == 1000)
        var loop = Playhead(length: 1000)
        loop.play(looping: true)
        loop.setRate(2, kernel: nil, at: 0)
        #expect(loop.position(after: 700) == 400)
        #expect(loop.number(after: 700) == 700)
        #expect(!loop.hasEnded(after: 700))
    }

    @Test("解析が包絡を引く位置は経った数: 速さ 0 の間を挟んだ番号は、止まっていた間の経った数を足した位置")
    func analysisEnvelopeCountsElapsed() {
        var head = Playhead(length: 10_000)
        head.jump(to: 100)
        head.play(looping: false)
        head.setRate(2, kernel: nil, at: 0)
        head.setRate(0, kernel: nil, at: 300)
        head.setRate(1, kernel: nil, at: 800)
        #expect(head.elapsed(atNumber: 100 + 250) == 250)
        // 鳴った数 300 の標本は、止まっていた 500 標本の後 (経った数 800) に鳴った
        #expect(head.elapsed(atNumber: 100 + 300) == 800)
        #expect(head.elapsed(atNumber: 100 + 350) == 850)
        #expect(head.elapsed(atNumber: 50) == -50, "区切りの前は始まりからの負の数")
    }

    @Test("極端に大きい速さでも落ちない: 1 度だけは次の標本で終わり、ループの位置は長さの内に収まる")
    func playheadSurvivesHugeRates() {
        var head = Playhead(length: 1000)
        head.play(looping: false)
        head.setRate(1e30, kernel: nil, at: 0)
        #expect(head.endingElapsed == 1)
        #expect(head.position(after: 10) == 1000)
        var loop = Playhead(length: 1000)
        loop.play(looping: true)
        loop.setRate(Double(Float.greatestFiniteMagnitude), kernel: nil, at: 0)
        for played in [1, 7, 48_000, 1 << 30] {
            let place = loop.position(after: played)
            #expect((0..<1000).contains(place), "\(played): \(place)")
        }
        // 極端に小さい速さは、着くまでの数が数えられないので着かない
        var crawl = Playhead(length: 1000)
        crawl.play(looping: false)
        crawl.setRate(1e-300, kernel: nil, at: 0)
        #expect(crawl.endingElapsed == nil)
    }

    // MARK: - 係数

    @Test("係数は比が 1 以下なら作らず、同じ比には同じものを返し、8 倍を越える比は 8 倍で作る。使われなくなった係数は捨てる")
    func kernelsAreSharedAndCapped() throws {
        var cache: [UInt64: RateKernel] = [:]
        #expect(RateKernel.make(ratio: 1, cache: &cache) == nil)
        #expect(RateKernel.make(ratio: 0.5, cache: &cache) == nil)
        let two = try #require(RateKernel.make(ratio: 2, cache: &cache))
        #expect(RateKernel.make(ratio: 2, cache: &cache) === two)
        let huge = try #require(RateKernel.make(ratio: 1000, cache: &cache))
        #expect(huge.ratio == FileRate.maximumRatio)
        #expect(RateKernel.make(ratio: 9, cache: &cache) === huge)
        var pool: [UInt64: RateKernel] = [:]
        var held = RateKernel.make(ratio: 2, cache: &pool)
        _ = RateKernel.make(ratio: 3, cache: &pool)
        RateKernel.prune(&pool)
        #expect(pool.count == 1 && pool[2.0.bitPattern] === held, "持たれている 2 倍だけが残る")
        held = nil
        RateKernel.prune(&pool)
        #expect(pool.isEmpty && held == nil)
    }

    // MARK: - 直に鳴らす経路 (``FileVoice``)

    /// 錨を受けた順に、主スレッドの再生位置へ置く (``SoundFile`` が鳴らす側の錨を受けるのと同じ)。
    private func absorb(_ player: FilePlayer, into head: inout Playhead, cache: inout [UInt64: RateKernel]) {
        guard let (anchor, current) = player.absorbRate() else { return }
        let kernel = RateKernel.make(ratio: anchor.rate, cache: &cache)
        if current {
            head.setRate(anchor.rate, kernel: kernel, at: anchor.elapsed, position: anchor.position)
        } else {
            head.retime(anchor.rate, kernel: kernel)
        }
    }

    @Test(
        "鳴った標本は、主スレッドの解析が同じ錨から作る標本と 1 つも違わない (遅く・速く・止める・極端に速く・ループの折り返しをまたいで)",
        arguments: [false, true])
    func voiceAndAnalysisMakeTheSameSamples(looping: Bool) throws {
        let values = Self.wobble(6000)
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        let player = try #require(FilePlayer(flow: flow, buffer: try monoBuffer(values)))
        var head = Playhead(length: values.count)
        var cache: [UInt64: RateKernel] = [:]
        head.jump(to: 100)
        head.play(looping: looping)
        player.play(from: 100, looping: looping)
        // (区間の長さ, 速さ)。ループは 5900 標本の残りを 2 倍速で越えて、頭へ折り返す
        let steps: [(Int, Double)] = [(700, 1), (1000, 0.5), (900, 2), (500, 0), (800, 1.5), (300, 1000), (900, 0.75)]
        var heard: [Float] = []
        var elapsed = 0
        for (index, step) in steps.enumerated() {
            if index > 0 {
                player.rate(step.1, kernel: RateKernel.make(ratio: step.1, cache: &cache))
            }
            heard += try render(flow, step.0)
            elapsed += step.0
            absorb(player, into: &head, cache: &cache)
        }
        // 主スレッドが作る標本 (番号は鳴った数で数えるので、速さ 0 の間は無い)
        let last = head.number(after: elapsed)
        let expected = (100..<last).map { head.sample(at: $0, in: values) }
        // 鳴った音から、速さ 0 の間 (無音) を除く。1 度だけなら、終わりの後の無音も除く
        var sounded: [Float] = []
        var cursor = 0
        for step in steps {
            if step.1 != 0 { sounded += heard[cursor..<cursor + step.0] }
            cursor += step.0
        }
        let silentFrom = 700 + 1000 + 900
        #expect(heard[silentFrom..<silentFrom + 500].allSatisfy { $0 == 0 }, "速さ 0 の間は無音")
        try #require(sounded.count >= expected.count)
        #expect(Array(sounded.prefix(expected.count)) == expected)
        if !looping {
            #expect(head.hasEnded(after: elapsed), "1 度だけは終わりに着いている")
            #expect(sounded[expected.count...].allSatisfy { $0 == 0 }, "終わりの後は無音")
        } else {
            #expect(expected.count == sounded.count)
        }
        // 速さ 1 の区間は器の標本そのまま
        #expect(Array(heard[0..<700]) == Array(values[100..<800]))
    }

    @Test("速さ 2 の区間は器の偶数番目の標本そのまま (整数の位置)、0.5 は三次補間の値。速さ 0 の間も経った数は進む")
    func voiceReadsAtTheRate() throws {
        let values = Self.wobble(4000)
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        let player = try #require(
            FilePlayer(flow: flow, buffer: try monoBuffer(values), rate: 0.5, kernel: nil))
        player.play(from: 0, looping: false)
        let slow = try render(flow, 400)
        let expected = values.withUnsafeBufferPointer { buffer in
            (0..<400).map {
                FileRate.read(buffer.baseAddress!, length: 4000, at: Double($0) * 0.5, looping: false, kernel: nil)
            }
        }
        #expect(slow == expected)
        #expect(slow[1] != values[0] && slow[1] != values[1], "半分の位置は補間した値")
        player.rate(0, kernel: nil)
        _ = player.absorbRate()
        #expect(try render(flow, 300).allSatisfy { $0 == 0 })
        #expect(player.played == 700, "速さ 0 の間も経った数は進む")
        _ = player.absorbRate()
        // 速さ 2 は低域通過を掛けて読む (係数なしで頼むと、整数の位置の器の標本そのまま)
        player.rate(2, kernel: nil)
        let fast = try render(flow, 300)
        #expect(fast == (0..<300).map { values[200 + 2 * $0] })
    }

    @Test("速くするときは低域通過を掛けて読む: 15 kHz の正弦を速さ 2 で鳴らすと (30 kHz は出せない)、折り返さずにほぼ消える")
    func fastReadsFilterAboveHalf() throws {
        let tone = (0..<8000).map { Float(0.5 * sin(2 * Double.pi * 15_000 * Double($0) / 48_000)) }
        var cache: [UInt64: RateKernel] = [:]
        func loudest(kernel: RateKernel?) throws -> Float {
            let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
            let player = try #require(
                FilePlayer(flow: flow, buffer: try monoBuffer(tone), rate: 2, kernel: kernel))
            player.play(from: 0, looping: true)
            let heard = try render(flow, 3000)
            return heard[500...].map { abs($0) }.max() ?? 0
        }
        let filtered = try loudest(kernel: RateKernel.make(ratio: 2, cache: &cache))
        let folded = try loudest(kernel: nil)
        #expect(filtered < 0.02, "低域通過の後 \(filtered)")
        #expect(folded > 0.2, "係数なしなら折り返して聞こえる \(folded)")
    }

    @Test("1 度だけを速さ 2 で鳴らすと、器の半分の標本数で鳴り終わって無音になる")
    func voiceEndsEarlyAtRateTwo() throws {
        let values = Self.wobble(1000).map { $0 + 2 }
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        let player = try #require(
            FilePlayer(flow: flow, buffer: try monoBuffer(values), rate: 2, kernel: nil))
        player.play(from: 0, looping: false)
        let heard = try render(flow, 800)
        #expect(heard[0..<500].allSatisfy { $0 != 0 })
        #expect(heard[500...].allSatisfy { $0 == 0 })
    }

    @Test("前の錨を主スレッドが読むまで、音の側は次の速さを受けない (錨を取りこぼさない)")
    func voiceWaitsUntilTheAnchorIsRead() throws {
        let values = Self.wobble(4000)
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        let player = try #require(FilePlayer(flow: flow, buffer: try monoBuffer(values)))
        player.play(from: 0, looping: false)
        player.rate(2, kernel: nil)
        let first = try render(flow, 100)
        player.rate(0.5, kernel: nil)
        // 錨を読んでいないので、まだ 2 倍
        let second = try render(flow, 100)
        #expect(first + second == (0..<200).map { values[2 * $0] })
        let anchor = try #require(player.absorbRate())
        #expect(anchor.anchor.rate == 2 && anchor.anchor.elapsed == 0 && anchor.current)
        _ = try render(flow, 100)
        let next = try #require(player.absorbRate())
        #expect(next.anchor.rate == 0.5 && next.anchor.elapsed == 200 && next.anchor.position == 400)
        #expect(player.absorbRate() == nil, "新しい錨は無い")
    }

    @Test("包絡は経った数で進む: 速さ 2 でも、400 標本の立ち上がりは 400 標本かかる")
    func envelopeCountsElapsedSamples() throws {
        let values = [Float](repeating: 0.5, count: 4000)
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        let player = try #require(
            FilePlayer(flow: flow, buffer: try monoBuffer(values), rate: 2, kernel: nil))
        var shape = EnvelopeShape()
        shape.attack = 400
        shape.sustain = 600
        shape.release = 400
        shape.level = 1
        let envelope = FileEnvelope(shape: shape, offset: 0)
        player.play(from: 0, looping: false, envelope: envelope)
        let heard = try render(flow, 1400)
        for index in [0, 100, 399, 400, 999, 1200] {
            #expect(abs(heard[index] - 0.5 * envelope.gain(atPlayed: index)) < 1e-6, "\(index)")
        }
    }

    // MARK: - エフェクトへ通した経路 (``FileNode``)

    @Test("ラックの節を速さ 2 で鳴らすと、立ち上がった後は偶数番目の標本で、1 度だけは半分の数で終わって終わりの印を立てる")
    func nodeReadsAtTheRate() throws {
        let samples = Self.wobble(20_000)
        let rack = SynthRack(sampleRate: 48_000)
        let node = try #require(
            rack.addFile(samples: samples, fileRate: 48_000, amplitude: 1, rate: 2))
        rack.post(
            SynthCommand(
                op: .segment, node: UInt8(node.id), bits: FileNode.segment(start: 0, looping: false, generation: 1)))
        let heard = render(rack, 12_000)
        let center = Float(0.5).squareRoot()
        let expected = (4000..<10_000).map { samples[2 * $0] * center }
        #expect(mismatch(Array(heard.left[4000..<10_000]), expected) == nil)
        #expect(heard.left[10_000...].allSatisfy { $0 == 0 })
        #expect(node.ended(generation: 1))
        #expect(node.played(generation: 1) == 10_000)
    }

    @Test("ラックの節は、鳴らしている間に頼んだ速さを次に描くときに受け、その点の錨を返す。速さ 0 は無音で位置が進まない")
    func nodeTakesTheRateAndReportsTheAnchor() throws {
        let samples = Self.wobble(20_000)
        let rack = SynthRack(sampleRate: 48_000)
        let node = try #require(rack.addFile(samples: samples, fileRate: 48_000, amplitude: 1))
        rack.post(
            SynthCommand(
                op: .segment, node: UInt8(node.id), bits: FileNode.segment(start: 100, looping: true, generation: 1)))
        _ = render(rack, 5000)
        node.link.request(0, kernel: nil)
        let still = render(rack, 1000)
        #expect(still.left.allSatisfy { $0 == 0 })
        let anchor = try #require(node.link.absorb())
        #expect(anchor.rate == 0 && anchor.elapsed == 5000 && anchor.position == 5100)
        #expect(FileNode.matches(anchor.generation, current: 1))
        node.link.request(1.5, kernel: nil)
        _ = render(rack, 1000)
        let moving = try #require(node.link.absorb())
        #expect(moving.elapsed == 6000 && moving.position == 5100, "速さ 0 の間は位置が進まない")
        #expect(node.played(generation: 1) == 7000)
        #expect(!node.ended(generation: 1))
    }

    @Test("44.1 kHz のファイルを速さ 2 (読む比 1.84) で通すと、係数を掛けて読み、半分の時間で終わる")
    func nodeUsesTheKernelAboveOne() throws {
        let samples = [Float](repeating: 0.25, count: 44_100)
        var cache: [UInt64: RateKernel] = [:]
        let rack = SynthRack(sampleRate: 48_000)
        let node = try #require(
            rack.addFile(
                samples: samples, fileRate: 44_100, amplitude: 1, rate: 2,
                kernel: { RateKernel.make(ratio: $0, cache: &cache) }))
        #expect(cache.count == 1, "読む比 2 × 44100 ÷ 48000 の係数を作った")
        rack.post(
            SynthCommand(
                op: .segment, node: UInt8(node.id), bits: FileNode.segment(start: 0, looping: false, generation: 1)))
        let heard = render(rack, 30_000)
        let center = Float(0.5).squareRoot()
        // 直流は係数を通してもそのままの大きさ
        #expect(abs(heard.left[10_000] - 0.25 * center) < 1e-4)
        #expect(heard.left[24_100...].allSatisfy { $0 == 0 }, "0.5 秒 (24000 標本) ほどで終わる")
        #expect(node.ended(generation: 1))
    }
}
