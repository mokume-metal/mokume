// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreMedia
import Foundation
import MokumeCore

/// 動画ファイルの映像を、位置を指定して 1 枚ずつ読む。**AVFoundation で動画を読むのはこの型だけ
/// である。**
///
/// ## 読み進め、戻るときだけ読み直す
///
/// `AVAssetReader` で表示順に読み進め、頼まれた位置に映っているコマ (表示時刻がその位置以下で
/// 最も遅いコマ) を返す。後ろへ戻る (ループの継ぎ目・頭出し) か、``seekAhead`` より先へ飛ぶ
/// ときだけ、その位置から読み直す。同じ並びで頼めば同じ道を通るので、同じ位置には同じコマが
/// 返る — 固定の時計で書き出すと、何度書き出しても同じフレームに同じコマが出る。
///
/// **読み直した最初のコマは、表示時刻が読み直した位置に書き換わって届く** (AVFoundation が
/// 範囲の頭で切る。実測)。中身はその位置に映っているコマそのもので、続くコマは本来の時刻で届く。
///
/// ## main actor の上で同期に読む
///
/// 待ち行列もスレッドも足さない。OS のコールバックを受ける口が無いので、[ADR-0042] 決定 7 の
/// 「受ける点」が要らない。1 枚の復号と変換はフレームの予算に収まる大きさで、コマが変わった
/// フレームにだけ払う。
///
/// 作るときのトラックの読み込みだけは、AVFoundation が非同期の口しか持たない (同期の口は
/// Swift では非推奨) ので、別の仕事で読ませて待つ (`WebFile.fetchWaiting` と同じ形)。手元の
/// ファイルなら 1 ms ほどで返る。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
final class MovieReader {
    /// 読めなかった理由。人が読む 1 文。
    struct Failure: Error, Equatable {
        let reason: String
    }

    /// 届いた 1 枚。
    private struct Decoded {
        /// 表示時刻 (秒)。トラックの始まりを 0 とする。
        let time: Double
        let buffer: CVPixelBuffer
        /// 届いた順の番号。同じコマを 2 度渡さないための印。
        let serial: Int
    }

    /// これより先へ飛ぶときは、読み進めずに読み直す (秒)。
    ///
    /// 読み進めると、飛んだ間のコマを全部復号する。読み直すと、その位置の手前の鍵のコマから
    /// 復号し直す。普通の動画の鍵のコマの間隔 (1〜2 秒) と同じ桁に置く。
    static let seekAhead = 1.0

    /// 失敗の説明に載せる名前 (利用者が渡した綴り)。
    let path: String
    /// 幅 (画素)。最初のコマの大きさ。
    let width: Int
    /// 高さ (画素)。
    let height: Int
    /// 長さ (秒)。
    let duration: Double

    private let asset: AVURLAsset
    private let track: AVAssetTrack
    /// トラックの始まり (アセットの時間軸の上)。
    private let start: CMTime
    private let converter: FrameConverter

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// いま映しているコマ。
    private var current: Decoded?
    /// 次のコマ (読み終えていれば `nil`)。
    private var upcoming: Decoded?
    private var serial = 0
    /// 最後に渡したコマの番号。
    private var handed: Int?
    /// 読めなくなった後、読み直しを試してよい位置 (秒)。
    private var retryAfter = 0.0

    /// 開いて、最初のコマまで読む。
    ///
    /// - Parameters:
    ///   - url: 動画ファイルの場所。
    ///   - path: 失敗の説明に載せる名前。
    init(url: URL, path: String) throws(MovieFailure) {
        self.path = path
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (track, range) = try Self.inspect(asset, path: path)
        let duration = range.duration.seconds
        guard duration.isFinite, duration > 0 else { throw .unreadable(path: path) }

        // 最初のコマまで読む。読めなければ作れない (大きさも最初のコマで決まる)
        let opened: (reader: AVAssetReader, output: AVAssetReaderTrackOutput)
        let first: (time: CMTime, buffer: CVPixelBuffer)
        do {
            guard let made = try Self.open(asset: asset, track: track, from: range.start),
                let sample = try Self.next(from: made.output, reader: made.reader)
            else { throw Failure(reason: "no frame") }
            opened = made
            first = sample
        } catch {
            throw .unreadable(path: path)
        }
        self.asset = asset
        self.track = track
        self.start = range.start
        self.duration = duration
        width = CVPixelBufferGetWidth(first.buffer)
        height = CVPixelBufferGetHeight(first.buffer)
        converter = FrameConverter(width: width, height: height)
        reader = opened.reader
        output = opened.output
        serial = 1
        current = Decoded(
            time: CMTimeSubtract(first.time, range.start).seconds, buffer: first.buffer, serial: serial)
        do {
            upcoming = try readNext()
        } catch {
            throw .unreadable(path: path)
        }
    }

