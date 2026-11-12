// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Accelerate
import Foundation
import MokumeCore
import MokumeDiagnostics

/// 再生できる音声ファイル。``Sketch/loadSound(_:)`` が作り、実行中のスケッチへ追加する。
///
/// 再生しながら、**現在再生している音**を解析した値を読める。値の名前と変換の仕方は ``AudioIn`` と
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
/// ## 再生・停止
///
/// | メソッド | 動作 |
/// | --- | --- |
/// | ``play()`` | 1 度再生する。末尾まで再生すると停止して先頭へ戻る |
/// | ``loop()`` | 末尾から先頭へ戻って再生し続ける |
/// | ``pause()`` | 停止して、位置を保持する。次の ``play()`` / ``loop()`` はそこから |
/// | ``stop()`` | 停止して先頭へ戻す |
/// | ``jump(_:)`` | 指定した秒の位置へシークする。停止中は位置だけを動かす |
/// | ``position`` | 現在の再生位置 (秒) |
/// | ``duration`` | 長さ (秒) |
/// | ``amp(_:)`` | 音量 (0〜1) |
/// | ``pan(_:)`` | 左右の定位 (-1〜1)。モノラルは中央で左右とも元の大きさ、ステレオはバランス |
///
/// 位置・長さ・シーク・定位の名前は Processing Sound の `position()`・`duration()`・`jump()`・`pan()` に倣った。
/// 動画 (`Movie`) では同じ量を `time` と呼ぶ — `Movie` が倣う Processing Video が `time()` と呼ぶため。
///
/// 再生中に ``play()`` か ``loop()`` を呼ぶと、先頭から再生し直す (キーを押すたびに鳴らす
/// 効果音の使い方)。一時停止して続きから再生するなら ``pause()`` と ``play()`` を組み合わせる。どのメソッドも投げない
/// ([ADR-0020] 決定 5)。
///
/// ## 解析するのは、現在再生している音
///
/// 各フレームでは、**前のフレームの再生位置から、このフレームの再生位置までに再生した全サンプル**(区間)に
/// 音量を掛け、``AudioIn`` と同じ解析に通す。停止中の値は無音 (``level`` が 0) になる。
/// ステレオのファイルはステレオのまま再生し、解析はチャンネルを平均して行う。
///
/// - ``rms``・``decibels``・``level``・``peak`` は区間全体の値。``spectrum`` は、**ファイルの位置 0 から
///   512 サンプルごと**に置いた 1024 サンプルのウィンドウのうち、終わりが区間に入るものの平均 (再生を始めた位置が途中でも、
///   ウィンドウの格子はファイルの位置に置く。ループで先頭へ戻った後は、戻らずに数え続ける)
/// - 再生を始めた最初のフレームの区間は、再生を始めてから進んだ分。``jump(_:)`` を挟んだフレームの区間は、
///   シーク前の区切りで前のフレームからそのフレームまで再生し続けていた分 (シーク前の位置の音)。シーク先の区間は
///   その次のフレームから始まる (ウィンドウの前の部分はファイルのサンプルで埋める)
/// - 1 度だけ再生して再生が終わったフレームは、ファイルの末尾までの区間を解析してから停止する (1 フレームより
///   短いワンショットの ``peak`` も出る)。次のフレームからは無音
/// - **読まれなかったフレームの区間は解析せず、次のフレームの値に混ぜない**。読んだ値は、毎フレーム解析した
///   ときと同じ。長く止まった後は、区間の終わりから 6144 サンプル (48 kHz で約 0.128 秒) までを解析する
///
/// ## エフェクトに通す
///
/// 合成音と同じエフェクトに通せる (``SoundEffect/process(_:)``)。
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
/// - **エフェクトに通した後は、ラック (合成音を生成してミックスするオーディオグラフ) で再生される。** 通すまでは、これまでどおり直接出力される。ラックでは、読み込んだサンプルを
///   合成音と同じクロックで読み出してノードとしてミックスする。通した音はエフェクトの出力を通してだけ聞こえる
/// - **ステレオはモノラルにまとめられる。** ラックのノードは中央に定位するので、ステレオのファイルも、エフェクトの出力では
///   モノラルになる。エフェクトを解除しても (``SoundEffect/stop()``)、通したファイルはラックで中央のまま再生される。
///   ``pan(_:)`` も効かない (合成した音の ``SynthSource/pan(_:)`` と同じ)
/// - **ラックのノードの上限を 1 つ使う。** 同時に存在できるノードは 64 までで、通したファイルはそのうちの 1 つ
///   (``SynthSound``)。スケッチから外す (`detach(_:)`) とノードが解放され、外したファイルを追加し直して通すと
///   ノードを取り直す。空きが無ければ通さず、そのことを 1 度だけ警告する。通せなかったファイルは直接出力される
/// - **サンプルレートが違えば、ラックのレートへリサンプリングされる。** ラックのサンプルレートは 48000 Hz (書き出しでも同じ) で、
///   レートの違うファイルを通すと、低いレートは補間で、高いレートはエイリアシングを抑えるローパスを掛けてリサンプリングする。
///   ``position``・``duration`` はファイルのレートのままの秒で返る
/// - **再生の開始・停止は約 5 ミリ秒かけてフェードイン・フェードアウトする** (合成音と同じ)。再生中に先頭から
///   再生し直すときやシークするときは、前の位置の音がフェードアウトしながら新しい位置の音がフェードインする
/// - 再生中に通しても、先頭へ戻らず、現在の位置から続く。**ただし、通す瞬間だけは継ぎ目がある** —
///   通す前に直接出力されていた音 (OS のプレーヤー) はその場で止まり、ラックのノードが約 5 ミリ秒かけてフェードインする。
///   2 つは別のクロック (プレーヤーのクロックとラックのクロック) で進んでいて、サンプル単位の精度では重ねられないので、継ぎ目で
///   音が一瞬だけ細くなる。避けるなら、再生を始める前 (`setup()`) に通す
/// - 通した後も ``play()``・``loop()``・``pause()``・``stop()``・``jump(_:)``・``amp(_:)`` は同じように働く。
///   ``position`` と解析値 (``level`` ほか) は、通さないときと同じ操作の並びから同じ値になる。**ただし、書き出し
///   (固定クロック) でサンプルレートが 48000 Hz でないファイルを、fps が 48000 を割り切れない (144 fps など)
///   ときに通すと、``position`` は通さないときと最大 1 サンプルずれる** (ラックは整数のサンプル数で進むので、
///   ファイルのサンプル位置へ換算すると端数が出る)。サンプルレートが 48000 Hz のファイルと、48000 を割り切れる fps
///   (60・30・24・100 fps など) では同じ
/// - **ラックへのコマンドのキューが詰まっている間** (1 フレームに数千の音の変更を要求するなど) は、``play()`` などの位置を
///   動かす操作は、位置と一緒にキューの詰まりが解けるまで (通常は次のフレーム) 保留する。聞こえている音と
///   ``position`` はずれない。保留中の ``isPlaying`` は、保留する前のまま (値はそのフレームの開始時点のもの)。
///   このときの ``SoundEffect/process(_:)`` は、何も変えずに拒否して 1 度だけ警告する (次のフレームから通せる)
/// - ``AudioIn`` (マイク) は通せない
///
/// Processing Sound では、`LowPass`・`Reverb` などの `process(_:)` が `SoundFile` を受け付ける。
///
/// ## エンベロープを掛ける
///
/// 合成した音と同じ ``Env`` で、音量にエンベロープを掛けられる (``Env/play(_:_:_:_:_:)-(SoundFile,_,_,_,_)``)。
/// 曲の頭の立ち上げ・終わりのフェードが、``amp(_:)`` を毎フレーム動かさずに書ける。再生中なら位置を動かさず、
/// 再生していなければ ``play()`` と同じ位置から 1 度だけ再生する。エンベロープが終わると無音になるが、再生は止まらない。
///
/// ## 書き出しでは、音を動画の音声トラックへ入れる
///
/// ウィンドウを表示して実行している間は実際に音を出し、解析の位置は実際に出力したサンプル数から読む。**固定クロックで `.mov` へ
/// 書き出す (`mokume render --out x.mov`・`beginRecord("x.mov")`) と、再生した音は動画の音声トラックに入る**
/// (LPCM・32 ビット浮動小数点・48 kHz・2 チャンネル。ステレオのファイルはステレオのまま入る)。
///
/// **操作が反映される時刻は、操作ごとに違う。** フレーム `N` の `draw()` が要求した ``play()``・``loop()``・``pause()``・
/// ``stop()``・``amp(_:)``・``pan(_:)`` は、区間 `N` の先頭のサンプルから反映される (音量は区間 `N` の先頭から変わり始め、区間 `N` の終わりまでに新しい音量に達する。途中の変化の形と長さは OS に依存するので保証しない。定位は区間 `N` の先頭から約 5 ミリ秒の直線で新しい定位に移る)。**``jump(_:)`` は、再生中は次のフレームの先頭で反映される
/// ので、区間 `N + 1` の先頭のサンプルから反映される** (区間 `N` はシーク前の位置のまま再生される。停止中は位置だけが動き、
/// 音は出さない)。
///
/// 音声トラックに入るのは、録画を要求したフレームの `draw()` が終わった時点でオーディオストリームに音源がある録画で、実時間クロック・MP4・GIF・
/// 連番画像の録画には入らない (音源があれば、そのことを 1 度だけ警告する)。
///
/// 録音しない書き出しと、ウィンドウを開かずに実行するテスト (時刻がフレーム数から決まるとき —
/// ``SketchPart/clock``) では**音を出さず**、位置を「再生を始めたフレームから進んだサンプル数」で決める。
/// サンプル数は絶対のフレーム番号 `N` から求めたサンプル位置 `⌊N × サンプルレート ÷ fps⌋` の差で、再生を始めたフレームの
/// 時刻がサンプルの境界に揃っていなくても、フレームごとの区間の境界 ([ADR-0042] 決定 6 の「時刻の対応」) とずれない。
/// どちらも同じ位置から同じ区間を切り出すので、書き出した絵は実時間で再生したときと同じ時刻の音で動き、
/// 何度書き出しても同じになる ([ADR-0028] 決定 7・[ADR-0025] の水準 2)。
///
/// エフェクトへ通したファイルは、どのクロックでも位置を**ラックのノードが生成したサンプル数**から読む (固定クロックでは
/// ラックが同じフレーム数で進み、実時間では打ち切り — 2 秒を超える停止の後は 2 秒ぶんずつ — もノードと
/// 同じに働く)。聞こえている音と ``position``・解析の位置がずれない。
///
/// 位置を進めるのはオーディオクロックで、``SketchPart/time`` ではない。``SketchPart/pauseTime()`` と
/// ``SketchPart/jumpTime(_:)`` は音を止めず、シークもしない。
///
/// 出力デバイスを開けないときは、音を出さずに実時間で位置を進め、そのことを 1 度だけ警告する。
/// 外した (`detach(_:)`) ファイルを追加し直して再生し直すときは、再生用のサンプルを読み込んだファイルから
/// もう 1 度読む (外している間は解析用のモノラルのサンプルだけを持つ)。読み直せないときも、音を出さずに実時間で
/// 位置を進め、読めなかった理由とともに 1 度だけ警告する。
/// 出力デバイスが切り替わって音が止まったときは、止まった位置から再生し直す。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
public final class SoundFile: Inlet, EffectInput, RealtimeSound {
    /// ファイルのサンプルレート (Hz)。帯域 `k` の中心は `k × sampleRate ÷ 1024` Hz。
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
    /// 左右の定位 (-1〜1。範囲へ寄せた値)。鳴らす player へ渡す。解析には掛けない (#3473)。
    private var panning: Float = 0
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
    /// ``Env`` が掛けた包絡 (#3099)。**一度も掛けていなければ `nil` で、鳴らす音も解析も掛ける前と同じ道を通る。**
    /// 位置のずれ (``FileEnvelope/offset``) は、いまの区切りの頭からの数。区切りが終わるたびに、鳴った数を
    /// 畳み込む (``foldEnvelope(after:)``)。
    private var envelope: FileEnvelope?
    /// 包絡の形の秒 (受けた値)。エフェクトへ通したときの節へ、同じ値から同じ形を作らせる。
    private var envelopeSeconds: EnvelopeArguments.Accepted?

