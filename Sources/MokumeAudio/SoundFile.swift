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
///     func setup() throws {
///         song = try loadSound("assets/song.wav")
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
/// 各フレームでは、**前のフレームの再生位置から、このフレームの再生位置までに鳴った全標本**(区間)に
/// 音量を掛け、``AudioIn`` と同じ解析に通す。止まっている間の値は無音 (``level`` が 0) になる。
/// 左右のあるファイルは左右のまま鳴らし、解析はチャンネルを平均して行う。
///
/// - ``rms``・``decibels``・``level``・``peak`` は区間全体の値。``spectrum`` は、**ファイルの位置 0 から
///   512 標本ごと**に置いた 1024 標本の窓のうち、終わりが区間に入るものの平均 (鳴らし始めた位置から始めても、
///   格子はファイルの位置に置く。ループで頭へ戻った後は、戻らずに数え続ける)
/// - 鳴らし始めた最初のフレームの区間は、鳴らし始めてから進んだ分。``jump(_:)`` を挟んだフレームの区間は、
///   飛ぶ前の区切りで前のフレームからそのフレームまで鳴り続けていた分 (飛ぶ前の位置の音)。飛び先の区間は
///   その次のフレームから始まる (窓の前の部分はファイルの標本で埋める)
/// - 1 度だけ鳴らして鳴り終わったフレームは、ファイルの終わりまでの区間を解析してから止まる (1 フレームより
///   短い一発音の ``peak`` も出る)。次のフレームからは無音
/// - **読まれなかったフレームの区間は解かず、次のフレームの値に混ぜない**。読んだ値は、毎フレーム解析した
///   ときと同じ。長く止まった後は、区間の終わりから 6144 標本 (48 kHz で約 0.128 秒) までを解析する
///
/// ## エフェクトに通す
///
/// 合成した音と同じエフェクトに通せる (``SoundEffect/process(_:)``)。
///
/// <!-- example: 文脈 var song: SoundFile?; var filter: LowPass? -->
/// ```swift
/// func setup() throws {
///     song = try loadSound("assets/song.wav")
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
///   (``SynthSound``)。スケッチから外す (`detach(_:)`) と節が返り、外したファイルを足し直して通すと
///   節を取り直す。埋まっていれば通さず、そのことを 1 度だけ知らせる。通せなかったファイルは直に鳴る
/// - **標本化率が違えば、ラックの率へ読み直される。** ラックの標本化率は 48000 Hz (書き出しでも同じ) で、
///   違うファイルは通すと、低い率は補間で、高い率は折り返しを抑える低域通過を掛けて読み直す。
///   ``position``・``duration`` はファイルの率のままの秒で返る
/// - **鳴らし始め・止めは約 5 ミリ秒かけて立ち上がる・消える** (合成した音と同じ)。鳴っている最中に頭から
///   鳴らし直すときや飛ぶときは、前の位置の音が消えながら新しい位置の音が立ち上がる
/// - 鳴っている最中に通しても、頭へ戻らず、いまの位置から続く。**ただし、通す瞬間だけはつなぎ目がある** —
///   通す前に直に鳴っていた音 (OS の再生機) はその場で止まり、ラックの節が約 5 ミリ秒かけて立ち上がる。
///   2 つは別の時計 (再生機の時計とラックの時計) で進んでいて、標本の精度では重ねられないので、つなぎ目で
///   音が一瞬だけ細る。避けるなら、鳴らし始める前 (`setup()`) に通す
/// - 通した後も ``play()``・``loop()``・``pause()``・``stop()``・``jump(_:)``・``amp(_:)`` は同じに効く。
///   ``position`` と解析の値 (``level`` ほか) は、通さないときと同じ操作の列から同じになる。**ただし、書き出し
///   (固定の時計) で標本化率が 48000 Hz でないファイルを、fps が 48000 を割り切れない (144 fps など)
///   ときに通すと、``position`` は通さないときと最大 1 標本ずれる** (ラックは整数の標本で進むので、
///   ファイルの標本へ直すと端数が出る)。標本化率が 48000 Hz のファイルと、48000 を割り切れる fps
///   (60・30・24・100 fps など) では同じ
/// - **ラックの操作の列が詰まっている間** (1 フレームに数千の音の変更を頼むなど) は、``play()`` などの位置を
///   動かす操作は、位置と一緒に詰まりが解けるまで (通常は次のフレーム) 控える。聞こえている音と
///   ``position`` はずれない。控えている間の ``isPlaying`` は、控える前のまま (値はそのフレームの始まりのもの)。
///   このときの ``SoundEffect/process(_:)`` は、何も変えずに断って 1 度だけ知らせる (次のフレームから通せる)
/// - ``AudioIn`` (マイク) は通せない
///
/// Processing Sound では、`LowPass`・`Reverb` などの `process(_:)` が `SoundFile` を受ける。
///
/// ## 書き出しでは、音を動画の音声トラックへ載せる
///
/// 窓に出して動かしている間は実際に鳴らし、解析の位置は実際に鳴った標本の数から読む。**固定の時計で `.mov` へ
/// 書き出す (`mokume render --out x.mov`・`beginRecord("x.mov")`) と、再生した音は動画の音声トラックに載る**
/// (LPCM・32 ビット浮動小数点・48 kHz・2 チャンネル。左右のあるファイルは左右のまま載る)。
///
/// **操作が効く時刻は、操作ごとに違う。** フレーム `N` の `draw()` が頼んだ ``play()``・``loop()``・``pause()``・
/// ``stop()``・``amp(_:)`` は、窓 `N` の先頭の標本から効く (音量は先頭から、窓 `N` のうちになめらかに変わる)。**``jump(_:)`` は、鳴っている間は次のフレームの頭で効く
/// ので、窓 `N + 1` の先頭の標本から効く** (窓 `N` は飛ぶ前の位置のまま鳴る。止まっている間は位置だけが動き、
/// 鳴らさない)。
///
/// 載るのは、録りを頼んだフレームの `draw()` が終わった時点で音の流れに音源がある録りで、実時間の時計・MP4・GIF・
/// 連番の録りには載らない (音源があれば、そのことを 1 度だけ知らせる)。
///
/// 録っていない書き出しと、窓を開かずに回す検査 (時刻がフレームの数え方から決まるとき —
/// ``SketchPart/clock``) では**鳴らさず**、位置を「鳴らし始めたフレームから進んだ標本の数」で決める。
/// 数は絶対のフレーム番号 `N` から求めた標本の位置 `⌊N × 標本化率 ÷ fps⌋` の差で、鳴らし始めたフレームが
/// 標本の継ぎ目の途中にあっても、フレームの窓の継ぎ目 ([ADR-0042] 決定 6 の「時刻の対応」) とずれない。
/// どちらも同じ位置から同じ区間を切り出すので、書き出した絵は実時間で鳴らしたときと同じ時刻の音で動き、
/// 何度書き出しても同じになる ([ADR-0028] 決定 7・[ADR-0025] の水準 2)。
///
/// エフェクトへ通したファイルは、位置をどの流れでも**ラックの節が描いた標本の数**から読む (固定の時計では
/// ラックが同じフレームの数で進み、実時間では打ち切り — 2 秒を超える停止の後は 2 秒ぶんずつ — も節と
/// 同じに働く)。聞こえている音と ``position``・解析の位置がずれない。
///
/// 位置を進めるのは音の時計で、``SketchPart/time`` ではない。``SketchPart/pauseTime()`` と
/// ``SketchPart/jumpTime(_:)`` は音を止めない・飛ばさない。
///
/// 出力の機材が開けないときは、鳴らさずに実時間で位置を進め、そのことを 1 度だけ知らせる。
/// 外した (`detach(_:)`) ファイルを足し直して鳴らし直すときは、鳴らす分の標本を読み込んだファイルから
/// もう 1 度読む (外している間は解析用のモノラルの標本だけを持つ)。読み直せないときも、鳴らさずに実時間で
/// 位置を進め、読めなかった事情とともに 1 度だけ知らせる。
/// 出力の機材が替わって音が止まったときは、止まった位置から鳴らし直す。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
public final class SoundFile: Inlet, EffectInput {
    /// ファイルの標本化率 (Hz)。帯域 `k` の真ん中は `k × sampleRate ÷ 1024` Hz。
    public let sampleRate: Float

