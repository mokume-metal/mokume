// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreMedia
import Foundation

extension RenderRequest {
    /// 書き出し先に、頼んだものが揃っていないこと。
    package nonisolated enum Shortfall: Equatable, Sendable {
        /// この回に書かれたファイルが無い (無い・前の回の残りだけ・空)。
        case notWritten
        /// ファイルは在るが、動画として読めない。
        case unreadable
        /// 書かれたのは頼んだ枚数に足りない (`found` 枚)。
        case frames(found: Int)
    }

    /// 子が 0 で終わった後に、**書き出し先に頼んだものが揃っているかを確かめる** ([#2481])。
    ///
    /// 終了コードは「子が自分を終えた」ことしか言わない。頼みを読まずに窓を開いて 0 で終わる古い版の
    /// 子 (道具と依存の版のずれ) も 0 で終わるので、道具が書き出し先を事後に見る。子との新しい口は
    /// 足さない。
    ///
    /// - `.mov`: ファイルが在り、映像の標本が頼んだ枚数ある。標本は復号せずに数える。
    /// - 連番: 番号の場所を 0 から数えた名前のファイルが、頼んだ枚数ぶん在る。
    ///
    /// **前の回の残りは数えない。** 同じ行き先へ書き直す回に、古い版の子が何も書かずに 0 で終わると、
    /// 前の回のファイルが揃って見える。`start` (道具が子を起こす前の時刻) より前に最後に書かれた
    /// ファイルは、この回のものではない。
    ///
    /// - Parameter start: 子を起こす直前の時刻。
    /// - Returns: 揃っていれば `nil`。
    ///
    /// [#2481]: https://github.com/mokume-metal/mokume/issues/2481
    package nonisolated func inspectOutput(since start: Date) -> Shortfall? {
        if FrameRecorder.isMovie(destination) {
            guard Self.isWritten(destination, since: start) else { return .notWritten }
            guard let found = MovieFile.videoSampleCount(atPath: destination) else {
                return .unreadable
            }
            return found == frameCount ? nil : .frames(found: found)
        }
        guard var sequence = FrameSequence(pattern: destination) else { return .notWritten }
        var found = 0
        for _ in 0..<frameCount where Self.isWritten(sequence.next(), since: start) {
            found += 1
        }
        return found == frameCount ? nil : .frames(found: found)
    }

    /// この回に書かれた、中身のあるファイルか。
    ///
    /// 時刻は 1 秒の余裕を見る。ファイルシステムが時刻を秒に丸めても、この回のものを
    /// 前の回の残りと取り違えない (前の回の残りがこの余裕に入るのは、1 秒以内に続けて打ったときだけ)。
    private nonisolated static func isWritten(_ path: String, since start: Date) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? Int, size > 0,
            let modified = attributes[.modificationDate] as? Date
        else { return false }
        return modified >= start.addingTimeInterval(-1)
    }
}

extension MovieFile {
    /// 動画の映像の標本の数。読めなければ `nil`。
    ///
    /// 復号しない (`outputSettings: nil`)。数えるだけなので、長い動画でも読みを待つのは入れ物の
    /// 索引くらいである。AVFoundation のトラックの読み込みは非同期の口しか無いので、別の仕事で
    /// 読ませて待つ (呼ぶのは道具の主スレッドで、仕事は主スレッドを要らない)。
    nonisolated static func videoSampleCount(atPath path: String) -> Int? {
        /// 仕事と待つ側の間で結果を渡す箱。**書くのは仕事が 1 度だけで、読むのは合図の後だけ**。
        nonisolated final class Box: @unchecked Sendable {
            var count: Int?
        }
        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        Task.detached {
            defer { finished.signal() }
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                let reader = try? AVAssetReader(asset: asset)
            else { return }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { return }
            reader.add(output)
            guard reader.startReading() else { return }
            var count = 0
            while let sample = output.copyNextSampleBuffer() {
                count += CMSampleBufferGetNumSamples(sample)
            }
            guard reader.status == .completed else { return }
            box.count = count
        }
        finished.wait()
        return box.count
    }
}
