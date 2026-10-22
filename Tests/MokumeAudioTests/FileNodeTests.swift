// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeAudio

/// ファイルの標本を、ラックの時計で読み出す節 (#2220)。描くのは純粋な処理なので、GPU も機材も要らない。
@Suite("ファイルの節")
struct FileNodeTests {
    private static let rate = 48_000.0
    /// 中央に定位した節の出口の係数 (``RackNode/mix(_:frames:left:right:)``)。
    private static let center = Float(0.5).squareRoot()

    /// 位置が分かる標本 (index を 1000 で割った値)。
    private static func ramp(_ count: Int) -> [Float] {
        (0..<count).map { Float($0) / 1000 }
    }

    private func makeRack() -> SynthRack {
        SynthRack(sampleRate: Self.rate)
    }

    private func addFile(
        _ rack: SynthRack, _ samples: [Float], fileRate: Double = rate, amplitude: Float = 1
    ) throws -> FileNode {
        try #require(rack.addFile(samples: samples, fileRate: fileRate, amplitude: amplitude))
    }

    private func begin(
        _ rack: SynthRack, _ node: FileNode, start: Int = 0, looping: Bool = false, generation: Int = 1
    ) {
        rack.post(
            SynthCommand(
                op: .segment, node: UInt8(node.id),
                bits: FileNode.segment(start: start, looping: looping, generation: generation)))
    }

    @Test("標本化率が同じなら、ファイルの標本がそのまま出口 (中央) に出て、終わりで止まる")
    func equalRateIsExact() throws {
        let samples = Self.ramp(3000)
        let rack = makeRack()
        let node = try addFile(rack, samples)
        begin(rack, node)
        let heard = render(rack, 4000)
        let expected = samples.map { $0 * Self.center } + Array(repeating: 0, count: 1000)
        #expect(mismatch(heard.left, expected) == nil)
        #expect(mismatch(heard.left, heard.right) == nil)
        // 鳴った数は、終わりまでの数 (主スレッドが終わりと読める)
        #expect(node.played(generation: 1) == 3000)
        #expect(node.isIdle)
    }

    @Test("始まる位置から鳴り、ループは終わりから頭へ戻って続け、描く区切り方によらず同じ標本列になる")
    func startOffsetAndLoop() throws {
        let samples = Self.ramp(1000)
        func heard(pieces: [Int]) throws -> [Float] {
            let rack = makeRack()
            let node = try addFile(rack, samples)
            begin(rack, node, start: 100, looping: true)
            return render(rack, pieces: pieces).left
        }
        let whole = try heard(pieces: [2500])
        let expected = (0..<2500).map { samples[(100 + $0) % 1000] * Self.center }
        #expect(mismatch(whole, expected) == nil)
        // 1 標本・512 を越える・中途半端な長さを混ぜる
        let pieces = [1, 300, 511, 513, 7, 1000, 168]
        #expect(pieces.reduce(0, +) == 2500)
        #expect(mismatch(try heard(pieces: pieces), whole) == nil)
    }

    @Test("標本化率が違うファイルは、ラックの率で読み直され、1 秒のファイルが 1 秒で終わる")
    func resamplesToTheRackRate() throws {
        // 44100 Hz で 441 Hz (ちょうど 100 標本で 1 周期)・1 秒
        let samples = (0..<44_100).map { Float(sin(2 * Double.pi * Double($0) / 100)) }
        func heard(pieces: [Int]) throws -> [Float] {
            let rack = makeRack()
            let node = try addFile(rack, samples, fileRate: 44_100)
            begin(rack, node)
            return render(rack, pieces: pieces).left
        }
        let whole = try heard(pieces: [49_000])
        // 48000 標本ぶん鳴って、その後は無音
        #expect(whole[47_000..<48_000].contains { abs($0) > 0.1 })
        #expect(whole[48_000...].allSatisfy { $0 == 0 })
        #expect(whole[47_990..<48_000].contains { $0 != 0 })

        // 440 ではなく 441 Hz の正弦波が、ラックの時間で崩れずに出ている (三次補間の誤差は小さい)
        var worst: Float = 0
        for index in 100..<47_900 {
            let time = Double(index) / Self.rate
            let expected = Float(sin(2 * Double.pi * 441 * time)) * Self.center
            worst = max(worst, abs(whole[index] - expected))
        }
        #expect(worst < 2e-3, "正弦波からのずれ \(worst)")

        // 区切り方によらず同じ標本列
        #expect(mismatch(try heard(pieces: [1, 300, 4096, 511, 513, 7, 5000, 38_572]), whole) == nil)
    }

    @Test("鳴った数は区切りの世代つきで返り、新しい区切りが届くまでは 0 になる")
    func playedCarriesTheGeneration() throws {
        let rack = makeRack()
        let node = try addFile(rack, Self.ramp(10_000))
        begin(rack, node, generation: 1)
        _ = render(rack, 800)
        #expect(node.played(generation: 1) == 800)
        // 新しい区切りを頼んだが、音の側がまだ受け取っていない間は、新しい世代の数は 0
        begin(rack, node, start: 5000, generation: 2)
        #expect(node.played(generation: 2) == 0)
        #expect(node.played(generation: 1) == 800)
        _ = render(rack, 300)
        #expect(node.played(generation: 2) == 300)
        // 古い世代の数は、新しい区切りが始まったら読めない
        #expect(node.played(generation: 1) == 0)
        // 区切りの頭の標本は、始まる位置のもの
        let again = render(rack, 1)
        #expect(again.left[0] == Self.ramp(10_000)[5300] * Self.center)
    }

    @Test("止めると無音になり、音量は 1 標本ごとに目標へ追って、始める前から目標のまま始まる")
    func haltAndAmplitude() throws {
        let rack = makeRack()
        let node = try addFile(rack, Array(repeating: 1, count: 48_000), amplitude: 0.5)
        begin(rack, node)
        let first = render(rack, 2000)
        // 作ったときの音量で始まる (立ち上がりで追わない)
        #expect(first.left[0] == 0.5 * Self.center)
        #expect(first.left[1999] == 0.5 * Self.center)
        rack.set(node.id, .amplitude, 0.25)
        let changed = render(rack, 6000)
        #expect(changed.left[0] > 0.25 * Self.center && changed.left[0] < 0.5 * Self.center)
        #expect(abs(changed.left[5999] - 0.25 * Self.center) < 1e-5)
        rack.post(SynthCommand(op: .stop, node: UInt8(node.id)))
        let stopped = render(rack, 100)
        #expect(stopped.left.allSatisfy { $0 == 0 })
    }

    @Test("ラックの置き場が埋まっていれば、ファイルの節は足せない")
    func fullRackRefuses() throws {
        let rack = makeRack()
        for _ in 0..<SynthRack.capacity { _ = try addFile(rack, [0, 0]) }
        #expect(rack.addFile(samples: [0, 0], fileRate: Self.rate, amplitude: 1) == nil)
    }
}
