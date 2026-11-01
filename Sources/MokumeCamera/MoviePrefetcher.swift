// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import MokumeCore
import Synchronization

/// 動画の先の数コマを、main actor の外の仕事 (係) で復号して待たせておく ([#2523])。**実時間の時計
/// (``Clock/wallClock``) で流しているときだけ** ``Movie`` が使う。
///
/// main は毎フレーム、錠を 1 度だけ取って位置を頼み、列から位置のコマを選ぶだけで、待たない。
/// 位置のコマがまだ列に無ければ `nil` を返し、``Movie`` は前のコマを映したままにする — ループの
/// 継ぎ目と `jump()` で、読み手を作り直す間 main を止めないためである。
///
/// ## 係
///
/// - 係は自分の読み進めの核 (``MovieFrames``、自分の `AVAssetReader`) を、動画ファイルの場所から開き直して
///   持つ。main の読み手 (``MovieReader``) とは共有しない ([ADR-0042] 決定 7 の改訂 (2026-10-31))
/// - 境界を越えるのは、頼み (位置・世代・何周目か) と、用意したコマ (``VideoFrame`` — 変換と向きを済ませた
///   `DisplayImage` か、面のまま GPU で色を変換する `PixelSurface`) だけで、`CVPixelBuffer` などの OS の型は越えない
///   (`PixelSurface` は面を包んだ自前の `Sendable` な値 — ADR-0042 決定 5 の改訂 (2026-11-01))
/// - 列の長さは ``depth`` 枚。ループで流していれば、終わりの後に頭から読み続け、継ぎ目の先を
///   先に用意する
/// - 並列は `Task` で分ける (ADR-0010 決定 4。`DispatchQueue` は足さない)。復号の間は協調スレッドを
///   1 本塞ぐ
/// - **係の優先度は既定より下げる (`.utility`)。** `copyNextSampleBuffer()` は AVFoundation が GCD の既定の
///   キューに出す仕事を待つ。既定の優先度の同期の待ちが協調プールを埋めると、その仕事が走れずに止まる
///   (#3396 の実測)。係は動画 1 本につき 1 本その待ちを持つので、作品の仕事の側へ寄せない
///
/// ## 世代と何周目か
///
/// 頼みの**世代**は、位置が続かなくなる (``Movie/jump(_:)``・ループでないのに戻る) たびに 1 つ進み、
/// 係は列を捨てて飛び先から読む。**何周目か** (lap) は、ループの継ぎ目で 1 つ進む。列のコマは
/// (何周目か, 表示の時刻) の順に並び、main は頼んだ位置以下で最も遅いコマを選ぶ。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
/// [#2523]: https://github.com/mokume-metal/mokume/issues/2523
final class MoviePrefetcher {
    /// 列に待たせておく先のコマの数。
    nonisolated static let depth = 3
    /// 閉じるときに、係が止まるのを待つ期限 (秒)。4K の読み直しの最悪 (約 150 ms) の 3 倍強。
    /// 越えたら待たずに返り、係は次に止めを見たところで自分の読み手を閉じて抜ける。
    static let stopLimit = 0.5

    private let mailbox = PrefetchMailbox()
    private let wakes: AsyncStream<Void>.Continuation
    /// 係が抜けた合図。
    private let stopped = DispatchSemaphore(value: 0)
    private var serial = 0
    private var closed = false
    /// 閉じるときに期限を越えたか。**検査が読む。**
    private(set) var stopTimedOut = false

    /// 係を起こす。
    ///
    /// - Parameters:
    ///   - source: 開き直す動画ファイル。
    ///   - pause: 係が 1 枚ごとに呼ぶ (検査が係を塞ぐのに使う)。
    init(source: MovieSource, pause: (@Sendable () -> Void)? = nil) {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakes = continuation
        let mailbox = mailbox
        let stopped = stopped
        // 係は self も Movie も握らない (循環しない)
        Task.detached(priority: .utility) {
            await Self.run(source: source, mailbox: mailbox, wakes: stream, pause: pause)
            mailbox.state.withLock { $0.exited = true }
            stopped.signal()
        }
    }

    /// 捨てられたら止めを伝える。待たない (係は自分の読み手を閉じて抜ける)。
    deinit {
        mailbox.state.withLock {
            $0.stopping = true
            $0.frames.removeAll()
        }
        wakes.finish()
    }

