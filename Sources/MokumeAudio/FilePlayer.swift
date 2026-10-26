// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import Synchronization

/// 読み込んだ音を、音の流れ (``SoundFlow``) で実際に鳴らす。AVFAudio で鳴らすのはこの型だけ
/// である ([ADR-0042] 決定 6 の「薄い層に閉じる」)。
///
/// ## 標本は自分で渡す
///
/// 器の標本は `AVAudioSourceNode` で、描き出しのたびに自分で渡す (``FileVoice``)。`AVAudioPlayerNode` に
/// 器を積んで ``AVAudioPlayerNode/play()`` を呼ぶ形は、**機材に出さない流れでは使わない** — 描いている
/// 途中の流れへ鳴らし始める命令は player の側のスレッドで取り込まれ、呼んだ直後の `renderOffline` に
/// 間に合わないと、窓まるごと (数百標本) 無音になる (#3277・M3 Max で 400 回のうち 10% 前後)。取り込みを
/// 確かめる手立ては無く、待つのは保証にならない。
///
/// **命令は 1 つの原子値で音の側へ渡す。** 呼んだ側が書き、次の描き出しの先頭で音の側が読む。機材に出さない
/// 流れの `renderOffline` は呼んだスレッドの中で節を呼ぶので、書き込みは必ず描き出しより前に済んでいて、
/// 直後の窓の先頭の標本から鳴る。実機に出す流れでも同じ原子値を、音の realtime スレッドが先頭で読む。
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
    init?(flow: SoundFlow, buffer: AVAudioPCMBuffer) {
        self.flow = flow
        guard let voice = FileVoice(buffer: buffer) else { return nil }
        self.voice = voice
        node = Self.makeNode(voice: voice, format: buffer.format)
        guard flow.join(node, format: buffer.format) else { return nil }
    }

    /// 音量 (0〜1)。
    var volume: Float {
        get { node.volume }
        set { node.volume = newValue }
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
    func play(from start: Int, looping: Bool) {
        generation += 1
        isPlaying = true
        voice.send(.play(start: start, looping: looping), generation: generation)
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
///   最後の語だけが効き、窓の途中で命令が混ざらない。
/// - ``progress`` (**音の側が書き、主スレッドが読む**): 世代と、区切りの始まりから描いた標本の数を詰めた
///   1 つの原子値。描き出しの末尾で release で書き、``played(generation:)`` が acquire で読む。世代と数を
///   別々に読んで取り違えない。
/// - 位置・数・ループ・適用した語 (``applied``): **音の側だけが読み書きする**。主スレッドは触らない。
/// - 器の標本 (``channels``): init で作ったあとは読むだけで、書き換えない。
///
/// **音の側は待たず、確保しない** ([ADR-0042] 決定 7)。原子値の読み書きと `memcpy` 相当の複写だけで、
/// ロック・配列の追加・Objective-C の呼び出しをしない。ポインタの表は init で 1 度だけ作る。
///
/// `@unchecked Sendable`: 主スレッドと音の側の両方から触るのは上の 2 つの原子値だけで、ほかは音の側だけが
/// 書く (器の標本は書かない)。
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

    private let command = Atomic<UInt64>(FileVoice.haltedBit)
    private let progress = Atomic<UInt64>(0)

    // 音の側だけが読み書きする。
    private var applied = FileVoice.haltedBit
    private var active = false
    private var looping = false
    private var position = 0
    private var count = 0
    private var generation: UInt64 = 0

    /// - Returns: 標本が浮動小数点・チャンネルごとの並びでなければ (読み込みの形式では起きない) `nil`。
    init?(buffer: AVAudioPCMBuffer) {
        guard !buffer.format.isInterleaved, let data = buffer.floatChannelData else { return nil }
        let count = Int(buffer.format.channelCount)
        guard count > 0 else { return nil }
        let table = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: count)
        for index in 0..<count { table[index] = UnsafePointer(data[index]) }
        self.buffer = buffer
        channels = table
        channelCount = count
        length = Int(buffer.frameLength)
    }

    deinit {
        channels.deallocate()
    }

    // MARK: - 主スレッド

    /// 命令を音の側へ渡す。次の描き出しの先頭で効く。
    func send(_ order: Command, generation: Int) {
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
        let word = command.load(ordering: .acquiring)
        if word != applied { begin(word) }
        guard active, frames > 0 else {
            Self.silence(output, channels: 0..<output.count, from: 0, to: frames)
            return true
        }
        let copied = min(channelCount, output.count)
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
        // 器の終わりで 1 度だけの区切りが尽きたぶんと、器に無いチャンネルは無音
        Self.silence(output, channels: 0..<copied, from: made, to: frames)
        Self.silence(output, channels: copied..<output.count, from: 0, to: frames)
        count += frames
        let bounded = UInt64(count) & Self.startMask
        progress.store(generation << Self.startBits | bounded, ordering: .releasing)
        return made == 0
    }

    /// 新しい命令を適用する。
    private func begin(_ word: UInt64) {
        applied = word
        generation = (word >> Self.generationShift) & Self.generationMask
        active = word & Self.haltedBit == 0 && length > 0
        guard active else { return }
        let start = Int(word & Self.startMask)
        // 範囲の外は頭から (旧実装と同じ。ラックの節 (``FileNode``) とそろえるかは #3303 で決める)
        position = start > 0 && start < length ? start : 0
        looping = word & Self.loopingBit != 0
        count = 0
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
