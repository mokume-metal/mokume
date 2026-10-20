// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import AppKit
import Foundation
import ImageIO
import Testing

@testable import MokumeCore

/// 窓を開かずに、配る形 (GIF・MP4) へ書き出す経路 (`mokume render --out loop.gif`・[#2440])。
///
/// 本番と同じ経路を、run loop を回さずに辿る (``SketchApplicationRenderTests`` と同じ)。駆動源の代わりに
/// ``SketchApplication/displayLinkFired()`` を叩き、終わりの経路を畳み、書き上がった実物を ImageIO・
/// AVFoundation で読み戻す。
///
/// [#2440]: https://github.com/mokume-metal/mokume/issues/2440
@Suite(
    "配る形へ書き出す経路",
    .signalStateKept,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct RenderDistributionTests {
    /// 4 秒で 1 周する輪 (Issue の作例)。**時刻の純関数**なので、周期で割り切れる枚数なら継ぎ目なしの 1 周になる。
    final class Turning: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 96, height: 54, frameRate: 60) }
        func draw() {
            background(15, 18, 23)
            noStroke()
            fill(240, 120, 50)
            let angle = time / 4 * 2 * Float.pi
            for index in 0..<8 {
                let a = angle + Float(index) / 8 * 2 * Float.pi
                circle(width / 2 + cos(a) * 20, height / 2 + sin(a) * 20, 5)
            }
        }
    }

    private final class Ending {
        var exitStatus: Int32?
        var replied = false
        var reply: NSApplication.TerminateReply?
    }

    /// 頭から終わりまで書き出す。決めた枚数より多く叩く (余計に描かないことも一緒に見る)。
    private func render(frameRate: Int, frames: Int, to path: String) throws -> Ending {
        let request = try #require(
            RenderRequest(frameRate: frameRate, frameCount: frames, destination: path))
        let ending = Ending()
        let application = try SketchApplication(sketch: Turning(), gpu: RenderDevice(), render: request)
        application.onRenderFinished = { [weak application] in ending.reply = application?.shouldTerminate() }
        application.replyToTermination = { ending.replied = true }
        application.exitProcess = { ending.exitStatus = $0 }
        application.didFinishLaunching()
        for _ in 0..<(frames + 3) { application.displayLinkFired() }
        if ending.reply == .terminateLater {
            let deadline = DispatchTime.now() + 60
            while !ending.replied, DispatchTime.now() < deadline {
                application.pollTermination()
                if !ending.replied { Thread.sleep(forTimeInterval: 0.005) }
            }
            try #require(ending.replied, "60 秒待っても後始末が済まない")
        }
        application.willTerminate()
        return ending
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mokume-render-distribution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    @Test("--out loop.gif は、枚数ぶんの枚・遅延 4/100 秒・繰り返し無限の GIF を書き、動く")
    func aGIFIsRendered() async throws {
        try await withDirectory { directory in
            let path = directory.appendingPathComponent("loop.gif").path
            let ending = try render(frameRate: 25, frames: 25, to: path)
            #expect(ending.exitStatus == nil, "揃ったのに 0 以外で終わった")

            let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
            #expect(CGImageSourceGetCount(source) == 25)
            let container = CGImageSourceCopyProperties(source, nil) as? [String: Any]
            let gif = container?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            #expect(gif?[kCGImagePropertyGIFLoopCount as String] as? Int == 0)
            #expect(gif?[kCGImagePropertyGIFCanvasPixelWidth as String] as? Int == 96)
            let frame = CGImageSourceCopyPropertiesAtIndex(source, 7, nil) as? [String: Any]
            let delay = (frame?[kCGImagePropertyGIFDictionary as String] as? [String: Any])?[
                kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
            #expect(delay == 0.04)
            // 動いている: 隣の枚は同じ絵ではない
            let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)).dataProvider?.data
            let later = try #require(CGImageSourceCreateImageAtIndex(source, 6, nil)).dataProvider?.data
            #expect(first != nil && later != nil && (first as Data?) != (later as Data?), "枚が動いていない")
        }
    }

    @Test("--out loop.mp4 は、H.264 の MP4 を書く。枚数と刻みは --fps と --seconds のとおり")
    func anMP4IsRendered() async throws {
        try await withDirectory { directory in
            let path = directory.appendingPathComponent("loop.mp4").path
            let ending = try render(frameRate: 30, frames: 30, to: path)
            #expect(ending.exitStatus == nil, "揃ったのに 0 以外で終わった")

            #expect(MovieFile.videoSampleCount(atPath: path) == 30)
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let descriptions = try await track.load(.formatDescriptions)
            #expect(try #require(descriptions.first).mediaSubType == .h264)
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - 1.0) < 0.01, "長さが \(duration) 秒")
        }
    }

    /// 道具が子の後に書き出し先を確かめる口 (`inspectOutput`) も、本物の書き出しで通る。
    @Test("書き出した GIF・MP4 は、道具の書き出し先の確かめを通る")
    func theToolsCheckAcceptsWhatWasWritten() async throws {
        try await withDirectory { directory in
            for (name, rate) in [("a.gif", 20), ("a.mp4", 24)] {
                let path = directory.appendingPathComponent(name).path
                let start = Date().addingTimeInterval(-1)
                _ = try render(frameRate: rate, frames: 10, to: path)
                let request = try #require(RenderRequest(frameRate: rate, frameCount: 10, destination: path))
                #expect(request.inspectOutput(since: start) == nil, "\(name)")
            }
        }
    }
}
