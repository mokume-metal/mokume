// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation

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
    static func load(_ url: URL, path: String) throws(AudioFailure) -> AVAudioPCMBuffer {
        guard let file = try? AVAudioFile(forReading: url) else { throw .unreadable(path: path) }
        // 器は長さ 0 では作れないので、空のファイルは器を作る前に見分ける
        guard file.length > 0, file.processingFormat.channelCount > 0 else { throw .empty }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
            (try? file.read(into: buffer)) != nil,
            buffer.floatChannelData != nil
        else { throw .unreadable(path: path) }
        guard buffer.frameLength > 0 else { throw .empty }
        return buffer
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
