// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics

/// 合成した音 (オシレータ・ノイズ・エフェクト) に共通の、鳴っている音の解析値。
///
/// ``Sketch/createSinOsc()`` のような口が作る型はどれもこれを継ぎ、値の名前と写し方は
/// ``AudioIn``・``SoundFile`` と同じである。`draw()` の前に、そのフレームの値が入っている。
///
/// ```swift
/// final class Meter: Sketch {
///     var noise: PinkNoise?
///     var filter: LowPass?
///     func setup() {
///         noise = createPinkNoise()
///         filter = createLowPass()
///         if let noise, let filter {
///             noise.play(0.3)
///             filter.process(noise, 800)
///         }
///     }
///     func draw() {
///         background(0)
///         guard let filter else { return }
///         // 低い音だけが残った、フィルタの出口のスペクトルで棒を伸ばす
///         for band in 1...64 {
///             let length = filter.spectrumLevels[band] * 300
///             rect(Float(band) * 10, height - length, 8, length)
///         }
///     }
/// }
/// ```
///
/// ## 解析するのは、その音の出口
///
/// 各フレームでは、その音の出口で終わる 1024 標本の窓を ``AudioIn`` と同じ解析に通す。
/// オシレータとノイズなら音量と包絡を掛けた後 (定位を掛ける前)、エフェクトなら処理した後の
/// 音である。鳴っていない間は無音 (``level`` が 0) になる。
///
/// ## 書き出しでも解析できる
///
/// 窓に出して動かしている間は実際に鳴らし、窓は実際に鳴った標本から取る。書き出し
/// (`mokume render`) と、窓を開かずに回す検査 (時刻がフレームの数え方から決まるとき —
/// ``Sketch/clock``) では**鳴らさず**、標本を「フレームの番号 × 標本化率 ÷ fps」まで進めて窓を
/// 取る。何を作ってどう操作したかが同じなら、何度書き出しても同じ値になる ([ADR-0028] 決定 7・
/// [ADR-0025] の水準 2)。
///
/// 音を進めるのは音の時計で、``Sketch/time`` ではない。``Sketch/pauseTime()`` と
/// ``Sketch/jumpTime(_:)`` は音を止めない・飛ばさない (``SoundFile`` と同じ)。
///
/// 1 つのスケッチで作れる合成した音は、オシレータ・ノイズ・エフェクトを合わせて 64 個までで、
/// 作った音はスケッチの終わりまで残る。`setup()` で作って使い回す。
///
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public class SynthSound {
    let stage: SynthStage
    let node: RackNode?
    /// 知らせに載せる型の名前。
    let name: String
    /// 鳴らし始めた (エフェクトなら入力を繋いだ) か。解析はここから始める。
    var isActive = false

    private var levels = AudioLevels.silence
    private var noticed: Set<String> = []

    init(stage: SynthStage, node: RackNode?, name: String) {
        self.stage = stage
        self.node = node
        self.name = name
        if node == nil { stage.noticeCapacity() }
        stage.register(self)
    }

    // MARK: - 生の値

    /// 窓の二乗平均の平方根 (振幅の単位)。無音で 0、全振幅の正弦波で約 0.707。
    public var rms: Float { levels.rms }
    /// ``rms`` を dBFS にしたもの。0 が最大で、無音は -160 (∞ にはしない)。
    public var decibels: Float { levels.decibels }
    /// 帯域ごとの大きさ (振幅の単位)。512 本で、帯域の真ん中にある全振幅の正弦波で 1。
    public var spectrum: [Float] { levels.spectrum }

    // MARK: - 0〜1 へ写した値

    /// 音の大きさを 0〜1 にしたもの。-60 dBFS 以下で 0、0 dBFS で 1。写し方は ``AudioIn/level`` と同じ。
    public var level: Float { levels.level }
    /// ``spectrum`` を帯域ごとに 0〜1 にしたもの。写し方は ``level`` と同じ。
    public var spectrumLevels: [Float] { levels.spectrumLevels }

    // MARK: - 出どころ

    /// 標本化率 (Hz)。帯域 `k` の真ん中は `k × sampleRate ÷ 1024` Hz。常に 48000。
    public var sampleRate: Float { Float(stage.rack.sampleRate) }

    // MARK: - ステージとの受け渡し

    /// フレームごとに、最新の窓を解析する。
    func refresh() {
        guard isActive, let node else {
            levels = .silence
            return
        }
        levels = AudioAnalysis.analyze(node.meter.latest(AudioAnalysis.windowSize))
    }

    /// スケッチが終わった。以後の値は無音。
    func silence() {
        levels = .silence
    }

    // MARK: - 音の側へ渡す

    /// 値を 1 つ変える。ステージが閉じていれば捨てる。
    func send(_ param: SynthParam, _ value: Float) {
        guard let node, !stage.isClosed else { return }
        stage.rack.set(node.id, param, value)
    }

    /// 操作を 1 つ渡す。ステージが閉じていれば捨てる。
    func post(_ op: SynthCommand.Op) {
        guard let node, !stage.isClosed else { return }
        stage.rack.post(SynthCommand(op: op, node: UInt8(node.id)))
    }

    /// 呼び出しで渡された値を、範囲へ丸めて受ける。数でない値・無限の値は `nil` (無視する)。
    ///
    /// どちらも投げず、同じ呼び出しについて 1 度だけ知らせる ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    func accept(
        _ value: Float, _ range: ClosedRange<Float>, call: String, meaning: String
    ) -> Float? {
        guard value.isFinite else {
            notice(
                "\(call).notFinite",
                "\(call)() got a value that is not a number, or an infinite one, so \(meaning) of "
                    + "this \(name) is not changed")
            return nil
        }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        if clamped != value {
            notice(
                "\(call).range",
                "\(call)() takes \(meaning) from \(range.lowerBound) to \(range.upperBound), so "
                    + "\(value) was clamped to \(clamped) for this \(name)")
        }
        return clamped
    }

    /// 同じ種類の知らせを 1 度だけ言う。
    func notice(_ key: String, _ message: String) {
        guard noticed.insert(key).inserted else { return }
        stage.warning(message)
    }
}

