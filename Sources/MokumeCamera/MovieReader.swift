// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreMedia
import Foundation
import MokumeCore

/// 動画ファイルの映像を、位置を指定して 1 枚ずつ読む。**AVFoundation で動画を読むのはこの型と、
/// この型が持つ読み進めの核 (``MovieFrames``) だけである。**
///
/// ## 読み進め、戻るときだけ読み直す
///
/// `AVAssetReader` で表示順に読み進め、頼まれた位置に映っているコマ (表示時刻がその位置以下で
/// 最も遅いコマ) を返す。後ろへ戻る (ループの継ぎ目・頭出し) か、``MovieFrames/seekAhead`` より先へ飛ぶか、
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
/// この型は、頼まれたフレームのうちに位置のコマを読んで返す (待つ)。``Movie`` がこの型で読むのは、
/// フレームの時計 (書き出し・検査・`clock: .frames` の窓)・時刻を指定した観測の 1 枚・実時間の時計の
/// 最初の 1 枚である。実時間の時計で流している間は、先読みの係 (``MoviePrefetcher``) が別の読み手で
/// 先を読み、この型の読み手は ``park()`` で休ませる。2 つは ``MovieFrames`` をそれぞれ 1 つずつ持ち、
/// `AVAssetReader` を共有しない ([ADR-0042] 決定 7 の改訂 (2026-10-31)、[#2523])。
///
/// 作るときのトラックの読み込みだけは、AVFoundation が非同期の口しか持たない (同期の口は
/// Swift では非推奨) ので、完了ハンドラで受けて待つ。ハンドラは AVFoundation の側のスレッドで呼ばれ、
/// Swift の協調プールを要らない — 作品が協調プールを埋めていても、作る呼び出しは返る (#3240)。
/// 受けるのは手元のファイルの場所だけ (`createVideo(_:)` が `assetURL(_:)` で解く) なので、
/// 待ちに期限は持たない。手元のファイルなら 1 ms ほどで返る。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
/// [#2523]: https://github.com/mokume-metal/mokume/issues/2523
/// [#2764]: https://github.com/mokume-metal/mokume/issues/2764
final class MovieReader {

    /// 読めなかった理由。人が読む 1 文。
    typealias Failure = MovieFrames.Failure

    /// 鍵のコマの位置を引く口。
    enum KeyFrameLookup {
        /// トラックのサンプルの目録から引く (既定)。
        case track
        /// 引かない。目録を引けない動画と同じく ``MovieFrames/seekAhead`` で分ける (検査が、
        /// 目録を引けない動画と変更前の振る舞いを再現するのに使う)。
        case unavailable
    }

    /// 読めなくなった後、読み直しを試すまでに先へ進む長さ (秒)。``MovieFrames/retryDistance`` と同じ。
    static let retryDistance = MovieFrames.retryDistance

    /// 失敗の説明に載せる名前 (利用者が渡した綴り)。
    let path: String
    /// 幅 (画素)。**回転の印 (``orientation``) を当てた後**の、最初のコマの大きさ。
    let width: Int
    /// 高さ (画素)。回転の印を当てた後。
    let height: Int
    /// 動画が記録している向き。``picture(at:)`` が返す 1 枚ごとに当てる。
    let orientation: VideoOrientation
    /// 長さ (秒)。
    var duration: Double { frames.duration }

    /// 先読みの係が開き直す動画ファイル。
    let source: MovieSource

    /// 読み進めの核。
    private let frames: MovieFrames
    private let converter: FrameConverter
    /// 最後に渡したコマの番号。
    private var handed: Int?
    /// 読み直した回数 (作るときに開いた分は数えない)。**検査が読む。**
    var restarts: Int { frames.restarts }
    /// 読めなくなって止まっていて、読み直しを試す位置にまだ届いていないか。
    ///
    /// **``picture(at:)`` の `nil` は「前と同じコマ」でも返る**ので、`nil` からは「読めているが新しい
    /// コマが無い」と「試さずに待っている」が分からない。後者の間は読めていないので、``Movie`` は
    /// ``SourceState/disconnected`` のまま保つ (#2908)。読み直して読めれば下りる。
    ///
    /// 変換できないコマは、これではなく「渡し済み」の印で表す。渡せていないコマは次のフレームも
    /// 変換を試して投げる (``picture(at:)``)。
    var isWaitingToRetry: Bool { frames.isWaitingToRetry }

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
        let (track, range, canProvideSampleCursors, transform) = try Self.inspect(asset, path: path)
        let duration = range.duration.seconds
        guard duration.isFinite, duration > 0 else { throw .unreadable(path: path) }

