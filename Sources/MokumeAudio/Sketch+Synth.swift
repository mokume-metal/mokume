// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

// 音の合成とエフェクト。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 手本は Processing Sound の `SinOsc`・`SqrOsc`・`TriOsc`・`SawOsc`・`WhiteNoise`・`PinkNoise`・
// `Env`・`LowPass`・`HighPass`・`BandPass`・`Reverb`・`Delay` である ([ADR-0020] 決定 1)。
// Processing の `new SinOsc(this)` に当たる作る口は、`createAudioIn()` の先例どおり
// `create` + 型の名前にする。呼べば使える標準の機能で ([ADR-0042] 決定 1)、`plugins` には何も
// 書かない。
//
// 作った音は、再生 (``SoundFile``) と同じ音の流れ (`SoundFlow`) へ入り、どれも同じ解析
// (``AudioIn`` と同じ値の名前) を読める ([ADR-0042] 決定 6)。作る口は投げない — 作れなかった
// ときは (64 個の上限) 診断に出し、何も鳴らさない音を返す。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
extension Sketch {

    // MARK: - オシレータ

    /// 正弦波のオシレータを作る。鳴らすのは ``Oscillator/play(_:_:_:_:)`` か ``SynthSource/play()`` を
    /// 呼んでから。
    ///
    /// <!-- example: 文脈 var osc: SinOsc? -->
    /// ```swift
    /// func setup() {
    ///     osc = createSinOsc()
    ///     osc?.play()
    /// }
    /// func draw() {
    ///     background(0)
    ///     // マウスの左右で 100〜1000 Hz に動かす
    ///     osc?.freq(map(mouseX, 0, width, 100, 1000))
    ///     if let osc { circle(width / 2, height / 2, 40 + osc.level * 300) }
    /// }
    /// ```
    ///
    /// - **呼んだときだけ音の流れへ入る。** `import mokume` しただけで鳴ったり、出力の機材が
    ///   開いたりはしない。許可も要らない
    /// - 作った音は ``Oscillator`` の口で操作し、``SynthSound`` の値で解析できる
    /// - 窓に出している間は実際に鳴り、書き出し (`mokume render`) では鳴らさずに、同じ操作から同じ
    ///   値を解析できる (``SynthSound``)
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    public func createSinOsc() -> SinOsc {
        SinOsc(stage: SynthStage.stage(for: self))
    }

    /// 矩形波のオシレータを作る。使い方は ``createSinOsc()`` と同じ。
    ///
    /// <!-- example: 文脈 var osc: SqrOsc? -->
    /// ```swift
    /// func setup() {
    ///     osc = createSqrOsc()
    ///     osc?.play(220, 0.2)
    /// }
    /// ```
    public func createSqrOsc() -> SqrOsc {
        SqrOsc(stage: SynthStage.stage(for: self))
    }

    /// 三角波のオシレータを作る。使い方は ``createSinOsc()`` と同じ。
    ///
    /// <!-- example: 文脈 var osc: TriOsc? -->
    /// ```swift
    /// func setup() {
    ///     osc = createTriOsc()
    ///     osc?.play(330, 0.4)
    /// }
    /// ```
    public func createTriOsc() -> TriOsc {
        TriOsc(stage: SynthStage.stage(for: self))
    }

    /// のこぎり波のオシレータを作る。使い方は ``createSinOsc()`` と同じ。
    ///
    /// <!-- example: 文脈 var osc: SawOsc? -->
    /// ```swift
    /// func setup() {
    ///     osc = createSawOsc()
    ///     osc?.play(110, 0.2)
    /// }
    /// ```
    public func createSawOsc() -> SawOsc {
        SawOsc(stage: SynthStage.stage(for: self))
    }

    // MARK: - ノイズ

    /// 白色雑音を作る。鳴らすのは ``Noise/play(_:_:_:)`` か ``SynthSource/play()`` を呼んでから。
    /// 呼んだときの決まりは ``createSinOsc()`` と同じ。
    ///
    /// <!-- example: 文脈 var noise: WhiteNoise? -->
    /// ```swift
    /// func setup() {
    ///     noise = createWhiteNoise()
    ///     noise?.play(0.2)
    /// }
    /// ```
    public func createWhiteNoise() -> WhiteNoise {
        WhiteNoise(stage: SynthStage.stage(for: self))
    }