    /// 解析に使う標本列 (チャンネルを平均したモノラル)。
    let samples: [Float]
    /// 読み込んだ器 (左右などチャンネルごとの標本)。鳴らすときに player へ渡し、鳴らさないと決まったら
    /// 手放す。手放した後に足し直して鳴らすときは、``source`` から読み直す。外している間に持ち続けるのは、
    /// 解析用のモノラルの ``samples`` だけである (器の写しは持たない)。
    private var buffer: AVAudioPCMBuffer?
    /// 読み込んだときの器の形式 (チャンネル数・標本化率)。読み直したファイルが同じものかを見分ける。
    private let format: AVAudioFormat
    /// 読み込んだときの標本の数。
    private let frameLength: AVAudioFrameCount
    /// 読み込んだファイルの場所。足し直して鳴らすとき、手放した器を読み直すのに使う。
    private let source: URL?
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
    /// フレームの頭の区間と、読まれたときに解いた値 (``DeferredLevels``)。
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
    /// 前のフレームの区間の終わり (区切りの通し番号 = 開始位置 + 鳴った標本の数)。区切りを始め直すと、始まりの位置に戻る。
    private var covered = 0
    /// エフェクトに通されたとき (``route(into:)``) の、引き継ぐ解析済みの終わり。次の ``beginSegment()`` で使う。
    private var continuedCoverage: Int?
    /// 止める (``pause()``・``stop()``) 操作の時点で、まだ解析していなかった区間 (前のフレーム以後、止めた位置まで)。
    /// 次の ``supply()`` が、止める前に鳴っていた分として見せてから無音にする (鳴り終わりと同じ形)。
    private var stoppedTail: AudioSpan?
    private var noticed: Set<Notice> = []
    /// エフェクトへ通されたとき (``SoundEffect/process(_:)``) に足す、ラックの節。通されるまでは `nil`。
    private var feed: Feed?
    /// ラックの操作の列が詰まっている間 (``SynthRack/isCongested``) に呼ばれた、位置を動かす操作 (頼んだ順)。
    /// 詰まりが解けた最初の ``supply()`` (か、次の呼び出し) で、頼んだ順に効かせる。
    private var waiting: [Operation] = []
    /// 控えている操作の中で、最後に頼まれた ``jump(_:)`` の飛び先 (標本)。**``position`` は飛び先を返す。**
    private var waitingTarget: Int?

