// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import IOSurface
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 見張りの子が道具へ渡す名乗りの中身を、面の属性に載せる ([#3919])。
///
/// GPU は使わない — 属性は面 (`IOSurface`) に載るもので、絵を焼く経路とは別である。
///
/// [#3919]: https://github.com/mokume-metal/mokume/issues/3919
@Suite("名乗りの中身を面に載せる")
@MainActor
struct FrameShareAttributeTests {
    private func makeSurface() throws -> IOSurfaceRef {
        try #require(IOSurfaceCreate(SharedFrameSurface.properties(width: 4, height: 4)))
    }

    @Test("載せた作品名と題を読める")
    func readsWhatWasPublished() throws {
        let surface = try makeSurface()
        let share = FrameShare(sketch: "Bricks", title: "Bricks and ball")
        SharedFrameSurface.publishFrameShare(share, to: surface)
        #expect(SharedFrameSurface.frameShare(on: surface) == share)
    }

    /// 面は使い回されるので、消さなければ前に載せた中身が残る。
    @Test("断った枚では属性ごと消し、前の中身を残さない")
    func clearsAStaleShare() throws {
        let surface = try makeSurface()
        SharedFrameSurface.publishFrameShare(FrameShare(sketch: "S", title: "T"), to: surface)
        SharedFrameSurface.publishFrameShare(nil, to: surface)
        #expect(SharedFrameSurface.frameShare(on: surface) == nil)
        #expect(IOSurfaceCopyValue(surface, SharedFrameSurface.frameShareAttribute as CFString) == nil)
    }

    /// 古いライブラリの子は載せない。**載っていないのは断っていること**として読む。形の違う値も同じ。
    @Test("載っていない面と、形の違う値は、断っていると読む")
    func absentOrMalformedMeansRefused() throws {
        let surface = try makeSurface()
        #expect(SharedFrameSurface.frameShare(on: surface) == nil)
        IOSurfaceSetValue(surface, SharedFrameSurface.frameShareAttribute as CFString, NSNumber(value: 1))
        #expect(SharedFrameSurface.frameShare(on: surface) == nil)
        IOSurfaceSetValue(
            surface, SharedFrameSurface.frameShareAttribute as CFString, ["title": "only"] as CFDictionary)
        #expect(SharedFrameSurface.frameShare(on: surface) == nil)
    }
}

/// 名乗るのはウィンドウの持ち主で、起こし方で決まる ([ADR-0049] 決定 2・[#3919])。
///
/// | 経路 | 名乗り |
/// | --- | --- |
/// | 自分のウィンドウを開く (直に走らせる・`run`・`.app`・見張りの子が倒れた回) | ライブラリが名乗る |
/// | 共有面へ差し出す見張りの子 | 名乗らず、面に作品名と題を載せる (道具が名乗る) |
/// | 書き出す (`render`) | 名乗らない |
///
/// [ADR-0049]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md
/// [#3919]: https://github.com/mokume-metal/mokume/issues/3919
@Suite(
    "名乗るのはウィンドウの持ち主",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct FrameShareLaunchTests {
    private final class Titled: Sketch {
        var settings: SketchSettings { SketchSettings(width: 32, height: 16, frameRate: 60, title: "Titled work") }
        func draw() { background(0) }
    }

    private func makeApplication(
        render: RenderRequest? = nil, listed: @escaping (String) -> Void
    ) throws -> SketchApplication {
        let application = try SketchApplication(sketch: Titled(), gpu: RenderDevice(), render: render)
        application.onStopSignal = { Issue.record("検査は合図を送っていないのに、終わりを頼んだ") }
        application.announce = { _ in }
        application.listFrames = { title in
            listed(title)
            return nil
        }
        return application
    }

    @Test("自分のウィンドウを開く経路は、題を添えて 1 度名乗り、終わるときに下ろす")
    func theOwnWindowPathAnnounces() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let missing = TestScratch.path("mokume-viewport", isDirectory: true)
        var titles: [String] = []
        let application = try makeApplication(listed: { titles.append($0) })
        // 本物の名乗りを検査の置き場へ (bootstrap には実際に登録する)
        application.listFrames = { title in
            titles.append(title)
            return FrameAnnouncement.announce(
                sketch: "Titled", identity: "/work/Titled", title: title, in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") })
        }
        application.resolveOutlet(at: missing, owner: nil)
        application.didFinishLaunching()
        defer { application.window?.close() }
        #expect(titles == ["Titled work"])
        #expect(FrameListing.entries(in: directory).map(\.title) == ["Titled work"])

        application.willTerminate()
        #expect(FrameListing.entries(in: directory).isEmpty, "終わったのに目録に残っている")
    }

    @Test("共有面へ差し出す見張りの子は名乗らず、作品名と題を面に載せる")
    func theSharedChildLeavesItToTheTool() throws {
        let facet = try TestScratch.directory("mokume-viewport")
        defer { try? FileManager.default.removeItem(at: facet) }
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        var titles: [String] = []
        let gpu = try RenderDevice()
        let application = try makeApplication(listed: { titles.append($0) })
        application.toolInput = pipe.fileHandleForReading.fileDescriptor
        defer { application.willTerminate() }

        application.resolveOutlet(at: facet, owner: "mokume watch")
        #expect(application.sharedSurface != nil, "共有面の経路になっていない")
        #expect(titles.isEmpty, "共有面の子が名乗った")
        let expected = FrameShare(sketch: FrameAnnouncement.ownSketchName, title: "Titled work")
        #expect(application.sharedSurface?.frameShare == expected)

        // 焼いた面に載る (子は焼きの結末を見てから名乗る・#2735)。駆動は `PointerLockSketchTests` と同じく拍を直に打つ。
        // 冷えた初回 (パイプラインの用意) は数拍では名乗りが届かないことがあるので、回数に上限を持って打ち続ける
        let manifest = try #require(SharedFrameSurface.readManifest(at: facet))
        var newest: (id: UInt32, frame: Int)?
        for _ in 0..<120 where newest == nil {
            application.displayLinkFired()
            _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
            newest = SharedFrameSurface.newest(among: manifest.ids)
        }
        let named = try #require(newest, "120 拍打っても名乗った面が無い")
        let surface = try #require(IOSurfaceLookup(named.id))
        #expect(SharedFrameSurface.frameShare(on: surface) == expected)
    }

    @Test("共有面を用意できずに自分のウィンドウへ倒れた見張りの子は、自分で名乗る")
    func aChildThatFallsBackAnnouncesItself() throws {
        let facet = try TestScratch.directory("mokume-viewport-locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: facet.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: facet.path)
            try? FileManager.default.removeItem(at: facet)
        }
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        var titles: [String] = []
        let application = try makeApplication(listed: { titles.append($0) })
        application.toolInput = pipe.fileHandleForReading.fileDescriptor
        defer { application.willTerminate() }

        application.resolveOutlet(at: facet, owner: "mokume watch")
        application.didFinishLaunching()
        defer { application.window?.close() }
        #expect(application.window != nil, "検査の前提: 自分のウィンドウへ倒れていない")
        #expect(titles == ["Titled work"])
    }

    @Test("書き出す経路は名乗らない")
    func renderingDoesNotAnnounce() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        sketchStopRequested = 0
        let output = try TestScratch.directory("mokume-frame-share-render")
        defer { try? FileManager.default.removeItem(at: output) }
        let request = try #require(
            RenderRequest(
                frameRate: 30, frameCount: 1,
                destination: output.appendingPathComponent("f-####.png").path))
        var titles: [String] = []
        let application = try makeApplication(render: request, listed: { titles.append($0) })
        application.exitProcess = { _ in }
        application.replyToTermination = {}
        application.resolveOutlet(at: TestScratch.path("mokume-viewport", isDirectory: true), owner: nil)
        application.didFinishLaunching()
        defer { application.willTerminate() }
        #expect(titles.isEmpty, "書き出す経路が名乗った")
    }
}