    /// 位置を動かす操作。
    private enum Operation {
        case play(looping: Bool)
        case pause
        case stop
        case jump(Int)
        /// ``Env`` が包絡を掛ける。鳴っていなければ ``play(looping:)`` と同じ位置から 1 度だけ鳴らす。
        case envelope(EnvelopeArguments.Accepted)
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
        ///
        /// 包絡を掛けているなら、区切りを始める操作の直後に、その区切りの包絡を載せる。**まとめて 1 度に
        /// 載せる** — 音の側が区切りだけを先に読んで、前の区切りの位置のずれで 1 回描く、ということが起きない。
        mutating func begin(
            start: Int, looping: Bool, envelope: FileEnvelope?, seconds: EnvelopeArguments.Accepted?
        ) {
            generation += 1
            let segment = SynthCommand(
                op: .segment, node: UInt8(node.id),
                bits: FileNode.segment(start: start, looping: looping, generation: generation))
            guard let envelope, let seconds else {
                stage.rack.post(segment)
                return
            }
            stage.rack.postReservation([segment] + shaping(envelope, seconds))
        }

        /// いまの区切りの包絡を置き換える。
        func reshape(_ envelope: FileEnvelope, seconds: EnvelopeArguments.Accepted) {
            stage.rack.postReservation(shaping(envelope, seconds))
        }

