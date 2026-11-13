// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import MokumeCore
import Synchronization

/// 読み込んだ音を、音の流れ (``SoundFlow``) で実際に鳴らす。AVFAudio で鳴らすのはこの型だけ
/// である ([ADR-0042] 決定 6 の「薄い層に閉じる」)。
///
/// ## 標本は自分で渡す
///
/// 器の標本は `AVAudioSourceNode` で、描き出しのたびに自分で渡す (``FileVoice``)。`AVAudioPlayerNode` に
/// 器を積んで ``AVAudioPlayerNode/play()`` を呼ぶ形は、**機材に出さない流れでは使わない** — 描いている
/// 途中の流れへ鳴らし始める命令は player の側のスレッドで取り込まれ、呼んだ直後の `renderOffline` に
/// 間に合わないと、ウィンドウまるごと (数百標本) 無音になる (#3277・M3 Max で 400 回のうち 10% 前後)。取り込みを
/// 確かめる手立ては無く、待つのは保証にならない。
///
/// **命令は 1 つの原子値で音の側へ渡す。** 呼んだ側が書き、次の描き出しの先頭で音の側が読む。機材に出さない
/// 流れの `renderOffline` は呼んだスレッドの中で節を呼ぶので、書き込みは必ず描き出しより前に済んでいて、
/// 直後のウィンドウの先頭の標本から鳴る。実機に出す流れでも同じ原子値を、音の realtime スレッドが先頭で読む。
///
/// ## 位置は描いた数から読む
///
/// 鳴らし始めるたびに区切りを始め直すので、音の側が数える標本の数 (``FileVoice/played(generation:)``) は
/// 区切りの始まりから描いた数になる。これを ``Playhead`` の `played` として渡す — 機材の時計で進むので、
/// 長く回しても鳴っている音と解析の位置がずれない。数えるのは器の標本化率で、鳴らし終えた後も止めるまで
/// 数え続ける。
///
/// ## 途中から鳴らすときはコピーしない
///
/// 止めた位置から鳴らし直すとき (``Playhead/pause(after:)`` の後・途中からのループ) は、読む位置を
/// 動かすだけで、器をコピーしない。曲 1 本ぶんの写しを鳴らし直すたびに作ると、それだけでフレームが詰まる。
///
/// ## 左右は自分で配る (#3473)
///
/// 定位 (``pan``) は、節の `AVAudioMixing.pan` ではなく ``FileVoice`` が左右の倍率を掛けて決める。節の
/// `pan` は、機材に出さない流れ (macOS 27) で 1 チャンネルにも 2 チャンネルにも効かなかった。**1 チャンネルの器は
/// 常に 2 チャンネルの節にして、左右へ同じ標本を配る** (#3473 の 2026-11-13 の決定・[ADR-0042] 決定 6)。定位を
/// 入れる前は 1 チャンネルの節を流れの混ぜる節が配っていて、混ぜる節の出口が 48 kHz (書き出し) などなら左右とも
/// 1 倍だったので、既定 (`pan` 0) では標本が 1 つも変わらない。**出口が 44.1 kHz のときだけ**、混ぜる節は
/// 1 チャンネルの節を左右とも約 1/√2 倍で配っていた (macOS 27 で測った)。そこでは既定のモノラルが約 3 dB 上がり、
/// ほかの出口と同じ大きさに揃う。3 チャンネル以上の器は器のままの節で、定位は先頭の 2 チャンネルにだけ掛ける。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
final class FilePlayer {
    let flow: SoundFlow
    private let voice: FileVoice
    private let node: AVAudioSourceNode
    /// いまの区切りの世代。主スレッドだけが進める。命令を出すたびに 1 つ進み、``FileVoice`` が区切りの
    /// 数を世代ごとに数える。
    private var generation = 0
    /// 鳴らしている (止めていない) か。止めている間は、描いた数は読めない。
    private var isPlaying = false

    /// 流れに入れる。鳴らせなければ (出力が開けない・標本が読めない) `nil`。
    ///
    /// - Parameters:
    ///   - rate: 最初の速さ (#3473)。
    ///   - kernel: 最初の速さが 1 を越えるときの低域通過の係数。
    init?(flow: SoundFlow, buffer: AVAudioPCMBuffer, rate: Double = 1, kernel: RateKernel? = nil) {
        self.flow = flow
        guard let voice = FileVoice(buffer: buffer, rate: rate, kernel: kernel),
            let format = Self.nodeFormat(for: buffer.format)
        else { return nil }
        self.voice = voice
        node = Self.makeNode(voice: voice, format: format)
        guard flow.join(node, format: format) else { return nil }
    }