// MARK: - 音源

/// 合成した音の音源 (オシレータとノイズ) に共通の操作。
///
/// 作っただけでは鳴らない。``play()`` で鳴らし、``stop()`` で止める。音量・足す値・定位は、
/// 鳴らす前にも鳴らしている最中にも変えられ、急に変えても音がぷつっと鳴らないよう
/// 約 5 ミリ秒かけて追う。どの口も投げない ([ADR-0020] 決定 5)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public class SynthSource: SynthSound {
    /// 鳴っているか。``play()`` で `true` になり、``stop()`` で `false` になる。
    ///
    /// ``Env`` の形が終わって音が 0 になっても `true` のまま (止めるのは ``stop()``)。
    public private(set) var isPlaying = false

    /// 鳴らし始める。今の周波数・音量・足す値・定位のまま。
    ///
    /// <!-- example: 文脈 var osc: SinOsc? -->
    /// ```swift
    /// func mousePressed() {
    ///     guard let osc else { return }
    ///     if osc.isPlaying { osc.stop() } else { osc.play() }
    /// }
    /// ```
    ///
    /// 鳴っている最中に呼んでも何も変わらない。止めた後に呼ぶと、位相を頭へ戻して鳴らし直す。
    public func play() {
        post(.play)
        isActive = true
        isPlaying = true
    }

    /// 止める。約 5 ミリ秒かけて消える。
    ///
    /// 鳴っていなければ何もしない。もう一度 ``play()`` で鳴らせる。
    public func stop() {
        post(.stop)
        isPlaying = false
    }

    /// 音量を決める。0 で無音、1 で最大。既定は 0.5。
    ///
    /// <!-- example: 文脈 var osc: SinOsc? -->
    /// ```swift
    /// osc?.amp(map(mouseY, 0, height, 1, 0))
    /// ```
    ///
    /// 0〜1 の外は端へ丸め、数でない値・無限の値は無視する。どちらもそのことを 1 度だけ知らせる
    /// (投げない — [ADR-0020] 決定 5)。解析の値も、この音量を掛けた音のものになる。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func amp(_ volume: Float) {
        guard let value = accept(volume, 0...1, call: "amp", meaning: "a volume") else { return }
        send(.amplitude, value)
    }

    /// 音に足す値を決める。-1〜1 で、既定は 0。
    ///
    /// 波形の全体を上下へずらす (直流を足す)。普通の音では 0 のままでよい。範囲の外・数でない値は
    /// ``amp(_:)`` と同じに扱う。
    public func add(_ offset: Float) {
        guard let value = accept(offset, -1...1, call: "add", meaning: "an offset") else { return }
        send(.offset, value)
    }

    /// 左右の定位を決める。-1 で左、0 で中央、1 で右。既定は 0。
    ///
    /// 左右の合わせた大きさが変わらない定位で、中央では左右とも 1/√2 になる。**エフェクトへ通した
    /// 音の定位は、エフェクトの出口で中央になる**。範囲の外・数でない値は ``amp(_:)`` と同じに扱う。
    public func pan(_ position: Float) {
        guard let value = accept(position, -1...1, call: "pan", meaning: "a position") else {
            return
        }
        send(.panning, value)
    }

    /// ``Env`` が、この音の包絡を頭から始める。鳴っていなければ鳴らし始める。
    func triggerEnvelope(
        attack: Float, sustain: Float, level: Float, release: Float
    ) {
        guard
            let attackTime = acceptTime(attack, call: "Env.play", meaning: "attackTime"),
            let sustainTime = acceptTime(sustain, call: "Env.play", meaning: "sustainTime"),
            let releaseTime = acceptTime(release, call: "Env.play", meaning: "releaseTime"),
            let sustainLevel = accept(
                level, 0...1, call: "Env.play", meaning: "a sustainLevel")
        else { return }
        send(.attack, attackTime)
        send(.sustain, sustainTime)
        send(.level, sustainLevel)
        send(.release, releaseTime)
        post(.trigger)
        play()
    }

    /// 秒の長さを受ける。負の値は 0 へ丸め、数でない値・無限の値は `nil` (無視する)。
    private func acceptTime(_ value: Float, call: String, meaning: String) -> Float? {
        guard value.isFinite else {
            notice(
                "\(call).notFinite",
                "\(call)() got a value that is not a number, or an infinite one, so the call is "
                    + "ignored for this \(name)")
            return nil
        }
        guard value >= 0 else {
            notice(
                "\(call).negative",
                "\(call)() takes \(meaning) of 0 seconds or more, so \(value) was changed to 0 "
                    + "for this \(name)")
            return 0
        }
        return value
    }
}

