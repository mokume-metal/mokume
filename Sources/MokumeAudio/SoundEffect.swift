// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 合成音を処理するエフェクトに共通の操作。種類ごとに ``LowPass``・``HighPass``・``BandPass``・
/// ``Reverb``・``Delay`` がある。
///
/// ``process(_:)`` で音を入力すると、入力された音は直接は出力されず、エフェクトの出力を通してだけ聞こえる。
/// 入力できるのは合成音 (オシレータ・ノイズ・別のエフェクト) と音声ファイル (``SoundFile``) で
/// (``EffectInput``)、``AudioIn`` は入力できない。
///
/// ```swift
/// final class Muffled: Sketch {
///     var noise: WhiteNoise?
///     var filter: LowPass?
///     func setup() {
///         noise = createWhiteNoise()
///         filter = createLowPass()
///         noise?.play(0.3)
///         if let noise { filter?.process(noise, 1000) }
///     }
///     func draw() {
///         background(0)
///         // マウスの左右でカットオフ周波数を動かす
///         filter?.freq(map(mouseX, 0, width, 200, 8000))
///         if let filter { circle(width / 2, height / 2, 40 + filter.level * 300) }
///     }
/// }
/// ```
///
/// - エフェクトを別のエフェクトへ入力できる (`reverb.process(lowPass)`)。エフェクトの出力が循環する
///   接続は拒否し、1 度だけ警告する
/// - 1 つのエフェクトへ複数の音を入力すると、ミックスして処理される。1 つの音を複数のエフェクトへ
///   入力すると、エフェクトごとの出力がミックスされて聞こえる
/// - エフェクトの定位は中央で、入力した音の定位は引き継がない。**ステレオの ``SoundFile`` も、エフェクトの
///   出力ではモノラル (中央) にまとめられる**
/// - 解析値 (``SynthSound/level`` ほか) は、エフェクトの出力の音のものになる
///
/// どのメソッドも投げない ([ADR-0020] 決定 5)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public class SoundEffect: SynthSound {
    /// 入力した音に、現在の設定のままエフェクトをかける。
    ///
    /// <!-- example: 文脈 var osc: SinOsc?; var reverb: Reverb? -->
    /// ```swift
    /// func setup() {
    ///     osc = createSinOsc()
    ///     reverb = createReverb()
    ///     if let osc { reverb?.process(osc) }
    ///     osc?.play()
    /// }
    /// ```
    ///
    /// 同じ音を何度入力しても 1 度かかるだけ。別の音を入力すると、ミックスして処理される。
    ///
    /// ``SoundFile`` も入力できる。最初に入力したときから、そのファイルは合成音と同じオーディオグラフ (ラック) で再生される (左右はモノラルにまとめられ、ノードの上限を
    /// 1 つ使う — ``SoundFile``)。``EffectInput`` に準拠しない型は処理されず、1 度だけ警告する。
    ///
    /// <!-- example: 文脈 var song: SoundFile?; var reverb: Reverb? -->
    /// ```swift
    /// func setup() throws {
    ///     song = try loadSound("assets/song.wav")
    ///     reverb = createReverb()
    ///     if let song { reverb?.process(song) }
    ///     song?.loop()
    /// }
    /// ```
    public func process(_ input: any EffectInput) {
        connect(input)
    }

    /// エフェクトを解除する。入力していた音は、エフェクトを通さず直接出力される状態へ戻る。
    ///
    /// リバーブやディレイの余韻は残さず、すぐ途切れる。もう一度 ``process(_:)`` で入力できる。入力していた
    /// ``SoundFile`` は、いったんラックで再生した後なので、中央のモノラルのまま直接出力され続ける。
    public func stop() {
        guard let node, !stage.isClosed else { return }
        stage.rack.setInputs(node.id, 0)
    }

    /// `input` を入力へ足す。足せたら `true`。
    ///
    /// ``SoundFile`` は、最初に通されたとき、ラックの節を足してそこから鳴らす形に切り替える
    /// (``SoundFile/route(into:)``)。
    @discardableResult
    func connect(_ input: any EffectInput) -> Bool {
        guard let node, !stage.isClosed else { return false }
        let source: RackNode
        // ファイルの節は、**入力に選んでから**鳴らし始める (``SoundFile/nodeIsConnected()``)
        var routed: SoundFile?
        defer { routed?.nodeIsConnected() }
        if let sound = input as? SynthSound {
            guard let inner = sound.node, sound.stage === stage else { return false }
            source = inner
        } else if let file = input as? SoundFile {
            // 断った理由は、ファイルの側が 1 度だけ知らせる
            guard let inner = file.route(into: stage) else { return false }
            source = inner
            routed = file
        } else {
            notice(
                "process.unsupported",
                "process() was given a sound that is neither a synthesized sound nor a SoundFile, so "
                    + "this \(name) keeps its other inputs")
            return false
        }
        guard stage.rack.canConnect(source.id, to: node.id) else {
            notice(
                "process.cycle",
                "process() was given a sound that is already fed by this \(name), so the "
                    + "connection would loop. This \(name) keeps its other inputs")
            return false
        }
        // 操作が溢れて受け付けられなければ、繋がず (入力の写しも変えず)、ステージが 1 度だけ知らせる (#3944)
        guard stage.rack.setInputs(node.id, stage.rack.inputs(of: node.id) | (1 << UInt64(source.id)))
        else {
            routed = nil
            return false
        }
        isActive = true
        return true
    }
}

