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
/// 最も遅いコマ) を返す。後ろへ戻る (ループの継ぎ目・頭出し) か、``seekAhead`` より先へ飛ぶか、
/// 次のコマと頼まれた位置の間に鍵のコマ (それだけで復号できるコマ) が十分先にある
/// (``KeyFrameIndex``、[#2764]) ときだけ、その位置から読み直す。同じ並びで頼めば同じ道を通るので、
/// 同じ位置には同じコマが返る — 固定の時計で書き出すと、何度書き出しても同じフレームに同じコマが
/// 出る。どちらで読むかは速さだけの違いで、映るコマは変わらない。
///
/// 読み直しのほうが速いのは、遠い先か、間に鍵のコマがあるときである。読み進めると間のコマを 1 枚
/// ずつ変換して受け取るが、読み直すと飛び先より前のコマは (手前の鍵のコマから) 復号するだけで
/// 受け取らない — 1 コマあたり半分ほどで済む (実測、4K で約 3.4 ms と 1.7 ms)。
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
/// Swift では非推奨) ので、完了ハンドラで受けて待つ。ハンドラは AVFoundation の側のスレッドで呼ばれ、
/// Swift の協調プールを要らない — 作品が協調プールを埋めていても、作る呼び出しは返る (#3240)。
/// 受けるのは手元のファイルの場所だけ (`createVideo(_:)` が `assetURL(_:)` で解く) なので、
/// 待ちに期限は持たない。手元のファイルなら 1 ms ほどで返る。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
/// [#2764]: https://github.com/mokume-metal/mokume/issues/2764
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

    /// 鍵のコマの位置を引く口。
    enum KeyFrameLookup {
        /// トラックのサンプルの目録から引く (既定)。
        case track
        /// 引かない。目録を引けない動画と同じく ``MovieReader/seekAhead`` で分ける (検査が、
        /// 目録を引けない動画と変更前の振る舞いを再現するのに使う)。
        case unavailable
    }

    /// これより先へ飛ぶときは、読み進めずに読み直す (秒)。
    ///
    /// 読み進めると、飛んだ間のコマを全部復号して変換する。読み直すと、その位置の手前の鍵のコマから
    /// 復号し直すが、飛び先より前のコマは変換しない。普通の動画の鍵のコマの間隔 (1〜2 秒) と同じ桁に
    /// 置く。**鍵のコマの位置を引けても縮めない** — 間に鍵のコマが無くても、遠い先は読み直すほうが
    /// 速い ([#2764] の実測: 4K で 75 コマ先へ読み進めると 257 ms、読み直すと 141 ms)。
    static let seekAhead = 1.0

    /// ``seekAhead`` より近い先へ鍵のコマを跨いで読み直すのは、飛び先の手前の鍵のコマが次のコマより
    /// これ以上先にあるときだけ (秒)。
    ///
    /// 読み直しは開く費用を払う (4K で 13〜17 ms)。すぐ先の鍵のコマのために読み直すと、読み進める
    /// より遅い。全部が鍵のコマの動画 (ProRes など) を 1 コマ飛ばしで流すと、毎フレーム読み直しにも
    /// なる。
    static let restartMargin = 0.2

    /// 読めなくなった後、読み直しを試すまでに先へ進む長さ (秒)。``Movie`` の説明文の「1 秒より先へ
    /// 進むと読み直し」がこれである。
    static let retryDistance = 1.0

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
    /// 鍵のコマの位置。引けない動画では `nil`。
    private let keyFrames: KeyFrameIndex?
    /// 読み直した回数 (作るときに開いた分は数えない)。**検査が読む。**
    private(set) var restarts = 0
    /// 読めなくなって止まっていて、読み直しを試す位置にまだ届いていないか。
    ///
    /// **``picture(at:)`` の `nil` は「前と同じコマ」でも返る**ので、`nil` からは「読めているが新しい
    /// コマが無い」と「試さずに待っている」が分からない。後者の間は読めていないので、``Movie`` は
    /// ``SourceState/disconnected`` のまま保つ (#2908)。読み直して読めれば下りる。
    ///
    /// 変換できないコマは、これではなく「渡し済み」の印で表す。渡せていないコマは次のフレームも
    /// 変換を試して投げる (``picture(at:)``)。
    private(set) var isWaitingToRetry = false

    /// 開いて、最初のコマまで読む。
    ///
    /// **開けないものを「壊れている・形式が違う」と名乗らない** ([#2358])。AVFoundation はディレクトリや
    /// 読む権利の無いファイルを、形式の誤りと同じく断る。読む前に開けるかを確かめ
    /// (``AssetOpening``)、開けなければ ``MovieFailure/unopenable(path:location:reason:)`` を投げる。
    ///
    /// - Parameters:
    ///   - url: 動画ファイルの場所。
    ///   - path: 失敗の説明に載せる名前。
    ///   - keyFrames: 鍵のコマの位置を引くか。
    ///
    /// [#2358]: https://github.com/mokume-metal/mokume/issues/2358
    init(url: URL, path: String, keyFrames lookup: KeyFrameLookup = .track) throws(MovieFailure) {
        self.path = path
        if let refusal = AssetOpening.refusal(at: url) {
            throw .unopenable(path: path, location: refusal.location, reason: refusal.reason)
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (track, range, canProvideSampleCursors) = try Self.inspect(asset, path: path)
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
        keyFrames =
            lookup == .track
            ? KeyFrameIndex(track: track, start: range.start, canProvideSampleCursors: canProvideSampleCursors)
            : nil
        width = CVPixelBufferGetWidth(first.buffer)
        height = CVPixelBufferGetHeight(first.buffer)
        // 動画は透過を持ちうるので、不透明度を乗算していないまま運ぶ (#2881)
        converter = FrameConverter(width: width, height: height, alpha: .straight)
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
    /// 止まった後は、頼まれた位置が手前へ戻るか ``retryDistance`` より先へ進んだときに読み直す。
    func picture(at position: Double) throws(Failure) -> DisplayImage? {
        let target = position + Playhead.tolerance
        do {
            if reader == nil {
                // 読めなくなった後。手前へ戻るか、十分先へ進むまでは試さない (``isWaitingToRetry`` は
                // 投げたときに立てたまま。ここでは下ろさない)
                if let current, target >= current.time, target < retryAfter { return nil }
                try restart(at: position)
            } else if needsRestart(to: target) {
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
            retryAfter = target + Self.retryDistance
            isWaitingToRetry = true
            throw error
        }
        // 投げずにここへ来たのは、読めている (読み直して読めた) とき
        isWaitingToRetry = false
        guard let current, current.serial != handed else { return nil }
        let image: DisplayImage
        do {
            image = try convert(current.buffer)
        } catch {
            // **渡し済みの印は、変換が通った後に書く。** 先に書くと、変換できないコマは次のフレームで
            // 「前と同じコマ」の `nil` になり、読めていないのに ``Movie`` が running と名乗る (#2908)。
            // 書かなければ、変換できる間は毎フレーム試して投げる
            throw Failure(reason: error.description)
        }
        handed = current.serial
        return image
    }

    /// コマの変換。既定は ``converter``。**検査が、変換できない動画を作らずに失敗を差し込む。**
    var conversion: ((CVPixelBuffer) throws(FrameConverter.Failure) -> DisplayImage)?

    private func convert(_ buffer: CVPixelBuffer) throws(FrameConverter.Failure) -> DisplayImage {
        if let conversion { return try conversion(buffer) }
        return try converter.convert(buffer)
    }

    /// 読むのをやめる。
    func close() {
        reader?.cancelReading()
        reader = nil
        output = nil
        upcoming = nil
        // **読み直しを試してよい位置も戻す** (#3122)。読めなくなって止まっていた動画を外して足し直すと、
        // 戻さない限り「まだ試さない」が続き、読めていないのに ``Movie`` が running と名乗る。
        // 足し直した最初のフレームで読み直し、読めなければ改めて disconnected になる
        retryAfter = 0
        isWaitingToRetry = false
    }

    // MARK: - 読む

    /// `target` 秒のコマを、読み進めずに読み直して得るか。
    private func needsRestart(to target: Double) -> Bool {
        guard let current else { return true }
        // 後ろへ戻る
        if target < current.time { return true }
        // 終わりまで読み終えていれば (`upcoming` が無い)、先はどこも終わりのコマなので読み直さない
        guard let upcoming else { return false }
        // 遠い先は、間に鍵のコマが無くても読み直すほうが速い
        if target > current.time + Self.seekAhead { return true }
        // 余裕より近い先は、間に鍵のコマがあってもすぐ先なので読み進める (目録を引くまでもない)
        guard target >= upcoming.time + Self.restartMargin else { return false }
        return keyFrames?.answer(after: upcoming.time, upTo: target, margin: Self.restartMargin) == .restart
    }

    /// `position` 秒から読み直す。届いた最初のコマがその位置に映っているコマになる。
    private func restart(at position: Double) throws(Failure) {
        restarts += 1
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

    /// 最初の映像のトラックと、その時間の範囲と、サンプルの目録を引かせるかを、待って受け取る。
    /// 目録を引かせるかが読めなくても失敗にはしない (引かせない扱いで、1 秒で分ける)。
    ///
    /// **読み込みは完了ハンドラで受ける。** ハンドラは AVFoundation の側のスレッドで呼ばれ、Swift の
    /// 協調プールの空きを要らない。async の口 (`load(_:)`) を別の仕事に載せて待つと、作品が協調プールを
    /// 同期の重い仕事で埋めている間は、読み込みが走れず、塞いで待つここが返らない (#3240)。
    /// `loadTracks(withMediaType:completionHandler:)` は非推奨ではないが、`loadValuesAsynchronously` と
    /// `timeRange`・`canProvideSampleCursors` の同期の getter は Swift から非推奨 (macOS 13〜) —
    /// 協調プールの外で待てる口がこれしか無いので使う。Apple がこれを消したら、そのときの async の口と
    /// executor の事情で選び直す。
    ///
    /// **検査が直に呼ぶ** (協調プールを埋めた状態で返るかを見る)。
    nonisolated static func inspect(
        _ asset: AVURLAsset, path: String
    ) throws(MovieFailure) -> (AVAssetTrack, CMTimeRange, Bool) {
        // 読み込みの結果を待つ側へ渡す箱。**書くのは完了ハンドラが 1 度だけで、読むのは合図を待った
        // 後だけ** — 合図が前後を決めるので、錠は要らない
        nonisolated final class Box: @unchecked Sendable {
            var outcome: Result<(AVAssetTrack, CMTimeRange, Bool)?, any Error> = .success(nil)
        }
        let box = Box()
        let loaded = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .video) { tracks, error in
            guard let track = tracks?.first else {
                // 映像が無いのは (トラックの一覧は読めた) `.success(nil)`、一覧が読めなかったのは失敗
                if let error { box.outcome = .failure(error) }
                loaded.signal()
                return
            }
            track.loadValuesAsynchronously(forKeys: ["timeRange", "canProvideSampleCursors"]) {
                var failure: NSError?
                if track.statusOfValue(forKey: "timeRange", error: &failure) == .loaded {
                    // 目録を引かせるかが読めなければ、引かせない扱い
                    let cursors =
                        track.statusOfValue(forKey: "canProvideSampleCursors", error: nil) == .loaded
                        && track.canProvideSampleCursors
                    box.outcome = .success((track, track.timeRange, cursors))
                } else {
                    box.outcome = .failure(failure ?? Failure(reason: "the time range could not be loaded"))
                }
                loaded.signal()
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
