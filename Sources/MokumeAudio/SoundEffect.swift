// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 合成した音を処理するエフェクトに共通の操作。種類ごとに ``LowPass``・``HighPass``・``BandPass``・
/// ``Reverb``・``Delay`` がある。
///
/// ``process(_:)`` で音を通すと、通された音は直には鳴らず、エフェクトの出口を通ってだけ鳴る。
/// 通せるのは合成した音 (オシレータ・ノイズ・別のエフェクト) だけで、``SoundFile`` や
/// ``AudioIn`` は通せない。
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
///         // マウスの左右で切れ目を動かす
///         filter?.freq(map(mouseX, 0, width, 200, 8000))
///         if let filter { circle(width / 2, height / 2, 40 + filter.level * 300) }
///     }
/// }
/// ```
///
/// - エフェクトを別のエフェクトへ通せる (`reverb.process(lowPass)`)。エフェクトの出口が輪になる
///   通し方は拒み、1 度だけ知らせる
/// - 1 つのエフェクトへ複数の音を通すと、足し合わされて処理される。1 つの音を複数のエフェクトへ
///   通すと、エフェクトごとの出口が足し合わされて鳴る
/// - エフェクトの定位は中央で、通した音の定位は引き継がない
/// - 解析の値 (``SynthSound/level`` ほか) は、エフェクトの出口の音のものになる
///
/// どの口も投げない ([ADR-0020] 決定 5)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public class SoundEffect: SynthSound {
    /// 通した音に、いまの設定のままエフェクトをかける。
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
    /// 同じ音を何度通しても 1 度かかるだけ。別の音を通すと、足し合わされて処理される。
    public func process(_ input: SynthSound) {
        connect(input)
    }

    /// エフェクトをやめる。通していた音は、直に鳴る形へ戻る。
    ///
    /// 残響や反響の尾は残さず、すぐ途切れる。もう一度 ``process(_:)`` で通せる。
    public func stop() {
        guard let node, !stage.isClosed else { return }
        stage.rack.setInputs(node.id, 0)
    }

    /// `input` を入力へ足す。足せたら `true`。
    @discardableResult
    func connect(_ input: SynthSound) -> Bool {
        guard let node, let source = input.node, !stage.isClosed, input.stage === stage else {
            return false
        }
        guard stage.rack.canConnect(source.id, to: node.id) else {
            notice(
                "process.cycle",
                "process() was given a sound that is already fed by this \(name), so the "
                    + "connection would loop. This \(name) keeps its other inputs")
            return false
        }
        stage.rack.setInputs(node.id, stage.rack.inputs(of: node.id) | (1 << UInt64(source.id)))
        isActive = true
        return true
    }
}

// MARK: - 濾波器

/// 低域か高域を通す濾波器に共通の操作。``LowPass`` と ``HighPass`` が使う。
///
/// 既定は切れ目 1000 Hz・山の高さ (Q) 1。山の高さは、切れ目のあたりをどれだけ強調するか。
/// 0.7071 で山が出ず、大きいほど切れ目の音が鳴る。
public class Filter: SoundEffect {
    init(stage: SynthStage, shape: FilterShape, name: String) {
        super.init(stage: stage, node: stage.rack.addFilter(shape), name: name)
    }

    /// 通した音に、切れ目を決めてエフェクトをかける。
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
    /// 範囲の外・数でない値は ``freq(_:)`` と同じに扱う。
    public func process(_ input: SynthSound, _ freq: Float) {
        self.freq(freq)
        process(input)
    }

    /// 通した音に、切れ目と山の高さを決めてエフェクトをかける。
    ///
    /// 範囲の外・数でない値は、それぞれ ``freq(_:)``・``res(_:)`` と同じに扱う。
    public func process(_ input: SynthSound, _ freq: Float, _ res: Float) {
        set(freq, res)
        process(input)
    }

    /// 切れ目の周波数を決める。単位は Hz で、10 から 20000 まで。既定は 1000。
    ///
    /// 範囲の外は端へ丸め、数でない値・無限の値は無視する。どちらもそのことを 1 度だけ知らせる
    /// (投げない — [ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func freq(_ frequency: Float) {
        guard let value = accept(
            frequency, 10...20_000, call: "freq", meaning: "a cutoff frequency")
        else { return }
        send(.cutoff, value)
    }

    /// 山の高さ (Q) を決める。0.1 から 100 まで。既定は 1。
    ///
    /// 範囲の外・数でない値は ``freq(_:)`` と同じに扱う。
    public func res(_ quality: Float) {
        guard let value = accept(quality, 0.1...100, call: "res", meaning: "a resonance")
        else { return }
        send(.resonance, value)
    }

    /// 切れ目と山の高さを決める。
    ///
    /// 範囲の外・数でない値は、それぞれ ``freq(_:)``・``res(_:)`` と同じに扱う。
    public func set(_ freq: Float, _ res: Float) {
        self.freq(freq)
        self.res(res)
    }
}

