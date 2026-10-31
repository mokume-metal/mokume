// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreMedia

/// 動画の映像のトラックを表示順に読み進め、頼まれた位置に映っているコマを持つ、読み進めの核。
///
/// ``MovieReader`` から、`AVAssetReader` を開いて読み進め・読み直す部分だけを切り出したもの
/// ([#2523])。読み方 (読み進めるか・読み直すか・読めなくなった後にいつ試すか) は ``MovieReader`` の
/// 説明のとおりで、ここはその中身を持つ。変換と向き、同じコマを 2 度渡さない印は ``MovieReader`` に残る。
///
/// **`Sendable` にしない。** 1 つの核を触るのは 1 本の流れだけで、この型はその上に閉じている。
/// 隔離を持たないのは、main actor の外 (先読みの係) でも同じ核を持てるようにするためである。
///
/// [#2523]: https://github.com/mokume-metal/mokume/issues/2523
nonisolated final class MovieFrames {
    /// 読めなかった理由。人が読む 1 文。
    struct Failure: Error, Equatable, Sendable {
        let reason: String
    }

    /// 届いた 1 枚。
    struct Decoded {
        /// 表示時刻 (秒)。トラックの始まりを 0 とする。
        let time: Double
        let buffer: CVPixelBuffer
        /// 届いた順の番号。同じコマを 2 度渡さないための印。
        let serial: Int
    }

    /// これより先へ飛ぶときは、読み進めずに読み直す (秒)。
    ///
    /// 読み進めると、飛んだ間のコマを全部復号して変換する。読み直すと、その位置の手前の鍵のコマから
    /// 復号し直すが、飛び先より前のコマは変換しない。普通の動画の鍵のコマの間隔 (1〜2 秒) と同じ桁に
    /// 置く。**鍵のコマの位置を引けても縮めない** — 間に鍵のコマが無くても、遠い先は読み直すほうが
    /// 速い ([#2764] の実測: 4K で 75 コマ先へ読み進めると 257 ms、読み直すと 141 ms)。
    ///
    /// [#2764]: https://github.com/mokume-metal/mokume/issues/2764
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

    /// 長さ (秒)。
    let duration: Double

    private let asset: AVURLAsset
    private let track: AVAssetTrack
    /// トラックの始まり (アセットの時間軸の上)。
    private let start: CMTime
    /// 鍵のコマの位置。引けない動画では `nil`。
    private let keyFrames: KeyFrameIndex?

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// いま映しているコマ。
    private(set) var current: Decoded?
    /// 次のコマ (読み終えていれば `nil`)。
    private(set) var upcoming: Decoded?
    private var serial = 0
    /// 読めなくなった後、読み直しを試してよい位置 (秒)。
    private var retryAfter = 0.0
    /// 読み直した回数 (作るときに開いた分は数えない)。**検査が読む。**
    private(set) var restarts = 0
    /// 読めなくなって止まっていて、読み直しを試す位置にまだ届いていないか。``MovieReader`` の同名の
    /// 値の説明を見る。
    private(set) var isWaitingToRetry = false

    /// 開いて、最初のコマと次のコマまで読む。
    ///
    /// - Parameters:
    ///   - asset: 動画。
    ///   - track: 読む映像のトラック。
    ///   - start: トラックの始まり (アセットの時間軸の上)。
    ///   - duration: 長さ (秒)。
    ///   - keyFrames: 鍵のコマの位置。引かないなら `nil` (``seekAhead`` で分ける)。
    init(
        asset: AVURLAsset, track: AVAssetTrack, start: CMTime, duration: Double, keyFrames: KeyFrameIndex?
    ) throws(Failure) {
        self.asset = asset
        self.track = track
        self.start = start
        self.duration = duration
        self.keyFrames = keyFrames
        guard let opened = try Self.open(asset: asset, track: track, from: start) else {
            throw Failure(reason: "no frame")
        }
        (reader, output) = opened
        guard let first = try readNext() else { throw Failure(reason: "no frame") }
        current = first
        upcoming = try readNext()
    }

    /// ``current`` を `position` 秒に映っているコマへ進める。読めなくなった後で、まだ試さなかったなら
    /// `false` を返す (``current`` は動かない)。
    ///
    /// 範囲の外は端のコマになる。読めなくなったら投げ、最後に読めたコマを持ったまま止まる。
    /// 止まった後は、頼まれた位置が手前へ戻るか ``retryDistance`` より先へ進んだときに読み直す。
    ///
    /// **試さなかったときの ``current`` は渡さない。** 読み進める途中で投げると、``current`` は渡す前の
    /// コマまで進んでいることがある。試さない間にそれを渡すと、読めていないのに新しいコマが届いて見える。
    @discardableResult
    func advance(to position: Double) throws(Failure) -> Bool {
        let target = position + Playhead.tolerance
        do {
            if reader == nil {
                // 読めなくなった後。手前へ戻るか、十分先へ進むまでは試さない (``isWaitingToRetry`` は
                // 投げたときに立てたまま。ここでは下ろさない)
                if let current, target >= current.time, target < retryAfter { return false }
                try restart(at: position)
            } else if needsRestart(to: target) {
                try restart(at: position)
            }
            while let next = upcoming, next.time <= target {
                current = next
                upcoming = try readNext()
            }
        } catch {
            stop(retryingAfter: target + Self.retryDistance)
            throw error
        }
        // 投げずにここへ来たのは、読めている (読み直して読めた) とき
        isWaitingToRetry = false
        return true
    }

    /// 次のコマへ 1 枚進める (``upcoming`` を ``current`` に)。読み終えていれば何もしない。
    ///
    /// 読めなくなったら投げ、``advance(to:)`` と同じく止まる。先読みの係が、列を 1 枚ずつ埋めるのに使う。
    func step() throws(Failure) {
        guard let next = upcoming else { return }
        current = next
        do {
            upcoming = try readNext()
        } catch {
            stop(retryingAfter: next.time + Playhead.tolerance + Self.retryDistance)
            throw error
        }
    }

    /// 読み手と持っているコマを手放す。次の ``advance(to:)`` は、頼まれた位置から読み直す。
    ///
    /// ``close()`` と違い、映していたコマも手放す (4K で 2 枚・約 63 MiB)。実時間の時計で先読みに移った
    /// main の読み手を休ませるのに使う。
    func park() {
        close()
        current = nil
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

    /// 読めなくなったところで止まる。最後に読めたコマは ``current`` に残し、`position` 秒より先へ
    /// 進むか手前へ戻るまで読み直しを試さない。
    private func stop(retryingAfter position: Double) {
        reader?.cancelReading()
        reader = nil
        output = nil
        upcoming = nil
        retryAfter = position
        isWaitingToRetry = true
    }

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
        // (``FrameConverter`` は BGRA だけを受ける。カメラと同じ理由)。面 (IOSurface) の裏付きで Metal が
        // 読める形も頼む — 面のまま絵へ渡す道 (``SurfaceRoute``・#2962) が要る
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
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
}