    /// `position` 秒 (`lap` 周目、世代 `generation`) のコマを列から選ぶ。**待たない。**
    ///
    /// 位置のコマがまだ列に無いか、前に渡したコマのままなら `nil`。係が読めなくなっていて、渡せる
    /// コマも無ければ投げる。
    func picture(at position: Double, generation: Int, lap: Int, looping: Bool) throws(MovieFrames.Failure)
        -> VideoFrame?
    {
        serial += 1
        let request = PrefetchRequest(
            serial: serial, generation: generation, lap: lap, position: position, looping: looping)
        let (chosen, failure) = mailbox.state.withLock { state -> (PrefetchedFrame?, MovieFrames.Failure?) in
            state.request = request
            state.frames.removeAll { $0.generation != generation }
            let limit = PrefetchKey(lap: lap, time: position + Playhead.tolerance)
            var chosen: PrefetchedFrame?
            if let index = state.frames.lastIndex(where: { $0.key <= limit }) {
                chosen = state.frames[index]
                state.frames.removeFirst(index + 1)
            }
            let failure = state.failure.flatMap { $0.generation == generation ? $0.failure : nil }
            return (chosen, failure)
        }
        wakes.yield()
        if let chosen { return chosen.image }
        if let failure { throw failure }
        return nil
    }

    /// 係が最新の頼みを見て、列を埋め終えた (か、終わり・失敗で止まった) か。**検査が待つのに使う。**
    var isSettled: Bool {
        mailbox.state.withLock { $0.idle && $0.seen == serial }
    }

    /// 係が動画を開けなかったか。開けなければ ``Movie`` は同期の読みに戻る。
    var isBroken: Bool {
        mailbox.state.withLock { $0.broken }
    }

    /// 係が自分の読み手を閉じて抜けたか。**検査が読む。**
    var hasExited: Bool {
        mailbox.state.withLock { $0.exited }
    }

    /// 係の読み手が読み直した回数。**検査が読む。**
    var restarts: Int {
        mailbox.state.withLock { $0.restarts }
    }

    /// 係が抜けるのを `seconds` 秒まで待つ。抜けていれば `true`。**検査が使う** (``close()`` が期限を
    /// 越えた後に、係が自分で抜けることを確かめる)。
    func waitUntilStopped(_ seconds: Double) -> Bool {
        stopped.wait(timeout: .now() + seconds) == .success
    }

    /// 係を止め、期限 (``stopLimit``) まで抜けるのを待つ。2 度目からは何もしない。
    func close() {
        guard !closed else { return }
        stopWorker()
        if stopped.wait(timeout: .now() + Self.stopLimit) == .timedOut { stopTimedOut = true }
    }

    /// 止めを立てて、起こす合図を閉じる。待たない。
    private func stopWorker() {
        closed = true
        mailbox.state.withLock {
            $0.stopping = true
            $0.frames.removeAll()
        }
        wakes.finish()
    }

    // MARK: - 係

    /// 係の本体。起こされるたびに、頼みに合わせて列を埋める。
    private nonisolated static func run(
        source: MovieSource, mailbox: PrefetchMailbox, wakes: AsyncStream<Void>, pause: (@Sendable () -> Void)?
    ) async {
        guard let frames = open(source) else {
            mailbox.state.withLock {
                $0.broken = true
                $0.idle = true
            }
            return
        }
        defer { frames.close() }
        var worker = PrefetchWorker(
            frames: frames,
            converter: FrameConverter(width: source.width, height: source.height, alpha: .straight),
            orientation: source.orientation, mailbox: mailbox, pause: pause)
        for await _ in wakes {
            guard worker.fill() else { break }
        }
    }

    /// 係の読み進めの核を、動画ファイルから開き直す。開けなければ `nil`。
    private nonisolated static func open(_ source: MovieSource) -> MovieFrames? {
        let asset = AVURLAsset(url: source.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let (track, range, canProvideSampleCursors, _) = try? MovieReader.inspect(asset, path: source.path)
        else { return nil }
        let keyFrames =
            source.indexesKeyFrames
            ? KeyFrameIndex(track: track, start: range.start, canProvideSampleCursors: canProvideSampleCursors)
            : nil
        return try? MovieFrames(
            asset: asset, track: track, start: range.start, duration: range.duration.seconds, keyFrames: keyFrames)
    }
}

/// 係が開き直す動画ファイルと、main の読み手が作るときに決めたこと。
nonisolated struct MovieSource: Sendable {
    let url: URL
    /// 失敗の説明に載せる名前。
    let path: String
    /// 鍵のコマの位置を引くか (``MovieReader/KeyFrameLookup/track``)。
    let indexesKeyFrames: Bool
    /// 記録された幅 (画素。回転の印を当てる前)。
    let width: Int
    /// 記録された高さ (画素。回転の印を当てる前)。
    let height: Int
    /// 1 枚ごとに当てる向き。
    let orientation: VideoOrientation
}

/// 列のコマの並びの鍵 (何周目か, 表示の時刻)。
nonisolated struct PrefetchKey: Comparable, Sendable {
    let lap: Int
    let time: Double

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.lap != rhs.lap ? lhs.lap < rhs.lap : lhs.time < rhs.time
    }
}