/// 低い音を通し、切れ目より高い音を小さくする濾波器。
///
/// 手本は Processing Sound の `LowPass`。作る口は ``Sketch/createLowPass()``。使い方は ``Filter``。
/// 切れ目から 1 オクターブ上がるごとに約 12 dB 小さくなる。
public final class LowPass: Filter {
    init(stage: SynthStage) {
        super.init(stage: stage, shape: .lowPass, name: "LowPass")
    }
}

/// 高い音を通し、切れ目より低い音を小さくする濾波器。
///
/// 手本は Processing Sound の `HighPass`。作る口は ``Sketch/createHighPass()``。使い方は ``Filter``。
/// 切れ目から 1 オクターブ下がるごとに約 12 dB 小さくなる。
public final class HighPass: Filter {
    init(stage: SynthStage) {
        super.init(stage: stage, shape: .highPass, name: "HighPass")
    }
}

/// 中心の周りの帯域だけを通す濾波器。
///
/// 手本は Processing Sound の `BandPass`。作る口は ``Sketch/createBandPass()``。
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
/// 既定は中心 1000 Hz・幅 500 Hz。中心の音はそのまま通り、幅が狭いほど細い音になる。
public final class BandPass: SoundEffect {
    init(stage: SynthStage) {
        super.init(stage: stage, node: stage.rack.addFilter(.bandPass), name: "BandPass")
    }

    /// 通した音に、中心と幅を決めてエフェクトをかける。
    ///
    /// 範囲の外・数でない値は、それぞれ ``freq(_:)``・``bw(_:)`` と同じに扱う。
    public func process(_ input: SynthSound, _ freq: Float, _ bw: Float) {
        set(freq, bw)
        process(input)
    }

    /// 通す帯域の中心の周波数を決める。単位は Hz で、10 から 20000 まで。既定は 1000。
    ///
    /// 範囲の外は端へ丸め、数でない値・無限の値は無視する。どちらもそのことを 1 度だけ知らせる
    /// (投げない — [ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func freq(_ frequency: Float) {
        guard let value = accept(
            frequency, 10...20_000, call: "freq", meaning: "a center frequency")
        else { return }
        send(.cutoff, value)
    }

    /// 通す帯域の幅を決める。単位は Hz で、1 から 20000 まで。既定は 500。
    ///
    /// 範囲の外・数でない値は ``freq(_:)`` と同じに扱う。
    public func bw(_ bandwidth: Float) {
        guard let value = accept(bandwidth, 1...20_000, call: "bw", meaning: "a bandwidth")
        else { return }
        send(.bandwidth, value)
    }

    /// 中心と幅を決める。
    ///
    /// 範囲の外・数でない値は、それぞれ ``freq(_:)``・``bw(_:)`` と同じに扱う。
    public func set(_ freq: Float, _ bw: Float) {
        self.freq(freq)
        self.bw(bw)
    }
}

// MARK: - リバーブ

/// 残響を足すエフェクト。
///
/// 手本は Processing Sound の `Reverb`。作る口は ``Sketch/createReverb()``。
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
/// Freeverb と同じ並べ方 (8 本の櫛形濾波器の後に 4 本の全域通過濾波器) で、既定は部屋の大きさ 0.5・
/// 高い音の吸われ方 0.5・残響の割合 0.5。残響の割合 0 では通した音がそのまま出る。
public final class Reverb: SoundEffect {
    init(stage: SynthStage) {
        super.init(stage: stage, node: stage.rack.addReverb(), name: "Reverb")
    }

    /// 通した音に、部屋の大きさ・高い音の吸われ方・残響の割合を決めてエフェクトをかける。
    ///
    /// 範囲の外・数でない値は、それぞれ ``room(_:)``・``damp(_:)``・``wet(_:)`` と同じに扱う。
    public func process(_ input: SynthSound, _ room: Float, _ damp: Float, _ wet: Float) {
        set(room, damp, wet)
        process(input)
    }