    /// 節の形式。1 チャンネルの器は、左右へ配るので 2 チャンネルにする。ほかは器のまま。
    private static func nodeFormat(for format: AVAudioFormat) -> AVAudioFormat? {
        guard format.channelCount == 1 else { return format }
        return AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)
    }

    /// 音量 (0〜1)。
    var volume: Float {
        get { node.volume }
        set { node.volume = newValue }
    }

    /// 定位 (-1〜1。範囲へ寄せた値を渡す)。次の描き出しの先頭から移り始める (``FileVoice/pan(_:)``)。
    var pan: Float = 0 {
        didSet { voice.pan(pan) }
    }

    /// 速さ (#3473) を頼む。音の側は次の描き出しの先頭で受け、受けた点を ``absorbRate()`` が返す。
    ///
    /// - Parameter kernel: 速さが 1 を越えるときの低域通過の係数。
    func rate(_ rate: Double, kernel: RateKernel?) {
        voice.link.request(rate, kernel: kernel)
    }

    /// 音の側が速さを受けた点。新しく受けていなければ `nil`。`current` は、受けたのがいまの区切りの中か (違えば、
    /// いまの区切りを始める前に受けた — いまの区切りは頭からその速さ)。
    func absorbRate() -> (anchor: RateLink.Anchor, current: Bool)? {
        guard let anchor = voice.link.absorb() else { return nil }
        return (anchor, isPlaying && FileVoice.matches(anchor.generation, current: generation))
    }

    /// 区切りの始まりから描いた標本の数。まだ描いていなければ 0、鳴らしていなければ `nil`。
    var played: Int? {
        guard isPlaying else { return nil }
        return voice.played(generation: generation)
    }

    /// `start` 標本目から鳴らす。前の区切りは捨てる。
    ///
    /// 命令は次の描き出しの先頭で効く。機材に出さない流れでは、呼んだ直後の `renderOffline` の最初の標本が
    /// `start` 標本目になる。
    ///
    /// - Parameter envelope: この区切りに掛ける包絡 (#3099)。`nil` なら掛けない (器の標本をそのまま渡す)。
    ///   **区切りを始める命令より先に渡す** — 音の側が新しい区切りを読んだとき、その区切りの包絡が必ず見える。
    ///
    /// - Parameter origin: 区切りの錨 (``FileVoice/send(_:generation:origin:)``)。`nil` なら `start` から。
    func play(
        from start: Int, looping: Bool, envelope: FileEnvelope? = nil,
        origin: (position: Double, elapsed: Int)? = nil
    ) {
        generation += 1
        isPlaying = true
        if let envelope { voice.send(envelope, generation: generation) }
        voice.send(.play(start: start, looping: looping), generation: generation, origin: origin)
    }

    /// 鳴らしている区切りの包絡を置き換える (#3099)。次の描き出しの先頭で効く。止めていれば何もしない。
    func reshape(_ envelope: FileEnvelope) {
        guard isPlaying else { return }
        voice.send(envelope, generation: generation)
    }

    /// 止める。積んだ区切りは捨てる。
    func halt() {
        generation += 1
        isPlaying = false
        voice.send(.halt, generation: generation)
    }

    /// 流れから外す。
    func leave() {
        halt()
        flow.leave(node)
    }

    /// 音の側で走る手続きを作る。
    ///
    /// **隔離の外で作る。** 手続きは音の realtime スレッド (機材に出さない流れでは `renderOffline` を呼んだ
    /// スレッド) で呼ばれるので、main actor に属させると動的な隔離検査 (SE-0423) で落ちる
    /// ([ADR-0042] 決定 7)。
    ///
    /// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
    nonisolated private static func makeNode(voice: FileVoice, format: AVAudioFormat)
        -> AVAudioSourceNode
    {
        AVAudioSourceNode(format: format) { isSilence, _, frameCount, bufferList in
            // 無音だけを書いたときは、混ぜる側が読まずに飛ばせるよう印を立てる (止めている間・鳴らし終えた後)
            isSilence.pointee = ObjCBool(
                voice.render(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(bufferList)))
            return noErr
        }
    }
}