        /// 包絡の形の値と、位置のずれを渡す操作。
        private func shaping(
            _ envelope: FileEnvelope, _ seconds: EnvelopeArguments.Accepted
        ) -> [SynthCommand] {
            let values: [(SynthParam, Float)] = [
                (.attack, seconds.attack), (.sustain, seconds.sustain), (.level, seconds.level),
                (.release, seconds.release),
            ]
            return values.map {
                SynthCommand(
                    op: .set, node: UInt8(node.id), param: $0.0, bits: UInt64($0.1.bitPattern))
            } + [
                SynthCommand(
                    op: .envelope, node: UInt8(node.id),
                    bits: UInt64(bitPattern: Int64(envelope.offset)))
            ]
        }

        /// 節を止める。
        func halt() {
            stage.rack.post(SynthCommand(op: .stop, node: UInt8(node.id)))
        }

        /// 手放す。鳴り終えた (消えきった) ら、置き場が戻る。
        func release() {
            stage.rack.post(SynthCommand(op: .release, node: UInt8(node.id)))
        }

        /// 音量を伝える。操作が溢れて受け付けられなければ `false` (#3944)。
        @discardableResult
        func amp(_ volume: Float) -> Bool {
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
        case panOutOfRange
        case panNotANumber
        case jumpNotANumber
        case energyNotANumber
        case cannotProcess
        case fileCapacity
        case congested
        /// `Env.play` の引数の知らせ。種類は ``EnvelopeArguments`` が名乗る。
        case envelope(String)
    }

    init(
        name: String, buffer: AVAudioPCMBuffer, owner: (any Sketch)?, flow: SoundFlow?,
        source: URL? = nil, decodedSamples: [Float]? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        warn: @escaping (String) -> Void = Diagnostics.warn
    ) {
        self.name = name
        self.buffer = buffer
        self.format = buffer.format
        self.frameLength = buffer.frameLength
        // 裏で解いてきたなら、解き直さない (``Sketch/requestSound(_:)``)
        self.samples = decodedSamples ?? AudioFile.mono(buffer)
        self.sampleRate = Float(buffer.format.sampleRate)
        self.channels = Int(buffer.format.channelCount)
        self.owner = owner
        self.injectedFlow = flow
        self.source = source
        self.now = now
        self.warn = warn
        playhead = Playhead(length: samples.count)
    }

    // MARK: - 鳴らす・止める

