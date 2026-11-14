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
/// **消えていく区切りは、自分の音量が 0 になるまで、後から来た操作で捨てない。** 同じ描き出しの前に
/// 始め直しが 2 つ載っても (1 フレームに `play()` が 2 回・前のフレームの `jump(_:)` と同じフレームの
/// `play()`)、始め直した直後に止めても、新しい区切りがファイルの終わりに着いても、鳴っていた区切りは
/// 消えきるまで鳴る。消えていく区切りは同時に ``maximumFadingSegments`` 個まで持ち (確保しない)、
/// 溢れたときだけ、音量がいちばん小さい (ほとんど聞こえない) ものを捨てる。
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
/// ## 包絡 (#3099)
///
/// ``Env`` が ``SoundFile`` に包絡を掛けると、区切りを始める操作の直後に、その区切りの位置のずれ (``FileEnvelope``) が
/// 届く。倍率は区切りの中で鳴ったファイルの標本の数 (``played(generation:)`` と同じ数え方) から引くので、解析
/// (``SoundFile``) が同じ数から同じ倍率を引ける。包絡を掛けていなければ何も掛けない。始め直して消えていく区切りは、
/// 消え始めた時点の倍率のまま消える。
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
    /// 同時に持つ、消えていく区切りの数の上限。音量が約 5 ミリ秒の時定数で 1e-6 まで下がるのに約 70 ミリ秒
    /// かかり、その間に始め直しが 8 回起きるのは、1 フレームに 1 回の始め直しでも超えにくい数。
    static let maximumFadingSegments = 8

    /// 世代の幅 (ビット)。`bits` と原子値の両方に使う。
    private static let generationBits: UInt64 = 23
    /// 位置・鳴った標本の数の幅 (ビット)。2^40 標本は 48 kHz で約 266 日。
    private static let countBits: UInt64 = 40
    private static let countMask: UInt64 = (1 << countBits) - 1
    private static let generationMask: UInt64 = (1 << generationBits) - 1
    private static let loopingBit: UInt64 = 1 << countBits

    /// ファイルの標本 (チャンネルを平均したモノラル)。
    private let samples: [Float]
    /// ファイルの標本化率と、ラックの標本化率 (Hz)。位置は `count × fileRate ÷ sampleRate` と、掛けてから
    /// 割って導く。
    private let fileRate: Double
    /// ラックより高い率のファイルを読む低域通過の係数。ラックの率以下なら `nil` (三次補間で読む)。
    private let lowPass: DownsamplingKernel?

    private var amplitude: Float
    private var amplitudeNow: Float
    private let smoothing: Float

    /// いまの区切りが続いているか (止める途中の消えていく間も続いている)。消えていく前の区切り
    /// (``fading``) は含まない。
    private var playing = false
    /// いまの区切りが、1 度だけ鳴らしてファイルの終わりに着いたか (``publish(_:)`` が終わりまでの数を返す)。
    private var reachedEnd = false
    private var looping = false
    /// 区切りの始まりの位置 (ファイルの標本)。
    private var start = 0
    /// 区切りが始まってから作った標本の数 (ラックの標本)。
    private var count = 0
    private var generation = 0
    /// 立ち上がり・消え方 (0〜1)。``SourceNode`` の `gate` と同じ。
    private var gate: Float = 0
    private var gateTarget: Float = 0
    /// 区切りを始め直したとき、消えていく前の区切り (先頭から `fadingCount` 個)。確保しないよう、上限の
    /// 個数ぶんを作っておく。
    private var fading = [Fading](
        repeating: Fading(origin: 0, count: 0, rate: 1, looping: false, gain: 0),
        count: FileNode.maximumFadingSegments)
    private var fadingCount = 0
    /// 世代 (上位) と、区切りの中で経った標本の数 (下位・ファイルの標本)。最上位のビットは、速さを変えた区切りが
    /// 1 度だけ鳴らしてファイルの終わりに着いた印 (``ended(generation:)``)。
    private let progress = Atomic<UInt64>(0)
    private static let endedBit: UInt64 = 1 << 63
    /// 速さ (#3473) の受け渡し。主スレッドが頼み、音の側が受けた点を返す。
    let link: RateLink
    /// いまの速さ。音の側だけが読み書きする。
    private var rate: Double
    /// いまの速さで読む比が 1 を越えるときの低域通過の係数 (主スレッドが作って持つ)。速さ 1 では使わない (``lowPass``)。
    private var kernel: Unmanaged<RateKernel>?
    /// いまの区切りの錨: 速さを最後に変えた点で読んでいた位置 (ファイルの標本・折り返さない) と、そこまでに区切りの中で
    /// 作った標本の数 (ラックの標本)。区切りの頭では、始まりの位置と 0。
    private var anchorPosition: Double = 0
    private var anchorCount = 0
    /// 次に始める区切りの、小数の始まりの位置 (``origin(_:)``)。`nil` なら区切りの始まりの標本から。
    private var pendingOrigin: Double?
    /// いまの区切りに掛ける包絡 (#3099)。`nil` なら掛けない。位置は区切りの中で鳴ったファイルの標本の数
    /// (``played(generation:)`` が返す数と同じ数え方) から引く。**区切りを始め直しても外さない** — 主スレッドが
    /// 区切りを始める操作の直後に、その区切りの位置のずれを渡す。
    private var envelope: FileEnvelope?
    // 包絡の形の秒 (``SourceNode`` と同じく、値で受けてから形にする)
    private var pendingAttack: Float = 0
    private var pendingSustain: Float = 0
    private var pendingLevel: Float = 1
    private var pendingRelease: Float = 0

    /// 消えていく区切り。位置を導くのに要るもの (錨の位置・錨から作った数・速さ) と、いまの音量。読み方 (係数) は
    /// いまの区切りと同じものを使う — 前の速さの係数は、主スレッドがもう手放しているかもしれない。
    private struct Fading {
        var origin: Double
        var count: Int
        var rate: Double
        var looping: Bool
        var gain: Float

        /// 作った数 `count` のところで読む位置 (``FileNode/position(at:)`` と同じ式)。
        func position(fileRate: Double, sampleRate: Double) -> Double {
            FileNode.position(from: origin, made: count, rate: rate, fileRate: fileRate, sampleRate: sampleRate)
        }
    }

    /// - Parameters:
    ///   - rate: 最初の速さ (#3473)。
    ///   - kernel: 最初の速さで読む比 (速さ × `fileRate` ÷ `sampleRate`) が 1 を越えるときの係数。速さ 1 なら使わない。
    init(
        id: Int, sampleRate: Double, meter: SampleRing, samples: [Float], fileRate: Double,
        amplitude: Float, rate: Double = 1, kernel: RateKernel? = nil
    ) {
        self.samples = samples
        self.fileRate = fileRate
        lowPass = fileRate > sampleRate ? DownsamplingKernel(ratio: fileRate / sampleRate) : nil
        self.rate = rate
        self.kernel = kernel.map { Unmanaged.passUnretained($0) }
        link = RateLink(kernel: kernel)
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

    /// 錨の世代 `generation` (音の側の数え方) が、主スレッドの世代 `current` の区切りか。
    static func matches(_ generation: UInt64, current: Int) -> Bool {
        generation == UInt64(truncatingIfNeeded: current) & generationMask
    }

    /// 世代 `generation` の区切りが、速さを変えたうえで 1 度だけ鳴らしてファイルの終わりに着いたか。速さを変えて
    /// いない区切りは、終わりに着くと ``played(generation:)`` が終わりまでの数を返すので、この印を立てない。
    func ended(generation: Int) -> Bool {
        let value = progress.load(ordering: .acquiring)
        let seen = (value >> Self.countBits) & Self.generationMask
        guard seen == UInt64(truncatingIfNeeded: generation) & Self.generationMask else { return false }
        return value & Self.endedBit != 0
    }

    // MARK: - 音の側

    override var isSource: Bool { true }

    override var isIdle: Bool { !playing && fadingCount == 0 }

    /// 止まって消えきったか (消えていく前の区切りも含む)。手放された節は、これが `true` になってから
    /// 置き場が戻る。
    override var isFinished: Bool { !playing && fadingCount == 0 }

    override func apply(_ param: SynthParam, _ value: Float) {
        switch param {
        case .amplitude: amplitude = value
        case .attack: pendingAttack = value
        case .sustain: pendingSustain = value
        case .level: pendingLevel = value
        case .release: pendingRelease = value
        default: break
        }
    }

    override func shapeEnvelope(offset: Int) {
        // 位置はファイルの標本で数えるので、形もファイルの標本化率で作る (主スレッドと同じ値から同じ形)
        envelope = FileEnvelope(
            shape: EnvelopeShape(
                attack: pendingAttack, sustain: pendingSustain, level: pendingLevel,
                release: pendingRelease, sampleRate: fileRate),
            offset: offset)
    }

    /// 区切りが始まってから `count` 標本 (ラックの標本) 作ったところで、鳴ったファイルの標本の数。
    private func filePlayed(_ count: Int) -> Int {
        Int((Double(count) * fileRate / sampleRate).rounded(.down))
    }

    override func begin(_ bits: UInt64) {
        // 鳴っている区切りは、消えながら残す。まだ音量が立ち上がっていない区切り (同じ描き出しの前に
        // 始め直しが 2 つ載ったときの 1 つ目) は音が出ていないので、残すものが無い。**消えていく前の区切りは
        // ここでは捨てない** — 自分の音量が 0 になるまで鳴らす。包絡を掛けていれば、消え始めの倍率で止めて残す
        if playing, gate > 0 {
            let shaped = envelope.map { gate * $0.gain(atPlayed: filePlayed(count)) } ?? gate
            pushFading(
                Fading(
                    origin: anchorPosition, count: count - anchorCount, rate: rate, looping: looping,
                    gain: shaped))
        }
        start = min(Int(bits & Self.countMask), samples.count)
        anchorPosition = pendingOrigin ?? Double(start)
        pendingOrigin = nil
        anchorCount = 0
        looping = bits & Self.loopingBit != 0
        generation = Int((bits >> (Self.countBits + 1)) & Self.generationMask)
        count = 0
        reachedEnd = false
        gate = 0
        gateTarget = 1
        playing = true
        publish(0)
    }

    /// 消えていく区切りを足す。溢れたら、音量がいちばん小さいもの (足すものを含む) を捨てる。
    private func pushFading(_ segment: Fading) {
        if fadingCount < fading.count {
            fading[fadingCount] = segment
            fadingCount += 1
            return
        }
        var quietest = 0
        for index in 1..<fadingCount where fading[index].gain < fading[quietest].gain { quietest = index }
        if fading[quietest].gain < segment.gain { fading[quietest] = segment }
    }

    override func halt() {
        gateTarget = 0
    }

    override func origin(_ position: Double) {
        pendingOrigin = position
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
        receiveRate()
        guard playing || fadingCount > 0, !samples.isEmpty else {
            output.update(repeating: 0, count: frames)
            return
        }
        let length = samples.count
        var made = 0
        samples.withUnsafeBufferPointer { source in
            while made < frames {
                var value: Float = 0
                if playing {
                    let position = position(at: count)
                    if !looping, position >= Double(length) {
                        // ファイルの終わり。ファイルが終わるので、いまの区切りは消えるのを待たずに止まる
                        // (消えていく前の区切りは、自分の音量が 0 になるまで続ける)
                        reachedEnd = true
                        playing = false
                        gate = 0
                        gateTarget = 0
                    } else {
                        gate = approach(gate, gateTarget)
                        if gateTarget == 0, gate == 0 {
                            // 止める途中の消え方が終わった
                            playing = false
                        } else {
                            // 速さ 0 の間は無音 (位置は進まず、区切りは続く)
                            value = rate == 0 ? 0 : read(source, at: position, looping: looping) * gate
                            if let envelope { value *= envelope.gain(atPlayed: filePlayed(count)) }
                            count += 1
                        }
                    }
                }
                var index = 0
                while index < fadingCount {
                    var previous = fading[index]
                    let before = previous.position(fileRate: fileRate, sampleRate: sampleRate)
                    guard previous.looping || before < Double(length) else {
                        removeFading(at: index)
                        continue
                    }
                    // 音量は読む前に 1 標本ぶん追う (``gate`` と同じ順)。そうすると、消える重みと立ち上がる
                    // 重みの和が、つなぎ目の 1 標本目から 1 を超えない
                    previous.gain = approach(previous.gain, 0)
                    if previous.gain == 0 {
                        removeFading(at: index)
                        continue
                    }
                    if previous.rate != 0 {
                        value += read(source, at: before, looping: previous.looping) * previous.gain
                    }
                    previous.count += 1
                    fading[index] = previous
                    index += 1
                }
                guard playing || fadingCount > 0 || value != 0 else { break }
                amplitudeNow = approach(amplitudeNow, amplitude)
                output[made] = value * amplitudeNow
                made += 1
            }
        }
        if made < frames { (output + made).update(repeating: 0, count: frames - made) }
        // 1 度だけで終わりに着いたら、鳴った数は終わりまでの数にする (主スレッドが終わりと読めるように)。速さを変えた
        // 区切りは、経った数のまま終わりの印を立てる (経った数と位置は比例しないので、数だけでは終わりと読めない)
        if reachedEnd, !isPlain {
            publish(filePlayed(count), ended: true)
        } else {
            publish(reachedEnd ? length - start : filePlayed(count))
        }
    }

    /// いまの区切りが、速さを変えずに鳴っているか (速さ 1 で、錨が区切りの頭のまま)。
    private var isPlain: Bool {
        rate == 1 && anchorCount == 0 && anchorPosition == Double(start)
    }

    /// 頼まれた速さを受ける。鳴っていれば、いまの位置を錨にして、そこから新しい速さで読む。受けた点を主スレッドへ返す。
    private func receiveRate() {
        guard let request = link.take() else { return }
        if playing {
            anchorPosition = position(at: count)
            anchorCount = count
        }
        rate = request.rate
        kernel = request.kernel
        link.publish(
            generation: UInt64(generation), elapsed: filePlayed(count), position: anchorPosition,
            rate: rate)
    }

    /// `index` 番目の消えていく区切りを外す (残りの順は保つ)。
    private func removeFading(at index: Int) {
        var next = index + 1
        while next < fadingCount {
            fading[next - 1] = fading[next]
            next += 1
        }
        fadingCount -= 1
    }

    private func publish(_ played: Int, ended: Bool = false) {
        let bounded = UInt64(max(0, played)) & Self.countMask
        progress.store(
            UInt64(generation) << Self.countBits | bounded | (ended ? Self.endedBit : 0),
            ordering: .releasing)
    }

    // MARK: - 読み出し

    /// いまの区切りの、区切りが始まってから `count` 標本 (ラックの標本) 作ったところで読む位置。錨 (速さを変えた点) から
    /// 導く (``FileRate``)。**速さを変えていなければ `start + count × fileRate ÷ sampleRate`** (掛けてから割る — 速さ 1 を
    /// 掛けても値は変わらない)。
    private func position(at count: Int) -> Double {
        Self.position(
            from: anchorPosition, made: count - anchorCount, rate: rate, fileRate: fileRate,
            sampleRate: sampleRate)
    }

    /// 錨 `origin` から `made` 標本 (ラックの標本) 作ったところで読む位置。**ファイルの率がラックの率と同じなら、
    /// ``FileRate/position(from:elapsed:rate:)`` (直に鳴らす道と解析の式) そのもの** — 率の比を掛けて割ると丸めが
    /// 入り、通さないときと位置が食い違う。違えば率の比を掛けてから割る。
    static func position(
        from origin: Double, made: Int, rate: Double, fileRate: Double, sampleRate: Double
    ) -> Double {
        guard fileRate != sampleRate else {
            return FileRate.position(from: origin, elapsed: made, rate: rate)
        }
        return origin + Double(made) * rate * fileRate / sampleRate
    }

    /// `position` (ファイルの標本・小数) の値。読み方は ``FileRate/read(_:length:at:looping:kernel:)`` (``SoundFile`` の
    /// 解析と同じ)。読む比 (速さ × ファイルの率 ÷ ラックの率) が 1 を越えれば低域通過を掛ける。**速さ 1 では、作ったときの
    /// 係数 (``lowPass``)** で読む。
    private func read(
        _ source: UnsafeBufferPointer<Float>, at position: Double, looping: Bool
    ) -> Float {
        guard let base = source.baseAddress else { return 0 }
        if rate == 1 || kernel == nil {
            return FileRate.read(
                base, length: source.count, at: position, looping: looping,
                kernel: rate == 1 ? lowPass : nil)
        }
        return kernel!._withUnsafeGuaranteedRef {
            FileRate.read(base, length: source.count, at: position, looping: looping, kernel: $0.kernel)
        }
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
