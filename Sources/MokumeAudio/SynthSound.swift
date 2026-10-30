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
/// 各フレームでは、**前のフレームからその音の出口に出た全標本**(区間)を ``AudioIn`` と同じ解析に通す。
/// 区間を切るのはフレームの頭で、**解析は値が読まれたときまで遅らせる** — 値を読まない音の解析は走らず、
/// 読んでも結果は毎フレーム解析したのと同じである。読まれなかったフレームの区間は解かず、次のフレームの
/// 値に混ぜない。
/// オシレータとノイズなら音量と包絡を掛けた後 (定位を掛ける前)、エフェクトなら処理した後の
/// 音である。鳴っていない間は無音 (``level`` が 0) になる。
///
/// 値の意味は ``AudioIn`` と同じで、``rms``・``decibels``・``level``・``peak`` は区間全体、
/// ``spectrum`` は区間に終わりが入る 512 標本ごとの窓の平均である。窓を置く格子の原点 (標本 0) は、
/// その音の出口が最初に標本を出したところ。標本が進まなかったフレームは前の値のまま。長く止まった後は、
/// 区間の終わりから 6144 標本 (48 kHz で約 0.128 秒) までを解析する。
///
/// ## 書き出しでは、音を動画の音声トラックへ載せ、解析もできる
///
/// 窓に出して動かしている間は実際に鳴らし、区間は実際に鳴った標本から取る。**固定の時計で `.mov` へ書き出すと、
/// 合成した音 (エフェクトを通した音を含む) は動画の音声トラックに載る** (``SoundFile`` と同じ。録りを頼んだ
/// フレームの `draw()` が頼んだ操作は、そのフレームの窓の先頭から効く)。録っていない書き出しと、窓を開かずに回す
/// 検査 (時刻がフレームの数え方から決まるとき — ``SketchPart/clock``) では**鳴らさず**、標本を「絶対のフレーム
/// 番号 × 標本化率 ÷ fps」の位置まで進めて区間を取る。何を作ってどう操作したかが同じなら、何度書き出しても同じ値になる ([ADR-0028] 決定 7・
/// [ADR-0025] の水準 2)。
///
/// 音を進めるのは音の時計で、``SketchPart/time`` ではない。``SketchPart/pauseTime()`` と
/// ``SketchPart/jumpTime(_:)`` は音を止めない・飛ばさない (``SoundFile`` と同じ)。
///
/// 1 つのスケッチで同時に生きていられる合成した音は、オシレータ・ノイズ・エフェクトを合わせて 64 個
/// まで (エフェクトへ通した ``SoundFile`` もこの数に入る — 下の段落)。**手放して (変数や配列から外して) 鳴り終えたオシレータとノイズは、数から外れる** — 鳴り終えたとは、
/// ``SynthSource/stop()`` で止めて消えたか、``Env`` の形が終わって無音になったこと。手放しても鳴っている音は
/// 切らず、鳴り終えてから数から外れる。鳴らしたまま (包絡なしの ``SynthSource/play()`` で) 手放した音は鳴り
/// 続け、数から外れない。**エフェクトはスケッチの終わりまで残る**。`setup()` で作って使い回す書き方は、
/// 今も勧める形で、当たるたびに短い音を作って捨てる書き方も、包絡で鳴り終えさせれば 64 個を使い切らない。
///
/// **エフェクトへ通した ``SoundFile`` も 1 つずつ数える** (同じ 64 個の内)。通したファイルは、スケッチから
/// 外す (`detach(_:)`) か、スケッチが終わるまで数に残る。外すと、鳴っている音は 5 ミリ秒ほどで消え、
/// 消えきってから数から外れる。
///
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public class SynthSound: EffectInput {
    let stage: SynthStage
    let node: RackNode?
    /// 知らせに載せる型の名前。
    let name: String
    /// 鳴らし始めた (エフェクトなら入力を繋いだ) か。解析はここから始める。
    var isActive = false

    /// フレームの頭の区間と、読まれたときに解いた値 (``DeferredLevels``)。
    private var deferred = DeferredLevels()
    private var levels: AudioLevels { deferred.levels() }
    /// 解析した回数。**検査が読む** — 読まれない値は解析しない。
    var analyses: Int { deferred.analyses }
    /// 前のフレームの区間の終わり (出口の標本の通し番号)。
    private var covered = 0
    private var noticed: Set<String> = []

    init(stage: SynthStage, node: RackNode?, name: String) {
        self.stage = stage
        self.node = node
        self.name = name
        // 鳴らし始める前の出口は無音 (ラックが 0 を書いている)。最初の区間の始まりが出口の標本 0 でなくても、
        // 最初の立ち上がりを拍にする
        deferred.beginsSilent = true
        if node == nil { stage.noticeCapacity() }
        stage.register(self)
    }

    // MARK: - 生の値

    /// 区間の二乗平均の平方根 (振幅の単位)。無音で 0、全振幅の正弦波で約 0.707。
    public var rms: Float { levels.rms }
    /// ``rms`` を dBFS にしたもの。0 が最大で、無音は -160 (∞ にはしない)。
    public var decibels: Float { levels.decibels }
    /// 区間の標本の絶対値の最大 (振幅の単位)。無音で 0、全振幅の音で 1。写し方は ``AudioIn/peak`` と同じ。
    ///
    /// **各フレームの値は、そのフレームの区間のものである。** 値は読まれたときに解くので、`draw()` が読まなかった
    /// フレームの区間は解かれず、次のフレームの値にも混ざらない。取りこぼしたくない値は、毎フレーム読む。
    public var peak: Float { levels.peak }
    /// 帯域ごとの大きさ (振幅の単位)。512 本で、帯域の真ん中にある全振幅の正弦波で 1。区間に終わりが入る
    /// 窓の平均。
    public var spectrum: [Float] { levels.spectrum }

    // MARK: - 0〜1 へ写した値

    /// 音の大きさを 0〜1 にしたもの。-60 dBFS 以下で 0、0 dBFS で 1。写し方は ``AudioIn/level`` と同じ。
    public var level: Float { levels.level }
    /// ``spectrum`` を帯域ごとに 0〜1 にしたもの。写し方は ``level`` と同じ。
    public var spectrumLevels: [Float] { levels.spectrumLevels }

    // MARK: - 帯域・波形・拍

    /// 周波数の範囲 `low`〜`high` (Hz) の大きさを 0〜1 で返す。低音の脈動を、帯域の番号を割り出さずに取る。
    ///
    /// <!-- example: 文脈 var sound: SynthSound? -->
    /// ```swift
    /// if let sound { circle(width / 2, height / 2, 100 + sound.energy(from: 20, to: 140) * 300) }
    /// ```
    ///
    /// 区間の ``spectrum`` の、中心がその範囲に入る帯域 (帯域 `k` の真ん中は `k × sampleRate ÷ 1024` Hz) の振幅の
    /// 平均を、``level`` と同じ dB の固定範囲 (-60 dBFS が 0、0 dBFS が 1) で写した値で、履歴に依らない。別の
    /// 解析は走らせない。手本は p5.sound の `getEnergy`。
    ///
    /// - 範囲に中心が入る帯域が無ければ、範囲の中点にいちばん近い 1 帯域の値
    /// - 逆順 (`low` が `high` より大きい) は入れ替える。0 Hz〜標本化率の半分の外へはみ出す分は端へ寄せ、
    ///   範囲が全部外なら 0
    /// - 数でない値・無限の値は 0 を返し、そのことを 1 度だけ知らせる (投げない — [ADR-0020] 決定 5)
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func energy(from low: Float, to high: Float) -> Float {
        let result = AudioAnalysis.energy(of: levels.spectrum, from: low, to: high, sampleRate: sampleRate)
        if !result.isNumber {
            notice(
                "energy.notFinite",
                "energy() got a value that is not a number, or an infinite one, so it returns 0 for "
                    + "this \(name)")
        }
        return result.value
    }

    /// 区間の終わりの 1024 標本 (古い順)。波形を描くのに使う。
    ///
    /// <!-- example: 文脈 var sound: SynthSound? -->
    /// ```swift
    /// if let sound {
    ///     noFill()
    ///     stroke(255)
    ///     beginShape()
    ///     for (i, s) in sound.waveform.enumerated() { vertex(Float(i) / 1024 * width, height * 0.8 + s * 100) }
    ///     endShape()
    /// }
    /// ```
    ///
    /// 標本は解析と同じもの (チャンネルを平均したもの。音量は掛けた後)。標本 0 より前は 0。標本が進まな
    /// かったフレームは前のまま。何も鳴っていなければ 1024 個の 0。手本は p5.sound の `waveform()` と
    /// Processing Sound の `Waveform`。
    public var waveform: [Float] { deferred.waveform() }

    /// このフレームの区間に拍があったか。区間に拍が 1 つ以上あれば `true` (複数あっても 1 回に畳む)。
    ///
    /// <!-- example: 文脈 var sound: SynthSound?; var flash: Float = 0 -->
    /// ```swift
    /// if sound?.isBeat == true { flash = 1 }
    /// flash *= 0.9
    /// background(30 + flash * 200, 30, 40)
    /// ```
    ///
    /// 拍は、ブロックごとのエネルギーが直近の平均を急に上回ったところ。ブロックは音源の標本 0 から 512 標本ごと
    /// に区切った固定の列で、**判定は届いた単位ではなくこの列の順にだけ進む**。同じ標本列からは、fps や
    /// 届くチャンクの長さが違っても同じ標本位置で拍が出る (``AudioIn`` のマイクを除く — 到着が実時間で決まる
    /// ので、固定の時計の書き出しの水準 2 を名乗れるのはファイル・標本列・合成音)。手本は Minim の `BeatDetect`、
    /// p5.sound の `PeakDetect`、Processing Sound の `BeatDetector`。感度の口は持たない。
    ///
    /// **鳴らし始めたとき** (エフェクトなら入力を繋いだとき) から履歴を溜め、読まないフレームの区間も毎フレーム処理する。
    /// どのフレームから読み始めても拍の有無は変わらず、読む間隔を変えても拍の位置は同じ (費用は標本あたり二乗和 1 回で、
    /// 1 フレームに数 µs)。鳴らす前は無音なので、最初の立ち上がりも拍になる。止めても履歴は続き、鳴らし直せば
    /// 続きから判定する。標本を落としたとき (区間の上限を越えたとき) は、履歴を捨てて始め直し、落とした区間では
    /// 拍を出さない。区間の上限があるので、約 7.8 fps (48 kHz) より遅いフレームでは区間の頭が落ち続け、拍は fps に依る。
    public var isBeat: Bool { deferred.isBeat }

    /// 拍の状態が区間を処理した回数。検査が読む — 一度も読まれなければ 0。
    var beatSteps: Int { deferred.beatSteps }

    // MARK: - 出どころ

    /// 標本化率 (Hz)。帯域 `k` の真ん中は `k × sampleRate ÷ 1024` Hz。常に 48000。
    public var sampleRate: Float { Float(stage.rack.sampleRate) }

    // MARK: - ステージとの受け渡し

    /// フレームごとに、前のフレーム以後の標本を区間として切り出す。**解析は値が読まれたときまで遅らせる** ([#2379])。
    ///
    /// 区間はここ (フレームの頭) で決める。読まれたときに引き直すと、フレームの途中で進んだ標本を
    /// 拾って値が変わる。鳴らし始める前も、区間の終わりは追い続ける (鳴らし始めた最初のフレームの区間は、
    /// 前のフレームからの分だけ)。
    ///
    /// [#2379]: https://github.com/mokume-metal/mokume/issues/2379
    func refresh() {
        deferred.beginFrame()
        guard let node else {
            deferred.silence()
            return
        }
        guard isActive else {
            deferred.silence()
            covered = node.meter.total
            return
        }
        let snapshot = node.meter.snapshot(since: covered)
        covered = snapshot.span.to
        deferred.hold(snapshot.span)
    }

    /// スケッチが終わった。以後の値は無音。
    func silence() {
        deferred.forget()
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

    /// 予約の秒 `seconds` (音の時計) を標本の位置にする。数でない値・無限の値は `nil` — その呼び出し全体を
    /// 無視し、1 度だけ知らせる (投げない — [ADR-0020] 決定 5)。今より前の値は知らせない (すぐ鳴らす)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    func reservationPosition(_ seconds: Double, call: String) -> Int? {
        if let position = stage.samplePosition(ofSeconds: seconds) { return position }
        notice(
            "\(call).at.notFinite",
            "\(call)() got an at: that is not a number, or an infinite one, so the call is "
                + "ignored for this \(name)")
        return nil
    }

    /// 値の変更と操作を、位置 `position` の 1 つの予約にして渡す。ステージが閉じていれば捨てる。
    /// 位置が今以前 (0 を含む) なら、次に作る標本の頭で全部が順に効く。
    func postReservation(
        values: [(param: SynthParam, value: Float)], ops: [SynthCommand.Op], at position: Int
    ) {
        guard let node, !stage.isClosed else { return }
        var commands: [SynthCommand] = values.map {
            SynthCommand(
                op: .set, node: UInt8(node.id), param: $0.param, bits: UInt64($0.value.bitPattern),
                at: position)
        }
        commands += ops.map { SynthCommand(op: $0, node: UInt8(node.id), at: position) }
        stage.rack.postReservation(commands)
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
    /// 鳴っているか。``play()``・``play(at:)`` で `true` になり、``stop()`` で `false` になる。
    ///
    /// ``Env`` の形が終わって音が 0 になっても `true` のまま (止めるのは ``stop()``)。
    public internal(set) var isPlaying = false

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
    /// 鳴っている最中に呼んでも何も変わらない。止めた後に呼ぶと、位相を頭へ戻して鳴らし直す。先の時刻に
    /// 鳴らすなら ``play(at:)``。
    public func play() {
        play(at: 0)
    }

    /// 音の時計の秒 `time` の標本の頭から鳴らし始める (先の時刻へ予約する)。今の周波数・音量・足す値・定位のまま。
    ///
    /// <!-- example: 文脈 var osc: SinOsc? -->
    /// ```swift
    /// func mousePressed() {
    ///     // 0.5 秒後の標本の頭から鳴らす
    ///     osc?.play(at: soundTime + 0.5)
    /// }
    /// ```
    ///
    /// `time` は**音の時計の秒** (``Sketch/soundTime`` と同じ時計) で、``SketchPart/time`` の秒ではない。
    /// ``SketchPart/pauseTime()``・``SketchPart/jumpTime(_:)`` は予約に効かない (音を進めるのは音の時計で、止めない・
    /// 飛ばさない)。今の音の時計より前の値 (負を含む) なら、次に作る標本の頭で鳴らし、知らせない。
    ///
    /// - 書き出しでは、フレームの途中でも標本の位置で効き、同じ操作から同じ標本が出る。実機でも、音の側の区切りの
    ///   途中で効く。手本は Tone.js の `triggerAttack(…, time)` と Web Audio の `OscillatorNode.start(when)`
    /// - ``isPlaying`` は**呼んだ時点で** `true` になる
    /// - **``stop()`` は、その音の先の予約も取り消す** (予約中の音に ``stop()`` を呼ぶと、予約した時刻に着いても
    ///   鳴らない)。``stop()`` に時刻は渡せない。予約を取り消された音は、鳴り終えたものと同じに置き場を返す
    /// - 数でない値・無限の値は、呼び出し全体を無視して 1 度だけ知らせる (投げない — [ADR-0020] 決定 5)
    /// - 先の予約は数に上限がある (``Env/play(_:_:_:_:_:at:)``)
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func play(at time: Double) {
        guard let position = reservationPosition(time, call: "play") else { return }
        postReservation(values: [], ops: [.play], at: position)
        isActive = true
        isPlaying = true
    }

    /// 止める。約 5 ミリ秒かけて消える。
    ///
    /// 鳴っていなければ何もしない。もう一度 ``play()`` で鳴らせる。**先の時刻へ予約していた鳴らす操作・包絡
    /// (``play(at:)``・``Env/play(_:_:_:_:_:at:)``) も、全部取り消す。** 時刻は渡せない。
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

    /// 音量・足す値・定位のうち、受けられた値 (範囲へ丸めた後)。受けられなかったものは入れない。
    func mixValues(_ amp: Float, _ add: Float, _ pan: Float) -> [(param: SynthParam, value: Float)] {
        var values: [(param: SynthParam, value: Float)] = []
        if let value = accept(amp, 0...1, call: "amp", meaning: "a volume") {
            values.append((.amplitude, value))
        }
        if let value = accept(add, -1...1, call: "add", meaning: "an offset") {
            values.append((.offset, value))
        }
        if let value = accept(pan, -1...1, call: "pan", meaning: "a position") {
            values.append((.panning, value))
        }
        return values
    }

    /// ``Env`` が、この音の包絡を頭から始める。鳴っていなければ鳴らし始める。
    func triggerEnvelope(
        attack: Float, sustain: Float, level: Float, release: Float, at time: Double
    ) {
        guard
            let position = reservationPosition(time, call: "Env.play"),
            let attackTime = acceptTime(attack, call: "Env.play", meaning: "attackTime"),
            let sustainTime = acceptTime(sustain, call: "Env.play", meaning: "sustainTime"),
            let releaseTime = acceptTime(release, call: "Env.play", meaning: "releaseTime"),
            let sustainLevel = accept(
                level, 0...1, call: "Env.play", meaning: "a sustainLevel")
        else { return }
        // 値・包絡・鳴らす操作を 1 つの予約として渡す。時刻が先なら、前の予約の値を書き換えないよう全部がその時刻に効く
        postReservation(
            values: [
                (.attack, attackTime), (.sustain, sustainTime), (.level, sustainLevel),
                (.release, releaseTime),
            ],
            ops: [.trigger, .play], at: position)
        isActive = true
        isPlaying = true
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
    /// ``SynthSource/pan(_:)`` と同じに扱う。先の時刻に鳴らすなら ``play(_:_:_:_:at:)``。
    public func play(_ freq: Float, _ amp: Float, _ add: Float = 0, _ pan: Float = 0) {
        play(freq, amp, add, pan, at: 0)
    }

    /// 周波数・音量・足す値・定位を決めて、音の時計の秒 `time` の標本の頭から鳴らし始める (先の時刻へ予約する)。
    ///
    /// <!-- example: 文脈 var osc: SinOsc? -->
    /// ```swift
    /// func mousePressed() {
    ///     // 0.25 秒後の標本の頭から、880 Hz で鳴らす
    ///     osc?.play(880, 0.5, at: soundTime + 0.25)
    /// }
    /// ```
    ///
    /// **値も、鳴らすのと同じ標本の頭から効く** (今すぐ値を変えるのではない)。`time` の意味・今より前の値・
    /// ``SynthSource/stop()`` が予約を取り消すことは ``SynthSource/play(at:)`` と同じ。範囲の外・数でない値は、
    /// それぞれ ``freq(_:)``・``SynthSource/amp(_:)``・``SynthSource/add(_:)``・``SynthSource/pan(_:)`` と同じに扱う。
    ///
    /// **包絡 (``Env``) と並べて、高さを変えながら刻める**: ``Env/play(_:_:_:_:_:at:)`` と同じ `time` で呼ぶと、高さも
    /// 形も同じ標本の頭から変わる (作例は ``Env/play(_:_:_:_:_:at:)`` の「高さを変えながら刻む」)。`add`・`pan` も
    /// 毎回渡し直す (省くと 0 に戻る)。``freq(_:)`` を今すぐ呼ぶのでは、鳴っている音の高さも変わってしまう。
    public func play(
        _ freq: Float, _ amp: Float, _ add: Float = 0, _ pan: Float = 0, at time: Double
    ) {
        guard let position = reservationPosition(time, call: "play") else { return }
        postReservation(values: voiceValues(freq, amp, add, pan), ops: [.play], at: position)
        isActive = true
        isPlaying = true
    }

    /// 周波数・音量・足す値・定位のうち、受けられた値 (範囲へ丸めた後)。受けられなかったものは入れない。
    private func voiceValues(
        _ freq: Float, _ amp: Float, _ add: Float, _ pan: Float
    ) -> [(param: SynthParam, value: Float)] {
        let limit = Float(stage.rack.sampleRate / 2)
        var values: [(param: SynthParam, value: Float)] = []
        if let value = accept(freq, 0...limit, call: "freq", meaning: "a frequency") {
            values.append((.frequency, value))
        }
        values += mixValues(amp, add, pan)
        return values
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
    /// ``SynthSource/pan(_:)`` と同じに扱う。先の時刻に鳴らすなら ``play(_:_:_:at:)``。
    public func play(_ amp: Float, _ add: Float = 0, _ pan: Float = 0) {
        play(amp, add, pan, at: 0)
    }

    /// 音量・足す値・定位を決めて、音の時計の秒 `time` の標本の頭から鳴らし始める (先の時刻へ予約する)。
    ///
    /// <!-- example: 文脈 var noise: WhiteNoise? -->
    /// ```swift
    /// func mousePressed() {
    ///     noise?.play(0.2, at: soundTime + 0.25)
    /// }
    /// ```
    ///
    /// **値も、鳴らすのと同じ標本の頭から効く。** `time` の意味・今より前の値・``SynthSource/stop()`` が予約を
    /// 取り消すことは ``SynthSource/play(at:)`` と同じ。範囲の外・数でない値は、それぞれ ``SynthSource/amp(_:)``・
    /// ``SynthSource/add(_:)``・``SynthSource/pan(_:)`` と同じに扱う。
    public func play(_ amp: Float, _ add: Float = 0, _ pan: Float = 0, at time: Double) {
        guard let position = reservationPosition(time, call: "play") else { return }
        postReservation(values: mixValues(amp, add, pan), ops: [.play], at: position)
        isActive = true
        isPlaying = true
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
    /// すぐ始める。先の時刻に始めるなら ``play(_:_:_:_:_:at:)``。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func play(
        _ input: SynthSource, _ attackTime: Float, _ sustainTime: Float, _ sustainLevel: Float,
        _ releaseTime: Float
    ) {
        play(input, attackTime, sustainTime, sustainLevel, releaseTime, at: 0)
    }

    /// 形を `input` にかけ、音の時計の秒 `time` の標本の頭から始める (先の時刻へ予約する)。`input` が鳴っていなければ
    /// 鳴らし始める。
    ///
    /// 形・引数・丸め方は ``play(_:_:_:_:_:)`` と同じ。
    ///
    /// - Parameters:
    ///   - input: 形をかける音源。
    ///   - attackTime: 立ち上がる秒数。
    ///   - sustainTime: 保つ秒数。
    ///   - sustainLevel: 保つ高さ (0〜1)。
    ///   - releaseTime: 下がる秒数。
    ///   - at: 始める時刻 (音の時計の秒。``Sketch/soundTime`` と同じ時計)。今より前 (負を含む) なら、次に作る
    ///     標本の頭で始める。
    ///
    /// 数でない値・無限の値 (`time` を含む) があれば呼び出し全体を無視して 1 度だけ知らせる (投げない —
    /// [ADR-0020] 決定 5)。
    ///
    /// ## 先の時刻へ予約する
    ///
    /// `at:` を渡すと、`draw()` が呼ばれたフレームの区切りではなく、**その標本の頭**から形が始まる。60 fps で
    /// 約 17 ミリ秒の粒に拍が揃わなくなり、120 BPM の 16 分音符 (125 ミリ秒) も等間隔に鳴る。**`at:` の秒は音の時計で、
    /// ``SketchPart/time`` ではない** — 音を進めるのは音の時計で、``SketchPart/pauseTime()``・``SketchPart/jumpTime(_:)``
    /// は予約に効かない (音を止めない・飛ばさない)。今の音の時計は ``Sketch/soundTime`` で読む。手本は Tone.js の
    /// `triggerAttackRelease(…, time)` と、Web Audio の `OscillatorNode.start(when)`。
    ///
    /// ```swift
    /// final class Sequencer: Sketch {
    ///     var osc: TriOsc?
    ///     var env: Env?
    ///     var lastStep = -1
    ///     let pattern = [true, false, true, false, true, false, true, true,
    ///                    true, false, true, false, true, false, false, true]
    ///     func setup() {
    ///         osc = createTriOsc()
    ///         env = createEnv()
    ///     }
    ///     func draw() {
    ///         background(20)
    ///         let now = soundTime                          // 音の時計の秒
    ///         let step = Int(now / 0.125) % 16
    ///         if step != lastStep {
    ///             lastStep = step
    ///             let next = (step + 1) % 16
    ///             if pattern[next], let osc, let env {
    ///                 // 次の 16 分の頭へ予約する。1 フレーム先より遠いので、実時間でも間に合う
    ///                 env.play(osc, 0.002, 0.03, 0.7, 0.1, at: Double(Int(now / 0.125) + 1) * 0.125)
    ///             }
    ///         }
    ///         for i in 0..<16 {
    ///             if i == step { fill(255, 180, 60) } else { fill(pattern[i] ? 120 : 50) }
    ///             rect(40 + Float(i) * 55, height / 2 - 25, 50, 50)
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// ## 高さを変えながら刻む
    ///
    /// 旋律のように音ごとに高さを変えるなら、**高さも同じ時刻に予約する**。`Env.play` が運ぶのは形 (秒数と持続の
    /// 音量) で、音の高さは運ばない。``Oscillator/play(_:_:_:_:at:)`` を、同じ `at:` に並べる。高さも形も、
    /// その標本の頭から変わる (どちらを先に呼んでも同じ標本になる)。
    ///
    /// ```swift
    /// final class Melody: Sketch {
    ///     var osc: TriOsc?
    ///     var env: Env?
    ///     var lastStep = -1
    ///     let notes: [Float] = [440, 494, 523, 587, 659, 587, 523, 494]   // 16 分音符ごとの高さ (Hz)
    ///     func setup() {
    ///         osc = createTriOsc()
    ///         env = createEnv()
    ///     }
    ///     func draw() {
    ///         background(20)
    ///         let step = Int(soundTime / 0.125)
    ///         if step != lastStep, let osc, let env {
    ///             lastStep = step
    ///             // 次の 16 分の頭へ、高さと形を同じ時刻に予約する (1 フレーム先より遠い)
    ///             let next = Double(step + 1) * 0.125
    ///             osc.play(notes[(step + 1) % notes.count], 0.5, at: next)   // 高さと音量。add・pan は 0 に戻る
    ///             env.play(osc, 0.01, 0.05, 0.5, 0.1, at: next)              // 形
    ///         }
    ///         for i in 0..<notes.count {
    ///             let high = (notes[i] - 400) / 4
    ///             if i == step % notes.count { fill(255, 180, 60) } else { fill(120) }
    ///             rect(60 + Float(i) * 85, height - 60 - high, 70, high)
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// - **``Oscillator/freq(_:)``・``SynthSource/amp(_:)``・``SynthSource/pan(_:)`` と ``Oscillator/set(_:_:_:_:)`` は
    ///   今すぐ効く**。鳴っている音 (予約済みの前の音の尾を含む) の高さ・音量・定位も変わる。次の拍の高さを
    ///   `freq(_:)` で今すぐ変えると、前の音の尾が次の高さで鳴り、1 拍先へ予約する書き方では、いま鳴り始めた音が
    ///   まるごと次の高さになる。値を予約できるのは ``Oscillator/play(_:_:_:_:at:)`` で、鳴らし直さずに値だけを
    ///   標本の精度で変える口 (`freq(_:at:)` など) は無い
    /// - 並べた形では、`add`・`pan` も毎回渡し直す。**省くと 0 に戻る** (`Oscillator.play` は 4 つの値をすべて
    ///   決める)
    /// - 1 音ごとに `osc.play` と `env.play` の 2 回を呼ぶ。置き場を 1 音で 11 個使う (下の「先の予約を溜める置き場」)
    ///
    /// - 値 (秒数・持続の音量) も、形も、鳴らす操作も、予約した時刻に**まとめて**効く。続けて予約しても、前の予約の
    ///   値を書き換えない
    /// - 実機では、音の側の区切りの途中で効く。予約が先の時刻なら、その標本の頭ちょうどから形が始まる。
    ///   書き出しでは、同じ操作から同じ標本が出る ([ADR-0025] の水準 2)
    /// - **先の予約を溜める置き場は、スケッチごとに 2048 個の操作まで**。この呼び出し 1 回は 6 個 (値 4・形・
    ///   鳴らす) を使い、時刻に着いて効いたぶんが空く。およそ 340 回ぶん先まで予約でき、足りなければその予約を
    ///   捨てて 1 度だけ知らせる (投げない)。**高さも並べた形は、``Oscillator/play(_:_:_:_:at:)`` の 5 個 (値 4・
    ///   鳴らす) を足した 1 音 11 個で、およそ 186 音ぶん**。曲全体を先に積まず、次の数音だけ予約する
    /// - **今の音の時計より前の `at:` は、次に作る標本の頭で始める** (知らせない)。実機で、`draw()` が間に合わず
    ///   予約が少し遅れたときも、この形で鳴る
    /// - 予約した音は、手放しても時刻に着いて鳴り終えるまで残る。**``SynthSource/stop()`` を呼ぶと、その音の先の
    ///   予約は全部取り消される** (時刻に着いても鳴らず、置き場も返る)
    /// - 音の時計は、最初の合成音を作ったときが 0 秒で、``SketchPart/time``・``SoundFile/position``・`.mov` の
    ///   音声トラックの時刻とは起点が違う (``Sketch/soundTime``)
    ///
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func play(
        _ input: SynthSource, _ attackTime: Float, _ sustainTime: Float, _ sustainLevel: Float,
        _ releaseTime: Float, at time: Double
    ) {
        input.triggerEnvelope(
            attack: attackTime, sustain: sustainTime, level: sustainLevel, release: releaseTime,
            at: time)
    }
}
