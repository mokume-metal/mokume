// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore
import Synchronization

/// 音声ファイルの標本を、ラックの時計で読み出す音源の節 (#2220)。
///
/// ``SoundFile`` が合成した音と同じエフェクトへ通されたときだけ作られる。通されていないファイルは
/// ``FilePlayer`` が鳴らすままで、この節は関わらない。
///
/// ## 位置は毎回導く
///
/// 区切りは ``segment(start:looping:generation:)`` で始まる。区切りの中で `n` 標本目に読む位置は
/// `start + n × (ファイルの標本化率 ÷ ラックの標本化率)` で、足し込まずに毎回導く。描かせる区切り方
/// (音の側の 1 回に何標本か) が変わっても、同じ位置の音が出る。ループなら位置をファイルの長さで
/// 折り返し、1 度だけなら終わりに着いた標本で止まる。
///
/// ## 標本化率の変換
///
/// 標本化率が同じなら、位置が整数になるので、ファイルの標本がそのまま出る。違えば、位置の前後
/// 4 標本の三次補間 (Catmull-Rom — 標本の位置では標本そのままを通る) で読む。ラックの標本化率は
/// 実機では 48000 Hz、書き出しでは `manualRenderingFormat` の率で、ファイルは 44100 Hz などのまま
/// である。補間は標本ごとの算術だけで、OS の変換器に依らないので、同じ設定から同じ標本列が出る
/// ([ADR-0025] の水準 2)。
///
/// ## 左右は畳む
///
/// ``SoundFile`` が持つのはチャンネルを平均したモノラルの標本列で、この節の出口は中央に定位する
/// (エフェクトの出口と同じ)。
///
/// ## 進み具合の返し方
///
/// 主スレッドは、区切りの中で何標本鳴ったかを ``played(generation:)`` で読む。**区切りの世代と標本の
/// 数を 1 つの原子値に詰めて**書くので、主スレッドが世代と数を別々の時点で読んで取り違えることが
/// 無い。
///
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
nonisolated final class FileNode: RackNode {
    /// 世代の幅 (ビット)。`bits` と原子値の両方に使う。
    private static let generationBits: UInt64 = 23
    /// 位置・鳴った標本の数の幅 (ビット)。2^40 標本は 48 kHz で約 266 日。
    private static let countBits: UInt64 = 40
    private static let countMask: UInt64 = (1 << countBits) - 1
    private static let generationMask: UInt64 = (1 << generationBits) - 1
    private static let loopingBit: UInt64 = 1 << countBits

    /// ファイルの標本 (チャンネルを平均したモノラル)。
    private let samples: [Float]
    /// ラックの 1 標本で進む、ファイルの標本の数 (ファイルの率 ÷ ラックの率)。
    private let ratio: Double

    private var amplitude: Float
    private var amplitudeNow: Float
    private let smoothing: Float

    private var playing = false
    private var looping = false
    /// 区切りの始まりの位置 (ファイルの標本)。
    private var start = 0
    /// 区切りが始まってから作った標本の数 (ラックの標本)。
    private var count = 0
    private var generation = 0
    /// 世代 (上位) と、区切りの中で鳴った標本の数 (下位・ファイルの標本)。
    private let progress = Atomic<UInt64>(0)

    init(
        id: Int, sampleRate: Double, meter: SampleRing, samples: [Float], fileRate: Double,
        amplitude: Float
    ) {
        self.samples = samples
        ratio = fileRate / sampleRate
        self.amplitude = amplitude
        amplitudeNow = amplitude
        smoothing = Float(1 - RuntimeMath.exp(-1 / (0.005 * sampleRate)))
        super.init(id: id, sampleRate: sampleRate, meter: meter)
    }

    // MARK: - 主スレッド

    /// 区切りを始める操作の `bits`。
    ///
    /// - Parameters:
    ///   - start: 始まる位置 (ファイルの標本)。
    ///   - looping: 終わりから頭へ戻って続けるか。
    ///   - generation: 区切りの世代。主スレッドが区切りごとに変え、``played(generation:)`` で
    ///     その区切りの進み具合だけを読む。
    static func segment(start: Int, looping: Bool, generation: Int) -> UInt64 {
        UInt64(max(0, start)) & countMask | (looping ? loopingBit : 0)
            | (UInt64(truncatingIfNeeded: generation) & generationMask) << (countBits + 1)
    }

    /// 世代 `generation` の区切りで、いままでに鳴った標本の数 (ファイルの標本)。その区切りがまだ
    /// 音の側へ届いていなければ 0。
    func played(generation: Int) -> Int {
        let value = progress.load(ordering: .acquiring)
        let seen = (value >> Self.countBits) & Self.generationMask
        guard seen == UInt64(truncatingIfNeeded: generation) & Self.generationMask else { return 0 }
        return Int(value & Self.countMask)
    }

    // MARK: - 音の側

    override var isSource: Bool { true }

    override var isIdle: Bool { !playing }

    override func apply(_ param: SynthParam, _ value: Float) {
        if param == .amplitude { amplitude = value }
    }

    override func begin(_ bits: UInt64) {
        start = min(Int(bits & Self.countMask), samples.count)
        looping = bits & Self.loopingBit != 0
        generation = Int((bits >> (Self.countBits + 1)) & Self.generationMask)
        count = 0
        playing = true
        publish(0)
    }

    override func halt() {
        playing = false
    }

    /// 音量を 1 標本ずつ目標へ近づける (``SourceNode`` と同じ追い方)。
    private func approach() {
        let next = amplitudeNow + (amplitude - amplitudeNow) * smoothing
        amplitudeNow = next == amplitudeNow || abs(amplitude - next) < 1e-6 ? amplitude : next
    }

    override func render(
        frames: Int, input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>
    ) {
        guard playing, !samples.isEmpty else {
            output.update(repeating: 0, count: frames)
            return
        }
        let length = samples.count
        var made = 0
        samples.withUnsafeBufferPointer { source in
            while made < frames {
                let position = Double(start) + Double(count) * ratio
                if !looping, position >= Double(length) {
                    playing = false
                    break
                }
                approach()
                output[made] = Self.value(source, at: position, looping: looping) * amplitudeNow
                made += 1
                count += 1
            }
        }
        if made < frames { (output + made).update(repeating: 0, count: frames - made) }
        // 1 度だけで終わりに着いたら、鳴った数は終わりまでの数にする (主スレッドが終わりと読めるように)
        let reached = Int((Double(count) * ratio).rounded(.down))
        publish(looping || playing ? reached : length - start)
    }

    private func publish(_ played: Int) {
        let bounded = UInt64(max(0, played)) & Self.countMask
        progress.store(UInt64(generation) << Self.countBits | bounded, ordering: .releasing)
    }

    /// `position` (ファイルの標本・小数) の値。位置が整数なら標本そのまま、そうでなければ前後 4 標本の
    /// 三次補間。ループなら端を折り返して読み、1 度だけなら端の標本を保って読む。
    private static func value(
        _ source: UnsafeBufferPointer<Float>, at position: Double, looping: Bool
    ) -> Float {
        let length = source.count
        var base = position.rounded(.down)
        if looping { base = base.truncatingRemainder(dividingBy: Double(length)) }
        let index = Int(base)
        let fraction = Float(position - position.rounded(.down))
        func at(_ offset: Int) -> Float {
            let place = index + offset
            if looping { return source[((place % length) + length) % length] }
            return source[min(max(place, 0), length - 1)]
        }
        let near = at(0)
        guard fraction != 0 else { return near }
        let before = at(-1)
        let next = at(1)
        let after = at(2)
        let cubic = -0.5 * before + 1.5 * near - 1.5 * next + 0.5 * after
        let square = before - 2.5 * near + 2 * next - 0.5 * after
        let slope = -0.5 * before + 0.5 * next
        return ((cubic * fraction + square) * fraction + slope) * fraction + near
    }
}