    /// 位置を動かす操作。
    private enum Operation {
        case play(looping: Bool)
        case pause
        case stop
        case jump(Int)
    }

    /// ラックの節と、いまの区切りの世代。区切りを始めるたびに世代を 1 つ進める。
    ///
    /// 区切りを始める操作は、ラックの操作の列が詰まっていないときにだけ頼む (``SoundFile/submit(_:)``)。
    /// 控えに回る操作で世代だけが進むと、``FileNode/played(generation:)`` が 0 を返し続けて位置が凍る。
    private struct Feed {
        let stage: SynthStage
        let node: FileNode
        var generation = 0
        /// エフェクトの入力に選ばれるまで、鳴らし始めるのを待っているか。
        ///
        /// 節を入力に選ぶ操作 (`.inputs`) より先に鳴らす操作 (`.segment`) が音の側へ届くと、その間に
        /// 描かれた区切りは、入力に選ばれていない鳴っている節 = 直に出る節として出てしまう。
        var waitsForInput = false

        /// 区切りを始めるよう、節へ頼む。
        mutating func begin(start: Int, looping: Bool) {
            generation += 1
            stage.rack.post(
                SynthCommand(
                    op: .segment, node: UInt8(node.id),
                    bits: FileNode.segment(start: start, looping: looping, generation: generation)))
        }

        /// 節を止める。
        func halt() {
            stage.rack.post(SynthCommand(op: .stop, node: UInt8(node.id)))
        }

        /// 手放す。鳴り終えた (消えきった) ら、置き場が戻る。
        func release() {
            stage.rack.post(SynthCommand(op: .release, node: UInt8(node.id)))
        }

        /// 音量を伝える。
        func amp(_ volume: Float) {
            stage.rack.post(
                SynthCommand(
                    op: .set, node: UInt8(node.id), param: .amplitude,
                    bits: UInt64(volume.bitPattern)))
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
        /// 足し直した後で、鳴らす流れは決まったが、器をまだ読み直していない。**器が要るのは実際に鳴らす
        /// とき (``beginSegment()``) だけ**で、エフェクトへ通すだけなら (``route(into:)``) 読まずに済む。
        case unloaded(SoundFlow)
        /// エフェクトへ通され、ラックの節が鳴らしている。**位置はどの流れでも節が描いた数から読む**
        /// (``Feed``) — 位置を導く時計を 1 本にするため。
        case routed
    }

