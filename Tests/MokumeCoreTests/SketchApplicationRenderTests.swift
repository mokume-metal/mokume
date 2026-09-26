// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import AppKit
import Foundation
import Testing

@testable import MokumeCore

/// 窓を開かずに、固定の fps で決めた枚数を書き出す経路 (`mokume render`・[#1282])。
///
/// **本番と同じ経路を、run loop を回さずに辿る。** 駆動源の代わりに ``SketchApplication/displayLinkFired()``
/// を叩き、`terminate(_:)` の代わりに AppKit が同じ呼び出しの中で問う ``SketchApplication/shouldTerminate()``
/// を呼ぶ。返事を待たせたら ``SketchApplication/pollTermination()`` で見に来て、最後に
/// ``SketchApplication/willTerminate()`` で畳む — AppKit が踏む順そのものである。
///
/// 見るのは読み戻した `.mov` (符号化を通った実物) と、スケッチから見えた時刻である。
///
/// [#1282]: https://github.com/mokume-metal/mokume/issues/1282
@Suite(
    "窓を開かずに書き出す経路",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"),
    .enabled(
        if: MovieFile.isAvailable,
        "この機械には ProRes 4444 の符号化器が無い")
)
@MainActor
struct SketchApplicationRenderTests {
    /// 時刻で右へ進む四角を描き、見えた時刻を憶えるスケッチ。**作品の宣言は 60 fps。**
    final class Sweep: Sketch {
        /// 見えた 1 枚。
        struct Moment: Equatable {
            let frame: Int
            let time: Float
            let deltaTime: Float
        }

        /// このフレームで `noLoop()` を呼ぶ。`nil` なら呼ばない。
        var stopsAtFrame: Int?
        /// このフレームを描けなかったことにする (検査の穴 `failureForTesting`)。
        var failsAtFrame: Int?
        private(set) var seen: [Moment] = []

        init() {}
        var settings: SketchSettings { SketchSettings(width: 48, height: 24, frameRate: 60) }

        func draw() {
            canvas.failureForTesting = frameCount == failsAtFrame ? .timedOut(seconds: 5) : nil
            seen.append(Moment(frame: frameCount, time: time, deltaTime: deltaTime))
            background(15)
            noStroke()
            fill(240, 120, 50)
            // 時刻の純関数。フレームごとに絵が変わるので、2 回の一致が中身の一致を意味する
            rect(time * 60, 8, 6, 8)
            if frameCount == stopsAtFrame { noLoop() }
        }
    }

    /// AppKit が呼ぶ終わりの経路の受け手。
    final class Ending {
        var finishedCalls = 0
        var stopCalls = 0
        var reply: NSApplication.TerminateReply?
        var replied = false
        /// ``SketchApplication/exitProcess`` へ渡った終了コード。**呼ばれなければ `nil`** (0 で終わる)。
        var exitStatus: Int32?
    }

    /// 書き出す経路で組み、終わりの経路の口を検査の側へ差し替える。
    ///
    /// **終了の口は必ず差し替える** — 揃わなかった回は ``SketchApplication/exitProcess`` を
    /// 呼ぶので、既定のままだと検査のプロセスが終わる。
    private func makeApplication(
        _ sketch: Sweep, _ request: RenderRequest, _ ending: Ending
    ) throws -> SketchApplication {
        let application = try SketchApplication(sketch: sketch, gpu: RenderDevice(), render: request)
        application.onRenderFinished = { [weak application] in
            ending.finishedCalls += 1
            ending.reply = application?.shouldTerminate()
        }
        application.onStopSignal = { [weak application] in
            ending.stopCalls += 1
            ending.reply = application?.shouldTerminate()
        }
        application.replyToTermination = { ending.replied = true }
        application.exitProcess = { ending.exitStatus = $0 }
        return application
    }

    /// 返事を待たせていれば決着まで見に来て、畳む。**待つ側が期限を持つ。**
    private func finishTerminating(_ application: SketchApplication, _ ending: Ending) throws {
        if ending.reply == .terminateLater {
            let deadline = Date().addingTimeInterval(60)
            while !ending.replied, Date() < deadline {
                application.pollTermination()
                if !ending.replied { Thread.sleep(forTimeInterval: 0.005) }
            }
            try #require(ending.replied, "60 秒待っても後始末が済まない")
        }
        application.willTerminate()
    }

    /// 駆動源の代わりに叩く。
    private func fire(_ application: SketchApplication, times: Int) {
        for _ in 0..<times { application.displayLinkFired() }
    }

