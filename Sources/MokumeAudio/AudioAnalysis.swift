// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Accelerate
import MokumeCore

/// 1 つの窓を解析した値。``AudioIn`` がフレームごとに 1 つ持つ。
nonisolated struct AudioLevels: Equatable, Sendable {
    /// 窓の二乗平均の平方根 (振幅の単位。全振幅の正弦波で約 0.707)。
    var rms: Float
    /// ``rms`` を dBFS にしたもの。無音は ``AudioAnalysis/floorDecibels``。
    var decibels: Float
    /// ``decibels`` を 0〜1 へ写したもの。
    var level: Float
    /// 帯域ごとの大きさ (振幅の単位。帯域の真ん中にある全振幅の正弦波で 1)。
    var spectrum: [Float]
    /// ``spectrum`` を帯域ごとに dB にして 0〜1 へ写したもの。
    var spectrumLevels: [Float]

    /// 何も鳴っていないときの値。
    static let silence = AudioLevels(
        rms: 0, decibels: AudioAnalysis.floorDecibels, level: 0,
        spectrum: Array(repeating: 0, count: AudioAnalysis.bandCount),
        spectrumLevels: Array(repeating: 0, count: AudioAnalysis.bandCount))
}

/// 音の解析。**機材にも時計にも触れない純粋な関数**で、実機・ファイル・合成した標本列の
/// どれも同じここを通る ([ADR-0042] 決定 6)。
///
/// - 実機は、環 (``SampleRing``) に溜まった最新の窓を ``analyze(_:)`` に通す
/// - ファイルと標本列は、``window(of:sampleRate:endingAt:)`` でフレームの時刻の窓を切り出して
///   から通す。窓がフレームの時刻だけで決まるので、固定の時計で書き出すと何度でも同じ値になる
///   ([ADR-0025] の水準 2)
///
/// ## 生の値と 0〜1 の値を別の名前にする
///
/// 前身の `volume` は振幅をそのまま 0〜1 と名乗り、普通の音量で 0.354 に張り付いた
/// (全振幅の正弦波の RMS が 0.707 で、それより大きくならない)。生の値 (``AudioLevels/rms``・
/// ``AudioLevels/decibels``・``AudioLevels/spectrum``) と、絵に使いやすく写した値
/// (``AudioLevels/level``・``AudioLevels/spectrumLevels``) を別の名前で出す。写し方は
/// **dB の固定の範囲** (``quietDecibels``〜0 dBFS) で、履歴に依らない — 同じ音はいつも同じ値になる。
///
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated enum AudioAnalysis {
    /// 窓の長さ (標本)。
    static let windowSize = 1024
    /// 帯域の数。窓の長さの半分で、帯域 k の真ん中は `k × 標本化率 ÷ windowSize` Hz。
    static let bandCount = windowSize / 2
    /// 0〜1 の値が 0 になる dBFS。これより小さい音は 0 に丸める。
    static let quietDecibels: Float = -60
    /// 無音の dBFS。対数は 0 で -∞ になるので、ここで止める (絵の計算に ∞ を流さない)。
    static let floorDecibels: Float = -160

    /// Hann 窓。
    private static let hann = vDSP.window(
        ofType: Float.self, usingSequence: .hanningDenormalized, count: windowSize,
        isHalfWindow: false)
    /// 窓の重みの和。大きさを振幅の単位へ戻すのに使う。
    private static let hannSum = vDSP.sum(hann)

    /// 窓 1 つを解析する。長さが ``windowSize`` に足りなければ、前を 0 で埋める。
    ///
    /// **呼ぶたびに変換の setup を作る** (11〜12 µs。解析 1 回の 4 分の 3)。純粋な参照の形で、
    /// 検査が「製品の経路の値」と突き合わせる相手でもある。繰り返し解析する側 (``AudioIn``・
    /// ``SoundFile``・``SynthSound``) は ``AudioAnalyzer`` を通る ([#2379])。
    ///
    /// [#2379]: https://github.com/mokume-metal/mokume/issues/2379
    static func analyze(_ window: [Float]) -> AudioLevels {
        analyze(window, using: makeTransform())
    }

    /// 窓の長さの前向きの変換を作る。作るのに時間が掛かるので、繰り返す側は 1 度作って使い回す
    /// (``AudioAnalyzer``)。作れなければ `nil` で、帯域は 0 のまま返る。
    static func makeTransform() -> vDSP.DiscreteFourierTransform<Float>? {
        try? vDSP.DiscreteFourierTransform(
            count: windowSize, direction: .forward, transformType: .complexComplex,
            ofType: Float.self)
    }

    /// 変換の入出力に使う作業領域。**値は持ち越さない** — 呼ぶたびに全部書き直してから読む。
    ///
    /// 窓の長さの配列を 4 本 (窓に重みを掛けた入力・虚部の 0・変換の出力の実部と虚部) 持つ。解析した
    /// 結果 (``AudioLevels/spectrum``・``AudioLevels/spectrumLevels``) はここに置かず、呼ぶたびに新しい
    /// 配列を作って返すので、利用者が保存した値は後の解析で書き換わらない。
    struct Scratch {
        var weighted = [Float](repeating: 0, count: windowSize)
        /// 入力の虚部。実数の入力なので 0 のまま (書き換えない)。
        let imaginary = [Float](repeating: 0, count: windowSize)
        var outputReal = [Float](repeating: 0, count: windowSize)
        var outputImaginary = [Float](repeating: 0, count: windowSize)
    }

    /// 作ってある変換で窓 1 つを解析する。**``analyze(_:)`` と同じ式**で、変換の作り手だけが違う。
    static func analyze(
        _ window: [Float], using transform: vDSP.DiscreteFourierTransform<Float>?
    ) -> AudioLevels {
        var scratch = Scratch()
        return analyze(window, using: transform, scratch: &scratch)
    }

    /// 作ってある変換と作業領域で窓 1 つを解析する。**``analyze(_:)`` と同じ式**で、一時配列の置き場だけが違う
    /// (値はビット一致する)。繰り返し解析する側 (``AudioAnalyzer``) が、作業領域を使い回すために呼ぶ。
    static func analyze(
        _ window: [Float], using transform: vDSP.DiscreteFourierTransform<Float>?,
        scratch: inout Scratch
    ) -> AudioLevels {
        let samples = padded(window)
        let rms = vDSP.rootMeanSquare(samples)
        let decibels = decibels(rms)

        var spectrum = Array(repeating: Float(0), count: bandCount)
        if let transform {
            vDSP.multiply(samples, hann, result: &scratch.weighted)
            transform.transform(
                inputReal: scratch.weighted, inputImaginary: scratch.imaginary,
                outputReal: &scratch.outputReal, outputImaginary: &scratch.outputImaginary)
            for band in 0..<bandCount {
                let real = scratch.outputReal[band]
                let imaginary = scratch.outputImaginary[band]
                let magnitude = (real * real + imaginary * imaginary).squareRoot()
                // 正の周波数と負の周波数に半分ずつ分かれるので 2 倍する (直流は分かれない)
                spectrum[band] = magnitude * (band == 0 ? 1 : 2) / hannSum
            }
        }
        return AudioLevels(
            rms: rms, decibels: decibels, level: level(decibels), spectrum: spectrum,
            spectrumLevels: spectrum.map { level(Self.decibels($0)) })
    }

    /// 標本列から、時刻 `time` (秒) で終わる窓を切り出す。
    ///
    /// - 列の始まりより前は 0 (鳴る前の無音)
    /// - 列の終わりより後は、始まりへ戻って続ける (``Sketch/createCapture(frames:mirrored:)`` と同じ)
    static func window(of samples: [Float], sampleRate: Float, endingAt time: Double) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else {
            return Array(repeating: 0, count: windowSize)
        }
        let end = Int((time * Double(sampleRate)).rounded(.down))
        return (0..<windowSize).map { offset in
            let index = end - windowSize + offset
            return index < 0 ? 0 : samples[index % samples.count]
        }
    }

    /// 振幅を dBFS にする。
    static func decibels(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return floorDecibels }
        return max(20 * RuntimeMath.log10(amplitude), floorDecibels)
    }

    /// dBFS を 0〜1 へ写す。``quietDecibels`` が 0、0 dBFS が 1 で、外は丸める。
    static func level(_ decibels: Float) -> Float {
        min(max((decibels - quietDecibels) / -quietDecibels, 0), 1)
    }

    private static func padded(_ window: [Float]) -> [Float] {
        if window.count == windowSize { return window }
        if window.count > windowSize { return Array(window.suffix(windowSize)) }
        return Array(repeating: 0, count: windowSize - window.count) + window
    }
}

