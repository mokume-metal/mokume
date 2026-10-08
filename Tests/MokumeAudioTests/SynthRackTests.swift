// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import Testing

@testable import MokumeAudio

/// 左右の標本。
struct Stereo: Equatable {
    var left: [Float] = []
    var right: [Float] = []
}

/// ラックを、`pieces` に分けて順に描かせる。
func render(_ rack: SynthRack, pieces: [Int]) -> Stereo {
    var heard = Stereo()
    for count in pieces {
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        left.withUnsafeMutableBufferPointer { left in
            right.withUnsafeMutableBufferPointer { right in
                rack.render(
                    left: left.baseAddress!, right: right.baseAddress!, frames: count)
            }
        }
        heard.left += left
        heard.right += right
    }
    return heard
}

/// ラックを 1 度で `frames` 標本描かせる。
func render(_ rack: SynthRack, _ frames: Int) -> Stereo {
    render(rack, pieces: [frames])
}

/// 2 つの標本列が最初に食い違う場所を言葉にする。同じなら `nil`。
///
/// 長い列を `#expect(a == b)` に渡すと、失敗したときに全部の標本が出力へ流れて読めない。
func mismatch(_ actual: [Float], _ expected: [Float]) -> String? {
    guard actual.count == expected.count else {
        return "長さが違う: \(actual.count) と \(expected.count)"
    }
    for index in actual.indices where actual[index] != expected[index] {
        return "標本 \(index) が違う: \(actual[index]) と \(expected[index])"
    }
    return nil
}

func mismatch(_ actual: Stereo, _ expected: Stereo) -> String? {
    mismatch(actual.left, expected.left).map { "左: " + $0 }
        ?? mismatch(actual.right, expected.right).map { "右: " + $0 }
}

/// 機材に出さない流れを、`chunk` 標本ずつ `frames` 標本ぶん描かせて、左右の音を返す。
func renderStereo(_ flow: SoundFlow, _ frames: Int, chunk: Int = 4096) throws -> Stereo {
    let output = try #require(
        AVAudioPCMBuffer(
            pcmFormat: flow.engine.manualRenderingFormat,
            frameCapacity: flow.engine.manualRenderingMaximumFrameCount))
    var heard = Stereo()
    var remaining = frames
    while remaining > 0 {
        let count = min(remaining, chunk, Int(output.frameCapacity))
        let status = try flow.engine.renderOffline(AVAudioFrameCount(count), to: output)
        #expect(status == .success)
        let data = try #require(output.floatChannelData)
        heard.left += (0..<Int(output.frameLength)).map { data[0][$0] }
        heard.right += (0..<Int(output.frameLength)).map { data[1][$0] }
        remaining -= count
    }
    return heard
}

/// 音源の節を足して、いくつかの値を決める。
@discardableResult
func addSource(
    _ rack: SynthRack, _ kind: SourceNode.Kind, _ values: [SynthParam: Float] = [:],
    playing: Bool = true
) throws -> RackNode {
    let node = try #require(rack.addSource(kind))
    for (param, value) in values { rack.set(node.id, param, value) }
    if playing { rack.post(SynthCommand(op: .play, node: UInt8(node.id))) }
    return node
}

/// 節 `node` の入力を `inputs` にする。
func connect(_ rack: SynthRack, _ node: RackNode, to inputs: [RackNode]) {
    rack.setInputs(node.id, inputs.reduce(0) { $0 | (1 << UInt64($1.id)) })
}