    /// 頭から終わりまで書き出す。**決めた枚数より多く叩く** — 余計に描かないことも一緒に見る。
    private func render(
        _ sketch: Sweep, frameRate: Int, frames: Int, to path: String
    ) throws -> Ending {
        let request = try #require(
            RenderRequest(frameRate: frameRate, frameCount: frames, destination: path))
        let ending = Ending()
        let application = try makeApplication(sketch, request, ending)
        application.didFinishLaunching()
        fire(application, times: frames + 3)
        try finishTerminating(application, ending)
        return ending
    }

    // MARK: - 時刻と枚数 (完了条件 3・6)

    /// **`--fps` が作品の宣言 (60) と違う組で見る。** 時計だけを替えると、最後の 1 枚の長さ
    /// (= 動画の長さ) が宣言から採られて半コマ短くなる。
    @Test("書き出した動画の枚数・各枚の時刻・長さは --fps から決まり、作品の宣言に左右されない")
    func theMovieTakesItsTimingFromTheRequest() async throws {
        try await withTemporaryDirectory("mokume-render-timing") { directory in
            let path = directory.appendingPathComponent("timing.mov").path
            let sketch = Sweep()
            let ending = try render(sketch, frameRate: 30, frames: 6, to: path)

            #expect(ending.finishedCalls == 1, "決めた枚数を描いても、終わりを 1 度だけ頼んでいない")
            #expect(ending.exitStatus == nil, "揃ったのに 0 以外で終わった")

            // スケッチから見た時刻は (frameCount - 1) / fps、経過は 1 / fps
            #expect(sketch.seen.map(\.frame) == Array(1...6), "枚数 + 1 枚目を描いた")
            for moment in sketch.seen {
                #expect(moment.time == Float(Double(moment.frame - 1) / 30), "\(moment.frame) 枚目")
                #expect(moment.deltaTime == Float(1.0 / 30), "\(moment.frame) 枚目")
            }

            let movie = try await decodeMovie(path)
            #expect(movie.times.count == 6)
            for (index, time) in movie.times.enumerated() {
                #expect(abs(time - Double(index) / 30) < 1e-4, "\(index) 枚目の時刻が \(time)")
            }
            #expect(abs(movie.duration - 6.0 / 30) < 1e-4, "動画の長さが \(movie.duration) 秒")
        }
    }

    /// **終わりを頼んでから終わるまでの間も、駆動源は呼んでくる。** AppKit が終わりをその場で
    /// 受け付けない間 (ここでは受け付けたことにしない) に描けば、枚数 + 1 枚目が撮る係へ届く。
    @Test("終わりを頼んだ後に駆動源が呼んでも、枚数 + 1 枚目を描かず、頼み直しもしない")
    func nothingIsDrawnPastTheCountWhileTheEndIsPending() async throws {
        try await withTemporaryDirectory("mokume-render-pending") { directory in
            let path = directory.appendingPathComponent("pending.mov").path
            let sketch = Sweep()
            let request = try #require(
                RenderRequest(frameRate: 30, frameCount: 4, destination: path))
            let ending = Ending()
            let application = try makeApplication(sketch, request, ending)
            application.onRenderFinished = { ending.finishedCalls += 1 }
            application.didFinishLaunching()
            fire(application, times: 8)

            #expect(sketch.seen.count == 4, "終わりを待っている間に描いた")
            #expect(ending.finishedCalls == 1, "終わりを重ねて頼んだ")
            ending.reply = application.shouldTerminate()
            try finishTerminating(application, ending)
            #expect(ending.exitStatus == nil)
            #expect(try await decodeMovie(path).times.count == 4)
        }
    }

    @Test("連番へ書き出すと、決めた枚数のファイルが 0 番から並ぶ")
    func aNumberedSeriesGetsEveryFrame() async throws {
        try await withTemporaryDirectory("mokume-render-series") { directory in
            let pattern = directory.appendingPathComponent("out/frame-###.png").path
            let ending = try render(Sweep(), frameRate: 24, frames: 4, to: pattern)
            #expect(ending.exitStatus == nil)

            let written = try FileManager.default.contentsOfDirectory(
                atPath: directory.appendingPathComponent("out").path
            ).sorted()
            #expect(written == ["frame-000.png", "frame-001.png", "frame-002.png", "frame-003.png"])
        }
    }

    // MARK: - 2 回書いて同じ (完了条件 4)

    @Test("同じ頼みで 2 回書き出すと、全フレームの画素と時刻が一致する")
    func twoRendersOfTheSameRequestMatch() async throws {
        try await withTemporaryDirectory("mokume-render-twice") { directory in
            let first = directory.appendingPathComponent("first.mov").path
            let second = directory.appendingPathComponent("second.mov").path
            _ = try render(Sweep(), frameRate: 24, frames: 8, to: first)
            _ = try render(Sweep(), frameRate: 24, frames: 8, to: second)

            let a = try await decodeMovie(first)
            let b = try await decodeMovie(second)
            #expect(a.frames.count == 8)
            #expect(a.times == b.times)
            #expect(a.frames == b.frames, "同じ引数から違う絵が出た")
            // **動いていることも見る。** 全部同じ絵なら、一致は何も言っていない
            #expect(Set(a.frames).count == a.frames.count, "絵がフレームごとに変わっていない")
        }
    }

    // MARK: - 窓を開かない (完了条件 5)

    /// 区画 `viewport` は見張りが畳めずに終わると残る。残っていても、書き出す経路は共有面へ
    /// 差し出さない — 面の番号の名乗り (manifest) も置かない。
    @Test("書き出す経路は窓を開かず、区画 viewport が残っていても共有面へ差し出さない")
    func renderingOpensNoWindowEvenWithAViewportFacet() async throws {
        try await withTemporaryDirectory("mokume-render-headless") { directory in
            let facet = directory.appendingPathComponent("viewport", isDirectory: true)
            try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("headless.mov").path
            let request = try #require(
                RenderRequest(frameRate: 30, frameCount: 3, destination: path))
            let ending = Ending()
            let windowsBefore = NSApplication.shared.windows.count

            let application = try makeApplication(Sweep(), request, ending)
            application.resolveOutlet(at: facet)
            application.didFinishLaunching()
            fire(application, times: 5)

            #expect(application.window == nil)
            #expect(NSApplication.shared.windows.count == windowsBefore, "窓が建った")
            #expect(application.activationPolicy == .accessory, "Dock に並ぶ")
            #expect(!application.endsAfterLastWindowClosed)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: facet.path).isEmpty,
                "共有面の名乗りを区画へ置いた")
            try finishTerminating(application, ending)
            #expect(ending.exitStatus == nil)
        }
    }

    // MARK: - 書けなかったら 0 以外 (完了条件 6)

    /// 読み取り専用のディレクトリ。撮る係が理由を名乗り (書き損じ)、締めくくりが 0 以外で終わる。
    @Test(
        "書き出し先に書けなければ、0 以外で終わる",
        arguments: ["motion.mov", "frame-###.png"])
    func anUnwritableDestinationEndsNonZero(name: String) async throws {
        try await withTemporaryDirectory("mokume-render-locked") { directory in
            let locked = directory.appendingPathComponent("locked", isDirectory: true)
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555], ofItemAtPath: locked.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: locked.path)
            }
            let path = locked.appendingPathComponent(name).path

            let ending = try render(Sweep(), frameRate: 30, frames: 3, to: path)
            #expect(ending.finishedCalls == 1, "枚数は描いている")
            #expect(ending.exitStatus == 1, "書けなかったのに 0 で終わる")
            #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path).isEmpty)
        }
    }

    /// **連番は描けなかった枚を黙って詰める** — 番号は書いた枚ごとに進むので、穴は名前に
    /// 残らない。動画のように落ちた数を名乗る係も居ないので、ここで数えないと 0 で終わる。
    @Test("描けなかったフレームがあれば、枚数は進めても揃わなかったと 0 以外で言う")
    func aFrameThatCouldNotBeDrawnEndsNonZero() async throws {
        try await withTemporaryDirectory("mokume-render-failed-frame") { directory in
            let pattern = directory.appendingPathComponent("frame-###.png").path
            let sketch = Sweep()
            sketch.failsAtFrame = 3
            let ending = try render(sketch, frameRate: 30, frames: 5, to: pattern)

            #expect(ending.finishedCalls == 1, "描けなかった枚も枚数に数える")
            #expect(ending.exitStatus == 1, "穴があるのに 0 で終わる")
            let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(written.count == 4)
        }
    }

    // MARK: - 途中で止めても壊れない (完了条件 7)

    /// 道具からの `SIGTERM`・端末の Control + C は、どちらも旗を立てて終わりの経路へ入る
    /// (``StopSignals``)。その 1 本で撮る係が閉じるので、それまでの枚が入った開ける動画が残る。
    @Test("途中で終わりの合図を受けても、それまでの枚が入った開ける動画が残り、0 以外で終わる")
    func aStopMidwayLeavesAPlayableMovie() async throws {
        try await withTemporaryDirectory("mokume-render-stopped") { directory in
            let path = directory.appendingPathComponent("stopped.mov").path
            let sketch = Sweep()
            let request = try #require(
                RenderRequest(frameRate: 30, frameCount: 10, destination: path))
            let ending = Ending()
            let application = try makeApplication(sketch, request, ending)
            application.didFinishLaunching()
            fire(application, times: 4)

            sketchStopRequested = 1
            fire(application, times: 3)
            #expect(ending.stopCalls == 1)
            #expect(ending.finishedCalls == 0)
            #expect(sketch.seen.count == 4, "終わりに向かっている間にも描いた")
            try finishTerminating(application, ending)
            #expect(ending.exitStatus == 1, "揃っていないのに 0 で終わる")

            let movie = try await decodeMovie(path)
            #expect(movie.times.count == 4)
        }
    }

    /// **待てば永久に届かない。** 止まったスケッチは入力が来なければ動き直さず、書き出す経路には
    /// 窓も入力も無い — 終わらせないと、道具は子を待ち続ける。
    @Test("作者が noLoop() で止めたら、そこで書き出しを終え、揃わなかったと 0 以外で言う")
    func aSketchThatStopsItsLoopEndsTheRender() async throws {
        try await withTemporaryDirectory("mokume-render-noloop") { directory in
            let path = directory.appendingPathComponent("noloop.mov").path
            let sketch = Sweep()
            sketch.stopsAtFrame = 3
            let ending = try render(sketch, frameRate: 30, frames: 10, to: path)

            #expect(ending.finishedCalls == 1)
            #expect(sketch.seen.count == 3)
            #expect(ending.exitStatus == 1)
            let movie = try await decodeMovie(path)
            #expect(movie.times.count == 3)
        }
    }

    // MARK: - 他の経路は変わらない (完了条件 8)

    /// 検査のプロセスには合図が渡っていないので、公開の入口はいつもの窓の経路を組む。
    @Test("書き出しの合図が無ければ、時計は実時間のまま窓の経路を組む")
    func withoutTheSignalTheWindowPathIsUnchanged() throws {
        try #require(
            ProcessInfo.processInfo.environment[StartupReads.render.key] == nil,
            "検査のプロセスに書き出しの合図が渡っている")
        let application = try SketchApplication(sketch: Sweep(), gpu: RenderDevice())
        defer { application.willTerminate() }
        #expect(application.clock == .wallClock)
        #expect(application.activationPolicy == .regular)
        #expect(application.endsAfterLastWindowClosed)
    }

    @Test("書き出しの頼みがあれば、時計はその刻みのフレーム番号になる")
    func theRequestSetsAFrameIndexClock() throws {
        let request = try #require(
            RenderRequest(frameRate: 24, frameCount: 2, destination: "/tmp/unused.mov"))
        let ending = Ending()
        let application = try makeApplication(Sweep(), request, ending)
        #expect(application.clock == .frameIndex(frameRate: 24))
        // 1 枚も描かずに畳む — 揃っていないので 0 以外になる (プロセスは終わらない)
        application.willTerminate()
        #expect(ending.exitStatus == 1)
    }
}

// MARK: - 共通の道具

/// 読み戻した動画。
private struct DecodedMovie {
    /// 各枚の画素 (符号化器が返す BGRA の並び、行の詰めものを除く)。
    let frames: [[UInt8]]
    /// 各枚の表示時刻 (秒)。
    let times: [Double]
    /// 動画の長さ (秒)。
    let duration: Double
}

/// 書き出した動画を読み戻す。**符号化を通った実物を見る。**
private func decodeMovie(_ path: String) async throws -> DecodedMovie {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let duration = try await asset.load(.duration)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.startReading()

    var frames: [[UInt8]] = []
    var times: [Double] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        times.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        frames.append(pixels(of: buffer))
    }
    return DecodedMovie(frames: frames, times: times, duration: CMTimeGetSeconds(duration))
}

/// 画素の並びを、行の詰めものを除いて取り出す。
private func pixels(of buffer: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        bytes.append(contentsOf: UnsafeBufferPointer(start: base + y * stride, count: width * 4))
    }
    return bytes
}

/// 検査のあいだだけ使う一時ディレクトリ。**引数つきの検査が並んで走っても重ならない名前にする。**
private func withTemporaryDirectory(
    _ name: String, _ body: (URL) async throws -> Void
) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}