    /// 1 度だけ言う知らせ。
    private enum Notice: Hashable {
        case noOutput
        case cannotReload
        case cannotCarry
        case volumeOutOfRange
        case volumeNotANumber
        case jumpNotANumber
        case cannotProcess
        case fileCapacity
        case congested
    }

    init(
        name: String, buffer: AVAudioPCMBuffer, owner: (any Sketch)?, flow: SoundFlow?,
        source: URL? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        warn: @escaping (String) -> Void = Diagnostics.warn
    ) {
        self.name = name
        self.buffer = buffer
        self.format = buffer.format
        self.frameLength = buffer.frameLength
        self.samples = AudioFile.mono(buffer)
        self.sampleRate = Float(buffer.format.sampleRate)
        self.owner = owner
        self.injectedFlow = flow
        self.source = source
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
        submit(.play(looping: false))
    }

    /// 終わりから頭へ戻って、鳴らし続ける。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// func setup() throws {
    ///     song = try loadSound("assets/song.wav")
    ///     song?.loop()
    /// }
    /// ```
    ///
    /// どこから鳴らし始めるかは ``play()`` と同じで、鳴っている最中に呼ぶと頭から鳴らし直す。
    public func loop() {
        submit(.play(looping: true))
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
        submit(.pause)
    }

    /// 止めて、頭へ戻す。次の ``play()`` か ``loop()`` は頭から鳴らす。
    public func stop() {
        submit(.stop)
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
    /// 区間は、飛ぶ前の区切りで前のフレームからそのフレームまで鳴り続けていた分 (飛ぶ前の位置の音)。次の
    /// フレームの区間が飛び先から始まる (そこに終わりが入る窓の前の部分は、飛ぶ前からそこまで鳴っていたのと
    /// 同じく、ファイルの標本で埋める)。止まっている間
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
        submit(.jump(Int(reach.rounded())))
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
    public var position: Float { seconds(waitingTarget ?? pendingJump ?? samplePosition) }

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
        feed?.amp(clamped)
    }

    /// 鳴っているか。``play()`` か ``loop()`` で `true` になり、``pause()``・``stop()``・
    /// 鳴り終わりで `false` になる。値はそのフレームの始まりのもの。
    public var isPlaying: Bool { playhead.isPlaying }

    // MARK: - 生の値

    /// 区間の二乗平均の平方根 (振幅の単位)。無音で 0、全振幅の正弦波で約 0.707。
    public var rms: Float { levels.rms }
    /// ``rms`` を dBFS にしたもの。0 が最大で、無音は -160 (∞ にはしない)。
    public var decibels: Float { levels.decibels }
    /// 区間の標本の絶対値の最大 (振幅の単位)。無音で 0、全振幅の音で 1。写し方は ``AudioIn/peak`` と同じで、
    /// 音量 (``amp(_:)``) を掛けた後の値。
    ///
    /// **各フレームの値は、そのフレームの区間のものである。** 値は読まれたときに解くので、`draw()` が読まなかった
    /// フレームの区間は解かれず、次のフレームの値にも混ざらない — `if 条件 { use(song.peak) }` で条件が偽だった
    /// フレームのキックは、後から読んでも落ちたままである。取りこぼしたくない値は、毎フレーム読む。
    public var peak: Float { levels.peak }
    /// 帯域ごとの大きさ (振幅の単位)。512 本で、帯域の真ん中にある全振幅の正弦波で 1。区間に終わりが入る
    /// 窓の平均。
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
        // **音を出す入り口が居ることを、録りが載せるかどうかに依らず混ぜ役に名乗らせる** — 載せない録り (実時間の
        // 時計・画面へ出す録り・MP4・GIF・連番) が、音源が居ることを 1 度だけ名乗れる ([#3125])
        let mixer = SoundTrackMixer.mixer(for: owner)
        if let injectedFlow {
            speak(through: injectedFlow)
        } else if let frameRate = owner.clock.soundFrameRate(onScreen: owner.isOnScreen) {
            // 書き出しの経路。鳴らさずに、フレームの数から位置を決める
            pace = .frames(perSecond: max(1, frameRate), origin: frame)
            // 音声トラックを載せる録りのために、混ぜ役へ名乗る。音声トラックが始まっていれば、最初からその流れで鳴る
            mixer?.register(file: self)
            if let flow = mixer?.flow { joinTrack(flow) }
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
        // 節が位置を決めているときは、ステージのラックをこのフレームまで進めてから読む。ステージと
        // このファイルのどちらが先に `supply()` を受けても、同じ位置になる
        if isRouted { feed?.stage.catchUpForFiles() }
        resumeIfStopped()
        // 列が詰まっている間に控えた操作は、詰まりが解けたここで、頼んだ順に効かせる
        drainDeferred()
        // 前のフレームで飛ぶよう頼まれていれば、このフレームを飛び先から始まる区切りの頭にする
        // (``position`` がちょうど飛び先になり、区間は飛び先から始まる)。列が詰まっていれば、解けるまで待つ
        if let target = pendingJump, !isCongested {
            pendingJump = nil
            // 飛ぶ前の区切りは、前のフレームからこのフレームまで鳴り続けていた。その分が、このフレームの区間になる
            // (飛び先の区間はまだ空)
            holdPlayedSegment()
            playhead.jump(to: target)
            beginSegment()
        }
        guard playhead.isPlaying else {
            // 止める操作の時点で解析していなかった分があれば、それを見せてから無音にする (1 フレームだけ)
            if let tail = stoppedTail, !tail.isEmpty { deferred.hold(tail) } else { deferred.silence() }
            stoppedTail = nil
            return
        }
        let played = played()
        lastPlayed = played
        // **区間は音量を掛けた形でフレームの頭に決め、解析は読まれたときまで遅らせる** (#2379)。標本が
        // 進まなかったフレーム (飛び先から始まる最初のフレームなど) の空の区間は、前の値を保つ
        holdPlayedSegment(after: played)
        // 鳴り終わったフレームは、終わりまでの区間を解析してから止まる (1 フレームより短い一発音の peak も出る)。
        // 次のフレームからは無音 (``isPlaying`` が `false` の間、値は鳴っていない音のもの)
        if playhead.settle(after: played) { halt() }
    }

