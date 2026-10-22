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
/// ## 始まりと止まりは約 5 ミリ秒かけて立ち上がる・消える
///
/// 合成した音源 (``SourceNode``) と同じ約束にそろえてある。鳴らし始めは 0 から、止めるときは 0 へ、
/// 約 5 ミリ秒の時定数で追う。**鳴っている最中に区切りを始め直したとき** (頭から鳴らし直す・飛ぶ) は、
/// 前の区切りが同じ速さで消えながら、新しい区切りが立ち上がる (つなぎ目でぷつっと鳴らない)。
/// 1 度だけ鳴らして**ファイルの終わりに着いた**ときは、ファイルが終わるので、そこで止まる。
///
/// ## 標本化率の変換
///
/// ラックの標本化率は、実機の出力でも書き出し (`mokume render`) でも 48000 Hz である (機材に出さない
/// 検査の流れだけは、描かせる形式の率になる — ``SoundFlow/synthesisRate``)。ファイルの率が同じなら、位置が
/// 整数になるので標本がそのまま出る。違えば、次のように読み直す。補間は標本ごとの算術と、起動時に作る
/// 係数の表だけで、OS の変換器に依らないので、同じ設定から同じ標本列が出る ([ADR-0025] の水準 2)。
///
/// - **ラックより低い率のファイル** (44100 Hz など): 位置の前後 4 標本の三次補間 (Catmull-Rom — 標本の
///   位置では標本そのままを通る)
/// - **ラックより高い率のファイル** (96000 Hz など): ラックの率の半分の少し手前を切れ目とする
///   低域通過 (ブラックマン窓つきの sinc) を掛けながら読む。通さずに間引くと、ラックの半分より上の音が
///   折り返して低い所に濁りとして出る
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
/// ## 置き場の返し方
///
/// 作者が ``SoundFile`` を手放したとき (``SoundFile/close()``)、止めてから手放しを伝える。止まって消え
/// きった節 (``isFinished``) の置き場が戻る (``SynthRack`` の「置き場は、手放して鳴り終えた音源のぶんだけ
/// 戻る」)。
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
    /// ラックより高い率のファイルを読む低域通過の係数。ラックの率以下なら `nil` (三次補間で読む)。
    private let lowPass: DownsamplingKernel?

    private var amplitude: Float
    private var amplitudeNow: Float
    private let smoothing: Float

    /// 区切りが続いているか (止める途中の消えていく間も続いている)。
    private var playing = false
    private var looping = false
    /// 区切りの始まりの位置 (ファイルの標本)。
    private var start = 0
    /// 区切りが始まってから作った標本の数 (ラックの標本)。
    private var count = 0
    private var generation = 0
    /// 立ち上がり・消え方 (0〜1)。``SourceNode`` の `gate` と同じ。
    private var gate: Float = 0
    private var gateTarget: Float = 0
    /// 区切りを始め直したとき、消えていく前の区切り。
    private var fading: Segment?
    private var fadingGain: Float = 0
    /// 世代 (上位) と、区切りの中で鳴った標本の数 (下位・ファイルの標本)。
    private let progress = Atomic<UInt64>(0)

    /// 区切りの位置を導くのに要るもの。
    private struct Segment {
        var start: Int
        var count: Int
        var looping: Bool
    }

    init(
        id: Int, sampleRate: Double, meter: SampleRing, samples: [Float], fileRate: Double,
        amplitude: Float
    ) {
        self.samples = samples
        ratio = fileRate / sampleRate
        lowPass = fileRate > sampleRate ? DownsamplingKernel(ratio: fileRate / sampleRate) : nil
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

    /// 止まって消えきったか。手放された節は、これが `true` になってから置き場が戻る。
    override var isFinished: Bool { !playing }

    override func apply(_ param: SynthParam, _ value: Float) {
        if param == .amplitude { amplitude = value }
    }

    override func begin(_ bits: UInt64) {
        if playing && gate > 0 {
            // 鳴っている最中の始め直しは、前の区切りを消しながら新しい区切りを立ち上げる
            fading = Segment(start: start, count: count, looping: looping)
            fadingGain = gate
        } else {
            fading = nil
            fadingGain = 0
        }
        start = min(Int(bits & Self.countMask), samples.count)
        looping = bits & Self.loopingBit != 0
        generation = Int((bits >> (Self.countBits + 1)) & Self.generationMask)
        count = 0
        gate = 0
        gateTarget = 1
        playing = true
        publish(0)
    }

    override func halt() {
        gateTarget = 0
    }

    /// `current` を `target` へ 1 標本ぶん近づける (``SourceNode`` と同じ追い方)。**十分近づいたら
    /// `target` に揃える** — 揃えないと、1 付近では差が 1e-5 のあたりで止まって届かない。
    private func approach(_ current: Float, _ target: Float) -> Float {
        let next = current + (target - current) * smoothing
        return next == current || abs(target - next) < 1e-6 ? target : next
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
        var ended = false
        samples.withUnsafeBufferPointer { source in
            while made < frames {
                let position = Double(start) + Double(count) * ratio
                if !looping, position >= Double(length) {
                    // ファイルの終わり。ファイルが終わるので、消えるのを待たずに止まる
                    ended = true
                    playing = false
                    gate = 0
                    gateTarget = 0
                    fading = nil
                    break
                }
                gate = approach(gate, gateTarget)
                if gateTarget == 0, gate == 0 {
                    // 止める途中の消え方が終わった
                    playing = false
                    fading = nil
                    break
                }
                amplitudeNow = approach(amplitudeNow, amplitude)
                var value = read(source, at: position, looping: looping) * gate
                if var previous = fading {
                    let before = Double(previous.start) + Double(previous.count) * ratio
                    if previous.looping || before < Double(length) {
                        value += read(source, at: before, looping: previous.looping) * fadingGain
                        previous.count += 1
                        fading = previous
                        fadingGain = approach(fadingGain, 0)
                        if fadingGain == 0 { fading = nil }
                    } else {
                        fading = nil
                    }
                }
                output[made] = value * amplitudeNow
                made += 1
                count += 1
            }
        }
        if made < frames { (output + made).update(repeating: 0, count: frames - made) }
        // 1 度だけで終わりに着いたら、鳴った数は終わりまでの数にする (主スレッドが終わりと読めるように)
        let reached = Int((Double(count) * ratio).rounded(.down))
        publish(ended ? length - start : reached)
    }

    private func publish(_ played: Int) {
        let bounded = UInt64(max(0, played)) & Self.countMask
        progress.store(UInt64(generation) << Self.countBits | bounded, ordering: .releasing)
    }

    // MARK: - 読み出し

    /// `position` (ファイルの標本・小数) の値。ループなら端を折り返して読み、1 度だけなら端の標本を保って読む。
    private func read(
        _ source: UnsafeBufferPointer<Float>, at position: Double, looping: Bool
    ) -> Float {
        let length = source.count
        let floor = position.rounded(.down)
        let fraction = position - floor
        var base = floor
        if looping { base = base.truncatingRemainder(dividingBy: Double(length)) }
        let index = Int(base)
        func at(_ place: Int) -> Float {
            if looping { return source[((place % length) + length) % length] }
            return source[min(max(place, 0), length - 1)]
        }
        if let lowPass { return lowPass.apply(at: index, fraction: fraction, read: at) }
        let near = at(index)
        guard fraction != 0 else { return near }
        let before = at(index - 1)
        let next = at(index + 1)
        let after = at(index + 2)
        let t = Float(fraction)
        let cubic = -0.5 * before + 1.5 * near - 1.5 * next + 0.5 * after
        let square = before - 2.5 * near + 2 * next - 0.5 * after
        let slope = -0.5 * before + 0.5 * next
        return ((cubic * t + square) * t + slope) * t + near
    }
}

