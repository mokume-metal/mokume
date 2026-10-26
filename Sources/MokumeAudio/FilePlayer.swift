// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation

/// 読み込んだ音を、音の流れ (``SoundFlow``) で実際に鳴らす。AVFAudio で鳴らすのはこの型だけ
/// である ([ADR-0042] 決定 6 の「薄い層に閉じる」)。
///
/// ## 位置は player が描いた数から読む
///
/// 鳴らし始めるたびに player を止めて区切りを積み直すので、player の時刻 (`playerTime`) は
/// 区切りの始まりから描いた標本の数になる。これを ``Playhead`` の `played` として渡す —
/// 機材の時計で進むので、長く回しても鳴っている音と解析の位置がずれない。
///
/// ## 途中から鳴らすときはコピーしない
///
/// 止めた位置から鳴らし直すとき (``Playhead/pause(after:)`` の後・途中からのループ) は、
/// 読み込んだ器の後ろ側をコピーせずに指す器を作る (``tail(of:from:)``)。曲 1 本ぶんの写しを
/// 鳴らし直すたびに作ると、それだけでフレームが詰まる。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
final class FilePlayer {
    let flow: SoundFlow
    private let player = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer

    /// 流れに入れる。鳴らせなければ (出力が開けない) `nil`。
    init?(flow: SoundFlow, buffer: AVAudioPCMBuffer) {
        self.flow = flow
        self.buffer = buffer
        guard flow.join(player, format: buffer.format) else { return nil }
    }

    /// 音量 (0〜1)。
    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    /// 区切りの始まりから描いた標本の数。まだ描いていなければ 0、鳴らしていなければ `nil`。
    var played: Int? {
        guard let rendered = player.lastRenderTime,
            rendered.isSampleTimeValid || rendered.isHostTimeValid,
            let time = player.playerTime(forNodeTime: rendered)
        else { return nil }
        return max(0, Int(time.sampleTime))
    }

    /// `start` 標本目から鳴らす。前の区切りは捨てる。
    func play(from start: Int, looping: Bool) {
        player.stop()
        let length = Int(buffer.frameLength)
        if start > 0, start < length, let tail = Self.tail(of: buffer, from: start) {
            player.scheduleBuffer(tail)
        }
        // 頭から 1 度だけ・ループの頭から先は、器そのものを積む
        if start <= 0 || start >= length || looping {
            player.scheduleBuffer(buffer, at: nil, options: looping ? .loops : [])
        }
        player.play()
        if flow.isOffline { Self.letTheStartBeTaken() }
    }

    /// 機材に出さない流れでは、``AVAudioPlayerNode/play()`` の命令を player が取り込むのを待つ。
    ///
    /// **描いている途中の流れへ鳴らし始める命令は、player の側のスレッドで取り込まれる。** 呼んだ直後に
    /// `renderOffline` を呼ぶと、取り込みが描くのに間に合わず、窓まるごと (数百標本) 無音になることがある
    /// (M3 Max で 400 回のうち 10% 前後・負荷が重いほど増える。命令を取り込んだことを知る手立ては見つからず、
    /// 呼び直し・`isPlaying` を待つ・時刻を指して始めるのは効かなかった)。描くのは呼んだ側が進める流れなので
    /// 待っても時間は進まず、待つのは窓を書き出す側の数 ms だけである。実機に出す流れは時計で進むので要らない。
    ///
    /// 100 µs でも 1200 回で 1 度も落ちなかったが、取り込みが遅れる上限は分からないので、数十倍の余裕を取る。
    private static func letTheStartBeTaken() {
        Thread.sleep(forTimeInterval: 0.005)
    }

    /// 止める。積んだ区切りは捨てる。
    func halt() {
        player.stop()
    }

    /// 流れから外す。
    func leave() {
        player.stop()
        flow.leave(player)
    }

    /// `buffer` の `start` 標本目から後ろを、コピーせずに指す器。
    ///
    /// **隔離の外で作る。** 後片付けの手続きは器が手放されたとき (player が鳴らし終えたとき) に
    /// 音の側のスレッドで呼ばれるので、main actor に属させると動的な隔離検査 (SE-0423) で落ちる
    /// ([ADR-0042] 決定 7)。手続きが元の器を持つので、指している間は元の器が消えない。
    ///
    /// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
    nonisolated static func tail(of buffer: AVAudioPCMBuffer, from start: Int) -> AVAudioPCMBuffer? {
        let length = Int(buffer.frameLength)
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        guard start > 0, start < length, bytesPerFrame > 0 else { return nil }
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let list = AudioBufferList.allocate(maximumBuffers: source.count)
        for (index, channel) in source.enumerated() {
            guard let data = channel.mData else {
                free(list.unsafeMutablePointer)
                return nil
            }
            list[index] = AudioBuffer(
                mNumberChannels: channel.mNumberChannels,
                mDataByteSize: UInt32((length - start) * bytesPerFrame),
                mData: data.advanced(by: start * bytesPerFrame))
        }
        let owner = BufferOwner(buffer: buffer, list: list.unsafeMutablePointer)
        guard
            let tail = AVAudioPCMBuffer(
                pcmFormat: buffer.format, bufferListNoCopy: list.unsafePointer,
                deallocator: { _ in owner.release() })
        else {
            owner.release()
            return nil
        }
        return tail
    }
}

/// 後ろ側を指す器が生きている間、元の器と指し先の並びを持っておく。
///
/// `@unchecked Sendable`: 作った後に書き換えるのは ``release()`` の 1 度だけで、それを呼ぶのは
/// 指す器の後片付け (1 度だけ呼ばれる) だけである。
private nonisolated final class BufferOwner: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    private let list: UnsafeMutablePointer<AudioBufferList>

    init(buffer: AVAudioPCMBuffer, list: UnsafeMutablePointer<AudioBufferList>) {
        self.buffer = buffer
        self.list = list
    }

    func release() {
        buffer = nil
        free(list)
    }
}
