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
            let capacity = capacity(forLength: file.length),
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity),
            buffer.floatChannelData != nil,
            readAll(file, into: buffer)
        else { throw .unreadable(path: path) }
        guard buffer.frameLength > 0 else { throw .empty }
        return buffer
    }

    /// 長さ `length` のファイルを入れる器の容量。器の容量は `AVAudioFrameCount` (UInt32) なので、
    /// 2^32 標本 (48 kHz で約 24.8 時間) 以上は収まらず `nil` — 変換で落とさない (#3969)。
    static func capacity(forLength length: AVAudioFramePosition) -> AVAudioFrameCount? {
        AVAudioFrameCount(exactly: length)
    }

    /// 1 回に読む標本の数の上限。`AVAudioFile.read(into:)` は器の容量にかかわらず 1 回に 2^24 標本までしか
    /// 読まないので (#3969)、それより小さな塊で読む。
    static let readChunk: AVAudioFrameCount = 1 << 20

    /// `file` を、塊 (``readChunk``) ごとにファイルの終わりまで読んで `buffer` の頭から並べる。
    /// 塊の器は 1 つだけで、メモリの上限は塊の大きさしか増えない。
    ///
    /// **見出しの長さ (`file.length`) と実際が食い違うファイルも、これまで読めていたものを読めなくしない** (#3969):
    /// - 見出しより実際が短い (終わりを削った) ファイルは、読めた所までを返す。`read` は終わりに着くと
    ///   ファイルの終わりの誤り (`kAudioFileEndOfFileError`) を投げるので、それを終わりの合図として扱う
    /// - 見出しより実際が長いファイルの余りは読めない。`AVAudioFile` は見出しの長さの所で終わりの誤りを投げ、
    ///   位置を動かしても読ませない (2026-11-11 に WAV・CAF で実測)
    ///
    /// **`read` が終わりの手前をどう返すかに頼らない** (#3969)。見出しより短い CAF で、残りより多く求めた
    /// `read` は、macOS 27 では読めた分を返してから次の `read` で終わりの誤りを投げるが、macOS 26 (下限) では
    /// 標本を返さずにいきなり誤りを投げる (CI の赤から読んだ)。だから `read` が誤りを投げたら、位置を読めた
    /// 標本の数へ戻し、求める数を半分にして読み直す。誤りの出ない読み方 (普通のファイル) は変わらない。
    ///
    /// `false` を返すのは、1 標本ずつにしても読めないときのうち、終わり以外の誤りを投げたときと、
    /// 1 標本も読めずに終わりの誤りを投げたとき (1 回で読んでいた頃に `unreadable` だったもの) だけ。
    static func readAll(_ file: AVAudioFile, into buffer: AVAudioPCMBuffer) -> Bool {
        readAll(
            length: file.length, into: buffer,
            seek: { file.framePosition = $0 },
            read: { piece, count in try file.read(into: piece, frameCount: count) })
    }

    /// ``readAll(_:into:)`` の中身。ファイルを読む手 (`read`) と位置を動かす手 (`seek`) を受け取るので、
    /// OS ごとの `read` の返し方を検査から差し替えられる。`length` は見出しの長さ。
    static func readAll(
        length fileLength: AVAudioFramePosition, into buffer: AVAudioPCMBuffer,
        seek: (AVAudioFramePosition) -> Void,
        read: (AVAudioPCMBuffer, AVAudioFrameCount) throws -> Void
    ) -> Bool {
        let length = min(fileLength, AVAudioFramePosition(buffer.frameCapacity))
        guard
            let piece = AVAudioPCMBuffer(
                pcmFormat: buffer.format, frameCapacity: min(readChunk, buffer.frameCapacity)),
            let target = buffer.floatChannelData, let source = piece.floatChannelData
        else { return false }
        let channelCount = Int(buffer.format.channelCount)
        var filled = 0
        // 1 回に求める数の上限。誤りで半分にし、読めたら倍に戻す (塊の大きさまで)
        var step = readChunk
        while AVAudioFramePosition(filled) < length {
            let wanted = AVAudioFrameCount(min(AVAudioFramePosition(step), length - AVAudioFramePosition(filled)))
            do {
                try read(piece, wanted)
            } catch {
                if wanted > 1 {
                    // 誤りの後の位置は当てにせず、読めた所へ戻してから小さく読み直す
                    seek(AVAudioFramePosition(filled))
                    step = wanted / 2
                    continue
                }
                let error = error as NSError
                if error.domain == NSOSStatusErrorDomain && error.code == Int(kAudioFileEndOfFileError) && filled > 0 {
                    break
                }
                return false
            }
            let count = Int(piece.frameLength)
            guard count > 0 else { break }
            for channel in 0..<channelCount {
                (target[channel] + filled).update(from: source[channel], count: count)
            }
            filled += count
            step = min(step * 2, readChunk)
        }
        buffer.frameLength = AVAudioFrameCount(filled)
        return true
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