    /// 区切りの中で `played` 標本鳴ったところまでの、前のフレーム以後の区間を置く。
    private func holdPlayedSegment(after played: Int? = nil) {
        guard playhead.isPlaying else { return }
        let span = playhead.span(of: samples, from: covered, after: played ?? self.played())
        covered = span.to
        deferred.hold(volume == 1 ? span : span.scaled(by: volume))
    }

    /// 止める操作の時点までの、前のフレーム以後の区間を控える。**止める前に鳴っていた分を、取りこぼさない。**
    /// 実際に鳴らしている間は、フレームの頭から ``pause()``・``stop()`` を呼ぶまでに数 ms 鳴っている。
    private func holdTail() {
        guard playhead.isPlaying else { return }
        let span = playhead.span(of: samples, from: covered, after: played())
        covered = span.to
        stoppedTail = volume == 1 ? span : span.scaled(by: volume)
    }

    /// いまの再生位置 (標本)。飛び先を待っている間も、まだ動いていない位置を返す。検査が読む。
    var samplePosition: Int { playhead.position(after: lastPlayed) }

    public func close() {
        pendingJump = nil
        waiting.removeAll()
        waitingTarget = nil
        if case .speaker(let player) = pace { player.leave() }
        // 止めて、手放す。節が消えきったら置き場が戻る (入力にも残らない)
        feed?.halt()
        feed?.release()
        feed = nil
        pace = nil
        playhead.stop()
        stoppedTail = nil
        deferred.silence()
    }

    // MARK: - エフェクトへ通す

