// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation

/// 音声ファイルを、モノラルの標本列へ読む。AVFAudio でファイルを読むのはここだけである
/// ([ADR-0042] 決定 6 の「薄い層に閉じる」)。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated enum AudioFile {
    /// 読んだ標本列 (チャンネルを平均したモノラル) と、その標本化率。
    struct Decoded: Equatable {
        var samples: [Float]
        var sampleRate: Float
    }

    /// `url` を読む。`path` は失敗の説明に載せる名前。
    static func read(_ url: URL, path: String) throws(AudioFailure) -> Decoded {
        guard let file = try? AVAudioFile(forReading: url),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
            (try? file.read(into: buffer)) != nil,
            let channels = buffer.floatChannelData
        else { throw .unreadable(path: path) }

        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard count > 0, channelCount > 0 else { throw .empty }
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
        return Decoded(samples: samples, sampleRate: Float(file.processingFormat.sampleRate))
    }
}