// MARK: - 濾波器

/// ローパスかハイパスのフィルタに共通の操作。``LowPass`` と ``HighPass`` が使う。
///
/// 既定はカットオフ周波数 1000 Hz・レゾナンス (Q) 1。レゾナンスは、カットオフ周波数の付近をどれだけ強調するか。
/// 0.7071 でピークが出ず、大きいほどカットオフ周波数の付近の音が強く出る。
public class Filter: SoundEffect {
    init(stage: SynthStage, shape: FilterShape, name: String) {
        super.init(stage: stage, node: stage.rack.addFilter(shape), name: name)
    }

    /// 入力した音に、カットオフ周波数を指定してエフェクトをかける。
    ///
    /// <!-- example: 文脈 var noise: PinkNoise?; var filter: LowPass? -->
    /// ```swift
    /// func setup() {
    ///     noise = createPinkNoise()
    ///     filter = createLowPass()
    ///     noise?.play(0.3)
    ///     if let noise { filter?.process(noise, 800) }
    /// }
    /// ```
    ///
    /// 範囲の外・NaN は ``freq(_:)`` と同じに扱う。
    public func process(_ input: any EffectInput, _ freq: Float) {
        self.freq(freq)
        process(input)
    }

    /// 入力した音に、カットオフ周波数とレゾナンスを指定してエフェクトをかける。
    ///
    /// 範囲の外・NaN は、それぞれ ``freq(_:)``・``res(_:)`` と同じに扱う。
    public func process(_ input: any EffectInput, _ freq: Float, _ res: Float) {
        set(freq, res)
        process(input)
    }

    /// カットオフ周波数を設定する。単位は Hz で、10 から 20000 まで。既定は 1000。
    ///
    /// 範囲の外は端にクランプし、NaN・無限大は無視する。どちらもそのことを 1 度だけ警告する
    /// (投げない — [ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func freq(_ frequency: Float) {
        guard let value = accept(
            frequency, 10...20_000, call: "freq", meaning: "a cutoff frequency")
        else { return }
        send(.cutoff, value)
    }

    /// レゾナンス (Q) を設定する。0.1 から 100 まで。既定は 1。
    ///
    /// 範囲の外・NaN は ``freq(_:)`` と同じに扱う。
    public func res(_ quality: Float) {
        guard let value = accept(quality, 0.1...100, call: "res", meaning: "a resonance")
        else { return }
        send(.resonance, value)
    }

    /// カットオフ周波数とレゾナンスを設定する。
    ///
    /// 範囲の外・NaN は、それぞれ ``freq(_:)``・``res(_:)`` と同じに扱う。
    public func set(_ freq: Float, _ res: Float) {
        self.freq(freq)
        self.res(res)
    }
}

/// 低い音を通し、カットオフ周波数より高い音を減衰させるフィルタ。
///
/// Processing Sound の `LowPass` に当たる。作る関数は ``Sketch/createLowPass()``。使い方は ``Filter``。
/// カットオフ周波数から 1 オクターブ上がるごとに約 12 dB 減衰する。
public final class LowPass: Filter {
    init(stage: SynthStage) {
        super.init(stage: stage, shape: .lowPass, name: "LowPass")
    }
}

