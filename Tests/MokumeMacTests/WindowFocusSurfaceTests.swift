// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import IOSurface
import Metal
import MokumeTestSupport
import Testing

@testable import MokumeCore
@testable import MokumeMac

// ウィンドウが前にあるか (`focused`) と題名の頼み (#3709) のうち、外枠 (面・アプリ) が運ぶ側の検査。線・合流点・
// 走っている実行の側は Core にあるので、MokumeCoreTests の WindowFocusTests.swift にある (#3804)。

/// 見張りの子の題名の頼みが共有面へ渡るか。GPU を要する。
@Suite(
    "ウィンドウの題名: 見張りの子",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct WindowTitleChildTests {
    /// 題名を変えるスケッチ。
    final class Retitler: Sketch {
        var title: String?
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func draw() {
            background(0)
            if let title { windowTitle(title) }
        }
    }

    /// 見張りの子はウィンドウを持たない ([ADR-0032] 決定 1)。題名を変えるのは道具の作品のウィンドウなので、頼みは共有面の
    /// 属性で渡る。名乗るのは 1 枚遅れる (#748)。止まったスケッチの頼みの変化も、絵の鍵に入るので焼き直して渡る。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    @Test("見張りの子は、題名の頼みを共有面に載せる")
    func theChildPublishesTheTitle() throws {
        let facet = try TestScratch.directory("mokume-window-title")
        defer { try? FileManager.default.removeItem(at: facet) }
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        let sketch = Retitler()
        let gpu = try RenderDevice()
        let application = try SketchApplication(sketch: sketch, gpu: gpu)
        application.onStopSignal = { Issue.record("検査は合図を送っていないのに、終わりを頼んだ") }
        application.toolInput = pipe.fileHandleForReading.fileDescriptor
        defer { application.willTerminate() }

        application.resolveOutlet(at: facet, owner: "mokume watch")
        #expect(!application.endsAfterLastWindowClosed, "共有面の経路になっていない")

        func refresh() {
            application.displayLinkFired()
            _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
        }
        for _ in 0..<3 { refresh() }
        let manifest = try #require(SharedFrameSurface.readManifest(at: facet))
        let untitled = try #require(SharedFrameSurface.newest(among: manifest.ids))
        let untitledSurface = try #require(IOSurfaceLookup(untitled.id))
        #expect(SharedFrameSurface.windowTitleRequest(on: untitledSurface) == nil)

        sketch.title = "clicked 3"
        for _ in 0..<3 { refresh() }
        let titled = try #require(SharedFrameSurface.newest(among: manifest.ids))
        #expect(titled.frame > untitled.frame)
        let titledSurface = try #require(IOSurfaceLookup(titled.id))
        #expect(SharedFrameSurface.windowTitleRequest(on: titledSurface) == "clicked 3")
    }
}

/// **ウィンドウが退いたときに離すのは、ウィンドウが流した押下だけ** ([#2443](https://github.com/mokume-metal/mokume/issues/2443)・
/// [#3709](https://github.com/mokume-metal/mokume/issues/3709) の決定)。面をウィンドウへ載せるが前には出さず、退いた知らせを
/// 送って、ウィンドウの押下と注入した押下が混ざった合流点を見る。面を作るのに Metal の装置が要る。
@Suite(
    "ウィンドウが退いたときの押下",
    .enabled(if: RenderDevice.isAvailable, "面を作るのに Metal の装置が要る"))
@MainActor
struct FocusLossSurfaceTests {
    @Test("退くと、ウィンドウの押下だけが離れ、注入した押下は残る。離した呼び出しの中から読む focused は false")
    func onlyWindowPressesAreReleased() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let input = InputState()
        let surface = SketchSurface(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64), device: device, input: input,
            canvasSize: (64, 64))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.contentView = nil }
        var lines: [String] = []
        surface.relay = { lines.append($0) }

        // ウィンドウの押下 (面が流す) と、注入した押下 (合流点へ直に積む)
        surface.deliver(.keyDown(code: .a, characters: "a", isRepeat: false))
        surface.deliver(.mouseDown(x: 5, y: 6, button: .left))
        input.enqueue(.keyDown(code: .space, characters: " ", isRepeat: false))
        input.enqueue(.mouseDown(x: 5, y: 6, button: .right))
        input.beginFrame()
        input.endFrame()
        lines.removeAll()

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        // 運び先 (道具のウィンドウなら子) へも、退いた知らせの後にウィンドウの分の解放だけが流れる
        #expect(
            lines == [
                InputEvent.focusChanged(focused: false).wireLine,
                InputEvent.keyUp(code: .a).wireLine,
                InputEvent.mouseUp(x: 5, y: 6, button: .left).wireLine,
            ], "\(lines)")

        var calls: [InputCallback] = []
        var focusedInCalls: [Bool] = []
        input.beginFrame { callback in
            calls.append(callback)
            focusedInCalls.append(input.focused)
        }
        #expect(calls == [.keyReleased, .mouseReleased, .mouseClicked], "\(calls)")
        #expect(focusedInCalls.allSatisfy { !$0 }, "離した呼び出しの中で、まだ前にある扱いだった")
        let keyboard = Keyboard(state: input)
        #expect(!keyboard.isPressed(.a), "ウィンドウのキーが残った")
        #expect(keyboard.isPressed(.space), "注入したキーを離した")
        #expect(input.pressedButtons == [.right], "離したボタンが違う: \(input.pressedButtons)")
        #expect(!input.focused)
    }
}
