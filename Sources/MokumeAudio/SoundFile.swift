// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Accelerate
import Foundation
import MokumeCore
import MokumeDiagnostics

/// 鳴らせる音声ファイル。``Sketch/loadSound(_:)`` が作り、走っているスケッチへ足す。
///
/// 鳴らしながら、**いま鳴っている音**を解析した値が読める。値の名前と写し方は ``AudioIn`` と
/// 同じで、`draw()` の前にそのフレームの値が入っている。
///
/// ```swift
/// final class Pulse: Sketch {
///     var song: SoundFile?
///     func setup() {
///         song = try? loadSound("assets/song.wav")
///         song?.loop()
///     }
///     func draw() {
///         background(0)
///         guard let song else { return }
///         circle(width / 2, height / 2, 40 + song.level * 300)
///     }
/// }
/// ```
///
/// ## 鳴らす・止める
///
/// | 口 | すること |
/// | --- | --- |
/// | ``play()`` | 1 度鳴らす。終わりまで鳴ると止まって頭へ戻る |
/// | ``loop()`` | 終わりから頭へ戻って鳴らし続ける |
/// | ``pause()`` | 止めて、位置を覚える。次の ``play()`` / ``loop()`` はそこから |
/// | ``stop()`` | 止めて頭へ戻す |
/// | ``jump(_:)`` | その秒の位置へ飛ぶ。止まっている間は位置だけを動かす |
/// | ``position`` | いま鳴らしている位置 (秒) |
/// | ``duration`` | 長さ (秒) |
/// | ``amp(_:)`` | 音量 (0〜1) |
///
/// 位置・長さ・飛ぶ口の名前は Processing Sound の `position()`・`duration()`・`jump()` に倣った。
/// 動画 (`Movie`) では同じ量を `time` と呼ぶ — あちらの手本の Processing Video が `time()` と呼ぶため。
///
/// 鳴っている最中に ``play()`` か ``loop()`` を呼ぶと、頭から鳴らし直す (キーを押すたびに鳴らす
/// 効果音の形)。止めて続きから鳴らすなら ``pause()`` と ``play()`` を組む。どの口も投げない
/// ([ADR-0020] 決定 5)。
///
/// ## 解析するのは、いま鳴っている音
///
/// 各フレームでは、再生位置で終わる 1024 標本の窓に音量を掛け、``AudioIn`` と同じ解析に通す。
/// 止まっている間の値は無音 (``level`` が 0) になる。左右のあるファイルは左右のまま鳴らし、
/// 解析はチャンネルを平均して行う。
///
/// ## エフェクトに通す
///
/// 合成した音と同じエフェクトに通せる (``SoundEffect/process(_:)``)。
///
/// <!-- example: 文脈 var song: SoundFile?; var filter: LowPass? -->
/// ```swift
/// func setup() {
///     song = try? loadSound("assets/song.wav")
///     filter = createLowPass()
///     if let song { filter?.process(song, 800) }
///     song?.loop()
/// }
/// ```
///
/// - **通した後は、ラックで鳴る。** 通されるまでは、いままでどおり直に鳴る。ラックでは、読み込んだ標本を
///   合成した音と同じ時計で読み出して節として混ぜる。通された音はエフェクトの出口を通ってだけ聞こえる
/// - **左右は畳まれる。** ラックの節は中央に定位するので、左右のあるファイルも、エフェクトの出口では
///   モノラルになる。エフェクトをやめても (``SoundEffect/stop()``)、通したファイルはラックで中央のまま鳴る
/// - **ラックの節の上限を 1 つ使う。** 同時に生きている節は 64 までで、通したファイルはそのうちの 1 つ
///   (``SynthSound``)。埋まっていれば通さず、そのことを 1 度だけ知らせる。通せなかったファイルは直に鳴る
/// - **標本化率が違っても同じ音になる。** ラックの標本化率 (実機で 48000 Hz) と違うファイルは、通すと
///   ラックの率へ読み直され、``position``・``duration`` はファイルの率のままの秒で返る
/// - 鳴っている最中に通しても、頭へ戻らず、いまの位置から続く。通した後も ``play()``・``loop()``・
///   ``pause()``・``stop()``・``jump(_:)``・``amp(_:)`` は同じに効き、``position`` と解析の値 (``level`` ほか)
///   も通さないときと同じになる
/// - ``AudioIn`` (マイク) は通せない
///
/// Processing Sound では、`LowPass`・`Reverb` などの `process(_:)` が `SoundFile` を受ける。
///
/// ## 書き出しでは鳴らさない
///
/// 窓に出して動かしている間は実際に鳴らし、解析の位置は実際に鳴った標本の数から読む。書き出し
/// (`mokume render`) と、窓を開かずに回す検査 (時刻がフレームの数え方から決まるとき —
/// ``SketchPart/clock``) では**鳴らさず**、位置を「鳴らし始めてから進んだフレームの数 × 標本化率
/// ÷ fps」で決める。どちらも同じ位置から同じ窓を切り出すので、書き出した絵は実時間で鳴らした
/// ときと同じ時刻の音で動き、何度書き出しても同じになる ([ADR-0028] 決定 7・[ADR-0025] の水準 2)。
///
/// 位置を進めるのは音の時計で、``SketchPart/time`` ではない。``SketchPart/pauseTime()`` と
/// ``SketchPart/jumpTime(_:)`` は音を止めない・飛ばさない。
///
/// 出力の機材が開けないときは、鳴らさずに実時間で位置を進め、そのことを 1 度だけ知らせる。
/// 出力の機材が替わって音が止まったときは、止まった位置から鳴らし直す。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public final class SoundFile: Inlet, EffectInput {
    /// ファイルの標本化率 (Hz)。帯域 `k` の真ん中は `k × sampleRate ÷ 1024` Hz。
    public let sampleRate: Float

    /// 解析に使う標本列 (チャンネルを平均したモノラル)。
    let samples: [Float]
    /// 読み込んだ器。鳴らすときに player へ渡し、鳴らさないと決まったら手放す。
    private var buffer: AVAudioPCMBuffer?
    /// 渡された名前。知らせに載せる。
    private let name: String
    private weak var owner: (any Sketch)?
    /// 差し替えた流れ (検査)。`nil` なら時計で決める。
    private let injectedFlow: SoundFlow?
    private let now: () -> TimeInterval
    private let warn: (String) -> Void

    private var playhead: Playhead
    /// 鳴っている間に頼まれた飛び先 (標本)。次のフレームの ``supply()`` で、そこから区切りを始め直す。
    private var pendingJump: Int?
    private var volume: Float = 1
    /// フレームの頭の窓と、読まれたときに解いた値 (``DeferredLevels``)。
    private var deferred = DeferredLevels()
    private var levels: AudioLevels { deferred.levels() }
    /// 解析した回数。**検査が読む** — 読まれない値は解析しない。
    var analyses: Int { deferred.analyses }
    /// 位置を進める時計。開くまで `nil`。
    private var pace: Pace?
    /// 最後に見たフレームが、時計の上で何フレーム目に並ぶか (最初のフレームが 0)。操作はこの
    /// フレームの時刻に効く。
    ///
    /// ``SketchPart/frameCount`` から 1 を引いたもので、`setup()` の間 (``SketchPart/frameCount`` が 0) も
    /// 0 にする。フレームの数え方の時計では、最初のフレームと `setup()` はどちらも 0 秒にいる。
    private var frame = 0
    /// 最後のフレームで読んだ、区切りの中で鳴った標本の数。
    private var lastPlayed = 0
    private var noticed: Set<Notice> = []
    /// エフェクトへ通されたとき (``SoundEffect/process(_:)``) に足す、ラックの節。通されるまでは `nil`。
    private var feed: Feed?

    /// ラックの節と、いまの区切りの世代。区切りを始めるたびに世代を 1 つ進める。
    private struct Feed {
        let stage: SynthStage
        let node: FileNode
        var generation = 0

        /// 区切りを始めるよう、節へ頼む。`frame` は頼んだフレーム。
        mutating func begin(start: Int, looping: Bool, frame: Int) {
            generation += 1
            stage.sendToFile(
                SynthCommand(
                    op: .segment, node: UInt8(node.id),
                    bits: FileNode.segment(start: start, looping: looping, generation: generation)),
                frame: frame)
        }

        /// 節を止める。
        func halt(frame: Int) {
            stage.sendToFile(SynthCommand(op: .stop, node: UInt8(node.id)), frame: frame)
        }

        /// 音量を伝える。
        func amp(_ volume: Float, frame: Int) {
            stage.sendToFile(
                SynthCommand(
                    op: .set, node: UInt8(node.id), param: .amplitude,
                    bits: UInt64(volume.bitPattern)),
                frame: frame)
        }
    }

    /// 位置を進める時計。
    private enum Pace {
        /// フレームの数え方 (固定の時計)。鳴らさない。`origin` は区切りが始まったフレーム。
        case frames(perSecond: Int, origin: Int)
        /// 実時間。出力が開けないとき。`origin` は区切りが始まった時刻 (秒)。
        case realTime(origin: TimeInterval)
        /// 実際に鳴らしている。位置は player が描いた数から読む。
        case speaker(FilePlayer)
        /// エフェクトへ通され、ラックの節が実際に鳴らしている。位置は節が描いた数から読む (``Feed``)。
        case routed
    }

    /// 1 度だけ言う知らせ。
    private enum Notice: Hashable {
        case noOutput
        case volumeOutOfRange
        case volumeNotANumber
        case jumpNotANumber
        case cannotProcess
        case fileCapacity
    }

    init(
        name: String, buffer: AVAudioPCMBuffer, owner: (any Sketch)?, flow: SoundFlow?,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        warn: @escaping (String) -> Void = Diagnostics.warn
    ) {
        self.name = name
        self.buffer = buffer
        self.samples = AudioFile.mono(buffer)
        self.sampleRate = Float(buffer.format.sampleRate)
        self.owner = owner
        self.injectedFlow = flow
        self.now = now
        self.warn = warn
        playhead = Playhead(length: samples.count)
    }

    // MARK: - 鳴らす・止める

    /// 1 度鳴らす。終わりまで鳴ると止まり、頭へ戻る。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// func keyPressed() {
    ///     if key == " " { song?.play() }
    /// }
    /// ```
    ///
    /// ``pause()`` の後なら止めた位置から、``stop()`` の後と鳴り終わった後は頭から鳴らす。
    /// **鳴っている最中に呼ぶと、頭から鳴らし直す。** ``loop()`` で鳴らしている最中に呼んだときも
    /// 頭から鳴らし直し、今度は終わりで止まる。
    public func play() {
        start(looping: false)
    }

    /// 終わりから頭へ戻って、鳴らし続ける。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// func setup() {
    ///     song = try? loadSound("assets/song.wav")
    ///     song?.loop()
    /// }
    /// ```
    ///
    /// どこから鳴らし始めるかは ``play()`` と同じで、鳴っている最中に呼ぶと頭から鳴らし直す。
    public func loop() {
        start(looping: true)
    }

    /// 止めて、いまの位置を覚える。次の ``play()`` か ``loop()`` は、そこから鳴らす。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// func mousePressed() {
    ///     guard let song else { return }
    ///     if song.isPlaying { song.pause() } else { song.play() }
    /// }
    /// ```
    ///
    /// 止まっていれば何もしない。
    public func pause() {
        guard playhead.isPlaying else { return }
        playhead.pause(after: played())
        // 同じフレームで先に飛ぶよう頼まれていれば、止めた位置はその飛び先にする
        if let target = pendingJump {
            pendingJump = nil
            playhead.jump(to: target)
        }
        halt()
    }

    /// 止めて、頭へ戻す。次の ``play()`` か ``loop()`` は頭から鳴らす。
    public func stop() {
        pendingJump = nil
        playhead.stop()
        halt()
    }

    /// `seconds` 秒の位置へ飛ぶ。**呼んだ直後から ``position`` は飛び先を返す。**
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// func keyPressed() {
    ///     if key == "2" { song?.jump(62) }  // サビから確かめる
    /// }
    /// ```
    ///
    /// 鳴っている間なら、次のフレームでその位置から鳴り、解析の値もその位置の音になる。そのフレームの
    /// 窓は、飛び先で終わるファイルの窓である (飛ぶ前からそこまで鳴っていたのと同じ)。止まっている間
    /// (``pause()`` の後・``stop()`` の後・鳴り終わった後) は位置だけを動かし、鳴らさない。次の
    /// ``play()`` か ``loop()`` がそこから鳴らす。
    ///
    /// 0 より前は頭、``duration`` より後は終わりへ寄せる。数でない値・無限の値は位置を変えず、
    /// そのことを 1 度だけ知らせる (投げない — [ADR-0020] 決定 5)。どれも `Movie` の `jump(_:)` と同じ。
    ///
    /// 同じフレームで後から ``play()`` か ``loop()`` を呼ぶと、鳴っている最中なら頭から鳴らし直す
    /// (後から呼んだ口が勝つ)。``stop()`` は頭へ戻す。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func jump(_ seconds: Float) {
        guard seconds.isFinite else {
            notice(
                .jumpNotANumber,
                "jump() got a value that is not a number, or an infinite one, so \"\(name)\" stays "
                    + "at \(position) seconds")
            return
        }
        // 寄せてから整数にする (大きな秒のまま整数へ直すと溢れる)。いちばん近い標本へ丸める — 切り捨てると、
        // 単精度で 5.1 をわずかに割る `jump(5.1)` が 1 標本手前になり、`position` が 5.1 に戻らない
        let reach = min(max(Double(seconds) * Double(sampleRate), 0), Double(samples.count))
        let target = Int(reach.rounded())
        if playhead.isPlaying {
            pendingJump = target
        } else {
            playhead.jump(to: target)
        }
    }

    /// いま鳴らしている位置 (秒)。0 から ``duration`` まで。``jump(_:)`` を呼んだ後なら、その飛び先。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// func draw() {
    ///     guard let song else { return }
    ///     let t = song.position
    ///     if t < 62 { background(40, 60, 160) } else { background(200, 40, 60) }
    ///     fill(255)
    ///     rect(0, height - 8, width * t / song.duration, 8)
    /// }
    /// ```
    ///
    /// 位置を進めるのは音の時計で、``SketchPart/time`` ではない。書き出し (固定の時計) では、鳴らし
    /// 始めてから進んだフレームの数で決まるので、同じフレームはいつも同じ位置で描かれる。値はその
    /// フレームの始まりのもの (``isPlaying`` と同じ)。止まっている間は止めた位置、鳴り終わった後は 0。
    public var position: Float { seconds(pendingJump ?? samplePosition) }

    /// 長さ (秒)。標本の数 ÷ ``sampleRate``。
    public var duration: Float { seconds(samples.count) }

    /// 標本の位置を秒にする。
    private func seconds(_ sample: Int) -> Float {
        Float(Double(sample) / Double(sampleRate))
    }

    /// 音量を決める。0 で無音、1 で読み込んだままの大きさ。既定は 1。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// song?.amp(mouseX / width)
    /// ```
    ///
    /// 解析の値も、この音量を掛けた音のものになる。0〜1 の外は端へ丸め、数でない値・無限の値は
    /// 無視する。どちらもそのことを 1 度だけ知らせる (投げない — [ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func amp(_ volume: Float) {
        guard volume.isFinite else {
            notice(
                .volumeNotANumber,
                "amp() got a value that is not a number, or an infinite one, so the volume of "
                    + "\"\(name)\" stays at \(self.volume)")
            return
        }
        let clamped = min(max(volume, 0), 1)
        if clamped != volume {
            notice(
                .volumeOutOfRange,
                "amp() takes a volume from 0 to 1, so \(volume) was clamped to \(clamped) for "
                    + "\"\(name)\"")
        }
        self.volume = clamped
        if case .speaker(let player) = pace { player.volume = clamped }
        feed?.amp(clamped, frame: frame)
    }

    /// 鳴っているか。``play()`` か ``loop()`` で `true` になり、``pause()``・``stop()``・
    /// 鳴り終わりで `false` になる。値はそのフレームの始まりのもの。
    public var isPlaying: Bool { playhead.isPlaying }

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

    // MARK: - Inlet

    public func open() throws {
        guard let owner else { return }
        frame = Self.frameIndex(of: owner)
        if let injectedFlow {
            speak(through: injectedFlow)
        } else if let frameRate = owner.clock.soundFrameRate(onScreen: owner.isOnScreen) {
            // 書き出しの経路。鳴らさずに、フレームの数から位置を決める
            pace = .frames(perSecond: max(1, frameRate), origin: frame)
        } else {
            // 画面へ出している経路は、時計によらず鳴らす (フレームの時計の窓も・#2601)
            speak(through: .speakers)
        }
        // 鳴らさないと決まったなら、器は要らない (鳴らすなら player が持っている)
        buffer = nil
        if playhead.isPlaying { beginSegment() }
    }

    public func supply() {
        if let owner { frame = Self.frameIndex(of: owner) }
        resumeIfStopped()
        // 前のフレームで飛ぶよう頼まれていれば、このフレームを飛び先から始まる区切りの頭にする
        // (``position`` がちょうど飛び先になり、窓は飛び先で終わる)
        if let target = pendingJump {
            pendingJump = nil
            playhead.jump(to: target)
            beginSegment()
        }
        guard playhead.isPlaying else {
            deferred.silence()
            return
        }
        let played = played()
        lastPlayed = played
        // 鳴り終わったフレームからは無音 (``isPlaying`` が `false` の間、値は鳴っていない音のもの)
        if playhead.settle(after: played) {
            halt()
            deferred.silence()
            return
        }
        let window = playhead.window(of: samples, after: played)
        // **窓は音量を掛けた形でフレームの頭に決め、解析は読まれたときまで遅らせる** (#2379)
        deferred.hold(volume == 1 ? window : vDSP.multiply(volume, window))
    }

    /// いまの再生位置 (標本)。飛び先を待っている間も、まだ動いていない位置を返す。検査が読む。
    var samplePosition: Int { playhead.position(after: lastPlayed) }

    public func close() {
        pendingJump = nil
        if case .speaker(let player) = pace { player.leave() }
        feed?.halt(frame: frame)
        feed = nil
        pace = nil
        playhead.stop()
        deferred.silence()
    }

    // MARK: - エフェクトへ通す

    /// エフェクト (``SoundEffect``) の入力に足す節を返す。**最初に通されたときだけ**、実際に鳴らす
    /// 経路を ``FilePlayer`` からラックの節 (``FileNode``) へ切り替える。以後は同じ節を返す。
    ///
    /// 通されたとき鳴っていれば、いまの位置から鳴らし続ける (頭へ戻さない)。位置の測り方は、ステージの
    /// 時計に合わせる — 実機・機材に出さない流れでは節が描いた標本の数、固定の時計と実時間ではフレームの数
    /// と時刻 (通す前と同じ)。
    ///
    /// - Parameter stage: エフェクトが属するステージ。このファイルを作ったスケッチのものでなければ断る。
    /// - Returns: 節。断ったとき (別のスケッチ・動いていない・ラックの置き場が埋まっている) は `nil` で、
    ///   そのことを 1 度だけ知らせる。断ったファイルは、いままでどおり ``FilePlayer`` で鳴る。
    func route(into stage: SynthStage) -> FileNode? {
        if let feed {
            guard feed.stage === stage else { return refuse(.cannotProcess) }
            return feed.node
        }
        guard let owner, stage.isOwned(by: owner), !stage.isClosed, let clock = stage.pace,
            pace != nil
        else { return refuse(.cannotProcess) }
        guard let node = stage.rack.addFile(
            samples: samples, fileRate: Double(sampleRate), amplitude: volume)
        else { return refuse(.fileCapacity) }

        // 位置は、時計を切り替える前の測り方で読む
        let position = playhead.position(after: played())
        let wasPlaying = playhead.isPlaying
        switch clock {
        case .speaker:
            if case .speaker(let player) = pace { player.leave() }
            pace = .routed
        case .frames(let frameRate, _):
            if case .speaker(let player) = pace { player.leave() }
            if case .frames = pace {} else { pace = .frames(perSecond: frameRate, origin: frame) }
        case .realTime:
            if case .speaker(let player) = pace { player.leave() }
            if case .realTime = pace {} else { pace = .realTime(origin: now()) }
        }
        feed = Feed(stage: stage, node: node)
        if wasPlaying {
            // いまの位置から区切りを始め直す。窓は、始まりより前もファイルの標本で埋める (``Playhead/jump(to:)``)
            // ので、解析の値は途切れない
            playhead.jump(to: position)
            beginSegment()
        }
        return node
    }

    /// 通せなかったことを 1 度だけ知らせて、`nil` を返す。
    private func refuse(_ kind: Notice) -> FileNode? {
        switch kind {
        case .fileCapacity:
            notice(
                kind,
                "process() could not take \"\(name)\": a sketch holds at most "
                    + "\(SynthRack.capacity) oscillators, noises, effects and sound files passed to "
                    + "effects alive together. \"\(name)\" keeps playing on its own, without the effect")
        default:
            notice(
                kind,
                "process() could not take \"\(name)\": the effect belongs to another sketch, or the "
                    + "sound is not running. \"\(name)\" keeps playing on its own, without the effect")
        }
        return nil
    }

    // MARK: - 時計

    /// `sketch` のいまのフレームが、時計の上で何フレーム目に並ぶか (``frame``)。
    private static func frameIndex(of sketch: any Sketch) -> Int {
        max(0, sketch.frameCount - 1)
    }

    /// 実際に鳴らす。出力が開けなければ、鳴らさずに実時間で進める。
    private func speak(through flow: SoundFlow) {
        if let buffer, let player = FilePlayer(flow: flow, buffer: buffer) {
            player.volume = volume
            pace = .speaker(player)
            return
        }
        pace = .realTime(origin: now())
        notice(
            .noOutput,
            "No audio output could be opened, so \"\(name)\" is not heard. Its position still "
                + "follows the clock, and its analysis keeps working")
    }

    /// いまの区切りの中で鳴った標本の数。
    private func played() -> Int {
        switch pace {
        case .frames(let frameRate, let origin):
            // 整数のフレーム数から掛けて割る。秒を足し込まないので、何フレーム目でも丸めがずれない
            return Int((Double(frame - origin) * Double(sampleRate) / Double(frameRate)).rounded(.down))
        case .realTime(let origin):
            return Int(((now() - origin) * Double(sampleRate)).rounded(.down))
        case .speaker(let player):
            return player.played ?? lastPlayed
        case .routed:
            return feed.map { $0.node.played(generation: $0.generation) } ?? lastPlayed
        case nil:
            return 0
        }
    }

    /// 鳴らし始める。鳴っている最中なら頭から鳴らし直す (``Playhead/play(looping:)``)。
    private func start(looping: Bool) {
        // 飛び先を待つのは鳴っている間だけで、鳴っている最中の play() / loop() は頭から鳴らし直す
        pendingJump = nil
        playhead.play(looping: looping)
        beginSegment()
    }

    /// 区切りを始め直す。いまのフレーム (鳴らしているなら、いま) が区切りの始まりになる。
    private func beginSegment() {
        lastPlayed = 0
        switch pace {
        case .frames(let frameRate, _):
            pace = .frames(perSecond: frameRate, origin: frame)
        case .realTime:
            pace = .realTime(origin: now())
        case .speaker(let player):
            player.play(from: playhead.start, looping: playhead.isLooping)
        case .routed, nil:
            break
        }
        feed?.begin(start: playhead.start, looping: playhead.isLooping, frame: frame)
    }

    /// 鳴らしている player と、ラックの節を止める。
    private func halt() {
        if case .speaker(let player) = pace { player.halt() }
        feed?.halt(frame: frame)
    }

    /// 出力の機材が替わると、流れは自分で止まり、player も止まる。最後に読んだ位置から鳴らし直す。
    /// 流れを始め直せなければ、鳴らさずに実時間で進める。
    private func resumeIfStopped() {
        guard case .speaker(let player) = pace, playhead.isPlaying, !player.flow.isRunning
        else { return }
        let looping = playhead.isLooping
        if playhead.settle(after: lastPlayed) { return }
        playhead.pause(after: lastPlayed)
        playhead.play(looping: looping)
        if !player.flow.start() {
            player.leave()
            pace = .realTime(origin: now())
            notice(
                .noOutput,
                "The audio output stopped and could not be restarted, so \"\(name)\" is no longer "
                    + "heard. Its position still follows the clock, and its analysis keeps working")
        }
        beginSegment()
    }

    private func notice(_ kind: Notice, _ message: String) {
        guard noticed.insert(kind).inserted else { return }
        warn(message)
    }
}