    /// 1 度再生する。末尾まで再生すると停止し、先頭へ戻る。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// func keyPressed() {
    ///     if key == " " { song?.play() }
    /// }
    /// ```
    ///
    /// ``pause()`` の後なら停止した位置から、``stop()`` の後と再生が終わった後は先頭から再生する。
    /// ``jump(_:)`` で末尾にクランプされた後も、再生が終わった後と同じ位置なので先頭から再生する。
    /// **再生中に呼ぶと、先頭から再生し直す。** ``loop()`` で再生している最中に呼んだときも
    /// 先頭から再生し直し、今度は末尾で停止する。
    public func play() {
        submit(.play(looping: false))
    }

    /// 末尾から先頭へ戻って、再生し続ける。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// func setup() throws {
    ///     song = try loadSound("assets/song.wav")
    ///     song?.loop()
    /// }
    /// ```
    ///
    /// どこから再生を始めるかは ``play()`` と同じで、再生中に呼ぶと先頭から再生し直す。
    public func loop() {
        submit(.play(looping: true))
    }

    /// 一時停止して、現在の位置を保持する。次の ``play()`` か ``loop()`` は、そこから再生する。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// func mousePressed() {
    ///     guard let song else { return }
    ///     if song.isPlaying { song.pause() } else { song.play() }
    /// }
    /// ```
    ///
    /// 停止中なら何もしない。
    public func pause() {
        submit(.pause)
    }

    /// 停止して、先頭へ戻す。次の ``play()`` か ``loop()`` は先頭から再生する。
    public func stop() {
        submit(.stop)
    }

    /// `seconds` 秒の位置へシークする。**呼んだ直後から ``position`` はシーク先を返す。**
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// func keyPressed() {
    ///     if key == "2" { song?.jump(62) }  // サビから確認する
    /// }
    /// ```
    ///
    /// 再生中なら、次のフレームでその位置から再生され、解析値もその位置の音になる。そのフレームの
    /// 区間は、シーク前の区切りで前のフレームからそのフレームまで再生し続けていた分 (シーク前の位置の音)。次の
    /// フレームの区間がシーク先から始まる (そこに終わりが入るウィンドウの前の部分は、シーク前からそこまで再生していたのと
    /// 同じく、ファイルのサンプルで埋める)。停止中
    /// (``pause()`` の後・``stop()`` の後・再生が終わった後) は位置だけを動かし、音は出さない。次の
    /// ``play()`` か ``loop()`` がそこから再生する。
    ///
    /// 0 より前は先頭、``duration`` より後は末尾にクランプする (``duration`` を渡せば、長いファイルでも末尾に達する)。NaN・無限大は位置を変えず、
    /// そのことを 1 度だけ警告する (投げない — [ADR-0020] 決定 5)。どれも `Movie` の `jump(_:)` と同じ。
    ///
    /// 同じフレームで後から ``play()`` か ``loop()`` を呼ぶと、再生中なら先頭から再生し直す
    /// (後から呼んだメソッドが優先される)。``stop()`` は先頭へ戻す。**末尾へシークして再生し続けると、残りが無いので
    /// 無音で停止する** (先頭の音は出ない)。停止中に末尾へシークした後の ``play()`` は先頭から再生する。
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
        submit(.jump(Self.landing(seconds, sampleRate: sampleRate, count: samples.count)))
    }

    /// `seconds` 秒 (公開の単精度) の標本の番号。0〜`count` へ寄せる。
    ///
    /// 寄せてから整数にする (大きな秒のまま整数へ直すと溢れる)。いちばん近い標本へ丸める — 切り捨てると、
    /// 単精度で 5.1 をわずかに割る `jump(5.1)` が 1 標本手前になり、`position` が 5.1 に戻らない。
    /// **公開の長さ (``duration``。標本の数 ÷ 標本化率を単精度へ丸めたもの) 以上の秒は、終わりの標本 (`count`) へ
    /// 寄せる** — 丸めの向きによっては、長いファイル (48 kHz で 250 秒ほどから) で `jump(duration)` が
    /// 1 標本手前に着き、終わりの位置と見なされず、1 標本だけ鳴って終わる (#3303)。
    nonisolated static func landing(_ seconds: Float, sampleRate: Float, count: Int) -> Int {
        let length = Float(Double(count) / Double(sampleRate))
        if seconds >= length { return count }
        let reach = min(max(Double(seconds) * Double(sampleRate), 0), Double(count))
        return Int(reach.rounded())
    }

    /// 現在の再生位置 (秒)。0 から ``duration`` まで。``jump(_:)`` を呼んだ後なら、そのシーク先。
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
    /// 位置を進めるのはオーディオクロックで、``SketchPart/time`` ではない。書き出し (固定クロック) では、再生を
    /// 始めてから進んだフレーム数で決まるので、同じフレームは常に同じ位置で描かれる。値はその
    /// フレームの開始時点のもの (``isPlaying`` と同じ)。停止中は停止した位置、再生が終わった後は 0。
    public var position: Float { seconds(waitingTarget ?? pendingJump ?? samplePosition) }

    /// 長さ (秒)。サンプル数 ÷ ``sampleRate``。
    public var duration: Float { seconds(samples.count) }

    /// ファイルのチャンネルの数。モノラルは 1、ステレオは 2。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// guard let song else { return }
    /// if song.channels == 2 {
    ///     // 左右のあるファイルは、左右に分けて丸を描く
    ///     circle(width * 0.3, height / 2, 40 + song.level * 200)
    ///     circle(width * 0.7, height / 2, 40 + song.level * 200)
    /// } else {
    ///     circle(width / 2, height / 2, 40 + song.level * 200)
    /// }
    /// ```
    ///
    /// **読み込んだファイルの数をそのまま返し、3 チャンネル以上でも 2 に畳まない** (Processing Sound の
    /// `SoundFile.channels()` と同じ)。解析の値 (``level`` など) はチャンネルを平均したものだが、この数は平均する前のもの。
    /// 外した (`detach(_:)`) 後も、追加し直した後も同じ値を返す。
    public let channels: Int