/// main の頼み。
nonisolated struct PrefetchRequest: Sendable {
    /// 頼んだ順の番号。
    let serial: Int
    let generation: Int
    let lap: Int
    let position: Double
    let looping: Bool
}

/// 係が用意したコマ。**`CVPixelBuffer`・`CMSampleBuffer` を持たない** — 変換した絵か、面の値 (``PixelSurface``。
/// 面を包んだ自前の `Sendable` な値で、ADR-0042 決定 7 の条件 2 の「OS の型」に当たらない — 決定 5 の改訂
/// (2026-11-01))。
nonisolated struct PrefetchedFrame: Sendable {
    let generation: Int
    let lap: Int
    let time: Double
    let image: VideoFrame

    var key: PrefetchKey { PrefetchKey(lap: lap, time: time) }
}

/// main と係の間の受け渡し。錠 1 つで守る。
nonisolated final class PrefetchMailbox: Sendable {
    struct State: Sendable {
        /// 最新の頼み。
        var request: PrefetchRequest?
        /// 係が見た最新の頼みの番号。
        var seen = 0
        /// 係が仕事を終えて、次に起こされるのを待っているか。
        var idle = false
        /// 待たせているコマ (並びの鍵の順)。
        var frames: [PrefetchedFrame] = []
        /// ループでないまま終わりまで読んだ (今の世代で)。
        var ended = false
        /// 読めなくなった世代と理由。
        var failure: (generation: Int, failure: MovieFrames.Failure)?
        /// 係が動画を開けなかった。
        var broken = false
        var stopping = false
        /// 係が読み手を閉じて抜けた。
        var exited = false
        var restarts = 0
    }

    let state = Mutex(State())
}