/// 製品の経路の解析器。**変換の setup を 1 つ持ち、使い回す** ([#2379])。
///
/// 変換は `Sendable` でないので、呼ぶ側と同じ main actor に置く。解析する側 (``AudioIn``・
/// ``SoundFile``・``SynthSound``) はどれも main actor の上で解析するので、共有しても競合は無い。
/// 変換の入出力の作業領域 (16 KB) も 1 組だけ持って使い回す ([#3086])。音源ごとには持たない。
///
/// 以前は「フレームに 1 度で、数十マイクロ秒」を前提に呼ぶたびに作っていたが、合成音が音ごとに
/// 解析するようになって前提が崩れた (最大 64 個で 1 フレームに 64 回)。
///
/// [#2379]: https://github.com/mokume-metal/mokume/issues/2379
/// [#3086]: https://github.com/mokume-metal/mokume/issues/3086
final class AudioAnalyzer {
    static let shared = AudioAnalyzer()

    private let transform = AudioAnalysis.makeTransform()
    /// 変換の作業領域。解析のたびに書き直すので、呼び出しの間に値は持ち越さない。
    private var scratch = AudioAnalysis.Scratch()
    /// 解析した回数。**検査が読む** — 製品の経路がここを通ることと、読まれない値は解析しないことを
    /// 数で見る。
    private(set) var analyses = 0