    /// 部屋の大きさを決める。0〜1 で、大きいほど残響が長い。既定は 0.5。
    ///
    /// 範囲の外は端へ丸め、数でない値・無限の値は無視する。どちらもそのことを 1 度だけ知らせる
    /// (投げない — [ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func room(_ size: Float) {
        guard let value = accept(size, 0...1, call: "room", meaning: "a room size") else {
            return
        }
        send(.room, value)
    }

    /// 高い音の吸われ方を決める。0〜1 で、大きいほど残響がこもる。既定は 0.5。
    ///
    /// 範囲の外・数でない値は ``room(_:)`` と同じに扱う。
    public func damp(_ amount: Float) {
        guard let value = accept(amount, 0...1, call: "damp", meaning: "a damping") else {
            return
        }
        send(.damping, value)
    }

    /// 残響の割合を決める。0 で通した音だけ、1 で残響だけ。既定は 0.5。
    ///
    /// 範囲の外・数でない値は ``room(_:)`` と同じに扱う。
    public func wet(_ amount: Float) {
        guard let value = accept(amount, 0...1, call: "wet", meaning: "a wet amount") else {
            return
        }
        send(.wetness, value)
    }

    /// 部屋の大きさ・高い音の吸われ方・残響の割合を決める。
    ///
    /// 範囲の外・数でない値は、それぞれ ``room(_:)``・``damp(_:)``・``wet(_:)`` と同じに扱う。
    public func set(_ room: Float, _ damp: Float, _ wet: Float) {
        self.room(room)
        self.damp(damp)
        self.wet(wet)
    }
}

// MARK: - ディレイ

/// 遅れた音を重ねて、反響を繰り返すエフェクト。
///
/// 手本は Processing Sound の `Delay`。作る口は ``Sketch/createDelay()``。
///
/// <!-- example: 文脈 var osc: SinOsc?; var env: Env?; var delay: Delay? -->
/// ```swift
/// func setup() {
///     osc = createSinOsc()
///     env = createEnv()
///     delay = createDelay()
///     if let osc { delay?.process(osc, 2, 0.5) }
///     delay?.time(0.3)
/// }
/// func mousePressed() {
///     if let osc { env?.play(osc, 0.01, 0.05, 0.5, 0.1) }
/// }
/// ```
///
/// 元の音に、`time` 秒遅れた同じ大きさの音を重ね、その音を `feedback` の割合で小さくしながら
/// 繰り返す。`feedback` が 0 なら反響は 1 度、大きいほど長く続く。**重なったぶん大きくなる**ので、
/// 歪むときは音源の音量を下げる。既定は遅れ 0.25 秒・戻す割合 0.5。
public final class Delay: SoundEffect {
    /// 遅れの上限 (秒)。``process(_:_:)`` で変える。
    private var maximumTime: Float = Float(EchoKernel.maximumSeconds)

    init(stage: SynthStage) {
        super.init(stage: stage, node: stage.rack.addDelay(), name: "Delay")
    }

    /// 通した音に、遅れの上限を決めてエフェクトをかける。
    ///
    /// 遅れ (``time(_:)``) は 0 から `maxDelayTime` 秒まで。0 から 5 秒の外は端へ丸め、数でない値・
    /// 無限の値は無視する。どちらもそのことを 1 度だけ知らせる (投げない — [ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func process(_ input: SynthSound, _ maxDelayTime: Float) {
        if let value = accept(
            maxDelayTime, 0...Float(EchoKernel.maximumSeconds), call: "process",
            meaning: "a maxDelayTime")
        {
            maximumTime = value
        }
        process(input)
    }

    /// 通した音に、遅れの上限と戻す割合を決めてエフェクトをかける。
    ///
    /// 範囲の外・数でない値は、それぞれ ``process(_:_:)``・``feedback(_:)`` と同じに扱う。
    public func process(_ input: SynthSound, _ maxDelayTime: Float, _ feedback: Float) {
        self.feedback(feedback)
        process(input, maxDelayTime)
    }

    /// 遅れを決める。単位は秒で、0 から ``process(_:_:)`` で決めた上限まで (既定は 5)。既定の遅れは 0.25。
    ///
    /// 範囲の外は端へ丸め、数でない値・無限の値は無視する。どちらもそのことを 1 度だけ知らせる
    /// (投げない — [ADR-0020] 決定 5)。遅れを動かしている最中は、音の高さが揺れる。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func time(_ seconds: Float) {
        guard let value = accept(
            seconds, 0...maximumTime, call: "time", meaning: "a delay time")
        else { return }
        send(.time, value)
    }

    /// 戻す割合を決める。0〜1 で、大きいほど反響が長く続く。既定は 0.5。
    ///
    /// 範囲の外・数でない値は ``time(_:)`` と同じに扱う。1 は止まらなくなるので、手前の 0.99 で止める。
    public func feedback(_ amount: Float) {
        guard let value = accept(amount, 0...1, call: "feedback", meaning: "a feedback") else {
            return
        }
        send(.feedback, value)
    }

    /// 遅れと戻す割合を決める。
    ///
    /// 範囲の外・数でない値は、それぞれ ``time(_:)``・``feedback(_:)`` と同じに扱う。
    public func set(_ time: Float, _ feedback: Float) {
        self.time(time)
        self.feedback(feedback)
    }
}