        // 最初のコマまで読む。読めなければ作れない (大きさも最初のコマで決まる)
        let keyFrames =
            lookup == .track
            ? KeyFrameIndex(track: track, start: range.start, canProvideSampleCursors: canProvideSampleCursors)
            : nil
        let frames: MovieFrames
        do {
            frames = try MovieFrames(
                asset: asset, track: track, start: range.start, duration: duration, keyFrames: keyFrames)
        } catch {
            throw .unreadable(path: path)
        }
        guard let first = frames.current else { throw .unreadable(path: path) }
        self.frames = frames
        let recordedWidth = CVPixelBufferGetWidth(first.buffer)
        let recordedHeight = CVPixelBufferGetHeight(first.buffer)
        // 縦に撮った動画は、横長の絵に回転の印が付いている。変換は記録された大きさで済ませ、向きは
        // 変換した後の 1 枚に当てる (公開する大きさは当てた後)
        orientation = VideoOrientation(transform)
        (width, height) = orientation.size(width: recordedWidth, height: recordedHeight)
        // 動画は透過を持ちうるので、不透明度を乗算していないまま運ぶ (#2881)
        converter = FrameConverter(width: recordedWidth, height: recordedHeight, alpha: .straight)
        source = MovieSource(
            url: url, path: path, indexesKeyFrames: lookup == .track, width: recordedWidth, height: recordedHeight,
            orientation: orientation)
    }

    /// `position` 秒に映っているコマ。**前に渡したコマと同じなら `nil`。** 面のまま渡せるコマは面で返す
    /// (``SurfaceRoute``。表は作らず、先読みの係やカメラが作った表があるときだけ — main で作らない)。
    ///
    /// 範囲の外・読めなくなったときは ``picture(at:)`` と同じ。
    func frame(at position: Double) throws(Failure) -> VideoFrame? {
        guard try frames.advance(to: position) else { return nil }
        guard let current = frames.current, current.serial != handed else { return nil }
        if case .success(let surface) = SurfaceRoute.surface(
            for: current.buffer, alpha: .straight, reshaped: orientation != .identity || conversion != nil,
            builds: false)
        {
            handed = current.serial
            return .surface(surface)
        }
        return try picture(at: position).map(VideoFrame.converted)
    }

    /// `position` 秒に映っているコマ。**前に渡したコマと同じなら `nil`。**
    ///
    /// 範囲の外は端のコマを返す。読めなくなったら投げ、最後に読めたコマを持ったまま止まる。
    /// 止まった後は、頼まれた位置が手前へ戻るか ``retryDistance`` より先へ進んだときに読み直す。
    func picture(at position: Double) throws(Failure) -> DisplayImage? {
        // 読めなくなった後で、まだ試さなかった
        guard try frames.advance(to: position) else { return nil }
        guard let current = frames.current, current.serial != handed else { return nil }
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
        return image.oriented(orientation)
    }

    /// コマの変換。既定は ``converter``。**検査が、変換できない動画を作らずに失敗を差し込む。**
    var conversion: ((CVPixelBuffer) throws(FrameConverter.Failure) -> DisplayImage)?

    private func convert(_ buffer: CVPixelBuffer) throws(FrameConverter.Failure) -> DisplayImage {
        if let conversion { return try conversion(buffer) }
        return try converter.convert(buffer)
    }

    /// 読み手を休ませる。開いている `AVAssetReader` と持っているコマ (4K で 2 枚・約 63 MiB) を手放し、
    /// 次の ``picture(at:)`` はその位置から読み直す。実時間の時計で先読みに移ったときに呼ぶ。
    func park() {
        frames.park()
    }

    /// 読むのをやめる。
    func close() {
        frames.close()
    }

    // MARK: - 開く

    /// 最初の映像のトラックと、その時間の範囲と、サンプルの目録を引かせるかと、回転の印を、待って受け取る。
    /// 目録を引かせるかが読めなくても失敗にはしない (引かせない扱いで、1 秒で分ける)。
    ///
    /// **読み込みは完了ハンドラで受ける。** ハンドラは AVFoundation の側のスレッドで呼ばれ、Swift の
    /// 協調プールの空きを要らない。async の口 (`load(_:)`) を別の仕事に載せて待つと、作品が協調プールを
    /// 同期の重い仕事で埋めている間は、読み込みが走れず、塞いで待つここが返らない (#3240)。
    /// `loadTracks(withMediaType:completionHandler:)` は非推奨ではないが、`loadValuesAsynchronously` と
    /// `timeRange`・`canProvideSampleCursors`・`preferredTransform` の同期の getter は Swift から非推奨 (macOS 13〜) —
    /// 協調プールの外で待てる口がこれしか無いので使う。Apple がこれを消したら、そのときの async の口と
    /// executor の事情で選び直す。
    ///
    /// **検査が直に呼ぶ** (協調プールを埋めた状態で返るかを見る)。
    nonisolated static func inspect(
        _ asset: AVURLAsset, path: String
    ) throws(MovieFailure) -> (AVAssetTrack, CMTimeRange, Bool, CGAffineTransform) {
        // 読み込みの結果を待つ側へ渡す箱。**書くのは完了ハンドラが 1 度だけで、読むのは合図を待った
        // 後だけ** — 合図が前後を決めるので、錠は要らない
        nonisolated final class Box: @unchecked Sendable {
            var outcome: Result<(AVAssetTrack, CMTimeRange, Bool, CGAffineTransform)?, any Error> = .success(nil)
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
            track.loadValuesAsynchronously(forKeys: ["timeRange", "canProvideSampleCursors", "preferredTransform"]) {
                var failure: NSError?
                if track.statusOfValue(forKey: "timeRange", error: &failure) == .loaded {
                    // 目録を引かせるかが読めなければ、引かせない扱い
                    let cursors =
                        track.statusOfValue(forKey: "canProvideSampleCursors", error: nil) == .loaded
                        && track.canProvideSampleCursors
                    // 回転の印が読めなければ、当てない (記録された向きのまま映す)
                    let transform =
                        track.statusOfValue(forKey: "preferredTransform", error: nil) == .loaded
                        ? track.preferredTransform : .identity
                    box.outcome = .success((track, track.timeRange, cursors, transform))
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