/// 合成の音を、複数の音源とエフェクトで組んだ 1 つの設定。**同じ設定から同じ標本列が出ること**を
/// 見るのに使う (#1980)。
func buildPatch(_ rack: SynthRack) throws {
    let sine = try addSource(
        rack, .wave(.sine), [.frequency: 440, .amplitude: 0.4, .panning: 0.5])
    let saw = try addSource(
        rack, .wave(.saw), [.frequency: 110, .amplitude: 0.3, .panning: -0.5])
    let pink = try addSource(rack, .noise(.pink), [.amplitude: 0.2])
    let square = try addSource(rack, .wave(.square), [.frequency: 220, .amplitude: 0.2])
    _ = sine

    let band = try #require(rack.addFilter(.bandPass))
    rack.set(band.id, .cutoff, 800)
    rack.set(band.id, .bandwidth, 300)
    connect(rack, band, to: [pink])

    let low = try #require(rack.addFilter(.lowPass))
    rack.set(low.id, .cutoff, 1500)
    connect(rack, low, to: [square])

    let reverb = try #require(rack.addReverb())
    rack.set(reverb.id, .room, 0.7)
    rack.set(reverb.id, .damping, 0.3)
    rack.set(reverb.id, .wetness, 0.4)
    connect(rack, reverb, to: [band, saw])

    let delay = try #require(rack.addDelay())
    rack.set(delay.id, .time, 0.1)
    rack.set(delay.id, .feedback, 0.4)
    connect(rack, delay, to: [low])
}

/// 合成した音を作るラックと、それを音の流れへ入れる口 (#1980)。
///
/// 描くのは純粋な処理なので、GPU も機材も要らない。**manual rendering (offline) の流れへ入れて
/// 描かせれば、同じ設定から同じ標本列が出る**ことを固定するのが、この suite の主な役目である
/// ([ADR-0042] 決定 6)。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
@Suite("合成のラック", .serialized)
struct SynthRackTests {
    private static let rate = 48_000.0

    private func makeRack() -> SynthRack {
        SynthRack(sampleRate: Self.rate)
    }

    // MARK: - 同じ設定から同じ標本列

    @Test("同じ設定のラックは、描かせる区切り方によらず、1 標本まで同じ標本列を出す")
    func samePatchGivesSameSamples() throws {
        let whole = makeRack()
        try buildPatch(whole)
        let wholeHeard = render(whole, 20_000)

        let pieced = makeRack()
        try buildPatch(pieced)
        // 1 標本・512 を越える・中途半端な長さを混ぜる
        let pieces = [1, 300, 4096, 511, 513, 1, 7, 5000, 2, 6000, 3569]
        #expect(pieces.reduce(0, +) == 20_000)
        let piecedHeard = render(pieced, pieces: pieces)

        #expect(mismatch(wholeHeard, piecedHeard) == nil)
        // 音が出ている (全部 0 で一致していては意味が無い)
        #expect(wholeHeard.left.map { abs($0) }.max() ?? 0 > 0.1)
        #expect(mismatch(wholeHeard.left, wholeHeard.right) != nil)
    }