    /// ファイルの標本 (フレーム) の数。1 チャンネルあたりの数で、チャンネルの数は掛けない。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// guard let song else { return }
    /// // 再生位置を、標本の番号で描く
    /// let current = Int(song.position * song.sampleRate)
    /// text("\(current) / \(song.frames)", 20, 40)
    /// ```
    ///
    /// 読み込んだ標本の数そのもので、``duration`` × ``sampleRate`` の近似ではない。``duration`` は単精度の秒に
    /// 丸めてあるので、掛け直して `Int` に切り捨てると、短いファイル (48 kHz で 7 標本から) でも 1 少なくなることがあり、
    /// 長いファイル (約 512 秒から) では 2 以上ずれうる。標本の数が要るときはこちらを使う。Processing Sound の
    /// `SoundFile.frames()` に当たる。外した後も、追加し直した後も同じ値を返す。
    public var frames: Int { samples.count }

    /// 標本の位置を秒にする。
    private func seconds(_ sample: Int) -> Float {
        Float(Double(sample) / Double(sampleRate))
    }

    /// 音量を設定する。0 で無音、1 で読み込んだままの大きさ。既定は 1。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// song?.amp(mouseX / width)
    /// ```
    ///
    /// 解析値も、この音量を掛けた音のものになる。0〜1 の外は端にクランプし、NaN・無限大は
    /// 無視する。どちらもそのことを 1 度だけ警告する (投げない — [ADR-0020] 決定 5)。
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
        // 操作が溢れて節が受け付けなかったら、音量を変えない — 解析は ``volume`` を掛けた標本で読むので、
        // 変えると聞こえる音と解析の値が食い違う。捨てたことはステージが 1 度だけ知らせる (#3944)
        if let feed, !feed.amp(clamped) { return }
        self.volume = clamped
        if case .speaker(let player) = pace { player.volume = clamped }
    }

    /// 左右の定位を設定する。-1 で左、0 で中央、1 で右。既定は 0。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// song?.pan(map(mouseX, 0, width, -1, 1))
    /// ```
    ///
    /// - **モノラルのファイル**は、左右を合わせた大きさが変わらない定位で、**中央では左右とも元の大きさ** (1 倍)
    ///   になる (左 = √2·cos θ・右 = √2·sin θ。θ は -1〜1 を 0〜π/2 へ写したもの)。**代償: 端 (`pan(-1)`・`pan(1)`)
    ///   では片側が元の √2 倍 (+3 dB) になり、``amp(_:)`` が 1 で目一杯の大きさのファイルは 1 を越えうる。**
    ///   合成した音の ``SynthSource/pan(_:)`` は中央で左右とも 1/√2 なので、同じ定位でも基準の大きさが違う
    /// - **ステレオのファイル**はバランスで、反対側にだけ 1 - |位置| を掛ける。`pan(-1)` で右が無音・左は元の左のまま。
    ///   左右を畳まない。3 チャンネル以上のファイルは、先頭の 2 チャンネルを左・右として同じに掛ける
    /// - **解析の値 (``level``・``rms`` ほか) は定位で変わらない** — 解析するのは定位を掛ける前の音
    ///   (合成した音の解析と同じ)
    /// - フレーム `N` の `draw()` で呼ぶと、区間 `N` の先頭のサンプルから約 5 ミリ秒かけて新しい定位へ移る
    ///   (書き出しでも同じ操作から同じサンプルになる)。停止中に呼べば、次に再生した先頭からその定位で鳴る
    /// - **エフェクトに通したファイルの定位は、エフェクトの出力で中央になる** (``SynthSource/pan(_:)`` と同じ)。
    ///   エフェクトを解除しても中央のまま
    ///
    /// -1〜1 の外は端にクランプし、NaN・無限大は無視する。どちらもそのことを 1 度だけ警告する (投げない —
    /// [ADR-0020] 決定 5。``SynthSource/pan(_:)`` と同じ扱い)。Processing Sound の `SoundFile.pan()` に当たる。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func pan(_ position: Float) {
        guard position.isFinite else {
            notice(
                .panNotANumber,
                "pan() got a value that is not a number, or an infinite one, so the position of "
                    + "\"\(name)\" stays at \(panning)")
            return
        }
        let clamped = min(max(position, -1), 1)
        if clamped != position {
            notice(
                .panOutOfRange,
                "pan() takes a position from -1 to 1, so \(position) was clamped to \(clamped) for "
                    + "\"\(name)\"")
        }
        panning = clamped
        if case .speaker(let player) = pace { player.pan = clamped }
    }

    /// 再生中か。``play()`` か ``loop()`` で `true` になり、``pause()``・``stop()``・
    /// 再生の終了で `false` になる。値はそのフレームの開始時点のもの。
    ///
    /// ``Env/play(_:_:_:_:_:)-(SoundFile,_,_,_,_)`` で再生を始めたときも `true` になり、エンベロープが終わって無音になっても
    /// `true` のまま (再生は止まらない)。
    public var isPlaying: Bool { playhead.isPlaying }

    // MARK: - 包絡

    /// ``Env`` が、このファイルの音量に包絡を頭から掛ける (#3099)。鳴っていなければ ``play()`` と同じ位置から
    /// 1 度だけ鳴らす。引数の検めは合成した音源と同じ ``EnvelopeArguments`` を通す (形はファイルの標本化率で数える)。
    func triggerEnvelope(attack: Float, sustain: Float, level: Float, release: Float) {
        guard
            let accepted = EnvelopeArguments.accept(
                attack: attack, sustain: sustain, level: level, release: release,
                sampleRate: Double(sampleRate), subject: "\"\(name)\"",
                notice: { key, message in notice(.envelope(key), message) })
        else { return }
        submit(.envelope(accepted))
    }

    /// 受けた秒の値から、ファイルの標本の数の形を作る。
    private func envelopeShape(_ seconds: EnvelopeArguments.Accepted) -> EnvelopeShape {
        EnvelopeShape(
            attack: seconds.attack, sustain: seconds.sustain, level: seconds.level,
            release: seconds.release, sampleRate: Double(sampleRate))
    }

    /// いまの区切りが `played` 標本鳴ったところで終わる。鳴った数を包絡の位置のずれへ畳み込み、次の区切りの頭から
    /// 数え直せるようにする。**区切りを終える操作 (止める・飛ぶ・鳴らし直す・鳴り終わる・節や録りへ移す) が、
    /// 再生位置を動かす前に呼ぶ。**
    private func foldEnvelope(after played: Int) {
        guard envelope != nil else { return }
        envelope?.offset += playhead.heard(after: played)
    }

    /// 鳴らしている音の側へ、いまの区切りの包絡を渡し直す。
    private func reshapeEnvelope() {
        guard let envelope, let envelopeSeconds else { return }
        switch pace {
        case .speaker(let player):
            player.reshape(envelope)
        case .routed:
            feed?.reshape(envelope, seconds: envelopeSeconds)
        case .frames, .realTime, .unloaded, nil:
            // 鳴らさない (解析だけが包絡を読む)
            break
        }
    }

    /// 区間に音量と包絡を掛ける。**包絡を掛けていなければ、掛ける前と同じ式** (音量だけ)。
    ///
    /// 区間の番号から区切りの中で鳴った数を引き (``Playhead`` の番号は、いまの区切りの頭が `shift + start`)、
    /// 鳴らす側と同じ ``FileEnvelope/gain(atPlayed:)`` で倍率を決める。区間の前の履歴のうち、包絡を掛けた時点より前は
    /// ``FileEnvelope/before``。
    private func shaped(_ span: AudioSpan) -> AudioSpan {
        guard let envelope else { return volume == 1 ? span : span.scaled(by: volume) }
        let head = playhead.shift + playhead.start
        var samples = span.samples
        for index in samples.indices {
            samples[index] *= volume * envelope.gain(atPlayed: span.base + index - head)
        }
        return AudioSpan(base: span.base, samples: samples, from: span.from)
    }

    // MARK: - 生の値

    /// 区間の二乗平均平方根 (振幅の単位)。無音で 0、フルスケールの正弦波で約 0.707。
    public var rms: Float { levels.rms }
    /// ``rms`` を dBFS にしたもの。0 が最大で、無音は -160 (∞ にはしない)。
    public var decibels: Float { levels.decibels }
    /// 区間のサンプルの絶対値の最大 (振幅の単位)。無音で 0、フルスケールの音で 1。求め方は ``AudioIn/peak`` と同じで、
    /// 音量 (``amp(_:)``) を掛けた後の値。
    ///
    /// **各フレームの値は、そのフレームの区間のものである。** 値は読まれたときに解析するので、`draw()` が読まなかった
    /// フレームの区間は解析されず、次のフレームの値にも混ざらない — `if 条件 { use(song.peak) }` で条件が偽だった
    /// フレームのキックは、後から読んでも失われたままである。取りこぼしたくない値は、毎フレーム読む。
    public var peak: Float { levels.peak }
    /// 帯域ごとの大きさ (振幅の単位)。512 本で、帯域の中心にあるフルスケールの正弦波で 1。区間に終わりが入る
    /// ウィンドウの平均。
    public var spectrum: [Float] { levels.spectrum }

    // MARK: - 0〜1 へ写した値

    /// 音の大きさを 0〜1 にしたもの。-60 dBFS 以下で 0、0 dBFS で 1。変換の仕方は ``AudioIn/level`` と同じ。
    public var level: Float { levels.level }
    /// ``spectrum`` を帯域ごとに 0〜1 にしたもの。変換の仕方は ``level`` と同じ。
    public var spectrumLevels: [Float] { levels.spectrumLevels }

    // MARK: - 帯域・波形・拍

    /// 周波数の範囲 `low`〜`high` (Hz) の大きさを 0〜1 で返す。低音の脈動を、帯域の番号を計算せずに取得できる。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// if let song { circle(width / 2, height / 2, 100 + song.energy(from: 20, to: 140) * 300) }
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
    public func energy(from low: Float, to high: Float) -> Float {
        let result = AudioAnalysis.energy(of: levels.spectrum, from: low, to: high, sampleRate: sampleRate)
        if !result.isNumber {
            notice(
                .energyNotANumber,
                "energy() got a value that is not a number, or an infinite one, so it returns 0 for "
                    + "\"\(name)\"")
        }
        return result.value
    }

    /// 区間の終わりの 1024 サンプル (古い順)。波形を描くのに使う。
    ///
    /// <!-- example: 文脈 var song: SoundFile? -->
    /// ```swift
    /// if let song {
    ///     noFill()
    ///     stroke(255)
    ///     beginShape()
    ///     for (i, s) in song.waveform.enumerated() { vertex(Float(i) / 1024 * width, height * 0.8 + s * 100) }
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
    /// <!-- example: 文脈 var song: SoundFile?; var flash: Float = 0 -->
    /// ```swift
    /// if song?.isBeat == true { flash = 1 }
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
    /// **再生が始まったときから**履歴を蓄積し、読まないフレームの区間も毎フレーム処理する。どのフレームから読み始めても
    /// ビートの有無は変わらず、読む間隔を変えてもビートの位置は同じ (コストはサンプルあたり二乗和 1 回で、1 フレームに数 µs)。
    /// 履歴は区間の番号 (ファイルの位置) が連続しているかで判断する。ループで先頭へ戻っても、一時停止した位置から続けても、出力デバイスが
    /// 切り替わって再生し直しても履歴は続く。先頭から再生し直す・シークすると履歴を捨ててやり直し、シーク先から約 85 ミリ秒は
    /// ビートが出ない (ファイルの先頭からなら最初のアタックもビートになる)。シークするフレームには、シーク前の区間のビートが残る。
    /// ループしないファイルの末尾では、512 サンプルに満たない最後のブロックも判定する。
    /// サンプルを取りこぼしたとき (区間の上限を越えたとき) は、履歴を捨ててやり直し、取りこぼした区間ではビートを出さない。
    /// 区間の上限があるので、約 7.8 fps (48 kHz) より遅いフレームでは区間の先頭が切り捨てられ続け、ビートは fps に依存する。
    ///
    /// **判定は音量 (``amp(_:)``) を掛けた後のサンプルで行う** (``level``・``waveform`` と同じサンプル)。音量を急に変えると
    /// ビートが出る・消える (-60 dBFS 相当を越えない小さい音量では出ない)。
    public var isBeat: Bool { deferred.isBeat }

    /// 拍の状態が区間を処理した回数。検査が読む — 一度も読まれなければ 0。
    var beatSteps: Int { deferred.beatSteps }

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
            // 画面へ出している経路は、時計によらず鳴らす (フレームの時計のウィンドウも・#2601)
            speak(through: .speakers)
        }
        // 鳴らさないと決まったなら、器は要らない (鳴らすなら player が持っている)
        buffer = nil
        if playhead.isPlaying { beginSegment() }
    }

    public func supply() {
        deferred.beginFrame()
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
            foldEnvelope(after: played())
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
        if playhead.hasEnded(after: played) { foldEnvelope(after: played) }
        // 鳴り終わったフレームは、終わりまでの区間を解析してから止まる (1 フレームより短い一発音の peak も出る)。
        // 次のフレームからは無音 (``isPlaying`` が `false` の間、値は鳴っていない音のもの)
        if playhead.settle(after: played) {
            // 鳴り終わった。閉じていない端数のブロックにだけある立ち上がりも、このフレームの拍にする
            deferred.endStream()
            halt()
        }
    }

    /// 区切りの中で `played` 標本鳴ったところまでの、前のフレーム以後の区間を置く。
    private func holdPlayedSegment(after played: Int? = nil) {
        guard playhead.isPlaying else { return }
        let span = playhead.span(of: samples, from: covered, after: played ?? self.played())
        covered = span.to
        deferred.hold(shaped(span))
    }

    /// 止める操作の時点までの、前のフレーム以後の区間を控える。**止める前に鳴っていた分を、取りこぼさない。**
    /// 実際に鳴らしている間は、フレームの頭から ``pause()``・``stop()`` を呼ぶまでに数 ms 鳴っている。
    private func holdTail(after played: Int) {
        guard playhead.isPlaying else { return }
        let span = playhead.span(of: samples, from: covered, after: played)
        covered = span.to
        stoppedTail = shaped(span)
    }

    /// いまの再生位置 (標本)。飛び先を待っている間も、まだ動いていない位置を返す。検査が読む。
    var samplePosition: Int { playhead.position(after: lastPlayed) }

    public func close() {
        pendingJump = nil
        waiting.removeAll()
        waitingTarget = nil
        if case .speaker(let player) = pace { player.leave() }
        // 足し直して鳴らしても、包絡は止めた所から続く
        foldEnvelope(after: lastPlayed)
        // 止めて、手放す。節が消えきったら置き場が戻る (入力にも残らない)
        feed?.halt()
        feed?.release()
        feed = nil
        pace = nil
        playhead.stop()
        stoppedTail = nil
        deferred.forget()
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
        let wasPlaying = playhead.isPlaying
        if case .speaker(let player) = pace { player.leave() }
        pace = .routed
        feed = Feed(stage: stage, node: node)
        if wasPlaying {
            // いまの位置から区切りを始め直す。ウィンドウは、始まりより前もファイルの標本で埋める (``Playhead/carry(after:)``)
            // ので、解析の値は途切れない。鳴らし始めるのは、入力に選ばれてから (``nodeIsConnected()``)
            foldEnvelope(after: playedNow)
            playhead.carry(after: playedNow)
            lastPlayed = 0
            // 前の区間の続きから (``beginSegment()`` が始まりの位置へ戻さない)。標本の流れは続く (飛んだのではない)
            // ので、**区間の番号も続ける** — 番号を位置の側へ付け直すと、ループで何周かした後はウィンドウの格子が
            // ずれて、通さないときと別の値になる (#3268)。番号が続くので、拍の状態にも伝えなくてよい (履歴は捨てられない)
            continuedCoverage = covered
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
            player.pan = panning
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
    /// 同期の読み込みだが、録りの頭の 1 回である。画面へ出す実行では `loadSound(_:)` と同じく 1 度だけ知らせ、
    /// 書き出しでは知らせない — ``noticeRereadForTrack()``・[#2601])。
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
            noticeRereadForTrack()
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
        player.pan = panning
        let wasPlaying = playhead.isPlaying
        // 位置は、切り替える前の測り方 (フレームの数) で読む
        let playedNow = played()
        pace = .speaker(player)
        if wasPlaying {
            // 同じ音が続くので、区間の番号も続ける (``Playhead/carry(after:)``)。位置の側へ付け直すと、ループで何周かした後は
            // ウィンドウの格子がずれて、載せないときと別の値になる (#3268)
            foldEnvelope(after: playedNow)
            playhead.carry(after: playedNow)
            continuedCoverage = covered
            beginSegment()
        }
    }

    /// 録りの頭で器を読み直すことを、``BlockingLoads`` に知らせる。**画面へ出す実行だけ** ([#3125])。
    ///
    /// 同期の読み込みが困るのは、画面へ出しながら回すとき (フレームが遅れて見える) である。書き出し
    /// (`mokume render`・画面へ出さない固定の時計) は、フレームの番号で進めて絵を抜かないので、読み直す間待つ
    /// だけで、`setup()` で読むよう案内しても当たらない。
    ///
    /// [#3125]: https://github.com/mokume-metal/mokume/issues/3125
    func noticeRereadForTrack() {
        guard let owner, owner.isOnScreen else { return }
        owner.noticeBlockingLoad(
            "beginRecord() on a sketch with a SoundFile (the file is read again for the recording)",
            instead: nil)
    }

    /// 足し直した後に初めて鳴らすとき、器を読み直して player を作る。
    ///
    /// 読むのは `draw()` を止める同期の読み込みなので、`loadSound(_:)` と同じく知らせる ([#2601])。
    /// 読み直せなければ、鳴らさずに実時間で進め、読めなかった事情を 1 度だけ知らせる。
    ///
    /// [#2601]: https://github.com/mokume-metal/mokume/issues/2601
    private func loadPlayer(through flow: SoundFlow) {
        if let owner {
            owner.noticeBlockingLoad(
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
            // ウィンドウの継ぎ目 (``FrameSamples``) とも揃う
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
        // 包絡は位置を動かさない (鳴っていなければ、止めた位置 = 控えた飛び先から鳴らす)
        case .pause, .envelope: break
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
            if playhead.isPlaying { foldEnvelope(after: played()) }
            playhead.play(looping: looping)
            beginSegment()
        case .pause:
            guard playhead.isPlaying else { return }
            continuedCoverage = nil
            // 区間・包絡の位置・止めた位置を、同じ 1 回の読みから求める (実際に鳴らしている間は、読むたびに進む)
            let playedNow = played()
            holdTail(after: playedNow)
            foldEnvelope(after: playedNow)
            playhead.pause(after: playedNow)
            // 同じフレームで先に飛ぶよう頼まれていれば、止めた位置はその飛び先にする
            if let target = pendingJump {
                pendingJump = nil
                playhead.jump(to: target)
            }
            halt()
        case .stop:
            pendingJump = nil
            continuedCoverage = nil
            let playedNow = played()
            holdTail(after: playedNow)
            foldEnvelope(after: playedNow)
            playhead.stop()
            halt()
        case .envelope(let seconds):
            let shape = envelopeShape(seconds)
            envelopeSeconds = seconds
            guard playhead.isPlaying else {
                // 鳴っていなければ、``play()`` と同じ位置から 1 度だけ鳴らす (Processing Sound の `Env.play` が
                // `input.play()` を呼ぶのと同じ)。形は新しい区切りの頭から
                envelope = FileEnvelope(
                    shape: shape, offset: 0, before: envelope?.gain(atPlayed: 0) ?? 1)
                continuedCoverage = nil
                playhead.play(looping: false)
                beginSegment()
                return
            }
            // 鳴っていれば位置を動かさず、いま (区切りの中で鳴った所) から形を掛け直す。書き出しではフレームの頭、
            // 実際に鳴らしているなら音の側が描いた所
            let origin = playhead.heard(after: played())
            envelope = FileEnvelope(
                shape: shape, offset: -origin, before: envelope?.gain(atPlayed: origin) ?? 1)
            reshapeEnvelope()
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
        // 通された (``route(into:)``) ときは、解析済みの終わりを引き継ぐ。そうでなければ新しい区切りの始まり。
        // 拍の履歴が続くかは、ここでは決めない — 次の区間の始まりが前の区間の終わりに続いているか (番号の連続) を
        // ``BeatTracker`` が見る。同じ位置から続けば残り、頭から鳴らし直す・飛ぶと捨てる
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
            player.play(from: playhead.start, looping: playhead.isLooping, envelope: envelope)
        case .routed, .unloaded, nil:
            break
        }
        feed?.begin(
            start: playhead.start, looping: playhead.isLooping, envelope: envelope,
            seconds: envelopeSeconds)
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
        // 鳴り終わっていても、止めた位置から鳴らし直しても、区切りはここで終わる
        foldEnvelope(after: lastPlayed)
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
        // 位置は連続している (止めた位置からそのまま鳴らし直す)。区間の番号だけ、ループで頭へ戻った分を畳み直すので、
        // 流れが続くことを拍の状態に伝える
        deferred.rebase(to: covered)
    }

    private func notice(_ kind: Notice, _ message: String) {
        guard noticed.insert(kind).inserted else { return }
        warn(message)
    }
}