    /// `position` 秒に映っているコマ。**前に渡したコマと同じなら `nil`。**
    ///
    /// 範囲の外は端のコマを返す。読めなくなったら投げ、最後に読めたコマを持ったまま止まる。
    /// 止まった後は、頼まれた位置が手前へ戻るか ``seekAhead`` より先へ進んだときに読み直す。
    func picture(at position: Double) throws(Failure) -> DisplayImage? {
        let target = position + Playhead.tolerance
        do {
            if reader == nil {
                // 読めなくなった後。手前へ戻るか、十分先へ進むまでは試さない
                if let current, target >= current.time, target < retryAfter { return nil }
                try restart(at: position)
            } else if let current,
                target < current.time || (upcoming != nil && target > current.time + Self.seekAhead)
            {
                // 終わりまで読み終えていれば (`upcoming` が無い)、先はどこも終わりのコマなので読み直さない
                try restart(at: position)
            }
            while let next = upcoming, next.time <= target {
                current = next
                upcoming = try readNext()
            }
        } catch {
            reader?.cancelReading()
            reader = nil
            output = nil
            upcoming = nil
            retryAfter = target + Self.seekAhead
            throw error
        }
        guard let current, current.serial != handed else { return nil }
        handed = current.serial
        do {
            return try converter.convert(current.buffer)
        } catch {
            throw Failure(reason: error.description)
        }
    }

    /// 読むのをやめる。
    func close() {
        reader?.cancelReading()
        reader = nil
        output = nil
        upcoming = nil
    }

    // MARK: - 読む

    /// `position` 秒から読み直す。届いた最初のコマがその位置に映っているコマになる。
    private func restart(at position: Double) throws(Failure) {
        reader?.cancelReading()
        reader = nil
        output = nil
        upcoming = nil
        // 終わりちょうどから読むと 1 枚も届かない。終わりのコマを映すため、終わりの 1 µs 手前から読む
        let end = CMTimeAdd(start, CMTime(seconds: duration, preferredTimescale: Self.timescale))
        var from = CMTimeAdd(start, CMTime(seconds: max(0, position), preferredTimescale: Self.timescale))
        if CMTimeCompare(from, end) >= 0 {
            from = CMTimeSubtract(end, CMTime(value: 1, timescale: Self.timescale))
        }
        guard let opened = try Self.open(asset: asset, track: track, from: from) else {
            throw Failure(reason: "the reader could not start")
        }
        (reader, output) = opened
        // 読めなければ、いま映しているコマは残す
        guard let first = try readNext() else { throw Failure(reason: "no frame at \(position) s") }
        current = first
        upcoming = try readNext()
    }

    /// 次の 1 枚。読み終えていれば `nil`。
    private func readNext() throws(Failure) -> Decoded? {
        guard let output, let sample = try Self.next(from: output, reader: reader) else { return nil }
        serial += 1
        return Decoded(time: CMTimeSubtract(sample.time, start).seconds, buffer: sample.buffer, serial: serial)
    }

    /// 位置を表す刻み (1 µs)。
    private static let timescale: CMTimeScale = 1_000_000

    /// `from` から読む読み手を開く。開けなければ `nil`。
    private static func open(
        asset: AVURLAsset, track: AVAssetTrack, from: CMTime
    ) throws(Failure) -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput)? {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw Failure(reason: error.localizedDescription)
        }
        // **画素の形式は 32BGRA を頼む** — YpCbCr から RGB へは AVFoundation に変換させる
        // (``FrameConverter`` は BGRA だけを受ける。カメラと同じ理由)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        // 書き換えないので写さない
        output.alwaysCopiesSampleData = false
        reader.timeRange = CMTimeRange(start: from, duration: .positiveInfinity)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else {
            throw Failure(reason: reader.error?.localizedDescription ?? "the reader could not start")
        }
        return (reader, output)
    }

    /// 読み手から次の 1 枚 (表示時刻と画素)。読み終えていれば `nil`、読めなくなったら投げる。
    private static func next(
        from output: AVAssetReaderTrackOutput, reader: AVAssetReader?
    ) throws(Failure) -> (time: CMTime, buffer: CVPixelBuffer)? {
        while true {
            guard let sample = output.copyNextSampleBuffer() else {
                if let reader, reader.status == .failed {
                    throw Failure(reason: reader.error?.localizedDescription ?? "the reader failed")
                }
                return nil
            }
            // 画素を持たない標本 (区切りの印など) は飛ばす
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            return (CMSampleBufferGetPresentationTimeStamp(sample), buffer)
        }
    }

    // MARK: - 開く

    /// 最初の映像のトラックと、その時間の範囲を、待って受け取る。
    private static func inspect(
        _ asset: AVURLAsset, path: String
    ) throws(MovieFailure) -> (AVAssetTrack, CMTimeRange) {
        // 読み込みの仕事と待つ側の間で結果を渡す箱。**書くのは読み込みの仕事が 1 度だけで、
        // 読むのは合図を待った後だけ** — 合図が前後を決めるので、錠は要らない
        nonisolated final class Box: @unchecked Sendable {
            var outcome: Result<(AVAssetTrack, CMTimeRange)?, any Error> = .success(nil)
        }
        let box = Box()
        let loaded = DispatchSemaphore(value: 0)
        // main actor の外で読ませる。読み込みは main actor を要らないので、塞いで待っても詰まらない
        Task.detached {
            defer { loaded.signal() }
            do {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
                box.outcome = .success((track, try await track.load(.timeRange)))
            } catch {
                box.outcome = .failure(error)
            }
        }
        loaded.wait()
        switch box.outcome {
        case .success(let found?): return found
        case .success(nil): throw .noVideo(path: path)
        case .failure: throw .unreadable(path: path)
        }
    }
}
