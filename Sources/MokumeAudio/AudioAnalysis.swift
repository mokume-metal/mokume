// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Accelerate
import MokumeCore

/// 1 つの区間を解析した値。``AudioIn`` がフレームごとに 1 つ持つ。
nonisolated struct AudioLevels: Equatable, Sendable {
    /// 区間の二乗平均の平方根 (振幅の単位。全振幅の正弦波で約 0.707)。
    var rms: Float
    /// ``rms`` を dBFS にしたもの。無音は ``AudioAnalysis/floorDecibels``。
    var decibels: Float
    /// ``decibels`` を 0〜1 へ写したもの。
    var level: Float
    /// 区間の標本の絶対値の最大 (振幅の生の値。全振幅の正弦波で約 1)。
    var peak: Float
    /// 帯域ごとの大きさ (振幅の単位。帯域の真ん中にある全振幅の正弦波で 1)。区間に終わりが入る
    /// 格子の窓の平均。
    var spectrum: [Float]
    /// ``spectrum`` を帯域ごとに dB にして 0〜1 へ写したもの。
    var spectrumLevels: [Float]

    /// 何も鳴っていないときの値。
    static let silence = AudioLevels(
        rms: 0, decibels: AudioAnalysis.floorDecibels, level: 0, peak: 0,
        spectrum: Array(repeating: 0, count: AudioAnalysis.bandCount),
        spectrumLevels: Array(repeating: 0, count: AudioAnalysis.bandCount))
}

/// 解析する区間と、それを覆うのに要る標本。**音源の標本 0 からの通し番号**で持つ。
///
/// 区間は ``from`` (含む) から ``to`` (含まない) まで — 前のフレームの区間の終わりから、このフレームの
/// 区間の終わりまで。標本は区間の前の履歴 (最初の窓の頭まで) も含み、``base`` から ``to`` までを並べる。
/// 始まりの 0 より前と ``base`` より前は 0 として読む。
nonisolated struct AudioSpan: Equatable, Sendable {
    /// `samples[0]` の通し番号。
    var base: Int
    /// ``base`` から ``to`` までの標本。
    var samples: [Float]
    /// 区間の始まり (通し番号。含む)。
    var from: Int

    /// 区間の終わり (通し番号。含まない)。
    var to: Int { base + samples.count }
    /// 区間に標本が 1 つも無いか。
    var isEmpty: Bool { from >= to }

    init(base: Int, samples: [Float], from: Int) {
        self.base = base
        self.samples = samples
        self.from = from
    }

    /// 標本列の全部を 1 つの区間にする (頭が標本 0)。
    init(window: [Float]) {
        self.init(base: 0, samples: window, from: 0)
    }

    /// 区間の終わりで終わる `count` 標本 (古い順)。標本 0 より前と、持っていない前の履歴は 0。
    func tail(_ count: Int) -> [Float] {
        let start = to - count
        if start >= base { return Array(samples[(start - base)...]) }
        let missing = min(base - start, count)
        return [Float](repeating: 0, count: missing) + samples.suffix(count - missing)
    }

    /// 全部の標本に `gain` を掛けた区間。
    func scaled(by gain: Float) -> AudioSpan {
        AudioSpan(base: base, samples: vDSP.multiply(gain, samples), from: from)
    }
}