    @Test("同じ設定を manual rendering の流れで 2 度描かせると同じ標本列で、純粋な描画とも一致する")
    func offlineFlowRendersTheSameSamples() throws {
        let frames = 12_288
        func heard(chunk: Int) throws -> Stereo {
            let flow = try SoundFlow.offline(
                sampleRate: Self.rate, channels: 2, maximumFrames: 4096)
            let rack = makeRack()
            try buildPatch(rack)
            let player = try #require(RackPlayer(flow: flow, rack: rack))
            defer { player.leave() }
            return try renderStereo(flow, frames, chunk: chunk)
        }
        let first = try heard(chunk: 4096)
        let second = try heard(chunk: 4096)
        #expect(mismatch(first, second) == nil)
        // 流れが 1 度に描かせる長さを変えても同じ
        #expect(mismatch(try heard(chunk: 1000), first) == nil)

        let pure = makeRack()
        try buildPatch(pure)
        let expected = render(pure, frames)
        #expect(first.left.count == frames)
        let worst = zip(first.left + first.right, expected.left + expected.right)
            .map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-6)
        #expect(first.left.map { abs($0) }.max() ?? 0 > 0.1)
    }

    @Test("機材に出さない流れが描かせる標本化率で、ラックも標本を作る")
    func rackFollowsTheFlowRate() throws {
        let flow = try SoundFlow.offline(sampleRate: 44_100, channels: 2, maximumFrames: 1024)
        #expect(flow.synthesisRate == 44_100)
        let rack = SynthRack(sampleRate: flow.synthesisRate)
        // 44100 Hz の流れで 441 Hz は、ちょうど 100 標本で 1 周期
        _ = try addSource(
            rack, .wave(.sine), [.frequency: 441, .amplitude: 1, .panning: -1])
        let player = try #require(RackPlayer(flow: flow, rack: rack))
        defer { player.leave() }
        let heard = try renderStereo(flow, 8192, chunk: 1000)
        let expected = (7168..<8192).map { Float(sin(2 * Double.pi * Double($0) / 100)) }
        let worst = zip(heard.left.suffix(1024), expected).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-4)
        #expect(heard.right.suffix(1024).allSatisfy { abs($0) < 1e-6 })
    }

    // MARK: - 音源

    @Test("鳴らす前の音源は無音で、写しにも無音が入る")
    func silentBeforePlay() throws {
        let rack = makeRack()
        let node = try addSource(rack, .wave(.sine), [.frequency: 440], playing: false)
        let heard = render(rack, 1000)
        #expect(heard.left.allSatisfy { $0 == 0 } && heard.right.allSatisfy { $0 == 0 })
        #expect(node.meter.latest(1000).allSatisfy { $0 == 0 })
        #expect(node.meter.total == 1000)
    }

    @Test("正弦波の音源は、落ち着いた後は音量 × sin(2π f n / 標本化率) になる")
    func sineSourceFollowsTheFormula() throws {
        let rack = makeRack()
        let node = try addSource(
            rack, .wave(.sine), [.frequency: 1000, .amplitude: 0.5])
        _ = render(rack, 8192)
        let tail = node.meter.latest(1024)
        let expected = (7168..<8192).map {
            Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / Self.rate))
        }
        let worst = zip(tail, expected).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-5)
    }

    @Test("定位は、-1 で左だけ・0 で左右が同じ・1 で右だけ。中央は左右とも 1/√2")
    func panLaw() throws {
        func settled(_ pan: Float) throws -> (left: Float, right: Float) {
            let rack = makeRack()
            _ = try addSource(
                rack, .wave(.square), [.frequency: 100, .amplitude: 1, .panning: pan])
            let heard = render(rack, 24_000)
            let peak: (Stereo) -> (Float, Float) = { stereo in
                (
                    stereo.left.suffix(2000).map { abs($0) }.max() ?? 0,
                    stereo.right.suffix(2000).map { abs($0) }.max() ?? 0
                )
            }
            return peak(heard)
        }
        let left = try settled(-1)
        #expect(left.right < 1e-6 && abs(left.left - 1) < 0.02)
        let center = try settled(0)
        #expect(center.left == center.right)
        #expect(abs(center.left - Float(0.5).squareRoot()) < 0.02)
        let right = try settled(1)
        #expect(right.left < 1e-6 && abs(right.right - 1) < 0.02)
    }

    @Test("止めると消えて無音になり、鳴らし直すと位相を頭へ戻して同じ立ち上がりになる")
    func stopSilencesAndRestartsFromPhaseZero() throws {
        let rack = makeRack()
        let node = try addSource(rack, .wave(.sine), [.frequency: 440, .amplitude: 0.5])
        let first = render(rack, 2000)
        rack.post(SynthCommand(op: .stop, node: UInt8(node.id)))
        let stopped = render(rack, 12_000)
        // 約 5 ミリ秒かけて消えて、その後は 1 標本も出ない
        #expect(stopped.left.suffix(8000).allSatisfy { $0 == 0 })
        #expect(stopped.left.prefix(100).map { abs($0) }.max() ?? 0 > 0)
        rack.post(SynthCommand(op: .play, node: UInt8(node.id)))
        let second = render(rack, 2000)
        #expect(mismatch(first, second) == nil)
    }

    @Test("音源は、値を急に変えても約 5 ミリ秒かけて追い、描かせる区切り方に依らない")
    func valuesAreSmoothed() throws {
        func run(pieces: [Int]) throws -> [Float] {
            let rack = makeRack()
            let node = try addSource(rack, .wave(.sine), [.frequency: 100, .amplitude: 0.1])
            _ = render(rack, 4800)
            rack.set(node.id, .amplitude, 0.9)
            _ = render(rack, pieces: pieces)
            return node.meter.latest(2400)
        }
        let whole = try run(pieces: [2400])
        #expect(mismatch(try run(pieces: [1, 2399]), whole) == nil)
        #expect(mismatch(try run(pieces: [100, 300, 2000]), whole) == nil)
        // 音量は 1 標本では変わらない: 最初の山は小さく、後ろの山は大きい
        #expect((whole.prefix(30).map { abs($0) }.max() ?? 1) < 0.15)
        #expect((whole.suffix(480).map { abs($0) }.max() ?? 0) > 0.85)
    }

    @Test("包絡は、鳴っている音へ台形をかけ、終わった後は 0 のまま")
    func envelopeShapesTheSource() throws {
        let rack = makeRack()
        let node = try addSource(rack, .wave(.sine), [.frequency: 480, .amplitude: 1])
        _ = render(rack, 9600)
        // 96 標本で立ち上がり、48 標本保ち、96 標本で下がる (高さ 0.5)
        rack.set(node.id, .attack, 96 / 48_000)
        rack.set(node.id, .sustain, 48 / 48_000)
        rack.set(node.id, .level, 0.5)
        rack.set(node.id, .release, 96 / 48_000)
        rack.post(SynthCommand(op: .trigger, node: UInt8(node.id)))
        _ = render(rack, 1000)
        let shaped = node.meter.latest(1000)
        let shape = EnvelopeShape(
            attack: 96 / 48_000, sustain: 48 / 48_000, level: 0.5, release: 96 / 48_000,
            sampleRate: 48_000)
        for index in 0..<240 {
            let phase = Double(9600 + index) * 480 / 48_000
            let expected = Float(sin(2 * Double.pi * phase)) * (shape.gain(at: index) ?? 0)
            #expect(abs(shaped[index] - expected) < 1e-4, "標本 \(index)")
        }
        #expect(shaped.suffix(700).allSatisfy { $0 == 0 })

        // もう一度かけると、頭から始まる
        rack.post(SynthCommand(op: .trigger, node: UInt8(node.id)))
        _ = render(rack, 300)
        #expect(node.meter.latest(300).prefix(240).map { abs($0) }.max() ?? 0 > 0.3)
    }

    // MARK: - 繋がり

    @Test("エフェクトへ通した音は直には出ず、エフェクトの出口が中央で出る")
    func connectedSourceGoesThroughTheEffect() throws {
        let rack = makeRack()
        let source = try addSource(rack, .wave(.sine), [.frequency: 1000, .amplitude: 0.5])
        let filter = try #require(rack.addFilter(.lowPass))
        rack.set(filter.id, .cutoff, 100)
        connect(rack, filter, to: [source])
        let heard = render(rack, 4000)

        // 濾波器の出口は、音源の出口に同じ濾波器をかけたもの
        var biquad = Biquad()
        biquad.configure(.lowPass, frequency: 100, quality: 1, sampleRate: Self.rate)
        let expected = source.meter.latest(4000).map { biquad.process($0) }
        #expect(mismatch(filter.meter.latest(4000), expected) == nil)
        // 左右へ出るのは濾波器の出口だけ (中央で、左右とも 1/√2)
        let gain = Float(0.5).squareRoot()
        #expect(mismatch(heard.left, expected.map { $0 * gain }) == nil)
        #expect(mismatch(heard.right, heard.left) == nil)
        // 1 kHz は 100 Hz の切れ目のずっと上なので、大きく小さくなっている
        #expect((expected.suffix(1000).map { abs($0) }.max() ?? 1) < 0.1)
    }

    @Test("エフェクトの出口をエフェクトへ通せて、描く順は作った順によらない")
    func effectsChainRegardlessOfCreationOrder() throws {
        let rack = makeRack()
        // 先に後ろのエフェクトを作る
        let reverb = try #require(rack.addReverb())
        let filter = try #require(rack.addFilter(.highPass))
        let source = try addSource(rack, .noise(.white), [.amplitude: 0.5])
        rack.set(filter.id, .cutoff, 3000)
        rack.set(reverb.id, .wetness, 1)
        connect(rack, reverb, to: [filter])
        connect(rack, filter, to: [source])
        _ = render(rack, 6000)

        var biquad = Biquad()
        biquad.configure(.highPass, frequency: 3000, quality: 1, sampleRate: Self.rate)
        let filtered = source.meter.latest(6000).map { biquad.process($0) }
        #expect(mismatch(filter.meter.latest(6000), filtered) == nil)
        let tank = ReverbKernel(sampleRate: Self.rate)
        tank.configure(room: 0.5, damp: 0.5, wet: 1)
        #expect(mismatch(reverb.meter.latest(6000), filtered.map { tank.process($0) }) == nil)
    }

    @Test("複数の音を 1 つのエフェクトへ通すと足されて処理され、複数のエフェクトへ通すと出口が足される")
    func fanInAndFanOut() throws {
        let rack = makeRack()
        let first = try addSource(rack, .wave(.sine), [.frequency: 300, .amplitude: 0.3])
        let second = try addSource(rack, .wave(.sine), [.frequency: 500, .amplitude: 0.2])
        let low = try #require(rack.addFilter(.lowPass))
        let high = try #require(rack.addFilter(.highPass))
        connect(rack, low, to: [first, second])
        connect(rack, high, to: [first])
        let heard = render(rack, 3000)

        let gain = Float(0.5).squareRoot()
        let summed = zip(first.meter.latest(3000), second.meter.latest(3000)).map { $0 + $1 }
        var lowFilter = Biquad()
        lowFilter.configure(.lowPass, frequency: 1000, quality: 1, sampleRate: Self.rate)
        #expect(mismatch(low.meter.latest(3000), summed.map { lowFilter.process($0) }) == nil)
        // 左右の出口は 2 つのエフェクトの出口の和
        let expected = zip(low.meter.latest(3000), high.meter.latest(3000)).map {
            ($0 + $1) * gain
        }
        let worst = zip(heard.left, expected).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-6)
    }

    @Test("エフェクトをやめると、通していた音が直に出る形へ戻り、エフェクトの出口は無音になる")
    func stoppingTheEffectReturnsTheSource() throws {
        func rack(withEffect: Bool) throws -> (SynthRack, RackNode?) {
            let rack = makeRack()
            let source = try addSource(rack, .wave(.sine), [.frequency: 700, .amplitude: 0.5])
            guard withEffect else { return (rack, nil) }
            let reverb = try #require(rack.addReverb())
            connect(rack, reverb, to: [source])
            return (rack, reverb)
        }
        let (dry, _) = try rack(withEffect: false)
        let straight = render(dry, 2000)

        let (wet, reverb) = try rack(withEffect: true)
        let through = render(wet, 1000)
        #expect(mismatch(through.left, Array(straight.left.prefix(1000))) != nil)
        wet.setInputs(try #require(reverb).id, 0)
        let after = render(wet, 1000)
        #expect(mismatch(after.left, Array(straight.left.suffix(1000))) == nil)
        #expect(mismatch(after.right, Array(straight.right.suffix(1000))) == nil)
        #expect(try #require(reverb).meter.latest(1000).allSatisfy { $0 == 0 })
    }

    @Test("エフェクトへ入力が戻ったとき、前の尾を持ち越さない")
    func effectStateResetsWhenInputsReturn() throws {
        let rack = makeRack()
        let source = try addSource(rack, .noise(.white), [.amplitude: 0.5])
        let reverb = try #require(rack.addReverb())
        rack.set(reverb.id, .wetness, 1)
        connect(rack, reverb, to: [source])
        _ = render(rack, 4000)
        rack.setInputs(reverb.id, 0)
        _ = render(rack, 100)
        rack.post(SynthCommand(op: .stop, node: UInt8(source.id)))
        _ = render(rack, 12_000)
        // 音源が止まった後で入力を戻すと、前の尾は残っておらず無音のまま
        connect(rack, reverb, to: [source])
        _ = render(rack, 2000)
        #expect(reverb.meter.latest(2000).allSatisfy { $0 == 0 })
    }

    @Test("輪になる通し方は拒み、輪にならない通し方は受ける")
    func cyclesAreRefused() throws {
        let rack = makeRack()
        let source = try addSource(rack, .wave(.sine))
        let first = try #require(rack.addFilter(.lowPass))
        let second = try #require(rack.addFilter(.highPass))
        let third = try #require(rack.addReverb())

        #expect(rack.canConnect(source.id, to: first.id))
        connect(rack, first, to: [source])
        #expect(rack.canConnect(first.id, to: second.id))
        connect(rack, second, to: [first])
        connect(rack, third, to: [second])
        // 自分自身・出口を入口へ戻す・輪を作る
        #expect(!rack.canConnect(first.id, to: first.id))
        #expect(!rack.canConnect(second.id, to: first.id))
        #expect(!rack.canConnect(third.id, to: first.id))
        // 出口の側へ向かうのは構わない
        #expect(rack.canConnect(first.id, to: third.id))
        #expect(rack.canConnect(source.id, to: third.id))
    }

    @Test("輪の中のエフェクトは動かず、出口は無音で、他の音には影響しない")
    func looseCycleIsSilent() throws {
        let rack = makeRack()
        let other = try addSource(rack, .wave(.sine), [.frequency: 440, .amplitude: 0.5])
        let first = try #require(rack.addFilter(.lowPass))
        let second = try #require(rack.addFilter(.lowPass))
        // 主スレッドの確かめを通さずに、音の側へ輪を渡す
        connect(rack, first, to: [second])
        connect(rack, second, to: [first])
        let heard = render(rack, 2000)
        #expect(first.meter.latest(2000).allSatisfy { $0 == 0 })
        #expect(second.meter.latest(2000).allSatisfy { $0 == 0 })
        #expect(heard.left.map { abs($0) }.max() ?? 0 > 0.1)
        #expect(other.meter.latest(2000).map { abs($0) }.max() ?? 0 > 0.1)
    }

    // MARK: - 上限

    @Test("節は 64 個まで作れて、65 個目は作れない")
    func capacityIsBounded() throws {
        let rack = makeRack()
        for _ in 0..<SynthRack.capacity { _ = try #require(rack.addSource(.wave(.sine))) }
        #expect(rack.addSource(.wave(.sine)) == nil)
        #expect(rack.addFilter(.lowPass) == nil)
        #expect(rack.addReverb() == nil)
        #expect(rack.addDelay() == nil)
        // 置いた節は、全部描ける
        let heard = render(rack, 100)
        #expect(heard.left.count == 100)
    }

    @Test("操作の列が埋まると載せられず、描かせて空けると載せられる")
    func commandQueueIsBounded() throws {
        let rack = makeRack()
        let node = try #require(rack.addSource(.wave(.sine)))
        var accepted = 0
        // 節を足したときの 1 つが載っている
        while rack.set(node.id, .frequency, 440) { accepted += 1 }
        #expect(accepted == 4096 - 1)
        #expect(!rack.set(node.id, .frequency, 440))
        _ = render(rack, 10)
        #expect(rack.set(node.id, .frequency, 880))
    }
}
