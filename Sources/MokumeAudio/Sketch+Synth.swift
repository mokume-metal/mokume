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
// ときは (同時に生きている音 64 個の上限。手放して鳴り終えたオシレータ・ノイズと、外したエフェクト入力の
// ファイルは数から外れる) 診断に出し、
// 何も鳴らさない音を返す。走っている実行へ足せない所で呼ばれ、音の流れ
// (``SynthStage``) をまだ足していなければ、作る口の名前で 1 度だけ警告して、鳴らない音を返す (#2740)。`setup()`
// などで先に合成音を作って流れを足してあれば、外から作った音もその流れに入って鳴る。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
extension Sketch {

    // MARK: - オシレータ

    /// 正弦波のオシレータを作る。鳴らすのは ``Oscillator/play(_:_:_:_:at:)`` か ``SynthSource/play(at:)`` を
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
    /// - 窓に出している間は実際に鳴り、固定の時計で `.mov` へ書き出すと、動画の音声トラックに載る
    ///   (``SynthSound``)。録っていない書き出しでは鳴らさずに、同じ操作から同じ値を解析できる
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。外 (初期化子の中・後片付けの後・`Task` の中) で
    /// 呼んで、音の流れを走っている実行へ足せなければ、鳴らない音を返し、この口の名前で 1 度だけ警告する。
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

    /// 白色雑音を作る。鳴らすのは ``Noise/play(_:_:_:at:)`` か ``SynthSource/play(at:)`` を呼んでから。
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

    /// 包絡 (音の大きさの形) を作る。かけるのは ``Env/play(_:_:_:_:_:at:)``。
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

    // MARK: - 音の時計

    /// いまの音の時計 (秒)。合成した音の予約 (`play(at:)`・``Env/play(_:_:_:_:_:at:)``) が読む時計で、次の拍の頭を
    /// 求めるのに使う。
    ///
    /// <!-- example: 文脈 var osc: SinOsc?; var env: Env? -->
    /// ```swift
    /// func draw() {
    ///     guard let osc, let env else { return }
    ///     // 次の 0.5 秒の頭ちょうどへ鳴らす
    ///     let next = (soundTime / 0.5).rounded(.down) * 0.5 + 0.5
    ///     env.play(osc, 0.002, 0.03, 0.7, 0.1, at: next)
    /// }
    /// ```
    ///
    /// - 合成した音を **1 つ作ってから** 0 秒を起点に数え、`setup()` で作ったスケッチを 60 fps の固定の時計で回すと、
    ///   `frameCount` が 121 の `draw()` で 2.0 を返す (`SoundFile` の `position` と同じ数え方)。合成した音を
    ///   1 つも作っていなければ、いつも 0 を返す
    /// - **``SketchPart/time`` ではない。** ``SketchPart/pauseTime()`` でも止まらず、``SketchPart/jumpTime(_:)`` でも
    ///   飛ばない (音を進めるのは音の時計で、``SynthSound`` と同じ)
    /// - 書き出し (固定の時計) では、フレームの数から決まるので、同じフレームはいつも同じ値を返す。窓では、
    ///   音の側が**実際に作った標本の数**から読む (`clock: .frames` の窓も)。処理が落ちて音が遅れた間は、
    ///   ``SketchPart/time`` とずれうる
    /// - 単精度なので、3 分を超えるあたりから 1 標本 (約 0.02 ミリ秒) の粒には揃わず、予約が数標本ずれうる
    /// - 読むのに錠は取らず、音の側を待たせない
    ///
    /// 手本は Tone.js の `Tone.now()` と Web Audio の `AudioContext.currentTime`。
    public var soundTime: Float {
        Float(SynthStage.existing(for: self)?.soundSeconds ?? 0)
    }
}
