// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics

/// 合成音 (オシレータ・ノイズ・エフェクト) に共通の、再生中の音の解析値。
///
/// ``Sketch/createSinOsc()`` などの関数が作る型はどれもこれを継承し、値の名前と変換の仕方は
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
///         // 低い音だけが残った、フィルタの出力のスペクトルで棒を伸ばす
///         for band in 1...64 {
///             let length = filter.spectrumLevels[band] * 300
///             rect(Float(band) * 10, height - length, 8, length)
///         }
///     }
/// }
/// ```
///
/// ## 解析するのは、その音の出力
///
/// 各フレームでは、**前のフレームからその音の出力に出た全サンプル**(区間)を ``AudioIn`` と同じ解析に通す。
/// 区間を区切るのはフレームの開始時点で、**解析は値が読まれるときまで遅延する** — 値を読まない音の解析は実行されず、
/// 読んでも結果は毎フレーム解析したのと同じである。読まれなかったフレームの区間は解析せず、次のフレームの
/// 値に混ぜない。
/// オシレータとノイズなら音量とエンベロープを掛けた後 (定位を掛ける前)、エフェクトなら処理した後の
/// 音である。再生していない間は無音 (``level`` が 0) になる。
///
/// 値の意味は ``AudioIn`` と同じで、``rms``・``decibels``・``level``・``peak`` は区間全体、
/// ``spectrum`` は区間に終わりが入る、512 サンプルごとに置いたウィンドウの平均である。ウィンドウを置く格子の原点 (サンプル 0) は、
/// その音の出力が最初にサンプルを出したところ。サンプルが進まなかったフレームは前の値のまま。長く止まった後は、
/// 区間の終わりから 6144 サンプル (48 kHz で約 0.128 秒) までを解析する。
///
/// ## 書き出しでは、音を動画の音声トラックへ入れ、解析もできる
///
/// ウィンドウを表示して実行している間は実際に音を出し、区間は実際に出力したサンプルから取る。**固定クロックで `.mov` へ書き出すと、
/// 合成音 (エフェクトを通した音を含む) は動画の音声トラックに入る** (``SoundFile`` と同じ。録画を要求した
/// フレームの `draw()` が要求した操作は、そのフレームの区間の先頭から反映される)。録音しない書き出しと、ウィンドウを開かずに実行する
/// テスト (時刻がフレーム数から決まるとき — ``SketchPart/clock``) では**音を出さず**、サンプルを「絶対のフレーム
/// 番号 × サンプルレート ÷ fps」の位置まで進めて区間を取る。何を作ってどう操作したかが同じなら、何度書き出しても同じ値になる ([ADR-0028] 決定 7・
/// [ADR-0025] の水準 2)。
///
/// 音を進めるのはオーディオクロックで、``SketchPart/time`` ではない。``SketchPart/pauseTime()`` と
/// ``SketchPart/jumpTime(_:)`` は音を止めず、シークもしない (``SoundFile`` と同じ)。
///
/// 1 つのスケッチで同時に存在できる合成音は、オシレータ・ノイズ・エフェクトを合わせて 64 個
/// まで (エフェクトへ通した ``SoundFile`` もこの数に入る — 下の段落)。**参照を手放して (変数や配列から外して) 再生が終わったオシレータとノイズは、数から外れる** — 再生が終わったとは、
/// ``SynthSource/stop()`` で停止して音が消えたか、``Env`` のエンベロープが終わって無音になったこと。参照を手放しても再生中の音は
/// 切らず、再生が終わってから数から外れる。再生したまま (エンベロープなしの ``SynthSource/play()`` で) 手放した音は再生され
/// 続け、数から外れない。**エフェクトはスケッチの終了まで残る**。`setup()` で作って使い回す書き方は、
/// 今も推奨する書き方で、イベントのたびに短い音を作って捨てる書き方も、エンベロープで再生を終わらせれば 64 個を使い切らない。
///
/// **エフェクトへ通した ``SoundFile`` も 1 つずつ数える** (同じ 64 個の内)。通したファイルは、スケッチから
/// 外す (`detach(_:)`) か、スケッチが終了するまで数に残る。外すと、再生中の音は 5 ミリ秒ほどでフェードアウトし、
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

    /// 区間の二乗平均平方根 (振幅の単位)。無音で 0、フルスケールの正弦波で約 0.707。
    public var rms: Double { Double(levels.rms) }
    /// ``rms`` を dBFS にしたもの。0 が最大で、無音は -160 (∞ にはしない)。
    public var decibels: Double { Double(levels.decibels) }
    /// 区間のサンプルの絶対値の最大 (振幅の単位)。無音で 0、フルスケールの音で 1。求め方は ``AudioIn/peak`` と同じ。
    ///
    /// **各フレームの値は、そのフレームの区間のものである。** 値は読まれたときに解析するので、`draw()` が読まなかった
    /// フレームの区間は解析されず、次のフレームの値にも混ざらない。取りこぼしたくない値は、毎フレーム読む。
    public var peak: Double { Double(levels.peak) }
    /// 帯域ごとの大きさ (振幅の単位)。512 本で、帯域の中心にあるフルスケールの正弦波で 1。区間に終わりが入る
    /// ウィンドウの平均。
    public var spectrum: [Float] { levels.spectrum }

    // MARK: - 0〜1 へ写した値

    /// 音の大きさを 0〜1 にしたもの。-60 dBFS 以下で 0、0 dBFS で 1。変換の仕方は ``AudioIn/level`` と同じ。
    public var level: Double { Double(levels.level) }
    /// ``spectrum`` を帯域ごとに 0〜1 にしたもの。変換の仕方は ``level`` と同じ。
    public var spectrumLevels: [Float] { levels.spectrumLevels }

    // MARK: - 帯域・波形・拍

    /// 周波数の範囲 `low`〜`high` (Hz) の大きさを 0〜1 で返す。低音の脈動を、帯域の番号を計算せずに取得できる。
    ///
    /// <!-- example: 文脈 var sound: SynthSound? -->
    /// ```swift
    /// if let sound { circle(width / 2, height / 2, 100 + sound.energy(from: 20, to: 140) * 300) }
    /// ```
    ///
    /// 区間の ``spectrum`` のうち、中心がその範囲に入る帯域 (帯域 `k` の中心は `k × sampleRate ÷ 1024` Hz) の振幅の
    /// 平均を、``level`` と同じ dB の固定範囲 (-60 dBFS が 0、0 dBFS が 1) で変換した値で、履歴に依らない。別の
    /// 解析は実行しない。p5.sound の `getEnergy` に当たる。
    ///
    /// - 範囲に中心が入る帯域が無ければ、範囲の中点に最も近い 1 帯域の値
    /// - 逆順 (`low` が `high` より大きい) は入れ替える。0 Hz〜サンプルレートの半分からはみ出す分は端にクランプし、
    ///   範囲がすべて外なら 0
    /// - NaN・無限大は 0 を返し、そのことを 1 度だけ警告する (投げない — [ADR-0020] 決定 5)
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func energy(from low: Double, to high: Double) -> Double {
        Double(energyValue(from: Float(low), to: Float(high)))
    }

    func energyValue(from low: Float, to high: Float) -> Float {
        let result = AudioAnalysis.energy(of: levels.spectrum, from: low, to: high, sampleRate: Float(sampleRate))
        if !result.isNumber {
            notice(
                "energy.notFinite",
                "energy() got a value that is not a number, or an infinite one, so it returns 0 for "
                    + "this \(name)")
        }
        return result.value
    }

    /// 区間の終わりの 1024 サンプル (古い順)。波形を描くのに使う。
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
    /// サンプルは解析と同じもの (チャンネルを平均したもの。音量を掛けた後)。サンプル 0 より前は 0。サンプルが進まな
    /// かったフレームは前のまま。何も再生されていなければ 1024 個の 0。p5.sound の `waveform()` と
    /// Processing Sound の `Waveform` に当たる。
    public var waveform: [Float] { deferred.waveform() }

    /// このフレームの区間にビートがあったか。区間にビートが 1 つ以上あれば `true` (複数あっても 1 回にまとめる)。
    ///
    /// <!-- example: 文脈 var sound: SynthSound?; var flash: Float = 0 -->
    /// ```swift
    /// if sound?.isBeat == true { flash = 1 }
    /// flash *= 0.9
    /// background(30 + flash * 200, 30, 40)
    /// ```
    ///
    /// ビートは、ブロックごとのエネルギーが直近の平均を急に上回ったところ。ブロックは音源のサンプル 0 から 512 サンプルごと
    /// に区切った固定の並びで、**判定は届いた単位ではなくこの並びの順にだけ進む**。同じサンプル列からは、fps や
    /// 届くチャンクの長さが違っても同じサンプル位置でビートが出る (``AudioIn`` のマイクを除く — 到着が実時間で決まる
    /// ので、固定クロックの書き出しで水準 2 を満たせるのはファイル・サンプル列・合成音)。Minim の `BeatDetect`、
    /// p5.sound の `PeakDetect`、Processing Sound の `BeatDetector` に当たる。感度を設定する API は持たない。
    ///
    /// **再生を始めたとき** (エフェクトなら入力を接続したとき) から履歴を蓄積し、読まないフレームの区間も毎フレーム処理する。
    /// どのフレームから読み始めてもビートの有無は変わらず、読む間隔を変えてもビートの位置は同じ (コストはサンプルあたり二乗和 1 回で、
    /// 1 フレームに数 µs)。再生前は無音なので、最初のアタックもビートになる。停止しても履歴は続き、再生し直せば
    /// 続きから判定する。サンプルを取りこぼしたとき (区間の上限を越えたとき) は、履歴を捨ててやり直し、取りこぼした区間では
    /// ビートを出さない。区間の上限があるので、約 7.8 fps (48 kHz) より遅いフレームでは区間の先頭が切り捨てられ続け、ビートは fps に依存する。
    public var isBeat: Bool { deferred.isBeat }

    /// 拍の状態が区間を処理した回数。検査が読む — 一度も読まれなければ 0。
    var beatSteps: Int { deferred.beatSteps }

    // MARK: - 出どころ

    /// サンプルレート (Hz)。帯域 `k` の中心は `k × sampleRate ÷ 1024` Hz。常に 48000。
    public var sampleRate: Double { Double(Float(stage.rack.sampleRate)) }

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