/// 高い音を通し、カットオフ周波数より低い音を減衰させるフィルタ。
///
/// Processing Sound の `HighPass` に当たる。作る関数は ``Sketch/createHighPass()``。使い方は ``Filter``。
/// カットオフ周波数から 1 オクターブ下がるごとに約 12 dB 減衰する。
public final class HighPass: Filter {
    init(stage: SynthStage) {
        super.init(stage: stage, shape: .highPass, name: "HighPass")
    }
}

/// 中心周波数の周りの帯域だけを通すフィルタ。
///
/// Processing Sound の `BandPass` に当たる。作る関数は ``Sketch/createBandPass()``。
///
/// <!-- example: 文脈 var noise: WhiteNoise?; var band: BandPass? -->
/// ```swift
/// func setup() {
///     noise = createWhiteNoise()
///     band = createBandPass()
///     noise?.play(0.3)
///     if let noise { band?.process(noise, 1000, 200) }
/// }
/// ```
///
/// 既定は中心周波数 1000 Hz・帯域幅 500 Hz。中心周波数の音はそのまま通り、帯域幅が狭いほど細い音になる。
///
/// 幅の決め方は 2 通りある。``bw(_:)`` は幅を Hz で保ち、中心周波数を動かしても幅は変わらない。``res(_:)`` は
/// Q (中心周波数 ÷ 幅) を保ち、中心周波数を動かすと幅もそれに比例して変わる (音の高さに追従する細さ)。
/// **後に呼んだほうが効く** (``set(_:_:)``・``process(_:_:_:)`` の幅は ``bw(_:)`` と同じ)。
public final class BandPass: SoundEffect {
    init(stage: SynthStage) {
        super.init(stage: stage, node: stage.rack.addFilter(.bandPass), name: "BandPass")
    }

    /// 入力した音に、中心周波数と帯域幅を指定してエフェクトをかける。
    ///
    /// 範囲の外・NaN は、それぞれ ``freq(_:)``・``bw(_:)`` と同じに扱う。
    public func process(_ input: any EffectInput, _ freq: Float, _ bw: Float) {
        set(freq, bw)
        process(input)
    }

    /// 通す帯域の中心周波数を設定する。単位は Hz で、10 から 20000 まで。既定は 1000。
    ///
    /// 範囲の外は端にクランプし、NaN・無限大は無視する。どちらもそのことを 1 度だけ警告する
    /// (投げない — [ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func freq(_ frequency: Float) {
        guard let value = accept(
            frequency, 10...20_000, call: "freq", meaning: "a center frequency")
        else { return }
        send(.cutoff, value)
    }

    /// 通す帯域の幅を設定する。単位は Hz で、1 から 20000 まで。既定は 500。
    ///
    /// 中心周波数を動かしても、幅は Hz のまま保つ。``res(_:)`` を呼んだ後に呼ぶと、こちらが効く。
    /// 範囲の外・NaN は ``freq(_:)`` と同じに扱う。
    public func bw(_ bandwidth: Float) {
        guard let value = accept(bandwidth, 1...20_000, call: "bw", meaning: "a bandwidth")
        else { return }
        send(.bandwidth, value)
    }

    /// 帯域の細さを Q (中心周波数 ÷ 幅) で設定する。0.1 から 10 まで。
    ///
    /// <!-- example: 文脈 var band: BandPass? -->
    /// ```swift
    /// // 細さを保ったまま、マウスの左右で中心を 200〜4000 Hz に動かす (幅は中心の 1/8)
    /// band?.res(8)
    /// band?.freq(map(mouseX, 0, width, 200, 4000))
    /// ```
    ///
    /// **中心周波数を動かすと、幅も比例して変わる** — Q 5 なら、中心 1000 Hz で幅 200 Hz、中心 2000 Hz で幅 400 Hz。
    /// 幅を Hz で保つなら ``bw(_:)``。``bw(_:)``・``set(_:_:)`` を呼んだ後に呼ぶと、こちらが効く。
    ///
    /// 範囲は Processing Sound の `BandPass.res()` と同じ 0.1〜10 で、``Filter/res(_:)`` (0.1〜100) とは違う。
    /// 範囲の外は端にクランプし、NaN・無限大は無視する。どちらもそのことを 1 度だけ警告する
    /// (投げない — [ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func res(_ quality: Float) {
        guard let value = accept(quality, 0.1...10, call: "res", meaning: "a resonance (Q)")
        else { return }
        send(.resonance, value)
    }

    /// 中心周波数と帯域幅を設定する。
    ///
    /// 範囲の外・NaN は、それぞれ ``freq(_:)``・``bw(_:)`` と同じに扱う。
    public func set(_ freq: Float, _ bw: Float) {
        self.freq(freq)
        self.bw(bw)
    }
}