/// 読み込んだ器の標本を、描き出しのたびに音の側で渡す ([#3277])。
///
/// ## 誰がどの値をどのスレッドで書き、読むか
///
/// - ``command`` (**主スレッドが書き、音の側が読む**): 区切りの始まりの標本・ループか・止めか・世代を詰めた
///   1 つの原子値。``send(_:generation:)`` が release で 1 回書き、``render(frames:into:)`` が描き出しの
///   先頭で acquire で 1 回読む。前回適用した語と違えば区切りを始め直す。同じ描き出しの前に命令が複数載っても
///   最後の語だけが効き、ウィンドウの途中で命令が混ざらない。
/// - ``progress`` (**音の側が書き、主スレッドが読む**): 世代と、区切りの始まりから描いた標本の数を詰めた
///   1 つの原子値。描き出しの末尾で release で書き、``played(generation:)`` が acquire で読む。世代と数を
///   別々に読んで取り違えない。
/// - 位置・数・ループ・適用した語 (``applied``): **音の側だけが読み書きする**。主スレッドは触らない。
/// - 器の標本 (``channels``): init で作ったあとは読むだけで、書き換えない。
/// - 包絡 (`envelope` で始まる原子値と ``envelopeSequence``。#3099): **主スレッドが書き、音の側が読む**。形・位置のずれ・
///   区切りの世代は 1 語に収まらないので、版の番号で挟む (seqlock)。主スレッドは版を奇数にしてから各値を書き、
///   偶数に戻す (どれも release)。音の側は版・各値・版の順に読み (値は acquire)、版が偶数で前後が同じときだけ
///   受ける。書いている途中に読んだら受けず、次の描き出しで読み直す — **待たない**。包絡を掛けていないファイルは
///   版が 0 のままで包絡を受けず待ちもせず、標本は器の標本そのまま (掛ける前と 1 つも変わらない)。
/// - 定位 (``panTarget``。#3473): **主スレッドが書き、音の側が読む**。単精度のビット列を 1 つの原子値で渡す。
///   音の側は描き出しの先頭で読み、変わっていれば、そこから ``panRamp`` 標本かけて直線で移る (移る途中の位置・
///   倍率は音の側だけが持つ)。移り方は描いた標本の数だけで決まるので、描き出しの区切り方に依らない。
///
/// 包絡は、区切りの世代が同じときだけ受ける。主スレッドは区切りを始める命令 (``command``) より先に、その世代の
/// 包絡を書く (``FilePlayer/play(from:looping:envelope:)``) ので、新しい区切りを読んだ描き出しで、ふつうはその包絡も
/// 受けられる。**受けられなかった描き出しは無音にする** — 一度でも包絡が書かれたファイル (版が 0 でない) は、どの
/// 区切りにも主スレッドが包絡を書くので、受けられないのは主スレッドが次の包絡を書いている途中 (版が奇数) か、
/// 次の区切りの包絡が命令より先に見えた (世代が 1 つ先) ときだけ。前の区切りの包絡を持ち越すと、その位置のずれは
/// 前の区切りの頭からの数なので、立ち上がりの頭 (倍率 0 のはず) や形の後 (無音のはず) に保つ高さを出しうる。
/// 無音にすれば、ずれるのは最大 1 描き出しの音が欠けることだけで、区切りの頭で音が飛び出さない。
///
/// **音の側は待たず、確保しない** ([ADR-0042] 決定 7)。原子値の読み書きと `memcpy` 相当の複写だけで、
/// ロック・配列の追加・Objective-C の呼び出しをしない。ポインタの表は init で 1 度だけ作る。
///
/// `@unchecked Sendable`: 主スレッドと音の側の両方から触るのは上の原子値 (命令・進み具合・包絡) だけで、ほかは
/// 音の側だけが書く (器の標本は書かない)。
///
/// [#3277]: https://github.com/mokume-metal/mokume/issues/3277
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated final class FileVoice: @unchecked Sendable {
    /// 主スレッドが出す命令。
    enum Command {
        /// `start` 標本目から鳴らす。`start` が器の範囲の外なら頭から。
        case play(start: Int, looping: Bool)
        case halt
    }

    /// 始まりの標本の幅 (ビット)。2^40 標本は 48 kHz で約 266 日。
    private static let startBits: UInt64 = 40
    private static let startMask: UInt64 = (1 << startBits) - 1
    private static let loopingBit: UInt64 = 1 << startBits
    private static let haltedBit: UInt64 = 1 << (startBits + 1)
    private static let generationShift: UInt64 = startBits + 2
    /// 世代の幅。``command`` と ``progress`` の両方に使う。
    private static let generationMask: UInt64 = (1 << 22) - 1

    /// 器。ポインタの指し先を生かしておく。
    private let buffer: AVAudioPCMBuffer
    /// チャンネルごとの先頭の標本。init で 1 度だけ作る (音の側で `floatChannelData` を呼ばない)。
    private let channels: UnsafeMutablePointer<UnsafePointer<Float>>
    private let channelCount: Int
    private let length: Int
    /// 定位が移りきるまでの標本の数 (器の標本化率で約 5 ミリ秒。合成音の定位と同じくらい)。
    private let panRamp: Int
    /// 速さ (#3473) の受け渡し。主スレッドが頼み、音の側が受けた点 (錨) を返す。
    let link: RateLink

    private let command = Atomic<UInt64>(FileVoice.haltedBit)
    private let progress = Atomic<UInt64>(0)
    /// 包絡の版。奇数の間は主スレッドが書いている途中。0 は一度も書いていない。
    private let envelopeSequence = Atomic<UInt64>(0)
    // 包絡の値: 立ち上がり・保つ・下がるの標本の数、高さのビット列、位置のずれ (2 の補数)、
    // 区切りの世代。
    private let envelopeAttack = Atomic<UInt64>(0)
    private let envelopeSustain = Atomic<UInt64>(0)
    private let envelopeRelease = Atomic<UInt64>(0)
    private let envelopeLevel = Atomic<UInt64>(0)
    private let envelopeOffset = Atomic<UInt64>(0)
    private let envelopeGeneration = Atomic<UInt64>(0)
    /// 頼まれた定位 (単精度のビット列)。
    private let panTarget = Atomic<UInt32>(Float(0).bitPattern)
    /// 区切りの錨の置き場 (#3473)。世代の偶奇で 2 つ持つ — 主スレッドが次の世代の錨を書いても、音の側が読みかけの
    /// 世代の置き場は上書きしない (2 つ先の世代まで)。音の側は命令・置き場・命令の順に読み、命令が変わっていれば読み直す。
    /// 位置は `Double` のビット列、経った数は 2 の補数。
    private let originPositionEven = Atomic<UInt64>(0)
    private let originElapsedEven = Atomic<UInt64>(0)
    private let originPositionOdd = Atomic<UInt64>(0)
    private let originElapsedOdd = Atomic<UInt64>(0)

    // 音の側だけが読み書きする。
    /// 目指している定位と、いまの定位・移り始めた定位・移りきるまでの残りの標本の数。
    private var panGoal: Float = 0
    private var panNow: Float = 0
    private var panFrom: Float = 0
    private var panRemaining = 0
    /// いまの定位の左右の倍率。
    private var leftGain: Float = 1
    private var rightGain: Float = 1
    /// いまの速さと、速さが 1 を越えるときの低域通過の係数 (主スレッドが作って持つ。``RateLink``)。
    private var rate: Double
    private var kernel: Unmanaged<RateKernel>?
    /// いまの区切りの錨: 速さを最後に変えた点で読んでいた位置 (器の標本・小数・ループでも折り返さない) と、そこまでに
    /// 区切りの中で描いた標本の数。区切りの頭では、始まりの位置と 0。速さ 1 で位置が整数の間は、``position`` から
    /// 器の標本をそのまま写す (速さを入れる前と同じ道)。
    private var anchorPosition: Double = 0
    private var anchorElapsed = 0
    private var applied = FileVoice.haltedBit
    private var active = false
    private var looping = false
    private var position = 0
    private var count = 0
    private var generation: UInt64 = 0
    /// いまの区切りに掛けている包絡。`nil` なら掛けない。
    private var envelope: FileEnvelope?
    /// 受けた包絡の版。
    private var envelopeApplied: UInt64 = 0
    /// いまの区切りが包絡を待っているか (一度でも包絡が書かれたファイルの区切り)。待っている間、描いた標本は
    /// 無音にする。包絡を掛けていないファイルは常に `false`。
    private var awaitsEnvelope = false

    /// - Parameters:
    ///   - rate: 最初の速さ (#3473)。
    ///   - kernel: 最初の速さが 1 を越えるときの低域通過の係数。
    /// - Returns: 標本が浮動小数点・チャンネルごとの並びでなければ (読み込みの形式では起きない) `nil`。
    init?(buffer: AVAudioPCMBuffer, rate: Double = 1, kernel: RateKernel? = nil) {
        guard !buffer.format.isInterleaved, let data = buffer.floatChannelData else { return nil }
        let count = Int(buffer.format.channelCount)
        guard count > 0 else { return nil }
        let table = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: count)
        for index in 0..<count { table[index] = UnsafePointer(data[index]) }
        self.buffer = buffer
        channels = table
        channelCount = count
        length = Int(buffer.frameLength)
        panRamp = max(1, Int((buffer.format.sampleRate * 0.005).rounded()))
        self.rate = rate
        self.kernel = kernel.map { Unmanaged.passUnretained($0) }
        link = RateLink(kernel: kernel)
    }

    /// 錨の世代 `generation` (音の側の数え方) が、主スレッドの世代 `current` の区切りか。
    static func matches(_ generation: UInt64, current: Int) -> Bool {
        generation == UInt64(truncatingIfNeeded: current) & generationMask
    }

    deinit {
        channels.deallocate()
    }

    // MARK: - 主スレッド

    /// 命令を音の側へ渡す。次の描き出しの先頭で効く。
    ///
    /// - Parameter origin: 鳴らし始める区切りの錨 (#3473)。区切りの頭から見た錨の経った数 (0 以下) と、そこで読んでいた
    ///   位置。`nil` なら始まりの標本 (経った数 0)。速さを変えて鳴っているファイルを、鳴らしたまま別の流れへ移すとき
    ///   (``Playhead/carry(after:)``)、移す前と同じ式で位置を導き続けるために渡す。
    func send(_ order: Command, generation: Int, origin: (position: Double, elapsed: Int)? = nil) {
        if case .play(let start, _) = order {
            // 命令より先に、その世代の側の置き場へ書く (音の側は命令を読んでから置き場を読む)
            let position = (origin?.position ?? Double(max(0, start))).bitPattern
            let elapsed = UInt64(bitPattern: Int64(origin?.elapsed ?? 0))
            if generation & 1 == 0 {
                originPositionEven.store(position, ordering: .releasing)
                originElapsedEven.store(elapsed, ordering: .releasing)
            } else {
                originPositionOdd.store(position, ordering: .releasing)
                originElapsedOdd.store(elapsed, ordering: .releasing)
            }
        }
        var word = (UInt64(truncatingIfNeeded: generation) & Self.generationMask) << Self.generationShift
        switch order {
        case .play(let start, let looping):
            word |= UInt64(max(0, start)) & Self.startMask
            if looping { word |= Self.loopingBit }
        case .halt:
            word |= Self.haltedBit
        }
        command.store(word, ordering: .releasing)
    }

    /// 世代 `generation` の区切りに掛ける包絡を音の側へ渡す (#3099)。次の描き出しの先頭で効く。
    ///
    /// 版を奇数にしてから値を書き、偶数に戻す。書くのは主スレッドだけなので、版の読み書きは競わない。
    ///
    /// - Parameter whileWriting: **検査だけが使う。** 値を半分書いたところ (版が奇数の間) で呼ぶ。音の側の描き出しが
    ///   書いている途中に入る順を、1 本のスレッドで再現する。
    func send(
        _ envelope: FileEnvelope, generation: Int, whileWriting: (() -> Void)? = nil
    ) {
        let version = envelopeSequence.load(ordering: .relaxed)
        envelopeSequence.store(version &+ 1, ordering: .releasing)
        envelopeAttack.store(UInt64(max(0, envelope.shape.attack)), ordering: .releasing)
        envelopeSustain.store(UInt64(max(0, envelope.shape.sustain)), ordering: .releasing)
        envelopeRelease.store(UInt64(max(0, envelope.shape.release)), ordering: .releasing)
        whileWriting?()
        envelopeLevel.store(UInt64(envelope.shape.level.bitPattern), ordering: .releasing)
        envelopeOffset.store(UInt64(bitPattern: Int64(envelope.offset)), ordering: .releasing)
        envelopeGeneration.store(
            UInt64(truncatingIfNeeded: generation) & Self.generationMask, ordering: .releasing)
        envelopeSequence.store(version &+ 2, ordering: .releasing)
    }

    /// 定位 (-1〜1。範囲へ寄せた値) を音の側へ渡す。次の描き出しの先頭から移り始める。
    func pan(_ position: Float) {
        panTarget.store(position.bitPattern, ordering: .releasing)
    }

    /// 定位 `position` の左右の倍率 (#3473 の 2026-11-13 の決定)。
    ///
    /// - 1 チャンネル (`mono`): 中央で 1 になるよう掛け直した、左右を合わせた大きさが変わらない定位。左 = √2·cos θ、
    ///   右 = √2·sin θ (θ は -1…1 を 0…π/2 へ写したもの)。端では片側が √2 倍・反対側が 0
    /// - 2 チャンネル以上 (バランス): 反対側にだけ 1 - |position| を掛ける。端で反対側が 0、手前の側は元のまま
    ///
    /// 0 と両端は式を通さずに返す — 中央が 1 から、端の反対側が 0 から、丸めで外れない。
    nonisolated static func gains(at position: Float, mono: Bool) -> (left: Float, right: Float) {
        if position == 0 { return (1, 1) }
        guard mono else {
            return (position > 0 ? 1 - position : 1, position < 0 ? 1 + position : 1)
        }
        let root2 = 2.0.squareRoot()
        if position <= -1 { return (Float(root2), 0) }
        if position >= 1 { return (0, Float(root2)) }
        let angle = Double(position + 1) * 0.25 * Double.pi
        return (Float(root2 * RuntimeMath.cos(angle)), Float(root2 * RuntimeMath.sin(angle)))
    }

    /// 世代 `generation` の区切りで、いままでに描いた標本の数。その区切りがまだ音の側へ届いていなければ 0。
    func played(generation: Int) -> Int {
        let value = progress.load(ordering: .acquiring)
        let seen = value >> Self.startBits
        guard seen == UInt64(truncatingIfNeeded: generation) & Self.generationMask else { return 0 }
        return Int(value & Self.startMask)
    }

    // MARK: - 音の側

    /// 描き出し 1 回ぶんの標本を渡す。**待たず、確保しない。**
    ///
    /// - Returns: 無音だけを書いたか (止めている・鳴らし終えて何も出なかった)。
    @discardableResult
    func render(frames: Int, into output: UnsafeMutableAudioBufferListPointer) -> Bool {
        var word = command.load(ordering: .acquiring)
        let begins = word != applied
        if begins {
            // 置き場は命令の後に読み、命令が動いていなければ受ける (動いていれば新しい命令で読み直す)
            var origin = readOrigin(of: word)
            for _ in 0..<4 {
                let again = command.load(ordering: .acquiring)
                if again == word { break }
                word = again
                origin = readOrigin(of: word)
            }
            begin(word, origin: origin)
        }
        if envelopeSequence.load(ordering: .relaxed) != envelopeApplied { receiveEnvelope() }
        receivePan()
        receiveRate()
        // 区切りの頭 (鳴らし始め・鳴らし直し) と鳴っていない間は、移らずにその定位から鳴らす
        if begins || !active { settlePan() }
        guard active, frames > 0 else {
            Self.silence(output, channels: 0..<output.count, from: 0, to: frames)
            return true
        }
        let copied = min(channelCount, output.count)
        let made = isDirect ? copy(frames, into: output, channels: copied) : resample(frames, into: output, channels: copied)
        if let envelope {
            shape(output, channels: copied, made: made, by: envelope)
        } else if awaitsEnvelope {
            // 受けるはずの包絡がまだ読めない (書いている途中・世代が先)。全音量を出さない
            Self.silence(output, channels: 0..<copied, from: 0, to: made)
        }
        // 器の終わりで 1 度だけの区切りが尽きたぶんと、器に無いチャンネルは無音
        Self.silence(output, channels: 0..<copied, from: made, to: frames)
        Self.silence(output, channels: copied..<output.count, from: 0, to: frames)
        if output.count >= 2 {
            // 1 チャンネルの器は、左へ描いた標本を右へも配る (節は 2 チャンネル)
            if channelCount == 1, let left = output[0].mData?.assumingMemoryBound(to: Float.self),
                let right = output[1].mData?.assumingMemoryBound(to: Float.self)
            {
                right.update(from: left, count: frames)
            }
            applyPan(output, frames: frames)
        }
        count += frames
        let bounded = UInt64(count) & Self.startMask
        progress.store(generation << Self.startBits | bounded, ordering: .releasing)
        return made == 0
    }

    /// 速さ 1 で位置が整数か。そうなら、器の標本をそのまま写す。
    private var isDirect: Bool {
        rate == 1 && anchorPosition.rounded(.down) == anchorPosition
    }

    /// 器の標本を ``position`` からそのまま写す (速さ 1)。写した数を返す。
    private func copy(
        _ frames: Int, into output: UnsafeMutableAudioBufferListPointer, channels copied: Int
    ) -> Int {
        var made = 0
        var place = position
        while made < frames {
            if place >= length {
                guard looping else { break }
                place = 0
            }
            let run = min(frames - made, length - place)
            for channel in 0..<copied {
                guard let target = output[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                (target + made).update(from: channels[channel] + place, count: run)
            }
            place += run
            made += run
        }
        position = place
        return made
    }

    /// 錨から導く位置で、器を読み直して描く (速さ ≠ 1 か、位置が整数でない)。描いた数を返す。速さ 0 の間は描かない
    /// (無音。区切りは続く — #3473 の 2026-11-14 の決定 3)。1 度だけなら、位置が終わりに着いたところで止まる。
    private func resample(
        _ frames: Int, into output: UnsafeMutableAudioBufferListPointer, channels copied: Int
    ) -> Int {
        guard rate != 0 else { return 0 }
        let since = count - anchorElapsed
        let end = Double(length)
        var made = 0
        while made < frames {
            let place = FileRate.position(from: anchorPosition, elapsed: since + made, rate: rate)
            if !looping, place >= end { break }
            for channel in 0..<copied {
                guard let target = output[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                target[made] = read(channels[channel], at: place)
            }
            made += 1
        }
        return made
    }

    /// 1 チャンネルの位置 `place` の値。
    @inline(__always)
    private func read(_ source: UnsafePointer<Float>, at place: Double) -> Float {
        guard let kernel else {
            return FileRate.read(source, length: length, at: place, looping: looping, kernel: nil)
        }
        return kernel._withUnsafeGuaranteedRef {
            FileRate.read(source, length: length, at: place, looping: looping, kernel: $0.kernel)
        }
    }

    /// 頼まれた速さを受ける。いまの位置を錨にして、そこから新しい速さで読む。受けた点を主スレッドへ返す。
    private func receiveRate() {
        guard let request = link.take() else { return }
        let place = FileRate.position(from: anchorPosition, elapsed: count - anchorElapsed, rate: rate)
        anchorPosition = place
        anchorElapsed = count
        rate = request.rate
        kernel = request.kernel
        if active, isDirect {
            // 写す道へ戻る。写す位置は、錨の位置を器の中へ折り返したもの
            let end = Double(length)
            position =
                looping
                ? Int(place.truncatingRemainder(dividingBy: end)) : (place >= end ? length : Int(place))
        }
        link.publish(generation: generation, elapsed: count, position: place, rate: rate)
    }

    /// 命令の語 `word` の世代の、区切りの錨の置き場。
    private func readOrigin(of word: UInt64) -> (position: Double, elapsed: Int) {
        let position: UInt64
        let elapsed: UInt64
        if (word >> Self.generationShift) & 1 == 0 {
            position = originPositionEven.load(ordering: .acquiring)
            elapsed = originElapsedEven.load(ordering: .acquiring)
        } else {
            position = originPositionOdd.load(ordering: .acquiring)
            elapsed = originElapsedOdd.load(ordering: .acquiring)
        }
        return (Double(bitPattern: position), Int(Int64(bitPattern: elapsed)))
    }

    /// 新しい命令を適用する。
    private func begin(_ word: UInt64, origin: (position: Double, elapsed: Int)) {
        applied = word
        generation = (word >> Self.generationShift) & Self.generationMask
        // 包絡は区切りごとに受け直す (``receiveEnvelope()``)。一度でも包絡が書かれていれば、この区切りの包絡も
        // 主スレッドが命令より先に書いている — 受けるまで無音で待つ。版は命令 (acquire で読んだ) より先に書かれる
        envelope = nil
        awaitsEnvelope = envelopeSequence.load(ordering: .relaxed) != 0
        active = word & Self.haltedBit == 0 && length > 0
        guard active else { return }
        let start = Int(word & Self.startMask)
        looping = word & Self.loopingBit != 0
        // 終わり以降から 1 度だけ鳴らす区切りは、鳴らす残りが無いので無音のまま終わる (ラックの節
        // (``FileNode``) と同じ。#3303)。**頭から鳴らし直すのは、区切りを決める ``Playhead`` の仕事** で、
        // ここで頭へ戻すと、鳴っている間に終わりへ飛んだとき頭の音が出る。ループなら頭から
        position = start < length ? start : (looping ? 0 : length)
        // 錨は主スレッドの ``Playhead`` と同じ (ふつうは折り返さない始まりの位置と 0)
        anchorPosition = origin.position
        anchorElapsed = origin.elapsed
        count = 0
    }

    /// 書かれた包絡を読む。**いまの区切りの世代のものだけを受ける。** 新しい区切りに入ったら、前の区切りの包絡は
    /// 外す (包絡を掛けているファイルなら、主スレッドが新しい区切りの包絡を先に書いている)。書いている途中に
    /// 読んだら受けず、次の描き出しで読み直す。
    private func receiveEnvelope() {
        let version = envelopeSequence.load(ordering: .acquiring)
        guard version & 1 == 0 else { return }
        let attack = envelopeAttack.load(ordering: .acquiring)
        let sustain = envelopeSustain.load(ordering: .acquiring)
        let release = envelopeRelease.load(ordering: .acquiring)
        let level = envelopeLevel.load(ordering: .acquiring)
        let offset = envelopeOffset.load(ordering: .acquiring)
        let owner = envelopeGeneration.load(ordering: .acquiring)
        // 値を読んでいる間に版が動いていれば、混ざった値かもしれない
        guard envelopeSequence.load(ordering: .relaxed) == version else { return }
        // まだ届いていない区切り (命令より先に書かれる) の包絡は、その区切りを読むまで待つ
        guard owner == generation else { return }
        envelopeApplied = version
        var shape = EnvelopeShape()
        shape.attack = Int(truncatingIfNeeded: attack)
        shape.sustain = Int(truncatingIfNeeded: sustain)
        shape.release = Int(truncatingIfNeeded: release)
        shape.level = Float(bitPattern: UInt32(truncatingIfNeeded: level))
        envelope = FileEnvelope(shape: shape, offset: Int(Int64(bitPattern: offset)))
    }

    /// 頼まれた定位を読む。変わっていれば、いまの定位からそこへ移り始める。
    private func receivePan() {
        let target = Float(bitPattern: panTarget.load(ordering: .acquiring))
        guard target != panGoal else { return }
        panGoal = target
        panFrom = panNow
        panRemaining = panRamp
    }

    /// 移る途中を飛ばして、目指す定位にする。
    private func settlePan() {
        guard panRemaining > 0 || panNow != panGoal else { return }
        panRemaining = 0
        panNow = panGoal
        (leftGain, rightGain) = Self.gains(at: panNow, mono: channelCount == 1)
    }

    /// 左 (出力の 0) と右 (1) に定位の倍率を掛ける。**既定の中央で移る途中でなければ、何も掛けない** (標本は
    /// 掛ける前と 1 つも変わらない)。移る途中は標本ごとに倍率を求め直す。
    private func applyPan(_ output: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard panRemaining > 0 || leftGain != 1 || rightGain != 1 else { return }
        guard let left = output[0].mData?.assumingMemoryBound(to: Float.self),
            let right = output[1].mData?.assumingMemoryBound(to: Float.self)
        else { return }
        let mono = channelCount == 1
        for index in 0..<frames {
            if panRemaining > 0 {
                panRemaining -= 1
                panNow =
                    panRemaining == 0
                    ? panGoal
                    : panFrom + (panGoal - panFrom) * Float(panRamp - panRemaining) / Float(panRamp)
                (leftGain, rightGain) = Self.gains(at: panNow, mono: mono)
            }
            left[index] *= leftGain
            right[index] *= rightGain
        }
    }

    /// 描いた `made` 標本に、包絡の倍率を掛ける。区切りの中の標本の数は ``count`` から数える (``FileEnvelope``)。
    private func shape(
        _ output: UnsafeMutableAudioBufferListPointer, channels copied: Int, made: Int,
        by envelope: FileEnvelope
    ) {
        for index in 0..<made {
            let gain = envelope.gain(atPlayed: count + index)
            for channel in 0..<copied {
                guard let target = output[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                target[index] *= gain
            }
        }
    }

    /// 出力の `channels` の `from` 標本目から `end` 標本目の手前までを 0 にする。
    private static func silence(
        _ output: UnsafeMutableAudioBufferListPointer, channels: Range<Int>, from: Int, to end: Int
    ) {
        guard from < end else { return }
        for channel in channels {
            guard let data = output[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            (data + from).update(repeating: 0, count: end - from)
        }
    }
}