    /// エフェクト (``SoundEffect``) の入力に足す節を返す。**最初に通されたときだけ**、実際に鳴らす
    /// 経路を ``FilePlayer`` からラックの節 (``FileNode``) へ切り替える。以後は同じ節を返す。
    ///
    /// 通されたとき鳴っていれば、いまの位置から鳴らし続ける (頭へ戻さない)。**位置は、以後どの流れでも
    /// 節が描いた標本の数から読む** (``Pace/routed``)。固定の時計と実時間でも、ファイルが自分の時計で
    /// 進めずに、ステージのラックを進める時計 (実時間なら 2 秒で打ち切る) の 1 本から導く。
    ///
    /// **節を鳴らし始める操作は、ここでは載せない。** 呼んだ側 (``SoundEffect``) が節を入力に選んでから
    /// ``nodeIsConnected()`` を呼ぶ。先に鳴らし始めると、入力に選ばれる前の節が直に出る。
    ///
    /// - Parameter stage: エフェクトが属するステージ。このファイルを作ったスケッチのものでなければ断る。
    /// - Returns: 節。断ったとき (別のスケッチ・動いていない・ラックの置き場が埋まっている) は `nil` で、
    ///   そのことを 1 度だけ知らせる。断ったファイルは、いままでどおり ``FilePlayer`` で鳴る。
    func route(into stage: SynthStage) -> FileNode? {
        if let feed {
            guard feed.stage === stage else { return refuse(.cannotProcess) }
            return feed.node
        }
        guard let owner, stage.isOwned(by: owner), !stage.isClosed, stage.pace != nil,
            pace != nil
        else { return refuse(.cannotProcess) }
        // 節を足す・入力に選ぶ・鳴らし始めるの 3 つが、**控えに回らず続けて載る**ときだけ切り替える。
        // どれかが控えに回ると、鳴らしていた音を外したのに節が鳴らない (か、入力に選ばれない節が直に鳴る) 間ができる
        guard !stage.rack.isCongested else { return refuse(.congested) }
        guard let node = stage.rack.addFile(
            samples: samples, fileRate: Double(sampleRate), amplitude: volume)
        else { return refuse(.fileCapacity) }

        // 位置は、時計を切り替える前の測り方で読む
        let playedNow = played()
        let position = playhead.position(after: playedNow)
        // 区間の番号は、ファイルの位置の通し番号 (``Playhead/span(of:from:after:)``)。ループで頭へ戻った後は通し番号が
        // 位置より大きいので、区切りを始め直しても番号がずれないよう、解析済みの終わりを位置の側へ寄せる
        let shifted = min(max(covered - (playhead.start + max(0, playedNow) - position), 0), position)
        let wasPlaying = playhead.isPlaying
        if case .speaker(let player) = pace { player.leave() }
        pace = .routed
        feed = Feed(stage: stage, node: node)
        if wasPlaying {
            // いまの位置から区切りを始め直す。窓は、始まりより前もファイルの標本で埋める (``Playhead/jump(to:)``)
            // ので、解析の値は途切れない。鳴らし始めるのは、入力に選ばれてから (``nodeIsConnected()``)
            playhead.jump(to: position)
            lastPlayed = 0
            // 前の区間の続きから (``beginSegment()`` が始まりの位置へ戻さない)
            covered = shifted
            continuedCoverage = shifted
            feed?.waitsForInput = true
        }
        return node
    }

    /// 節がエフェクトの入力に選ばれた。入力を待っていたなら、いまの位置から鳴らし始める。
    func nodeIsConnected() {
        guard feed?.waitsForInput == true else { return }
        feed?.waitsForInput = false
        if playhead.isPlaying { beginSegment() }
    }

    /// 節が位置を決めているか。
    private var isRouted: Bool {
        if case .routed = pace { return true }
        return false
    }