// MARK: - リバーブ

/// 残響を加えるエフェクト。
///
/// Processing Sound の `Reverb` に当たる。作る関数は ``Sketch/createReverb()``。
///
/// <!-- example: 文脈 var osc: SinOsc?; var reverb: Reverb? -->
/// ```swift
/// func setup() {
///     osc = createSinOsc()
///     reverb = createReverb()
///     if let osc { reverb?.process(osc, 0.8, 0.3, 0.5) }
///     osc?.play(440, 0.3)
/// }
/// ```
///
/// Freeverb と同じ構成 (8 本のコムフィルタの後に 4 本のオールパスフィルタ) で、既定は部屋の大きさ 0.5・
/// 高域の減衰 0.5・ウェットの割合 0.5。ウェットの割合 0 では入力した音がそのまま出る。
public final class Reverb: SoundEffect {
    init(stage: SynthStage) {
        super.init(stage: stage, node: stage.rack.addReverb(), name: "Reverb")
    }

    /// 入力した音に、部屋の大きさ・高域の減衰・ウェットの割合を指定してエフェクトをかける。
    ///
    /// 範囲の外・NaN は、それぞれ ``room(_:)``・``damp(_:)``・``wet(_:)`` と同じに扱う。
    public func process(_ input: any EffectInput, _ room: Float, _ damp: Float, _ wet: Float) {
        set(room, damp, wet)
        process(input)
    }

    /// 部屋の大きさを設定する。0〜1 で、大きいほど残響が長い。既定は 0.5。
    ///
    /// 範囲の外は端にクランプし、NaN・無限大は無視する。どちらもそのことを 1 度だけ警告する
    /// (投げない — [ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func room(_ size: Float) {
        guard let value = accept(size, 0...1, call: "room", meaning: "a room size") else {
            return
        }
        send(.room, value)
    }

    /// 高域の減衰 (ダンピング) を設定する。0〜1 で、大きいほど残響がこもる。既定は 0.5。
    ///
    /// 範囲の外・NaN は ``room(_:)`` と同じに扱う。
    public func damp(_ amount: Float) {
        guard let value = accept(amount, 0...1, call: "damp", meaning: "a damping") else {
            return
        }
        send(.damping, value)
    }

    /// ウェット (残響) の割合を設定する。0 で入力した音だけ、1 で残響だけ。既定は 0.5。
    ///
    /// 範囲の外・NaN は ``room(_:)`` と同じに扱う。
    public func wet(_ amount: Float) {
        guard let value = accept(amount, 0...1, call: "wet", meaning: "a wet amount") else {
            return
        }
        send(.wetness, value)
    }

    /// 部屋の大きさ・高域の減衰・ウェットの割合を設定する。
    ///
    /// 範囲の外・NaN は、それぞれ ``room(_:)``・``damp(_:)``・``wet(_:)`` と同じに扱う。
    public func set(_ room: Float, _ damp: Float, _ wet: Float) {
        self.room(room)
        self.damp(damp)
        self.wet(wet)
    }
}

// MARK: - ディレイ

/// 遅れた音を重ねて、反響を繰り返すエフェクト。
///
/// Processing Sound の `Delay` に当たる。作る関数は ``Sketch/createDelay()``。
///
/// <!-- example: 文脈 var osc: SinOsc?; var env: Env?; var delay: Delay? -->
/// ```swift
/// func setup() {
///     osc = createSinOsc()
///     env = createEnv()
///     delay = createDelay()
///     // 上限 2 秒・遅れ 0.3 秒・戻す割合 0.5
///     if let osc { delay?.process(osc, 2, 0.3) }
///     delay?.feedback(0.5)
/// }
/// func mousePressed() {
///     if let osc { env?.play(osc, 0.01, 0.05, 0.5, 0.1) }
/// }
/// ```
///
/// 元の音に、`time` 秒遅れた同じ大きさの音を重ね、その音を `feedback` の割合で小さくしながら
/// 繰り返す。`feedback` が 0 なら反響は 1 度、大きいほど長く続く。**重なったぶん音量が大きくなる**ので、
/// 歪むときは音源の音量を下げる。既定はディレイタイム 0.25 秒・フィードバック 0.5。
public final class Delay: SoundEffect {
    /// 遅れの上限 (秒)。``process(_:_:)`` で変える。
    private var maximumTime: Float = Float(EchoKernel.maximumSeconds)