/// 係の仕事の中身。係の仕事の上にだけ居る (``MovieFrames`` と変換器を持つので送れない)。
nonisolated struct PrefetchWorker {
    let frames: MovieFrames
    let converter: FrameConverter
    let orientation: VideoOrientation
    let mailbox: PrefetchMailbox
    let pause: (@Sendable () -> Void)?
    /// 列に積んでいる世代と何周目か。
    private var generation = -1
    private var lap = 0
    /// 読めなくなって、試し直しを待っているか。
    private var failing = false
    /// 最後に積んだコマの番号 (``MovieFrames/Decoded/serial``)。
    private var published: Int?

    init(
        frames: MovieFrames, converter: FrameConverter, orientation: VideoOrientation, mailbox: PrefetchMailbox,
        pause: (@Sendable () -> Void)?
    ) {
        self.frames = frames
        self.converter = converter
        self.orientation = orientation
        self.mailbox = mailbox
        self.pause = pause
    }

    /// 頼みに合わせて、列が埋まるか止まるまで読む。止めを見たら `false`。
    mutating func fill() -> Bool {
        while true {
            let snapshot = mailbox.state.withLock { state -> (PrefetchRequest, Int, Bool)? in
                guard !state.stopping, let request = state.request else { return nil }
                state.seen = request.serial
                state.idle = false
                let limit = PrefetchKey(lap: request.lap, time: request.position + Playhead.tolerance)
                let ahead = state.frames.count(where: { $0.generation == request.generation && $0.key > limit })
                return (request, ahead, state.ended)
            }
            guard let (request, ahead, ended) = snapshot else {
                return mailbox.state.withLock { state in
                    state.idle = true
                    return !state.stopping
                }
            }
            pause?()
            guard step(request: request, ahead: ahead, ended: ended) else {
                // することが無い。頼みが変わっていなければ休む (変わっていれば、もう 1 周見る)
                let rest = mailbox.state.withLock { state -> Bool in
                    guard state.request?.serial == request.serial || state.stopping else { return false }
                    state.idle = true
                    return true
                }
                if rest { return mailbox.state.withLock { !$0.stopping } }
                continue
            }
        }
    }

    /// 1 歩進める。することが無ければ `false`。
    private mutating func step(request: PrefetchRequest, ahead: Int, ended: Bool) -> Bool {
        let tolerance = Playhead.tolerance
        do {
            if request.generation != generation {
                // 飛んだ。列を捨てて飛び先から読む
                generation = request.generation
                lap = request.lap
                failing = false
                mailbox.state.withLock {
                    $0.frames.removeAll()
                    $0.ended = false
                    $0.failure = nil
                }
                try frames.advance(to: request.position)
                publish()
            } else if failing {
                // 読めなくなった後。読み手の規則 (戻る・1 秒より先) を満たすまでは試さない
                guard try frames.advance(to: request.position) else { return false }
                failing = false
                mailbox.state.withLock { $0.failure = nil }
                publish()
            } else if request.lap > lap {
                // main が先に継ぎ目を越えた (列が追いつかなかった)
                lap = request.lap
                mailbox.state.withLock { $0.ended = false }
                try frames.advance(to: request.position)
                publish()
            } else if request.lap == lap, let upcoming = frames.upcoming,
                upcoming.time <= request.position + tolerance
            {
                // 列が位置に追いついていない。読み手の判定で読み進めるか読み直す
                try frames.advance(to: request.position)
                publish()
            } else if ahead < MoviePrefetcher.depth, !ended {
                if frames.upcoming == nil {
                    guard request.looping else {
                        mailbox.state.withLock { $0.ended = true }
                        return false
                    }
                    // 継ぎ目の先を先に用意する
                    lap += 1
                    try frames.advance(to: 0)
                } else {
                    try frames.step()
                }
                publish()
            } else {
                return false
            }
        } catch {
            failing = true
            mailbox.state.withLock { [generation] in
                $0.failure = (generation, error)
                $0.restarts = frames.restarts
            }
        }
        return true
    }

    /// 読み手のいまのコマを変換して列に積む。同じコマは 2 度積まない。
    private mutating func publish() {
        defer { mailbox.state.withLock { $0.restarts = frames.restarts } }
        guard let frame = frames.current, frame.serial != published else { return }
        published = frame.serial
        let image: VideoFrame
        // 面のまま渡せるなら面で (#2962)。色の表が無ければ、係の上で作る (main では作らない)。
        // 記録の大きさと違うコマ (途中で大きさが変わる動画) は、変換器が縮めるので面に乗せない (#3690)
        let reshaped = orientation != .identity || SurfaceRoute.differs(frame.buffer, from: converter)
        if case .success(let surface) = SurfaceRoute.surface(
            for: frame.buffer, alpha: .straight, reshaped: reshaped, builds: true)
        {
            image = .surface(surface)
        } else {
            do {
                image = .converted(try converter.convert(frame.buffer).oriented(orientation))
            } catch {
                failing = true
                mailbox.state.withLock { [generation] in
                    $0.failure = (generation, MovieFrames.Failure(reason: error.description))
                }
                return
            }
        }
        let prefetched = PrefetchedFrame(generation: generation, lap: lap, time: frame.time, image: image)
        mailbox.state.withLock { state in
            // 変換の間に飛んでいれば積まない
            guard state.request?.generation == prefetched.generation, !state.stopping else { return }
            state.frames.append(prefetched)
        }
    }
}

/// 実時間の時計で流す位置の並びから、先読みの頼みの世代と何周目かを数える ([#2523])。
///
/// - 飛ぶよう頼まれた (``Movie/jump(_:)``) フレームで世代が進み、何周目かは 0 に戻る
/// - 位置が戻ったとき、ループで流していれば継ぎ目として何周目かが進み、そうでなければ (終わりから
///   流し直した、など) 世代が進む
///
/// ループで流している間に手前へ飛ぶと、`jump` は世代を進めるので取り違えない。
///
/// [#2523]: https://github.com/mokume-metal/mokume/issues/2523
nonisolated struct PlaybackContinuity: Equatable {
    private(set) var generation = 0
    private(set) var lap = 0
    private var last: Double?

    /// このフレームの位置を受けて数え直す。
    ///
    /// - Parameters:
    ///   - position: 映す位置 (秒)。
    ///   - jumped: このフレームで、飛ぶよう頼まれた位置へ移ったか。
    ///   - looping: ループで流しているか。
    mutating func note(position: Double, jumped: Bool, looping: Bool) {
        defer { last = position }
        guard let last else { return }
        if jumped {
            generation += 1
            lap = 0
        } else if position < last - Playhead.tolerance {
            if looping {
                lap += 1
            } else {
                generation += 1
                lap = 0
            }
        }
    }

    /// 続きを切る (同期の読みから先読みへ戻ったとき)。次の位置から新しい世代で数える。
    mutating func cut() {
        generation += 1
        lap = 0
        last = nil
    }
}