    /// 通せなかったことを 1 度だけ知らせて、`nil` を返す。
    private func refuse(_ kind: Notice) -> FileNode? {
        switch kind {
        case .fileCapacity:
            notice(
                kind,
                "process() could not take \"\(name)\": a sketch holds at most "
                    + "\(SynthRack.capacity) oscillators, noises, effects and sound files passed to "
                    + "effects alive together (a sound file stops counting once it is detached). "
                    + "\"\(name)\" keeps playing on its own, without the effect")
        case .congested:
            notice(
                kind,
                "process() could not take \"\(name)\" right now: the sketch sent the audio engine more "
                    + "commands in one frame than it could take at once (e.g. a very large number of "
                    + "effect or oscillator changes). \"\(name)\" keeps playing on its own, without the "
                    + "effect. Call process() again from the next frame")
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
    ///
    /// 器は最初に開いたときに手放しているので、足し直したときは、鳴らし始めるまで読み直さない
    /// (``Pace/unloaded(_:)``)。エフェクトへ通すだけなら、器は要らない。
    private func speak(through flow: SoundFlow) {
        guard let buffer else {
            pace = .unloaded(flow)
            return
        }
        startPlayer(through: flow, buffer: buffer)
    }

    private func startPlayer(through flow: SoundFlow, buffer: AVAudioPCMBuffer) {
        if let player = FilePlayer(flow: flow, buffer: buffer) {
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

    /// 音声トラックが始まった ([#3125])。鳴らさずに数で位置を進めていたファイルを、機材に出さない流れの
    /// ``FilePlayer`` へ切り替える。**位置は今の位置から続く。**
    ///
    /// 器は最初に開いたときに手放しているので、読み込んだファイルから 1 度だけ読み直す (`draw()` を止める
    /// 同期の読み込みだが、録りの頭の 1 回なので、`loadSound(_:)` と同じく 1 度だけ知らせる・[#2601])。
    /// エフェクトへ通したファイルは、ラックの節が鳴らすのでここでは何もしない。
    ///
    /// **載せられなくても、位置は数で進め続ける** (``Pace/frames``)。読み直せない・流れが受けてくれないときは、
    /// 鳴らさずに実時間へ落とさず — 実時間にすると、その録りの間だけ解析の位置が壁時計で進み、同じ設定から同じ値に
    /// ならない — 音が動画に入らないことを、事情どおりに 1 度だけ知らせる。
    ///
    /// [#2601]: https://github.com/mokume-metal/mokume/issues/2601
    /// [#3125]: https://github.com/mokume-metal/mokume/issues/3125
    func joinTrack(_ flow: SoundFlow) {
        guard case .frames = pace else { return }
        let loaded: AVAudioPCMBuffer
        if let held = buffer {
            loaded = held
        } else {
            if let owner {
                type(of: owner).noticeBlockingLoad(
                    "beginRecord() on a sketch with a SoundFile (the file is read again for the recording)",
                    instead: nil)
            }
            switch reloadBuffer() {
            case .success(let reloaded):
                loaded = reloaded
            case .failure(let why):
                notice(
                    .cannotCarry,
                    "\"\(name)\" could not be read again to put it in the recording, so its sound is not in "
                        + "the movie (\(why)). Its position still follows the frames, and its analysis keeps working")
                return
            }
        }
        guard let player = FilePlayer(flow: flow, buffer: loaded) else {
            notice(
                .cannotCarry,
                "\"\(name)\" could not be put in the recording: the audio flow of the recording could not "
                    + "take it, so its sound is not in the movie. Its position still follows the frames, and "
                    + "its analysis keeps working")
            return
        }
        player.volume = volume
        let wasPlaying = playhead.isPlaying
        // 位置は、切り替える前の測り方 (フレームの数) で読む
        let position = playhead.position(after: played())
        pace = .speaker(player)
        if wasPlaying {
            playhead.jump(to: position)
            beginSegment()
        }
    }

    /// 足し直した後に初めて鳴らすとき、器を読み直して player を作る。
    ///
    /// 読むのは `draw()` を止める同期の読み込みなので、`loadSound(_:)` と同じく知らせる ([#2601])。
    /// 読み直せなければ、鳴らさずに実時間で進め、読めなかった事情を 1 度だけ知らせる。
    ///
    /// [#2601]: https://github.com/mokume-metal/mokume/issues/2601
    private func loadPlayer(through flow: SoundFlow) {
        if let owner {
            type(of: owner).noticeBlockingLoad(
                "play() or loop() on a SoundFile attached again", instead: nil)
        }
        switch reloadBuffer() {
        case .success(let reloaded):
            startPlayer(through: flow, buffer: reloaded)
        case .failure(let why):
            pace = .realTime(origin: now())
            notice(
                .cannotReload,
                "\"\(name)\" could not be read again after it was attached back, so it is not heard "
                    + "(\(why)). Its position still follows the clock, and its analysis keeps working")
        }
    }

    /// 読み直せなかった事情。
    private enum ReloadFailure: Error, CustomStringConvertible {
        /// ファイルから作ったのではないので、読み直す先が無い。
        case noSource
        /// 読めなかった。`AudioFile.load` が名乗った事情をそのまま運ぶ
        /// (開けない・音声として読めないを取り違えない・[#2358])。
        ///
        /// [#2358]: https://github.com/mokume-metal/mokume/issues/2358
        case load(AudioFailure)
        /// 読めたが、読み込んだときのファイルと別のもの (標本の数・チャンネル数・標本化率が違う)。
        case changed

        var description: String {
            switch self {
            case .noSource:
                "it was not created from a file, so there is nothing to read it from"
            case .load(let failure):
                failure.description
            case .changed:
                "the file is no longer the one that was loaded: its length, channels or sample rate differ"
            }
        }
    }

    /// 手放した器を、読み込んだファイルから読み直す。
    private func reloadBuffer() -> Result<AVAudioPCMBuffer, ReloadFailure> {
        guard let source else { return .failure(.noSource) }
        let reloaded: AVAudioPCMBuffer
        do throws(AudioFailure) {
            reloaded = try AudioFile.load(source, path: name)
        } catch {
            return .failure(.load(error))
        }
        guard reloaded.frameLength == frameLength, reloaded.format == format else {
            return .failure(.changed)
        }
        return .success(reloaded)
    }

    /// いまの区切りの中で鳴った標本の数。
    private func played() -> Int {
        switch pace {
        case .frames(let frameRate, let origin):
            // 絶対のフレーム番号から掛けて割った位置の差。秒を足し込まないので、何フレーム目でも丸めがずれず、
            // 窓の継ぎ目 (``FrameSamples``) とも揃う
            return FrameSamples.count(
                from: origin, to: frame, perSecond: frameRate, sampleRate: Double(sampleRate))
        case .realTime(let origin):
            return Int(((now() - origin) * Double(sampleRate)).rounded(.down))
        case .speaker(let player):
            return player.played ?? lastPlayed
        case .routed:
            return feed.map { $0.node.played(generation: $0.generation) } ?? lastPlayed
        case .unloaded, nil:
            return 0
        }
    }

    // MARK: - 位置を動かす操作

    /// ラックの操作の列が詰まっているか。節を通した後だけ意味がある (``Feed``)。
    private var isCongested: Bool {
        feed?.stage.rack.isCongested ?? false
    }

    /// 操作を効かせる。**ラックの操作の列が詰まっている間は控え**、詰まりが解けたとき頼んだ順に効かせる。
    ///
    /// 詰まった列へ区切りを始める操作や止める操作を載せると、それは控えに回って、音の側へ届くまで古い区切りが
    /// 鳴り続ける。その間に位置だけを新しい区切りへ進めると、聞こえている音と ``position`` がずれる。位置を
    /// 動かす操作を、音の側へ渡せるときまで一緒に控えることで、ずれない。
    private func submit(_ operation: Operation) {
        drainDeferred()
        if waiting.isEmpty, !isCongested {
            perform(operation)
            return
        }
        waiting.append(operation)
        switch operation {
        case .jump(let target): waitingTarget = target
        case .play, .stop: waitingTarget = nil
        case .pause: break
        }
    }

    /// 控えていた操作を、列が詰まっていない間、頼んだ順に効かせる。
    private func drainDeferred() {
        while !waiting.isEmpty, !isCongested { perform(waiting.removeFirst()) }
        if waiting.isEmpty { waitingTarget = nil }
    }

    private func perform(_ operation: Operation) {
        switch operation {
        case .play(let looping):
            // 飛び先を待つのは鳴っている間だけで、鳴っている最中の play() / loop() は頭から鳴らし直す
            pendingJump = nil
            // 頭から (止めた位置から) 鳴らし直すので、エフェクトへ通したときの引き継ぎ値は古い位置のもの
            continuedCoverage = nil
            playhead.play(looping: looping)
            beginSegment()
        case .pause:
            guard playhead.isPlaying else { return }
            continuedCoverage = nil
            holdTail()
            playhead.pause(after: played())
            // 同じフレームで先に飛ぶよう頼まれていれば、止めた位置はその飛び先にする
            if let target = pendingJump {
                pendingJump = nil
                playhead.jump(to: target)
            }
            halt()
        case .stop:
            pendingJump = nil
            continuedCoverage = nil
            holdTail()
            playhead.stop()
            halt()
        case .jump(let target):
            continuedCoverage = nil
            if playhead.isPlaying {
                pendingJump = target
            } else {
                playhead.jump(to: target)
            }
        }
    }

    /// 区切りを始め直す。いまのフレーム (鳴らしているなら、いま) が区切りの始まりになる。
    private func beginSegment() {
        lastPlayed = 0
        // 通された (``route(into:)``) ときは、解析済みの終わりを引き継ぐ。そうでなければ新しい区切りの始まり
        covered = continuedCoverage ?? playhead.start
        continuedCoverage = nil
        stoppedTail = nil
        // 足し直した後に初めて鳴らすとき、ここで器を読み直す
        if case .unloaded(let flow) = pace { loadPlayer(through: flow) }
        switch pace {
        case .frames(let frameRate, _):
            pace = .frames(perSecond: frameRate, origin: frame)
        case .realTime:
            pace = .realTime(origin: now())
        case .speaker(let player):
            player.play(from: playhead.start, looping: playhead.isLooping)
        case .routed, .unloaded, nil:
            break
        }
        feed?.begin(start: playhead.start, looping: playhead.isLooping)
    }

    /// 鳴らしている player と、ラックの節を止める。
    private func halt() {
        if case .speaker(let player) = pace { player.halt() }
        feed?.halt()
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
