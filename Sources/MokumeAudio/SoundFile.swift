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
/// | ``amp(_:)`` | 音量 (0〜1) |
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
/// ## 書き出しでは鳴らさない
///
/// 窓に出して動かしている間は実際に鳴らし、解析の位置は実際に鳴った標本の数から読む。書き出し
/// (`mokume render`) と、窓を開かずに回す検査 (時刻がフレームの数え方から決まるとき —
/// ``Sketch/clock``) では**鳴らさず**、位置を「鳴らし始めてから進んだフレームの数 × 標本化率
/// ÷ fps」で決める。どちらも同じ位置から同じ窓を切り出すので、書き出した絵は実時間で鳴らした
/// ときと同じ時刻の音で動き、何度書き出しても同じになる ([ADR-0028] 決定 7・[ADR-0025] の水準 2)。
///
/// 位置を進めるのは音の時計で、``Sketch/time`` ではない。``Sketch/pauseTime()`` と
/// ``Sketch/jumpTime(_:)`` は音を止めない・飛ばさない。
///
/// 出力の機材が開けないときは、鳴らさずに実時間で位置を進め、そのことを 1 度だけ知らせる。
/// 出力の機材が替わって音が止まったときは、止まった位置から鳴らし直す。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public final class SoundFile: Inlet {
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
    private var volume: Float = 1
    private var levels = AudioLevels.silence
    /// 位置を進める時計。開くまで `nil`。
    private var pace: Pace?
    /// 最後に見たフレームが、時計の上で何フレーム目に並ぶか (最初のフレームが 0)。操作はこの
    /// フレームの時刻に効く。
    ///
    /// ``Sketch/frameCount`` から 1 を引いたもので、`setup()` の間 (``Sketch/frameCount`` が 0) も
    /// 0 にする。フレームの数え方の時計では、最初のフレームと `setup()` はどちらも 0 秒にいる。
    private var frame = 0
    /// 最後のフレームで読んだ、区切りの中で鳴った標本の数。
    private var lastPlayed = 0
    private var noticed: Set<Notice> = []

    /// 位置を進める時計。
    private enum Pace {
        /// フレームの数え方 (固定の時計)。鳴らさない。`origin` は区切りが始まったフレーム。
        case frames(perSecond: Int, origin: Int)
        /// 実時間。出力が開けないとき。`origin` は区切りが始まった時刻 (秒)。
        case realTime(origin: TimeInterval)
        /// 実際に鳴らしている。位置は player が描いた数から読む。
        case speaker(FilePlayer)
    }

    /// 1 度だけ言う知らせ。
    private enum Notice: Hashable {
        case noOutput
        case volumeOutOfRange
        case volumeNotANumber
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
        halt()
    }

    /// 止めて、頭へ戻す。次の ``play()`` か ``loop()`` は頭から鳴らす。
    public func stop() {
        playhead.stop()
        halt()
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
        } else {
            switch owner.clock {
            case .frameIndex(let frameRate):
                pace = .frames(perSecond: max(1, frameRate), origin: frame)
            case .wallClock:
                speak(through: .speakers)
            }
        }
        // 鳴らさないと決まったなら、器は要らない (鳴らすなら player が持っている)
        buffer = nil
        if playhead.isPlaying { beginSegment() }
    }

    public func supply() {
        if let owner { frame = Self.frameIndex(of: owner) }
        resumeIfStopped()
        guard playhead.isPlaying else {
            levels = .silence
            return
        }
        let played = played()
        lastPlayed = played
        // 鳴り終わったフレームからは無音 (``isPlaying`` が `false` の間、値は鳴っていない音のもの)
        if playhead.settle(after: played) {
            halt()
            levels = .silence
            return
        }
        let window = playhead.window(of: samples, after: played)
        levels = AudioAnalysis.analyze(volume == 1 ? window : vDSP.multiply(volume, window))
    }

    /// いまの再生位置 (標本)。検査が読む。
    var position: Int { playhead.position(after: lastPlayed) }

    public func close() {
        if case .speaker(let player) = pace { player.leave() }
        pace = nil
        playhead.stop()
        levels = .silence
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
        case nil:
            return 0
        }
    }

    /// 鳴らし始める。鳴っている最中なら頭から鳴らし直す (``Playhead/play(looping:)``)。
    private func start(looping: Bool) {
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
        case nil:
            break
        }
    }

    /// 鳴らしている player を止める。
    private func halt() {
        if case .speaker(let player) = pace { player.halt() }
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
