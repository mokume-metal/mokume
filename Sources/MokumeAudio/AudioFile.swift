// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import MokumeCore

/// 音声ファイルを読む。AVFAudio でファイルを読むのはここだけである
/// ([ADR-0042] 決定 6 の「薄い層に閉じる」)。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated enum AudioFile {
    /// 読んだ標本列 (チャンネルを平均したモノラル) と、その標本化率。
    struct Decoded: Equatable {
        var samples: [Float]
        var sampleRate: Float
    }

    /// `url` を、モノラルの標本列へ読む。`path` は失敗の説明に載せる名前。
    static func read(_ url: URL, path: String) throws(AudioFailure) -> Decoded {
        let buffer = try load(url, path: path)
        return Decoded(samples: mono(buffer), sampleRate: Float(buffer.format.sampleRate))
    }

    /// `url` を、ファイルの処理の形式 (チャンネルごとに分かれた 32 bit 浮動小数) のまま読む。
    /// 鳴らすときはこちらを使う — チャンネルを平均すると左右が消える。
    ///
    /// **開けないものを「壊れている・形式が違う」と名乗らない** ([#2358])。AVFAudio はディレクトリや
    /// 読む権利の無いファイルを、形式の誤りと同じく断る。読む前に開けるかを確かめ
    /// (``AssetOpening``)、開けなければ ``AudioFailure/unopenable(path:location:reason:)`` を投げる。
    ///
    /// [#2358]: https://github.com/mokume-metal/mokume/issues/2358
    static func load(_ url: URL, path: String) throws(AudioFailure) -> AVAudioPCMBuffer {
        if let refusal = AssetOpening.refusal(at: url) {
            throw .unopenable(path: path, location: refusal.location, reason: refusal.reason)
        }
        guard let file = try? AVAudioFile(forReading: url) else { throw .unreadable(path: path) }
        // 器は長さ 0 では作れないので、空のファイルは器を作る前に見分ける
        guard file.length > 0, file.processingFormat.channelCount > 0 else { throw .empty }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
            buffer.floatChannelData != nil,
            readAll(file, into: buffer)
        else { throw .unreadable(path: path) }
        guard buffer.frameLength > 0 else { throw .empty }
        return buffer
    }

    /// 1 回に読む標本の数の上限。`AVAudioFile.read(into:)` は器の容量にかかわらず 1 回に 2^24 標本までしか
    /// 読まないので (#3969)、それより小さな塊で読む。
    static let readChunk: AVAudioFrameCount = 1 << 20

    /// `file` の全部を、塊 (``readChunk``) ごとに読んで `buffer` の頭から並べる。**読めた数がファイルの長さに
    /// 届かなければ `false`** — 読めた分だけを黙って返すと、長いファイルの終わりが切れたまま鳴る (#3969)。
    /// 塊の器は 1 つだけで、メモリの上限は塊の大きさしか増えない。
    static func readAll(_ file: AVAudioFile, into buffer: AVAudioPCMBuffer) -> Bool {
        let length = file.length
        guard
            let piece = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: min(readChunk, buffer.frameCapacity)),
            let target = buffer.floatChannelData, let source = piece.floatChannelData
        else { return false }
        let channelCount = Int(file.processingFormat.channelCount)
        var filled = 0
        while AVAudioFramePosition(filled) < length {
            let wanted = AVAudioFrameCount(min(AVAudioFramePosition(readChunk), length - AVAudioFramePosition(filled)))
            guard (try? file.read(into: piece, frameCount: wanted)) != nil else { return false }
            let count = Int(piece.frameLength)
            guard count > 0 else { break }
            for channel in 0..<channelCount {
                (target[channel] + filled).update(from: source[channel], count: count)
            }
            filled += count
        }
        buffer.frameLength = AVAudioFrameCount(filled)
        return AVAudioFramePosition(filled) == length
    }

    /// チャンネルを平均したモノラルの標本列。
    static func mono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard count > 0, channelCount > 0, let channels = buffer.floatChannelData else { return [] }
        // 処理の形式はチャンネルごとの置き場 (分離) で届く
        let stride = buffer.stride
        var samples = [Float](repeating: 0, count: count)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for frame in 0..<count { samples[frame] += data[frame * stride] }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for frame in 0..<count { samples[frame] *= scale }
        }
        return samples
    }
}