/// 音の解析。**機材にも時計にも触れない純粋な関数**で、実機・ファイル・合成した標本列の
/// どれも同じここを通る ([ADR-0042] 決定 6)。
///
/// ## 解析するのは、前のフレームの区間の終わりから、このフレームの区間の終わりまでの全標本
///
/// 入力は区間 (``AudioSpan``) で、各音源が自分の標本 0 からの通し番号で渡す ([ADR-0042] 決定 6 の改訂
/// 〔2026-10-23〕・[#3136])。1 フレームに 1 窓だけを見ると、24 fps なら 2000 標本のうち半分が、どの窓にも
/// 入らない。
///
/// - ``AudioLevels/rms``・``AudioLevels/decibels``・``AudioLevels/level``・``AudioLevels/peak`` は、
///   窓を介さず**区間の標本から直に**求める
/// - ``AudioLevels/spectrum`` は、**音源の標本 0 から ``hop`` ごとに置いた固定の格子**の窓 (長さ
///   ``windowSize``。窓 `k` は標本 `[hop·k − windowSize, hop·k)`) のうち、**終わりが区間に入る窓**の平均。
///   連続するフレームの区間は継ぎ目なく並ぶので、どの窓も 1 度ずつ、どれかのフレームの区間に入る。格子は
///   音源の標本の数え方だけで決まり、供給の単位 (届くチャンクの長さ・fps) に依らない
/// - 終わりが入る窓が 0 本のフレーム (区間が ``hop`` より短い。48 kHz で 93.75 fps より速い) は、区間の
///   終わりまでに終わった最後の窓を使う。まだ 1 本も終わっていなければ 0
///
/// 長く止まった後は、区間の終わりから ``maxSpan`` 標本までに切る。
///
/// ## 生の値と 0〜1 の値を別の名前にする
///
/// 前身の `volume` は振幅をそのまま 0〜1 と名乗り、普通の音量で 0.354 に張り付いた
/// (全振幅の正弦波の RMS が 0.707 で、それより大きくならない)。生の値 (``AudioLevels/rms``・
/// ``AudioLevels/decibels``・``AudioLevels/peak``・``AudioLevels/spectrum``) と、絵に使いやすく写した値
/// (``AudioLevels/level``・``AudioLevels/spectrumLevels``) を別の名前で出す。写し方は
/// **dB の固定の範囲** (``quietDecibels``〜0 dBFS) で、履歴に依らない — 同じ音はいつも同じ値になる。
///
/// [#3136]: https://github.com/mokume-metal/mokume/issues/3136
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated enum AudioAnalysis {
    /// 窓の長さ (標本)。
    static let windowSize = 1024
    /// 格子の窓を並べる間隔 (標本)。窓の長さの半分。
    static let hop = windowSize / 2
    /// 帯域の数。窓の長さの半分で、帯域 k の真ん中は `k × 標本化率 ÷ windowSize` Hz。
    static let bandCount = windowSize / 2
    /// 1 回の解析が覆う区間の長さの上限 (標本)。長く止まった後は、区間の終わりからこれだけに切る。
    ///
    /// 区間の前の履歴 (最初の窓の頭まで。最大 `windowSize + hop - 1`) を足しても、合成の計器
    /// (``SynthRack/meterCapacity``) とマイクの環に収まる。48 kHz で約 0.128 秒 — 7.8 fps より遅いと、
    /// 区間の頭は解析されない。
    static let maxSpan = windowSize * 6
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

    // MARK: - 区間の取り方 (供給する側が使う)

    /// 区間の始まりを、``maxSpan`` で切る。`to` は区間の終わり。
    static func limited(from: Int, to: Int) -> Int {
        max(from, to - maxSpan, 0)
    }

    /// 区間が `from` から始まるとき、解析が読む最初の標本の通し番号 (0 より前は 0 に寄せる)。
    ///
    /// 区間に終わりが入る最初の窓の頭か、窓が 0 本のときに使う最後の窓の頭の、早いほう。
    static func firstNeeded(from: Int) -> Int {
        max(0, max(from, 0) / hop * hop - windowSize)
    }

    // MARK: - 解析

    /// 区間を解析する。
    ///
    /// **呼ぶたびに変換の setup を作る** (11〜12 µs。窓 1 本の 4 分の 3)。純粋な参照の形で、
    /// 検査が「製品の経路の値」と突き合わせる相手でもある。繰り返し解析する側 (``AudioIn``・
    /// ``SoundFile``・``SynthSound``) は ``AudioAnalyzer`` を通る ([#2379])。
    ///
    /// [#2379]: https://github.com/mokume-metal/mokume/issues/2379
    static func analyze(_ span: AudioSpan) -> AudioLevels {
        analyze(span, using: makeTransform())
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
    /// 窓の長さの配列を 5 本 (切り出した窓・窓に重みを掛けた入力・虚部の 0・変換の出力の実部と虚部)
    /// と、帯域の数の配列を 1 本 (窓ごとの大きさの和) 持つ。解析した結果
    /// (``AudioLevels/spectrum``・``AudioLevels/spectrumLevels``) はここに置かず、呼ぶたびに新しい
    /// 配列を作って返すので、利用者が保存した値は後の解析で書き換わらない。
    struct Scratch {
        var frame = [Float](repeating: 0, count: windowSize)
        var weighted = [Float](repeating: 0, count: windowSize)
        /// 入力の虚部。実数の入力なので 0 のまま (書き換えない)。
        let imaginary = [Float](repeating: 0, count: windowSize)
        var outputReal = [Float](repeating: 0, count: windowSize)
        var outputImaginary = [Float](repeating: 0, count: windowSize)
        /// 窓ごとの帯域の大きさ (重みを戻す前) の和。
        var accumulated = [Float](repeating: 0, count: bandCount)
    }

    /// 作ってある変換で区間を解析する。**``analyze(_:)`` と同じ式**で、変換の作り手だけが違う。
    static func analyze(
        _ span: AudioSpan, using transform: vDSP.DiscreteFourierTransform<Float>?
    ) -> AudioLevels {
        var scratch = Scratch()
        return analyze(span, using: transform, scratch: &scratch)
    }

    /// 作ってある変換と作業領域で区間を解析する。**``analyze(_:)`` と同じ式**で、一時配列の置き場だけが違う
    /// (値はビット一致する)。繰り返し解析する側 (``AudioAnalyzer``) が、作業領域を使い回すために呼ぶ。
    ///
    /// 区間が空 (``AudioSpan/isEmpty``) なら、`rms`・`peak` は 0 (無音)、`spectrum` は区間の終わりまでに
    /// 終わった最後の窓。
    static func analyze(
        _ span: AudioSpan, using transform: vDSP.DiscreteFourierTransform<Float>?,
        scratch: inout Scratch
    ) -> AudioLevels {
        let to = span.to
        let from = min(max(span.from, to - maxSpan, span.base), to)
        let interval = span.samples[(from - span.base)..<(to - span.base)]
        // 窓 k は標本 [hop·k − windowSize, hop·k)。終わりが区間 [from, to) に入るのは、
        // k が from / hop + 1 から to / hop まで (連続する区間で数えると、過不足なく並ぶ)
        let first = from / hop + 1
        let last = to / hop
        let windows: ClosedRange<Int>? =
            first <= last ? first...last : (last >= 1 ? last...last : nil)
        return levels(
            interval: interval, windows: windows, in: span, using: transform, scratch: &scratch)
    }

    /// 窓 1 つ (``windowSize`` 標本。足りなければ前を 0 で埋める) を解析する。窓の全体が区間。
    /// 検査が、窓 1 本の値を参照にするのに使う。製品の経路は使わない。
    static func analyze(_ window: [Float]) -> AudioLevels {
        let samples = padded(window)
        var scratch = Scratch()
        let span = AudioSpan(window: samples)
        return levels(
            interval: samples[...], windows: 2...2, in: span, using: makeTransform(),
            scratch: &scratch)
    }

    /// 区間の値と、`windows` (窓の番号) の平均のスペクトルから、値を組み立てる。
    private static func levels(
        interval: ArraySlice<Float>, windows: ClosedRange<Int>?, in span: AudioSpan,
        using transform: vDSP.DiscreteFourierTransform<Float>?, scratch: inout Scratch
    ) -> AudioLevels {
        let rms = interval.isEmpty ? 0 : vDSP.rootMeanSquare(interval)
        let peak = interval.isEmpty ? 0 : vDSP.maximumMagnitude(interval)
        let decibels = decibels(rms)

        var spectrum = Array(repeating: Float(0), count: bandCount)
        if let transform, let windows {
            vDSP.fill(&scratch.accumulated, with: 0)
            for k in windows {
                accumulate(windowEnding: hop * k, in: span, using: transform, scratch: &scratch)
            }
            let count = Float(windows.count)
            for band in 0..<bandCount {
                // 正の周波数と負の周波数に半分ずつ分かれるので 2 倍する (直流は分かれない)
                spectrum[band] = scratch.accumulated[band] / count * (band == 0 ? 1 : 2) / hannSum
            }
        }
        return AudioLevels(
            rms: rms, decibels: decibels, level: level(decibels), peak: peak, spectrum: spectrum,
            spectrumLevels: spectrum.map { level(Self.decibels($0)) })
    }

    /// 標本 `end - windowSize ..< end` の窓の帯域ごとの大きさを、作業領域の和へ足す。
    private static func accumulate(
        windowEnding end: Int, in span: AudioSpan,
        using transform: vDSP.DiscreteFourierTransform<Float>, scratch: inout Scratch
    ) {
        let start = end - windowSize
        if start >= span.base, end <= span.to {
            scratch.frame.replaceSubrange(
                0..<windowSize, with: span.samples[(start - span.base)..<(end - span.base)])
        } else {
            // 標本 0 より前 (鳴る前) と、区間が持たない前の履歴は 0
            for offset in 0..<windowSize {
                let index = start + offset - span.base
                scratch.frame[offset] =
                    index >= 0 && index < span.samples.count ? span.samples[index] : 0
            }
        }
        vDSP.multiply(scratch.frame, hann, result: &scratch.weighted)
        transform.transform(
            inputReal: scratch.weighted, inputImaginary: scratch.imaginary,
            outputReal: &scratch.outputReal, outputImaginary: &scratch.outputImaginary)
        for band in 0..<bandCount {
            let real = scratch.outputReal[band]
            let imaginary = scratch.outputImaginary[band]
            scratch.accumulated[band] += (real * real + imaginary * imaginary).squareRoot()
        }
    }

    /// 周波数の範囲 `low`〜`high` (Hz) の大きさ。`spectrum` の、中心がその範囲に入る帯域の振幅の**平均**を、
    /// ``level(_:)`` と同じ dB の固定範囲で 0〜1 に写したもの。
    ///
    /// - 範囲に中心が入る帯域が無ければ、範囲の中点にいちばん近い 1 帯域
    /// - 逆順は入れ替える。0〜標本化率の半分の外へはみ出す分は端へ寄せる。範囲が全部外なら 0
    /// - 標本化率がまだ分からない (0) なら 0
    /// - 数でない値・無限の値は 0 で、`isNumber` が `false` (呼ぶ側が 1 度だけ知らせる)
    static func energy(
        of spectrum: [Float], from low: Float, to high: Float, sampleRate: Float
    ) -> (value: Float, isNumber: Bool) {
        guard low.isFinite, high.isFinite else { return (0, false) }
        guard sampleRate > 0, sampleRate.isFinite, spectrum.count == bandCount else { return (0, true) }
        let nyquist = sampleRate / 2
        var lower = min(low, high)
        var upper = max(low, high)
        guard upper >= 0, lower <= nyquist else { return (0, true) }
        lower = max(lower, 0)
        upper = min(upper, nyquist)
        let width = sampleRate / Float(windowSize)
        var first = Int((lower / width).rounded(.up))
        var last = min(Int((upper / width).rounded(.down)), bandCount - 1)
        if first > last {
            first = min(max(Int(((lower + upper) / 2 / width).rounded()), 0), bandCount - 1)
            last = first
        }
        var total: Float = 0
        for band in first...last { total += spectrum[band] }
        return (level(decibels(total / Float(last - first + 1))), true)
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
/// 変換の入出力の作業領域 (20 KB) も 1 組だけ持って使い回す ([#3086])。音源ごとには持たない。
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

    func analyze(_ span: AudioSpan) -> AudioLevels {
        analyses += 1
        return AudioAnalysis.analyze(span, using: transform, scratch: &scratch)
    }
}

/// フレームの頭で切り出した区間と、読まれたときにそれを解いた値。
///
/// **区間はフレームの頭で決める。解析だけを読まれたときまで遅らせる** ([#2379])。読んだ値は、遅らせても
/// 毎フレーム解析したときと同じ (ビット一致) — 遅らせた分に進んだ標本は拾わない。同じフレームで
/// 何度読んでも解析は 1 回で、読まれなかったフレームの区間は次の区間に置き換わって解かれない
/// (次のフレームの値に混ぜない)。**空の区間は置き換えない** — 標本が 1 つも進まなかったフレーム
/// (飛び先から始まる最初のフレームなど) は、前のフレームの値のまま。
///
/// 波形 (``waveform()``) は、置いた区間の終わりの標本をそのまま返す。解析はしない。
///
/// 拍 (``isBeat()``) は**履歴を持つ**ので、値と違って読まれなかったフレームの区間も順に処理する。
/// 最初に読まれたフレームで状態を作り (そのフレームの区間から)、以後は区間を置くたび (``hold(_:)``) に
/// 処理する。一度も読まれなければ処理は 0 回 (``beatSteps``)。
///
/// [#2379]: https://github.com/mokume-metal/mokume/issues/2379
struct DeferredLevels {
    /// 置かれた最新の (空でない) 区間。解いた後も、波形のために残す。
    private var span: AudioSpan?
    /// ``span`` を解いたか。
    private var isSolved = true
    /// 解いた値、または無音。
    private var solved = AudioLevels.silence
    /// 解いた回数。検査が読む。
    private(set) var analyses = 0
    /// 波形の控え (``hold(_:)`` で捨てる)。
    private var waveformCache: [Float]?
    /// 拍の状態。``isBeat()`` が最初に読まれるまで `nil`。
    private var beat: BeatTracker?
    /// このフレームの区間に拍があったか。
    private var beatNow = false

    /// 拍の状態が区間を処理した回数。**検査が読む** — 一度も読まれなければ 0。
    var beatSteps: Int { beat?.calls ?? 0 }

    /// このフレームの区間を置く。前の区間が解かれていなくても捨てる。空の区間なら値と波形は変えない
    /// (そのフレームに拍は無い)。
    mutating func hold(_ span: AudioSpan) {
        guard !span.isEmpty else {
            beatNow = false
            return
        }
        self.span = span
        isSolved = false
        waveformCache = nil
        beatNow = beat?.process(span) ?? false
    }

    /// 無音にする。拍の履歴も捨てる (次に鳴り始めるのは、流れの最初から)。
    mutating func silence() {
        span = nil
        isSolved = true
        solved = .silence
        waveformCache = nil
        beat?.reset(fresh: true)
        beatNow = false
    }

    /// 標本の流れが途切れた (区切りを始め直した)。拍の履歴を捨てる。値と波形は変えない。
    ///
    /// - Parameter fresh: 新しい流れが、音源の最初から始まるか (ファイルの頭から鳴らすとき)。
    mutating func restartStream(fresh: Bool) {
        beat?.reset(fresh: fresh)
        beatNow = false
    }

    /// 読まれた値。区間が残っていればここで 1 回だけ解く。
    mutating func levels() -> AudioLevels {
        if !isSolved, let held = span {
            solved = AudioAnalyzer.shared.analyze(held)
            analyses += 1
            isSolved = true
        }
        return solved
    }

    /// 区間の終わりの ``AudioAnalysis/windowSize`` 標本 (古い順)。何も鳴っていなければ全部 0。
    mutating func waveform() -> [Float] {
        if let waveformCache { return waveformCache }
        let tail = span?.tail(AudioAnalysis.windowSize) ?? [Float](repeating: 0, count: AudioAnalysis.windowSize)
        waveformCache = tail
        return tail
    }

    /// このフレームの区間に拍があったか。**最初に読まれたときに、拍の状態を作る**。
    mutating func isBeat() -> Bool {
        if beat == nil {
            // 何も置かれていなければ流れの最初。置かれていれば、曲の途中から読み始めたことになる
            beat = BeatTracker(fresh: span.map { $0.from == 0 } ?? true)
            if let span { beatNow = beat?.process(span) ?? false }
        }
        return beatNow
    }
}