// MARK: - オシレータ

/// 周期のある波形を鳴らし続ける音源。波形ごとに ``SinOsc``・``SqrOsc``・``TriOsc``・``SawOsc`` がある。
///
/// ```swift
/// final class Theremin: Sketch {
///     var osc: SinOsc?
///     func setup() {
///         osc = createSinOsc()
///         osc?.play()
///     }
///     func draw() {
///         background(0)
///         // マウスの左右で 100〜1000 Hz、上下で音量を変える
///         osc?.freq(map(mouseX, 0, width, 100, 1000))
///         osc?.amp(map(mouseY, 0, height, 1, 0))
///         // 鳴っている音を、入力・再生と同じ解析で見る
///         if let osc { circle(width / 2, height / 2, 40 + osc.level * 300) }
///     }
/// }
/// ```
///
/// 既定は周波数 440 Hz・音量 0.5・足す値 0・定位 中央。位相は鳴らし始めるたびに頭 (0) から始まる。
/// 矩形とのこぎりは、高い倍音が折り返して濁らないよう角を丸めてある。
public class Oscillator: SynthSource {
    init(stage: SynthStage, waveform: Waveform, name: String) {
        super.init(
            stage: stage, node: stage.rack.addSource(.wave(waveform)), name: name)
    }

    /// 周波数・音量・足す値・定位を決めて、鳴らし始める。
    ///
    /// <!-- example: 文脈 var osc: SinOsc? -->
    /// ```swift
    /// func setup() {
    ///     osc = createSinOsc()
    ///     osc?.play(440, 0.5)
    /// }
    /// ```
    ///
    /// 範囲の外・数でない値は、それぞれ ``freq(_:)``・``SynthSource/amp(_:)``・``SynthSource/add(_:)``・
    /// ``SynthSource/pan(_:)`` と同じに扱う。
    public func play(_ freq: Float, _ amp: Float, _ add: Float = 0, _ pan: Float = 0) {
        set(freq, amp, add, pan)
        play()
    }