/// 合成音の音源 (オシレータとノイズ) に共通の操作。
///
/// 作っただけでは音が出ない。``play()`` で再生し、``stop()`` で停止する。音量・オフセット・定位は、
/// 再生前にも再生中にも変えられ、急に変えてもクリックノイズが出ないよう
/// 約 5 ミリ秒かけて追従する。どのメソッドも投げない ([ADR-0020] 決定 5)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public class SynthSource: SynthSound {
    /// 再生中か。``play()``・``play(at:)`` で `true` になり、``stop()`` で `false` になる。
    ///
    /// ``Env`` のエンベロープが終わって音が 0 になっても `true` のまま (停止するのは ``stop()``)。
    public internal(set) var isPlaying = false

    /// 再生を始める。現在の周波数・音量・オフセット・定位のまま。
    ///
    /// <!-- example: 文脈 var osc: SinOsc? -->
    /// ```swift
    /// func mousePressed() {
    ///     guard let osc else { return }
    ///     if osc.isPlaying { osc.stop() } else { osc.play() }
    /// }
    /// ```
    ///
    /// 再生中に呼んでも何も変わらない。停止した後に呼ぶと、位相を 0 に戻して再生し直す。先の時刻に
    /// 再生するなら ``play(at:)``。
    public func play() {
        play(at: 0)
    }

    /// オーディオクロックの `time` 秒のサンプルの先頭から再生を始める (先の時刻へ予約する)。現在の周波数・音量・オフセット・定位のまま。
    ///
    /// <!-- example: 文脈 var osc: SinOsc? -->
    /// ```swift
    /// func mousePressed() {
    ///     // 0.5 秒後のサンプルの先頭から再生する
    ///     osc?.play(at: soundTime + 0.5)
    /// }
    /// ```
    ///
    /// `time` は**オーディオクロックの秒** (``Sketch/soundTime`` と同じクロック) で、``SketchPart/time`` の秒ではない。
    /// ``SketchPart/pauseTime()``・``SketchPart/jumpTime(_:)`` は予約に影響しない (音を進めるのはオーディオクロックで、止まらず
    /// シークもしない)。現在のオーディオクロックより前の値 (負を含む) なら、次に生成するサンプルの先頭で再生を始め、警告しない。
    ///
    /// - 書き出しでは、フレームの途中でもサンプル単位の位置で反映され、同じ操作から同じサンプルが出る。実機でも、オーディオスレッドの処理単位の
    ///   途中で反映される。Tone.js の `triggerAttack(…, time)` と Web Audio の `OscillatorNode.start(when)` に当たる
    /// - ``isPlaying`` は**呼んだ時点で** `true` になる
    /// - **``stop()`` は、その音の先の予約も取り消す** (予約中の音に ``stop()`` を呼ぶと、予約した時刻になっても
    ///   音が出ない)。``stop()`` に時刻は渡せない。予約を取り消された音は、再生が終わったものと同じく同時に存在できる数から外れる
    /// - NaN・無限大は、呼び出し全体を無視して 1 度だけ警告する (投げない — [ADR-0020] 決定 5)
    /// - 先の予約は数に上限がある (``Env/play(_:_:_:_:_:at:)``)
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func play(at time: Double) {
        guard let position = reservationPosition(time, call: "play") else { return }
        postReservation(values: [], ops: [.play], at: position)
        isActive = true
        isPlaying = true
    }

    /// 停止する。約 5 ミリ秒かけてフェードアウトする。
    ///
    /// 再生していなければ何もしない。もう一度 ``play()`` で再生できる。**先の時刻へ予約していた再生の操作・エンベロープ
    /// (``play(at:)``・``Env/play(_:_:_:_:_:at:)``) も、すべて取り消す。** 時刻は渡せない。
    public func stop() {
        post(.stop)
        isPlaying = false
    }

    /// 音量を設定する。0 で無音、1 で最大。既定は 0.5。
    ///
    /// <!-- example: 文脈 var osc: SinOsc? -->
    /// ```swift
    /// osc?.amp(map(mouseY, 0, height, 1, 0))
    /// ```
    ///
    /// 0〜1 の外は端にクランプし、NaN・無限大は無視する。どちらもそのことを 1 度だけ警告する
    /// (投げない — [ADR-0020] 決定 5)。解析値も、この音量を掛けた音のものになる。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func amp(_ volume: Double) {
        let volume = Float(volume)
        guard let value = accept(volume, 0...1, call: "amp", meaning: "a volume") else { return }
        send(.amplitude, value)
    }

    /// 音に加えるオフセットを設定する。-1〜1 で、既定は 0。
    ///
    /// 波形の全体を上下へずらす (直流成分を加える)。普通の音では 0 のままでよい。範囲の外・NaN は
    /// ``amp(_:)`` と同じに扱う。
    public func add(_ offset: Double) {
        let offset = Float(offset)
        guard let value = accept(offset, -1...1, call: "add", meaning: "an offset") else { return }
        send(.offset, value)
    }

    /// 左右の定位を設定する。-1 で左、0 で中央、1 で右。既定は 0。
    ///
    /// 左右を合わせた大きさが変わらないパンニング (等パワー) で、中央では左右とも 1/√2 になる。**エフェクトへ通した
    /// 音の定位は、エフェクトの出力で中央になる**。範囲の外・NaN は ``amp(_:)`` と同じに扱う。
    public func pan(_ position: Double) {
        let position = Float(position)
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

/// 周期的な波形を出し続ける音源。波形ごとに ``SinOsc``・``SqrOsc``・``TriOsc``・``SawOsc`` がある。
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
///         // 再生中の音を、入力・再生と同じ解析で見る
///         if let osc { circle(width / 2, height / 2, 40 + osc.level * 300) }
///     }
/// }
/// ```
///
/// 既定は周波数 440 Hz・音量 0.5・オフセット 0・定位 中央。位相は再生を始めるたびに 0 から始まる。
/// 矩形波とのこぎり波は、高い倍音がエイリアシングで濁らないよう角を丸めてある。
public class Oscillator: SynthSource {
    init(stage: SynthStage, waveform: Waveform, name: String) {
        super.init(
            stage: stage, node: stage.rack.addSource(.wave(waveform)), name: name)
    }

    /// 周波数・音量・オフセット・定位を指定して、再生を始める。
    ///
    /// <!-- example: 文脈 var osc: SinOsc? -->
    /// ```swift
    /// func setup() {
    ///     osc = createSinOsc()
    ///     osc?.play(440, 0.5)
    /// }
    /// ```
    ///
    /// 範囲の外・NaN は、それぞれ ``freq(_:)``・``SynthSource/amp(_:)``・``SynthSource/add(_:)``・
    /// ``SynthSource/pan(_:)`` と同じに扱う。先の時刻に再生するなら ``play(_:_:_:_:at:)``。
    public func play(_ freq: Double, _ amp: Double, _ add: Double = 0, _ pan: Double = 0) {
        let (freq, amp, add, pan) = (Float(freq), Float(amp), Float(add), Float(pan))
        play(Double(freq), Double(amp), Double(add), Double(pan), at: 0)
    }

    /// 周波数・音量・オフセット・定位を指定して、オーディオクロックの `time` 秒のサンプルの先頭から再生を始める (先の時刻へ予約する)。
    ///
    /// <!-- example: 文脈 var osc: SinOsc? -->
    /// ```swift
    /// func mousePressed() {
    ///     // 0.25 秒後のサンプルの先頭から、880 Hz で再生する
    ///     osc?.play(880, 0.5, at: soundTime + 0.25)
    /// }
    /// ```
    ///
    /// **値も、再生と同じサンプルの先頭から反映される** (すぐに値を変えるのではない)。`time` の意味・現在より前の値・
    /// ``SynthSource/stop()`` が予約を取り消すことは ``SynthSource/play(at:)`` と同じ。範囲の外・NaN は、
    /// それぞれ ``freq(_:)``・``SynthSource/amp(_:)``・``SynthSource/add(_:)``・``SynthSource/pan(_:)`` と同じに扱う。
    ///
    /// **エンベロープ (``Env``) と組み合わせて、音高を変えながら連続して鳴らせる**: ``Env/play(_:_:_:_:_:at:)`` と同じ `time` で呼ぶと、音高も
    /// エンベロープも同じサンプルの先頭から変わる (作例は ``Env/play(_:_:_:_:_:at:)`` の「音高を変えながら連続して鳴らす」)。`add`・`pan` も
    /// 毎回渡し直す (省略すると 0 に戻る)。``freq(_:)`` をすぐに呼ぶと、再生中の音の音高も変わってしまう。
    public func play(_ freq: Double, _ amp: Double, _ add: Double = 0, _ pan: Double = 0, at time: Double) {
        let (freq, amp, add, pan) = (Float(freq), Float(amp), Float(add), Float(pan))
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

    /// 周波数を設定する。単位は Hz で、0 からサンプルレートの半分 (24000) まで。既定は 440。
    ///
    /// 範囲の外は端にクランプし、NaN・無限大は無視する。どちらもそのことを 1 度だけ警告する
    /// (投げない — [ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func freq(_ frequency: Double) {
        let frequency = Float(frequency)
        let limit = Float(stage.rack.sampleRate / 2)
        guard let value = accept(frequency, 0...limit, call: "freq", meaning: "a frequency")
        else { return }
        send(.frequency, value)
    }

    /// 周波数・音量・オフセット・定位を、再生せずに設定する。
    ///
    /// 範囲の外・NaN は、それぞれ ``freq(_:)``・``SynthSource/amp(_:)``・``SynthSource/add(_:)``・
    /// ``SynthSource/pan(_:)`` と同じに扱う。
    public func set(_ freq: Double, _ amp: Double, _ add: Double = 0, _ pan: Double = 0) {
        let (freq, amp, add, pan) = (Float(freq), Float(amp), Float(add), Float(pan))
        self.freq(Double(freq))
        self.amp(Double(amp))
        self.add(Double(add))
        self.pan(Double(pan))
    }
}

/// 正弦波を出す。倍音の無い、丸い音。
///
/// Processing Sound の `SinOsc` に当たる。作る関数は ``Sketch/createSinOsc()``。使い方は ``Oscillator``。
public final class SinOsc: Oscillator {
    init(stage: SynthStage) {
        super.init(stage: stage, waveform: .sine, name: "SinOsc")
    }
}

/// 矩形波を出す。奇数次の倍音が強い、硬い音。
///
/// Processing Sound の `SqrOsc` に当たる。作る関数は ``Sketch/createSqrOsc()``。使い方は ``Oscillator``。
public final class SqrOsc: Oscillator {
    init(stage: SynthStage) {
        super.init(stage: stage, waveform: .square, name: "SqrOsc")
    }
}

/// 三角波を出す。奇数次の倍音が弱い、正弦波に近い音。
///
/// Processing Sound の `TriOsc` に当たる。作る関数は ``Sketch/createTriOsc()``。使い方は ``Oscillator``。
public final class TriOsc: Oscillator {
    init(stage: SynthStage) {
        super.init(stage: stage, waveform: .triangle, name: "TriOsc")
    }
}

/// のこぎり波を出す。すべての倍音を含む、明るい音。
///
/// Processing Sound の `SawOsc` に当たる。作る関数は ``Sketch/createSawOsc()``。使い方は ``Oscillator``。
public final class SawOsc: Oscillator {
    init(stage: SynthStage) {
        super.init(stage: stage, waveform: .saw, name: "SawOsc")
    }
}

// MARK: - ノイズ

/// 周期の無い音 (ノイズ) を出し続ける音源。色ごとに ``WhiteNoise``・``PinkNoise`` がある。
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
/// 既定は音量 0.5・オフセット 0・定位 中央。**ノイズの系列は決定的である** — 同じ順にノイズを作れば、
/// 何度再生しても書き出しても同じ音になる (シードを選ぶ API は持たない)。
public class Noise: SynthSource {
    init(stage: SynthStage, color: NoiseColor, name: String) {
        super.init(
            stage: stage, node: stage.rack.addSource(.noise(color)), name: name)
    }

    /// 音量・オフセット・定位を指定して、再生を始める。
    ///
    /// <!-- example: 文脈 var noise: WhiteNoise? -->
    /// ```swift
    /// func setup() {
    ///     noise = createWhiteNoise()
    ///     noise?.play(0.2)
    /// }
    /// ```
    ///
    /// 範囲の外・NaN は、それぞれ ``SynthSource/amp(_:)``・``SynthSource/add(_:)``・
    /// ``SynthSource/pan(_:)`` と同じに扱う。先の時刻に再生するなら ``play(_:_:_:at:)``。
    public func play(_ amp: Double, _ add: Double = 0, _ pan: Double = 0) {
        let (amp, add, pan) = (Float(amp), Float(add), Float(pan))
        play(Double(amp), Double(add), Double(pan), at: 0)
    }

    /// 音量・オフセット・定位を指定して、オーディオクロックの `time` 秒のサンプルの先頭から再生を始める (先の時刻へ予約する)。
    ///
    /// <!-- example: 文脈 var noise: WhiteNoise? -->
    /// ```swift
    /// func mousePressed() {
    ///     noise?.play(0.2, at: soundTime + 0.25)
    /// }
    /// ```
    ///
    /// **値も、再生と同じサンプルの先頭から反映される。** `time` の意味・現在より前の値・``SynthSource/stop()`` が予約を
    /// 取り消すことは ``SynthSource/play(at:)`` と同じ。範囲の外・NaN は、それぞれ ``SynthSource/amp(_:)``・
    /// ``SynthSource/add(_:)``・``SynthSource/pan(_:)`` と同じに扱う。
    public func play(_ amp: Double, _ add: Double = 0, _ pan: Double = 0, at time: Double) {
        let (amp, add, pan) = (Float(amp), Float(add), Float(pan))
        guard let position = reservationPosition(time, call: "play") else { return }
        postReservation(values: mixValues(amp, add, pan), ops: [.play], at: position)
        isActive = true
        isPlaying = true
    }

    /// 音量・オフセット・定位を、再生せずに設定する。
    ///
    /// 範囲の外・NaN は、それぞれ ``SynthSource/amp(_:)``・``SynthSource/add(_:)``・
    /// ``SynthSource/pan(_:)`` と同じに扱う。
    public func set(_ amp: Double, _ add: Double = 0, _ pan: Double = 0) {
        let (amp, add, pan) = (Float(amp), Float(add), Float(pan))
        self.amp(Double(amp))
        self.add(Double(add))
        self.pan(Double(pan))
    }
}

/// ホワイトノイズを出す。すべての帯域が同じ強さの、さらさらした音。
///
/// Processing Sound の `WhiteNoise` に当たる。作る関数は ``Sketch/createWhiteNoise()``。使い方は ``Noise``。
public final class WhiteNoise: Noise {
    init(stage: SynthStage) {
        super.init(stage: stage, color: .white, name: "WhiteNoise")
    }
}

/// ピンクノイズを出す。1 オクターブごとに同じ強さの、ホワイトノイズより低くやわらかい音。
///
/// Processing Sound の `PinkNoise` に当たる。作る関数は ``Sketch/createPinkNoise()``。使い方は ``Noise``。
public final class PinkNoise: Noise {
    init(stage: SynthStage) {
        super.init(stage: stage, color: .pink, name: "PinkNoise")
    }
}

// MARK: - 包絡

/// エンベロープ (音量の時間変化)。アタック → サステイン → リリースの 3 段 (ASR) を、音源にかける。
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
/// エンベロープは呼ぶたびに最初から始まる。エンベロープが終わると音源の音は 0 (無音) になり、次に ``play(_:_:_:_:_:)`` を
/// 呼ぶまでそのままで、``SynthSource/play()`` で再生し直しても戻らない。
public final class Env {
    init() {}

    /// エンベロープを `input` にかけ、最初から始める。`input` が再生されていなければ再生を始める。
    ///
    /// エンベロープは、0 から `sustainLevel` まで `attackTime` 秒で上がり、`sustainTime` 秒 `sustainLevel` を
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
    ///   - input: エンベロープをかける音源。
    ///   - attackTime: アタック (立ち上がり) の秒数。
    ///   - sustainTime: サステイン (保持) の秒数。
    ///   - sustainLevel: サステインのレベル (0〜1)。
    ///   - releaseTime: リリース (減衰) の秒数。
    ///
    /// 秒数が負なら 0 に、`sustainLevel` が 0〜1 の外なら端にクランプし、NaN・無限大があれば
    /// 呼び出し全体を無視する。どちらもそのことを 1 度だけ警告する (投げない — [ADR-0020] 決定 5)。
    /// すぐに始める。先の時刻に始めるなら ``play(_:_:_:_:_:at:)``。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func play(_ input: SynthSource, _ attackTime: Double, _ sustainTime: Double, _ sustainLevel: Double, _ releaseTime: Double) {
        let (attackTime, sustainTime, sustainLevel, releaseTime) = (Float(attackTime), Float(sustainTime), Float(sustainLevel), Float(releaseTime))
        play(input, Double(attackTime), Double(sustainTime), Double(sustainLevel), Double(releaseTime), at: 0)
    }

    /// エンベロープを `input` にかけ、オーディオクロックの `time` 秒のサンプルの先頭から始める (先の時刻へ予約する)。`input` が再生されていなければ
    /// 再生を始める。
    ///
    /// エンベロープの形・引数・クランプの仕方は ``play(_:_:_:_:_:)`` と同じ。
    ///
    /// - Parameters:
    ///   - input: エンベロープをかける音源。
    ///   - attackTime: アタック (立ち上がり) の秒数。
    ///   - sustainTime: サステイン (保持) の秒数。
    ///   - sustainLevel: サステインのレベル (0〜1)。
    ///   - releaseTime: リリース (減衰) の秒数。
    ///   - at: 始める時刻 (オーディオクロックの秒。``Sketch/soundTime`` と同じクロック)。現在より前 (負を含む) なら、次に生成する
    ///     サンプルの先頭で始める。
    ///
    /// NaN・無限大 (`time` を含む) があれば呼び出し全体を無視して 1 度だけ警告する (投げない —
    /// [ADR-0020] 決定 5)。
    ///
    /// ## 先の時刻へ予約する
    ///
    /// `at:` を渡すと、`draw()` が呼ばれたフレームの区切りではなく、**そのサンプルの先頭**からエンベロープが始まる。60 fps の
    /// 約 17 ミリ秒単位にビートが量子化されなくなり、120 BPM の 16 分音符 (125 ミリ秒) も等間隔に鳴る。**`at:` の秒はオーディオクロックで、
    /// ``SketchPart/time`` ではない** — 音を進めるのはオーディオクロックで、``SketchPart/pauseTime()``・``SketchPart/jumpTime(_:)``
    /// は予約に影響しない (音を止めず、シークもしない)。現在のオーディオクロックは ``Sketch/soundTime`` で読む。Tone.js の
    /// `triggerAttackRelease(…, time)` と、Web Audio の `OscillatorNode.start(when)` に当たる。
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
    ///         let now = soundTime                          // オーディオクロックの秒
    ///         let step = Int(now / 0.125) % 16
    ///         if step != lastStep {
    ///             lastStep = step
    ///             let next = (step + 1) % 16
    ///             if pattern[next], let osc, let env {
    ///                 // 次の 16 分音符の頭へ予約する。1 フレーム先より遠いので、実時間でも間に合う
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
    /// ## 音高を変えながら連続して鳴らす
    ///
    /// メロディのように音ごとに音高を変えるなら、**音高も同じ時刻に予約する**。`Env.play` が渡すのはエンベロープ (秒数とサステインの
    /// 音量) で、音高は渡さない。``Oscillator/play(_:_:_:_:at:)`` を、同じ `at:` で呼ぶ。音高もエンベロープも、
    /// そのサンプルの先頭から変わる (どちらを先に呼んでも同じサンプルになる)。
    ///
    /// ```swift
    /// final class Melody: Sketch {
    ///     var osc: TriOsc?
    ///     var env: Env?
    ///     var lastStep = -1
    ///     let notes: [Float] = [440, 494, 523, 587, 659, 587, 523, 494]   // 16 分音符ごとの音高 (Hz)
    ///     func setup() {
    ///         osc = createTriOsc()
    ///         env = createEnv()
    ///     }
    ///     func draw() {
    ///         background(20)
    ///         let step = Int(soundTime / 0.125)
    ///         if step != lastStep, let osc, let env {
    ///             lastStep = step
    ///             // 次の 16 分音符の頭へ、音高とエンベロープを同じ時刻に予約する (1 フレーム先より遠い)
    ///             let next = Double(step + 1) * 0.125
    ///             osc.play(notes[(step + 1) % notes.count], 0.5, at: next)   // 音高と音量。add・pan は 0 に戻る
    ///             env.play(osc, 0.01, 0.05, 0.5, 0.1, at: next)              // エンベロープ
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
    ///   すぐに反映される**。再生中の音 (予約済みの前の音の余韻を含む) の音高・音量・定位も変わる。次のビートの音高を
    ///   `freq(_:)` ですぐに変えると、前の音の余韻が次の音高で鳴り、1 ビート先へ予約する書き方では、いま鳴り始めた音が
    ///   まるごと次の音高になる。値を予約できるのは ``Oscillator/play(_:_:_:_:at:)`` で、再生し直さずに値だけを
    ///   サンプル単位の精度で変えるメソッド (`freq(_:at:)` など) は無い
    /// - 組み合わせて使うときは、`add`・`pan` も毎回渡し直す。**省略すると 0 に戻る** (`Oscillator.play` は 4 つの値をすべて
    ///   設定する)
    /// - 1 音ごとに `osc.play` と `env.play` の 2 回を呼ぶ。予約キューの枠を 1 音で 11 個使う (下の「予約キューの上限」)
    ///
    /// - 値 (秒数・サステインの音量) も、エンベロープも、再生の操作も、予約した時刻に**まとめて**反映される。続けて予約しても、前の予約の
    ///   値を書き換えない
    /// - 実機では、オーディオスレッドの処理単位の途中で反映される。予約が先の時刻なら、そのサンプルの先頭ちょうどからエンベロープが始まる。
    ///   書き出しでは、同じ操作から同じサンプルが出る ([ADR-0025] の水準 2)
    /// - **予約キューの上限は、スケッチごとに 2048 個の操作まで**。この呼び出し 1 回は 6 個 (値 4・エンベロープ・
    ///   再生) を使い、時刻になって反映されたぶんが空く。およそ 340 回ぶん先まで予約でき、足りなければその予約を
    ///   捨てて 1 度だけ警告する (投げない)。**音高も組み合わせて予約する使い方では、``Oscillator/play(_:_:_:_:at:)`` の 5 個 (値 4・
    ///   再生) を加えた 1 音 11 個で、およそ 186 音ぶん**。曲全体を先に予約せず、次の数音だけ予約する
    /// - **現在のオーディオクロックより前の `at:` は、次に生成するサンプルの先頭で始める** (警告しない)。実機で、`draw()` が間に合わず
    ///   予約が少し遅れたときも、この動作になる
    /// - 予約した音は、参照を手放しても時刻になって再生が終わるまで残る。**``SynthSource/stop()`` を呼ぶと、その音の先の
    ///   予約はすべて取り消される** (時刻になっても音が出ず、予約キューの枠も空く)
    /// - オーディオクロックは、最初の合成音を作ったときが 0 秒で、``SketchPart/time``・``SoundFile/position``・`.mov` の
    ///   音声トラックの時刻とは起点が違う (``Sketch/soundTime``)
    ///
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func play(_ input: SynthSource, _ attackTime: Double, _ sustainTime: Double, _ sustainLevel: Double, _ releaseTime: Double, at time: Double) {
        let (attackTime, sustainTime, sustainLevel, releaseTime) = (Float(attackTime), Float(sustainTime), Float(sustainLevel), Float(releaseTime))
        input.triggerEnvelope(
            attack: attackTime, sustain: sustainTime, level: sustainLevel, release: releaseTime,
            at: time)
    }
}
