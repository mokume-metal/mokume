// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Accelerate

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
    static func analyze(_ window: [Float]) -> AudioLevels {
        let samples = padded(window)
        let rms = vDSP.rootMeanSquare(samples)
        let decibels = decibels(rms)

        var spectrum = Array(repeating: Float(0), count: bandCount)
        // 変換は `Sendable` でないので共有せず、呼ぶたびに作る (フレームに 1 度で、数十マイクロ秒)
        if let transform = try? vDSP.DiscreteFourierTransform(
            count: windowSize, direction: .forward, transformType: .complexComplex,
            ofType: Float.self)
        {
            let real = vDSP.multiply(samples, hann)
            let imaginary = [Float](repeating: 0, count: windowSize)
            let output = transform.transform(real: real, imaginary: imaginary)
            for band in 0..<bandCount {
                let magnitude = (output.real[band] * output.real[band]
                    + output.imaginary[band] * output.imaginary[band]).squareRoot()
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
    /// - 列の終わりより後は、始まりへ戻って続ける (``Sketch/createCapture(frames:)`` と同じ)
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
        return max(20 * log10(amplitude), floorDecibels)
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