/// ラックより高い率のファイルを、折り返しを抑えて読むための低域通過の係数 (ブラックマン窓つきの sinc)。
///
/// 切れ目はラックの率の 0.46 倍 (ラックの半分より少し手前)。係数は位置の小数部ごとの表 (256 段階 +
/// 1 本) に起動時に 1 度だけ作り、読むときは隣り合う 2 段を線形に混ぜる。**各段は和が 1 に揃えてある**
/// ので、直流 (と、通過帯域の低い音) はそのままの大きさで通る。係数を作る三角関数は ``RuntimeMath`` を
/// 通すので、機械によらず同じ表になる。
nonisolated struct DownsamplingKernel {
    /// 位置の小数部の段階の数。
    private static let phases = 256
    /// 切れ目までの零点の数 (片側)。多いほど切れ目の鋭さと遮断が増え、読む標本の数も増える。
    private static let crossings = 12.0
    /// 切れ目 (ラックの率に対する割合)。
    private static let cutoff = 0.46

    /// 位置の前後に何標本ずつ読むか (片側)。
    private let half: Int
    /// 段 × 標本の表。段 `k` の係数は `k × (2·half)` から `2·half` 個。
    private let table: [Float]

    /// - Parameter ratio: ファイルの率 ÷ ラックの率 (1 より大きい)。
    init(ratio: Double) {
        // ファイルの標本で測った切れ目 (周期 / 標本) と、零点の間隔 (標本)
        let cutoff = Self.cutoff / ratio
        let spacing = 1 / (2 * cutoff)
        let half = Int((Self.crossings * spacing).rounded(.up))
        self.half = half
        let taps = 2 * half
        var table = [Float](repeating: 0, count: (Self.phases + 1) * taps)
        for phase in 0...Self.phases {
            let fraction = Double(phase) / Double(Self.phases)
            var row = [Double](repeating: 0, count: taps)
            var total = 0.0
            for tap in 0..<taps {
                // 位置 `index + fraction` から、標本 `index + offset` までの距離
                let offset = Double(tap - (half - 1))
                let distance = offset - fraction
                let argument = 2 * cutoff * distance
                let sinc: Double
                if argument == 0 {
                    sinc = 1
                } else {
                    sinc = RuntimeMath.sin(Double.pi * argument) / (Double.pi * argument)
                }
                let w = distance / Double(half)
                let window =
                    abs(w) >= 1
                    ? 0
                    : 0.42 + 0.5 * RuntimeMath.cos(Double.pi * w)
                        + 0.08 * RuntimeMath.cos(2 * Double.pi * w)
                let value = 2 * cutoff * sinc * window
                row[tap] = value
                total += value
            }
            for tap in 0..<taps { table[phase * taps + tap] = Float(row[tap] / total) }
        }
        self.table = table
    }

    /// 位置 `index + fraction` の値。`read` は標本の番号から標本を返す (端の扱いは呼ぶ側が決める)。
    func apply(at index: Int, fraction: Double, read: (Int) -> Float) -> Float {
        let taps = 2 * half
        let scaled = fraction * Double(Self.phases)
        let phase = min(Int(scaled), Self.phases - 1)
        let mix = Float(scaled - Double(phase))
        var near: Float = 0
        var far: Float = 0
        table.withUnsafeBufferPointer { coefficients in
            let lower = phase * taps
            let upper = lower + taps
            for tap in 0..<taps {
                let value = read(index + tap - (half - 1))
                near += coefficients[lower + tap] * value
                far += coefficients[upper + tap] * value
            }
        }
        return near + (far - near) * mix
    }
}