    /// ピンクノイズを作る。使い方は ``createWhiteNoise()`` と同じ。
    ///
    /// <!-- example: 文脈 var noise: PinkNoise? -->
    /// ```swift
    /// func setup() {
    ///     noise = createPinkNoise()
    ///     noise?.play(0.3)
    /// }
    /// ```
    public func createPinkNoise() -> PinkNoise {
        PinkNoise(stage: SynthStage.stage(for: self))
    }

    // MARK: - 包絡

    /// 包絡 (音の大きさの形) を作る。かけるのは ``Env/play(_:_:_:_:_:)``。
    ///
    /// <!-- example: 文脈 var osc: SinOsc?; var env: Env? -->
    /// ```swift
    /// func setup() {
    ///     osc = createSinOsc()
    ///     env = createEnv()
    /// }
    /// func mousePressed() {
    ///     if let osc { env?.play(osc, 0.01, 0.2, 0.5, 0.4) }
    /// }
    /// ```
    ///
    /// 包絡は音を持たず、作っても数に入らない。
    public func createEnv() -> Env {
        Env()
    }

    // MARK: - エフェクト

    /// 低域を通す濾波器を作る。通す音は ``SoundEffect/process(_:)`` で渡す。
    /// 呼んだときの決まりは ``createSinOsc()`` と同じ。
    ///
    /// <!-- example: 文脈 var noise: WhiteNoise?; var filter: LowPass? -->
    /// ```swift
    /// func setup() {
    ///     noise = createWhiteNoise()
    ///     filter = createLowPass()
    ///     noise?.play(0.3)
    ///     if let noise { filter?.process(noise, 500) }
    /// }
    /// ```
    public func createLowPass() -> LowPass {
        LowPass(stage: SynthStage.stage(for: self))
    }

    /// 高域を通す濾波器を作る。使い方は ``createLowPass()`` と同じ。
    ///
    /// <!-- example: 文脈 var noise: WhiteNoise?; var filter: HighPass? -->
    /// ```swift
    /// func setup() {
    ///     noise = createWhiteNoise()
    ///     filter = createHighPass()
    ///     noise?.play(0.3)
    ///     if let noise { filter?.process(noise, 4000) }
    /// }
    /// ```
    public func createHighPass() -> HighPass {
        HighPass(stage: SynthStage.stage(for: self))
    }

    /// 帯域を通す濾波器を作る。使い方は ``createLowPass()`` と同じ。
    ///
    /// <!-- example: 文脈 var noise: WhiteNoise?; var band: BandPass? -->
    /// ```swift
    /// func setup() {
    ///     noise = createWhiteNoise()
    ///     band = createBandPass()
    ///     noise?.play(0.3)
    ///     if let noise { band?.process(noise, 1000, 100) }
    /// }
    /// ```
    public func createBandPass() -> BandPass {
        BandPass(stage: SynthStage.stage(for: self))
    }

    /// リバーブを作る。使い方は ``createLowPass()`` と同じ。
    ///
    /// <!-- example: 文脈 var osc: SinOsc?; var reverb: Reverb? -->
    /// ```swift
    /// func setup() {
    ///     osc = createSinOsc()
    ///     reverb = createReverb()
    ///     if let osc { reverb?.process(osc) }
    ///     osc?.play(440, 0.3)
    /// }
    /// ```
    public func createReverb() -> Reverb {
        Reverb(stage: SynthStage.stage(for: self))
    }

    /// ディレイを作る。使い方は ``createLowPass()`` と同じ。
    ///
    /// <!-- example: 文脈 var osc: SinOsc?; var delay: Delay? -->
    /// ```swift
    /// func setup() {
    ///     osc = createSinOsc()
    ///     delay = createDelay()
    ///     if let osc { delay?.process(osc, 1) }
    ///     delay?.set(0.4, 0.5)
    ///     osc?.play(440, 0.3)
    /// }
    /// ```
    public func createDelay() -> Delay {
        Delay(stage: SynthStage.stage(for: self))
    }
}