    init(stage: SynthStage) {
        super.init(stage: stage, node: stage.rack.addDelay(), name: "Delay")
    }

    /// 入力した音に、ディレイタイムの上限を指定してエフェクトをかける。
    ///
    /// ディレイタイム (``time(_:)``) は 0 から `maxDelayTime` 秒まで。0 から 5 秒の外は端にクランプし、NaN・
    /// 無限大は無視する。どちらもそのことを 1 度だけ警告する (投げない — [ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func process(_ input: any EffectInput, _ maxDelayTime: Float) {
        acceptMaximum(maxDelayTime)
        process(input)
    }

    /// 入力した音に、ディレイタイムの上限と始めのディレイタイムを指定してエフェクトをかける。
    ///
    /// <!-- example: 文脈 var osc: SinOsc?; var delay: Delay? -->
    /// ```swift
    /// func setup() {
    ///     osc = createSinOsc()
    ///     delay = createDelay()
    ///     // 上限 2 秒・遅れ 0.3 秒。戻す割合は feedback(_:) で決める
    ///     if let osc { delay?.process(osc, 2, 0.3) }
    ///     delay?.feedback(0.5)
    /// }
    /// ```
    ///
    /// **第 3 引数はディレイタイム (秒)** で、``time(_:)`` と同じ (Processing Sound の
    /// `process(input, maxDelayTime, delayTime)` と同じ)。フィードバックの割合は ``feedback(_:)`` か
    /// ``set(_:_:)`` で決める。範囲の外・NaN は、それぞれ ``process(_:_:)``・``time(_:)`` と同じに扱う
    /// (ディレイタイムは、この呼び出しで決めた上限で丸める)。
    public func process(_ input: any EffectInput, _ maxDelayTime: Float, _ delayTime: Float) {
        acceptMaximum(maxDelayTime)
        time(delayTime)
        process(input)
    }

    /// ディレイタイムの上限を受け、範囲の外は丸め、数でない値は無視する (どちらも 1 度だけ知らせる)。
    private func acceptMaximum(_ maxDelayTime: Float) {
        if let value = accept(
            maxDelayTime, 0...Float(EchoKernel.maximumSeconds), call: "process",
            meaning: "a maxDelayTime")
        {
            maximumTime = value
        }
    }

    /// ディレイタイムを設定する。単位は秒で、0 から ``process(_:_:)`` で指定した上限まで (既定は 5)。既定のディレイタイムは 0.25。
    ///
    /// 範囲の外は端にクランプし、NaN・無限大は無視する。どちらもそのことを 1 度だけ警告する
    /// (投げない — [ADR-0020] 決定 5)。ディレイタイムを変えている最中は、音の高さが揺れる。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func time(_ seconds: Float) {
        guard let value = accept(
            seconds, 0...maximumTime, call: "time", meaning: "a delay time")
        else { return }
        send(.time, value)
    }

    /// フィードバックの割合を設定する。0〜1 で、大きいほど反響が長く続く。既定は 0.5。
    ///
    /// 範囲の外・NaN は ``time(_:)`` と同じに扱う。1 では減衰しなくなるので、手前の 0.99 に制限する。
    public func feedback(_ amount: Float) {
        guard let value = accept(amount, 0...1, call: "feedback", meaning: "a feedback") else {
            return
        }
        send(.feedback, value)
    }

    /// ディレイタイムとフィードバックの割合を設定する。
    ///
    /// 範囲の外・NaN は、それぞれ ``time(_:)``・``feedback(_:)`` と同じに扱う。
    public func set(_ time: Float, _ feedback: Float) {
        self.time(time)
        self.feedback(feedback)
    }
}