    func analyze(_ window: [Float]) -> AudioLevels {
        analyses += 1
        return AudioAnalysis.analyze(window, using: transform, scratch: &scratch)
    }
}

/// フレームの頭で切り出した窓と、読まれたときにそれを解いた値。
///
/// **窓はフレームの頭で決める。解析だけを読まれたときまで遅らせる** ([#2379])。読んだ値は、遅らせても
/// 毎フレーム解析したときと同じ (ビット一致) — 遅らせた分に進んだ標本は拾わない。同じフレームで
/// 何度読んでも解析は 1 回で、読まれなかったフレームの窓は次の窓に置き換わって解かれない。
///
/// [#2379]: https://github.com/mokume-metal/mokume/issues/2379
struct DeferredLevels {
    /// まだ解いていない、フレームの頭の窓。
    private var window: [Float]?
    /// 解いた値、または無音。
    private var solved = AudioLevels.silence
    /// 解いた回数。検査が読む。
    private(set) var analyses = 0

    /// このフレームの窓を置く。前の窓が解かれていなくても捨てる。
    mutating func hold(_ window: [Float]) { self.window = window }

    /// 無音にする。
    mutating func silence() {
        window = nil
        solved = .silence
    }

    /// 読まれた値。窓が残っていればここで 1 回だけ解く。
    mutating func levels() -> AudioLevels {
        if let held = window {
            solved = AudioAnalyzer.shared.analyze(held)
            analyses += 1
            window = nil
        }
        return solved
    }
}