    /// 周波数を決める。単位は Hz で、0 から標本化率の半分 (24000) まで。既定は 440。
    ///
    /// 範囲の外は端へ丸め、数でない値・無限の値は無視する。どちらもそのことを 1 度だけ知らせる
    /// (投げない — [ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func freq(_ frequency: Float) {
        let limit = Float(stage.rack.sampleRate / 2)
        guard let value = accept(frequency, 0...limit, call: "freq", meaning: "a frequency")
        else { return }
        send(.frequency, value)
    }

    /// 周波数・音量・足す値・定位を、鳴らさずに決める。
    ///
    /// 範囲の外・数でない値は、それぞれ ``freq(_:)``・``SynthSource/amp(_:)``・``SynthSource/add(_:)``・
    /// ``SynthSource/pan(_:)`` と同じに扱う。
    public func set(_ freq: Float, _ amp: Float, _ add: Float = 0, _ pan: Float = 0) {
        self.freq(freq)
        self.amp(amp)
        self.add(add)
        self.pan(pan)
    }
}

/// 正弦波を鳴らす。倍音の無い、丸い音。
///
/// 手本は Processing Sound の `SinOsc`。作る口は ``Sketch/createSinOsc()``。使い方は ``Oscillator``。
public final class SinOsc: Oscillator {
    init(stage: SynthStage) {
        super.init(stage: stage, waveform: .sine, name: "SinOsc")
    }
}

/// 矩形波を鳴らす。奇数次の倍音が強い、硬い音。
///
/// 手本は Processing Sound の `SqrOsc`。作る口は ``Sketch/createSqrOsc()``。使い方は ``Oscillator``。
public final class SqrOsc: Oscillator {
    init(stage: SynthStage) {
        super.init(stage: stage, waveform: .square, name: "SqrOsc")
    }
}

/// 三角波を鳴らす。奇数次の倍音が弱い、正弦波に近い音。
///
/// 手本は Processing Sound の `TriOsc`。作る口は ``Sketch/createTriOsc()``。使い方は ``Oscillator``。
public final class TriOsc: Oscillator {
    init(stage: SynthStage) {
        super.init(stage: stage, waveform: .triangle, name: "TriOsc")
    }
}

/// のこぎり波を鳴らす。全部の倍音を含む、明るい音。
///
/// 手本は Processing Sound の `SawOsc`。作る口は ``Sketch/createSawOsc()``。使い方は ``Oscillator``。
public final class SawOsc: Oscillator {
    init(stage: SynthStage) {
        super.init(stage: stage, waveform: .saw, name: "SawOsc")
    }
}

// MARK: - ノイズ

/// 周期の無い音 (ノイズ) を鳴らし続ける音源。色ごとに ``WhiteNoise``・``PinkNoise`` がある。
///
/// ```swift
/// final class Hiss: Sketch {
///     var noise: WhiteNoise?
///     func setup() {
///         noise = createWhiteNoise()
///         noise?.play(0.2)
///     }
///     func draw() {
///         background(0)
///         if let noise { circle(width / 2, height / 2, 40 + noise.level * 300) }
///     }
/// }
/// ```
///
/// 既定は音量 0.5・足す値 0・定位 中央。**ノイズの列は決まっている** — 同じ順にノイズを作れば、
/// 何度鳴らしても書き出しても同じ音になる (種を選ぶ口は持たない)。
public class Noise: SynthSource {
    init(stage: SynthStage, color: NoiseColor, name: String) {
        super.init(
            stage: stage, node: stage.rack.addSource(.noise(color)), name: name)
    }

    /// 音量・足す値・定位を決めて、鳴らし始める。
    ///
    /// <!-- example: 文脈 var noise: WhiteNoise? -->
    /// ```swift
    /// func setup() {
    ///     noise = createWhiteNoise()
    ///     noise?.play(0.2)
    /// }
    /// ```
    ///
    /// 範囲の外・数でない値は、それぞれ ``SynthSource/amp(_:)``・``SynthSource/add(_:)``・
    /// ``SynthSource/pan(_:)`` と同じに扱う。
    public func play(_ amp: Float, _ add: Float = 0, _ pan: Float = 0) {
        set(amp, add, pan)
        play()
    }

