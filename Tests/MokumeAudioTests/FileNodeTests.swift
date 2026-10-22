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
    /// 立ち上がり (約 5 ミリ秒の時定数) が済んで、立ち上がりの値が 1 に揃った後の位置。
    private static let settled = 4000

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

    @Test("標本化率が同じなら、立ち上がった後はファイルの標本がそのまま出口 (中央) に出て、終わりで止まる")
    func equalRateIsExact() throws {
        let samples = Self.ramp(10_000)
        let rack = makeRack()
        let node = try addFile(rack, samples)
        begin(rack, node)
        let heard = render(rack, 12_000)
        let expected = samples.map { $0 * Self.center } + Array(repeating: 0, count: 2000)
        #expect(
            mismatch(Array(heard.left[Self.settled...]), Array(expected[Self.settled...])) == nil)
        #expect(mismatch(heard.left, heard.right) == nil)
        // 立ち上がりの間は、標本より小さい (鳴らし始めがぷつっと鳴らない)
        #expect(abs(heard.left[100]) < abs(expected[100]) * 0.6)
        // 鳴った数は、終わりまでの数 (主スレッドが終わりと読める)
        #expect(node.played(generation: 1) == 10_000)
        #expect(node.isIdle && node.isFinished)
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
        let whole = try heard(pieces: [8000])
        let expected = (0..<8000).map { samples[(100 + $0) % 1000] * Self.center }
        #expect(
            mismatch(Array(whole[Self.settled...]), Array(expected[Self.settled...])) == nil)
        // 1 標本・512 を越える・中途半端な長さを混ぜる
        let pieces = [1, 300, 511, 513, 7, 1000, 3000, 2668]
        #expect(pieces.reduce(0, +) == 8000)
        #expect(mismatch(try heard(pieces: pieces), whole) == nil)
    }

    @Test("標本化率が低いファイルは、ラックの率で読み直され、1 秒のファイルが 1 秒で終わる")
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

        // 441 Hz の正弦波が、ラックの時間で崩れずに出ている (三次補間の誤差は小さい)
        var worst: Float = 0
        for index in Self.settled..<47_900 {
            let time = Double(index) / Self.rate
            let expected = Float(sin(2 * Double.pi * 441 * time)) * Self.center
            worst = max(worst, abs(whole[index] - expected))
        }
        #expect(worst < 2e-3, "正弦波からのずれ \(worst)")

        // 区間の分け方によらず同じ標本列
        #expect(mismatch(try heard(pieces: [1, 300, 4096, 511, 513, 7, 5000, 38_572]), whole) == nil)
    }

    /// 96000 Hz の標本列を読ませて、立ち上がった後の 1024 標本の帯域ごとの大きさを返す。
    private func downsampledSpectrum(of tone: [Float]) throws -> [Float] {
        let rack = makeRack()
        let node = try addFile(rack, tone, fileRate: 96_000)
        begin(rack, node)
        let heard = render(rack, 30_000).left
        let window = Array(heard[20_000..<(20_000 + AudioAnalysis.windowSize)])
        return AudioAnalysis.analyze(window).spectrum
    }

    @Test("ラックより高い率のファイルは、ラックの半分より上の音を折り返さずに削り、通過帯域は保つ")
    func downsamplingDoesNotAlias() throws {
        func tone(_ frequencies: [Double]) -> [Float] {
            (0..<96_000).map { index in
                let time = Double(index) / 96_000
                return Float(
                    frequencies.map { 0.4 * sin(2 * Double.pi * $0 * time) }.reduce(0, +))
            }
        }
        // 帯域 21 (984.4 Hz)。30 kHz はラックの半分 (24 kHz) より上で、通さずに間引くと
        // 18 kHz (帯域 384) に折り返して濁る
        let spectrum = try downsampledSpectrum(of: tone([984.375, 30_000]))
        let passed = spectrum[21]
        let alias = spectrum[384]
        #expect(abs(passed - 0.4 * Self.center) < 0.02, "1 kHz の大きさ \(passed)")
        #expect(alias < passed * 1e-3, "折り返しの大きさ \(alias) (通過帯域 \(passed))")

        // 通過帯域の高い所 (帯域 213 = 9984 Hz) も大きさが保たれる
        let high = try downsampledSpectrum(of: tone([9984.375]))
        #expect(abs(high[213] - 0.4 * Self.center) < 0.02, "10 kHz の大きさ \(high[213])")
    }

    @Test("ラックより高い率のファイルでも、直流はそのままの大きさで通り、1 秒のファイルが 1 秒で終わる")
    func downsamplingKeepsTheLevelAndTheLength() throws {
        let rack = makeRack()
        let node = try addFile(rack, Array(repeating: 0.5, count: 96_000), fileRate: 96_000)
        begin(rack, node)
        let heard = render(rack, 49_000).left
        #expect(heard[Self.settled..<47_000].allSatisfy { abs($0 - 0.5 * Self.center) < 1e-4 })
        #expect(heard[47_000..<47_900].allSatisfy { abs($0) > 0.1 })
        #expect(heard[48_100...].allSatisfy { $0 == 0 })
        #expect(node.played(generation: 1) == 96_000)
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
    }

    @Test("鳴らし始めは 0 から、止めるときは 0 へ、約 5 ミリ秒の時定数で追う")
    func startsAndStopsWithAFade() throws {
        let rack = makeRack()
        let node = try addFile(rack, Array(repeating: 1, count: 48_000))
        begin(rack, node)
        let first = render(rack, 6000).left
        // 5 ミリ秒 = 240 標本で、立ち上がりの 1 − e^−1 ≈ 0.63
        let rising = first[239] / Self.center
        #expect(abs(rising - 0.632) < 0.03, "240 標本目の立ち上がり \(rising)")
        #expect(first[0] > 0 && first[0] < 0.02 * Self.center, "最初の標本 \(first[0])")
        #expect(abs(first[5999] - Self.center) < 1e-5)

        rack.post(SynthCommand(op: .stop, node: UInt8(node.id)))
        let last = render(rack, 6000).left
        let falling = last[239] / Self.center
        #expect(abs(falling - 0.368) < 0.03, "止めて 240 標本目の消え方 \(falling)")
        #expect(last[0] > 0.9 * Self.center, "止めた直後の標本 \(last[0])")
        // 消えきったら無音で、節は止まっている
        #expect(last[5000...].allSatisfy { $0 == 0 })
        #expect(node.isIdle && node.isFinished)
    }

    @Test("鳴っている最中に区切りを始め直すと、前の区切りが消えながら新しい区切りが立ち上がり、つなぎ目で跳ねない")
    func restartCrossfades() throws {
        // 頭の 5000 標本は 1、その後は 0.5
        let samples =
            Array(repeating: Float(1), count: 5000) + Array(repeating: Float(0.5), count: 20_000)
        let rack = makeRack()
        let node = try addFile(rack, samples)
        begin(rack, node, start: 0, generation: 1)
        let before = render(rack, 4000).left
        #expect(abs(before[3999] - Self.center) < 1e-5)
        begin(rack, node, start: 6000, generation: 2)
        let after = render(rack, 6000).left
        // 区切りを替えた直後は、前の値 (1) から離れていない。**立ち上げ直すだけなら 0.5 へ跳ぶ**
        #expect(after[0] > 0.95 * Self.center, "つなぎ目の最初の標本 \(after[0])")
        // 重なっている間は、2 つの重みの和が 1 のまま滑らかに移る
        #expect(zip(after, after.dropFirst()).allSatisfy { $1 <= $0 + 1e-5 }, "単調に下がる")
        #expect(abs(after[5999] - 0.5 * Self.center) < 1e-5)
    }

    /// 区間ごとに値が違う標本 (1・0.5・0.25 を 6000 標本ずつ。始まる位置 0・6000・12000 で区別する)。
    private static let steps: [Float] =
        Array(repeating: 1, count: 6000) + Array(repeating: 0.5, count: 6000)
        + Array(repeating: 0.25, count: 30_000)

    @Test("始め直しが同じ描き出しの前に 2 つ載っても、鳴っていた区切りは音量のまま消えていく")
    func twoRestartsBeforeOneRender() throws {
        let rack = makeRack()
        let node = try addFile(rack, Self.steps)
        begin(rack, node, start: 0, generation: 1)
        let before = render(rack, 4000).left
        #expect(abs(before[3999] - Self.center) < 1e-5)
        // 1 フレームに play() が 2 回 (または、前のフレームの jump と同じフレームの play())
        begin(rack, node, start: 6000, generation: 2)
        begin(rack, node, start: 12000, generation: 3)
        let after = render(rack, 6000).left
        // 鳴っていた区切り (1) から離れない。**捨てると 0 から立ち上げ直す**
        #expect(after[0] > 0.95 * Self.center, "つなぎ目の最初の標本 \(after[0])")
        #expect(zip(after, after.dropFirst()).allSatisfy { $1 <= $0 + 1e-5 }, "単調に下がる")
        #expect(abs(after[5999] - 0.25 * Self.center) < 1e-5)
        #expect(node.played(generation: 3) == 6000)
    }

    @Test("消えていく区切りが 2 つ重なっても、どちらも自分の音量が 0 になるまで残る")
    func severalFadingSegmentsOverlap() throws {
        let rack = makeRack()
        let node = try addFile(rack, Self.steps)
        begin(rack, node, start: 0, generation: 1)
        _ = render(rack, 4000)
        begin(rack, node, start: 6000, generation: 2)
        let middle = render(rack, 120).left
        begin(rack, node, start: 12000, generation: 3)
        let after = render(rack, 6000).left
        // 1 を出していた区切りは消えながら残っている (0.5 の区切りだけなら、最初の標本は 0.5 以下)
        let last = middle[119]
        #expect(last > 0.7 * Self.center, "2 つ目のつなぎ目の前 \(last)")
        #expect(abs(after[0] - last) < 0.02, "2 つ目のつなぎ目で跳ねない: \(last) → \(after[0])")
        // 3 つが重なっている間は、0.25 の区切りの音量が上がる分だけ、どの標本も 0.25 を下回らない
        #expect(after.allSatisfy { $0 >= 0.25 * Self.center - 1e-5 })
        #expect(abs(after[5999] - 0.25 * Self.center) < 1e-5)
    }

    @Test("始め直しの直後に止めても、鳴っていた区切りは約 5 ミリ秒で消えきるまで鳴る")
    func stoppingRightAfterARestart() throws {
        let rack = makeRack()
        let node = try addFile(rack, Self.steps)
        begin(rack, node, start: 0, generation: 1)
        _ = render(rack, 4000)
        // 同じ描き出しの前に、始め直して止める
        begin(rack, node, start: 6000, generation: 2)
        rack.post(SynthCommand(op: .stop, node: UInt8(node.id)))
        let after = render(rack, 6000).left
        // 止めたときの消え方 (240 標本目で 1/e) と同じ。**捨てると最初の標本から 0**
        #expect(after[0] > 0.95 * Self.center, "止めた直後の標本 \(after[0])")
        let falling = after[239] / Self.center
        #expect(abs(falling - 0.368) < 0.03, "240 標本目の消え方 \(falling)")
        #expect(after[5000...].allSatisfy { $0 == 0 })
        #expect(node.isIdle && node.isFinished)
    }

    @Test("新しい区切りがファイルの終わりに着いても、消えていく前の区切りは切れない")
    func reachingTheEndKeepsTheFadingSegment() throws {
        let rack = makeRack()
        let node = try addFile(rack, Array(repeating: 1, count: 20_000))
        begin(rack, node, start: 0, generation: 1)
        _ = render(rack, 4000)
        // 終わりの 50 標本手前から 1 度だけ鳴らす区切り (すぐ終わりに着く)
        begin(rack, node, start: 19_950, generation: 2)
        let after = render(rack, 5000).left
        // 新しい区切りは 50 標本で終わる。前の区切りは、その後も 240 標本で 1/e に消えていく
        let falling = after[289] / Self.center
        #expect(abs(falling - 0.368) < 0.1, "終わりに着いた後の消え方 \(falling) (50 + 240 標本目)")
        #expect(after[100] > 0.5 * Self.center)
        #expect(after[4500...].allSatisfy { $0 == 0 })
        #expect(node.played(generation: 2) == 50)
        #expect(node.isIdle && node.isFinished)
    }

    @Test("消えていく区切りは 8 つまで。溢れたら、いちばん小さいものを捨てるので、音は跳ねない")
    func fadingSegmentsAreBounded() throws {
        let rack = makeRack()
        let node = try addFile(rack, Array(repeating: 1, count: 48_000))
        begin(rack, node, generation: 1)
        var heard = render(rack, 4000).left
        // 立ち上がり終える前に 20 回始め直す (消えていく区切りが 8 を超える)
        for generation in 2...21 {
            begin(rack, node, start: 0, generation: generation)
            heard += render(rack, 400).left
        }
        heard += render(rack, 6000).left
        #expect(heard.allSatisfy { $0.isFinite && $0 <= Self.center * 1.0001 })
        #expect(abs(heard[heard.count - 1] - Self.center) < 1e-5)
        // 捨てるのは、消えかけてほとんど聞こえないものだけ (跳ねない)
        let jump = zip(heard, heard.dropFirst()).map { abs($1 - $0) }.max() ?? 1
        #expect(jump < 0.005, "隣の標本との差の最大 \(jump)")
    }

    @Test("鳴った数は整数の計算 (描いた数 × ファイルの率 ÷ ラックの率の切り捨て) と、どの標本でも同じ")
    func playedIsExactInIntegers() throws {
        for fileRate in [44_100.0, 22_050.0, 32_000.0, 96_000.0] {
            let rack = makeRack()
            let node = try addFile(rack, Array(repeating: 0.1, count: Int(fileRate) * 2), fileRate: fileRate)
            begin(rack, node)
            var made = 0
            for step in [1, 1, 2, 3, 5, 7, 11, 479, 480, 481, 1000, 4096, 9000] {
                _ = render(rack, step)
                made += step
                let expected = made * Int(fileRate) / 48_000
                #expect(node.played(generation: 1) == expected, "\(fileRate) Hz で \(made) 標本")
            }
            // 1 標本ずつ数えても同じ (掛けてから割る計算なので、割り切れる所で 1 標本低くならない)
            for _ in 0..<3000 {
                _ = render(rack, 1)
                made += 1
                #expect(node.played(generation: 1) == made * Int(fileRate) / 48_000)
            }
        }
    }

    @Test("止めている最中に始め直すと、鳴り続けて立ち上がり直す")
    func startingDuringTheFadeOut() throws {
        let rack = makeRack()
        let node = try addFile(rack, Array(repeating: 1, count: 48_000))
        begin(rack, node)
        _ = render(rack, 4000)
        rack.post(SynthCommand(op: .stop, node: UInt8(node.id)))
        _ = render(rack, 100)
        begin(rack, node, generation: 2)
        let again = render(rack, 6000).left
        #expect(!node.isFinished)
        #expect(abs(again[5999] - Self.center) < 1e-5)
        #expect(again.allSatisfy { $0 > 0 })
    }

    @Test("音量は 1 標本ごとに目標へ追い、作ったときの音量で始まる")
    func amplitudeFollowsTheTarget() throws {
        let rack = makeRack()
        let node = try addFile(rack, Array(repeating: 1, count: 48_000), amplitude: 0.5)
        begin(rack, node)
        let first = render(rack, Self.settled + 2000)
        // 作ったときの音量で立ち上がる (音量の方は追わない)
        #expect(first.left[Self.settled + 1999] == 0.5 * Self.center)
        rack.set(node.id, .amplitude, 0.25)
        let changed = render(rack, 6000)
        #expect(changed.left[0] > 0.25 * Self.center && changed.left[0] < 0.5 * Self.center)
        #expect(abs(changed.left[5999] - 0.25 * Self.center) < 1e-5)
    }

    @Test("手放して消えきった節は置き場が返り、鳴っている間は返らない")
    func aReleasedNodeReturnsItsSlot() throws {
        let rack = makeRack()
        let node = try addFile(rack, Array(repeating: 1, count: 48_000))
        begin(rack, node)
        _ = render(rack, 1000)
        #expect(rack.occupiedCount == 1)
        // 手放すだけでは、鳴っている音は切らず、置き場は返らない
        rack.release(node.id)
        _ = render(rack, 1000)
        rack.collectFreed()
        #expect(rack.occupiedCount == 1)
        // 止めると消えきって、置き場が返る
        rack.post(SynthCommand(op: .stop, node: UInt8(node.id)))
        _ = render(rack, 6000)
        rack.collectFreed()
        #expect(rack.occupiedCount == 0)
    }

    @Test("ラックの置き場が埋まっていれば、ファイルの節は足せない")
    func fullRackRefuses() throws {
        let rack = makeRack()
        for _ in 0..<SynthRack.capacity { _ = try addFile(rack, [0, 0]) }
        #expect(rack.addFile(samples: [0, 0], fileRate: Self.rate, amplitude: 1) == nil)
    }
}