    /// 音量・足す値・定位を、鳴らさずに決める。
    ///
    /// 範囲の外・数でない値は、それぞれ ``SynthSource/amp(_:)``・``SynthSource/add(_:)``・
    /// ``SynthSource/pan(_:)`` と同じに扱う。
    public func set(_ amp: Float, _ add: Float = 0, _ pan: Float = 0) {
        self.amp(amp)
        self.add(add)
        self.pan(pan)
    }
}

/// 白色雑音を鳴らす。全部の帯域が同じ強さの、さらさらした音。
///
/// 手本は Processing Sound の `WhiteNoise`。作る口は ``Sketch/createWhiteNoise()``。使い方は ``Noise``。
public final class WhiteNoise: Noise {
    init(stage: SynthStage) {
        super.init(stage: stage, color: .white, name: "WhiteNoise")
    }
}

/// ピンクノイズを鳴らす。1 オクターブごとに同じ強さの、白色雑音より低くやわらかい音。
///
/// 手本は Processing Sound の `PinkNoise`。作る口は ``Sketch/createPinkNoise()``。使い方は ``Noise``。
public final class PinkNoise: Noise {
    init(stage: SynthStage) {
        super.init(stage: stage, color: .pink, name: "PinkNoise")
    }
}

// MARK: - 包絡

/// 音の大きさの形 (包絡)。立ち上がる → 保つ → 下がるの 3 段 (ASR) を、音源にかける。
///
/// ```swift
/// final class Pluck: Sketch {
///     var osc: TriOsc?
///     var env: Env?
///     func setup() {
///         osc = createTriOsc()
///         env = createEnv()
///         osc?.play(440, 0.8)
///     }
///     func mousePressed() {
///         guard let osc, let env else { return }
///         // 0.01 秒で立ち上がり、0.2 秒保ち、0.4 秒で消える
///         env.play(osc, 0.01, 0.2, 0.6, 0.4)
///     }
///     func draw() {
///         background(0)
///         if let osc { circle(width / 2, height / 2, 40 + osc.level * 300) }
///     }
/// }
/// ```
///
/// 形は呼ぶたびに頭から始まる。形が終わると音源の音は 0 (無音) になり、次に ``play(_:_:_:_:_:)`` を
/// 呼ぶまでそのままで、``SynthSource/play()`` で鳴らし直しても戻らない。
public final class Env {
    init() {}

    /// 形を `input` にかけ、頭から始める。`input` が鳴っていなければ鳴らし始める。
    ///
    /// 形は、0 から `sustainLevel` まで `attackTime` 秒で上がり、`sustainTime` 秒 `sustainLevel` を
    /// 保ち、`releaseTime` 秒で 0 へ下がる。音源の音量にさらに掛かるので、音量 0.8・
    /// `sustainLevel` 0.5 なら最大 0.4 になる。
    ///
    /// <!-- example: 文脈 var osc: SinOsc?; var env: Env? -->
    /// ```swift
    /// func mousePressed() {
    ///     guard let osc, let env else { return }
    ///     env.play(osc, 0.001, 0.004, 0.3, 0.4)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - input: 形をかける音源。
    ///   - attackTime: 立ち上がる秒数。
    ///   - sustainTime: 保つ秒数。
    ///   - sustainLevel: 保つ高さ (0〜1)。
    ///   - releaseTime: 下がる秒数。
    ///
    /// 秒数が負なら 0 へ、`sustainLevel` が 0〜1 の外なら端へ丸め、数でない値・無限の値があれば
    /// 呼び出し全体を無視する。どちらもそのことを 1 度だけ知らせる (投げない — [ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func play(
        _ input: SynthSource, _ attackTime: Float, _ sustainTime: Float, _ sustainLevel: Float,
        _ releaseTime: Float
    ) {
        input.triggerEnvelope(
            attack: attackTime, sustain: sustainTime, level: sustainLevel, release: releaseTime)
    }
}
