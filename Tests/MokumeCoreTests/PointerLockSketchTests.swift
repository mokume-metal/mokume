// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 捕まえを頼むスケッチ。**頼むのは `setup()` で 1 度だけ**、``releases`` を立てると `draw()` で
/// 取り下げる。`draw()` から読めた値と、1 件ぶんの量の和を控える。
final class PointerLockLooker: Sketch {
    struct Seen: Equatable {
        let mouseX: Float
        let mouseY: Float
        let movedX: Float
        let movedY: Float
        /// そのフレームに `mouseMoved(deltaX:deltaY:)` と `mouseDragged(deltaX:deltaY:)` へ
        /// 渡った量の和。
        let deliveredX: Float
        let deliveredY: Float
    }

    var releases = false
    private(set) var seen: [Seen] = []
    private var deliveredX: Float = 0
    private var deliveredY: Float = 0

    init() {}
    var settings: SketchSettings { SketchSettings(width: 16, height: 16) }

    func setup() { requestPointerLock() }

    func mouseMoved(deltaX: Float, deltaY: Float) {
        deliveredX += deltaX
        deliveredY += deltaY
    }

    func mouseDragged(deltaX: Float, deltaY: Float) {
        deliveredX += deltaX
        deliveredY += deltaY
    }

    func draw() {
        background(0)
        if releases { exitPointerLock() }
        seen.append(
            Seen(
                mouseX: mouseX, mouseY: mouseY, movedX: movedX, movedY: movedY,
                deliveredX: deliveredX, deliveredY: deliveredY))
        deliveredX = 0
        deliveredY = 0
    }
}

/// 走っていないスケッチから頼んでも止まらない。GPU は使わない
/// ([#1144](https://github.com/mokume-metal/mokume/issues/1144) の条件 1)。
@Suite("走っていないときの捕まえの要求")
@MainActor
struct PointerLockOutsideRunTests {
    /// 入力を読む口 (``Sketch/mouseX``) が、走っていなければ空の状態を返すのと同じ向き —
    /// `init` やプロパティの初期化子から呼んだだけで落ちると、書いた人は理由に辿り着けない。
    @Test("走っていないときに頼んでも取り下げても、何も起きず止まらない")
    func doesNothingWhenNotRunning() {
        #expect(runningSketch == nil)
        let sketch = PointerLockLooker()
        sketch.requestPointerLock()
        sketch.exitPointerLock()
    }
}

/// 捕まえの要求が、窓の無い実行と見張りの子の出口でどう扱われるか
/// ([#1144](https://github.com/mokume-metal/mokume/issues/1144))。GPU を要する。
@Suite(
    "捕まえを頼むスケッチを走らせる",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct PointerLockSketchTests {
    private func makeFacet() throws -> URL {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-pointer-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        return facet
    }

    private func send(_ events: String, id: String, to facet: URL) throws {
        try AtomicFile.write(
            Data(#"{"id":"\#(id)","events":[\#(events)]}"#.utf8),
            to: facet.appendingPathComponent("request.json"))
    }

    /// 書き出し (`mokume render`・参照スケッチの `--render`) と同じく、窓を持たない実行。
    /// 要求は覚えるが、読む窓が無いので何も起きない — 止まらず、描き続ける。
    @Test("窓の無い実行で頼んでも、止まらずに描き、要求は取り下げるまで残る")
    func aWindowlessRunKeepsDrawing() throws {
        let sketch = PointerLockLooker()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil)

        for _ in 0..<3 { try runtime.advance() }
        #expect(sketch.seen.count == 3)
        #expect(runtime.pointerLockRequested)

        sketch.releases = true
        try runtime.advance()
        #expect(sketch.seen.count == 4)
        #expect(!runtime.pointerLockRequested)
    }

    /// **捕まえたスケッチも外から動かせる** (ADR-0001 原則 3)。外から送った位置を持たない移動は、
    /// 窓が捕まえている間に送るものと同じ出来事で、`mouseX` を動かさず量だけを運ぶ。決定論も
    /// ここで閉じる — 同じ出来事を送れば同じ値が読める (ADR-0025 の水準 2)。
    @Test("外から送った位置を持たない移動は、位置を動かさず、1 件ぶんの和がフレーム合計と一致する")
    func relativeMotionFromOutsideReachesTheSketch() throws {
        let facet = try makeFacet()
        defer { try? FileManager.default.removeItem(at: facet) }
        let sketch = PointerLockLooker()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))

        try send(#"{"type":"mouseMoved","x":5,"y":4}"#, id: "m1", to: facet)
        try runtime.advance()
        // 押していない 2 件と、押したままの 1 件。1 フレームにまとめて届く
        try send(
            #"""
            {"type":"mouseMovedBy","dx":2,"dy":1},
            {"type":"mouseMovedBy","dx":5,"dy":-3},
            {"type":"mouseDown","x":5,"y":4,"button":0},
            {"type":"mouseMovedBy","dx":-1,"dy":4}
            """#, id: "m2", to: facet)
        try runtime.advance()

        let frame = try #require(sketch.seen.last)
        #expect(frame.mouseX == 5)
        #expect(frame.mouseY == 4)
        #expect(frame.movedX == 6)
        #expect(frame.movedY == 2)
        #expect(frame.deliveredX == frame.movedX)
        #expect(frame.deliveredY == frame.movedY)
    }

    /// 見張りの子は窓を持たない ([ADR-0032] 決定 1)。捕まえるのは道具の窓なので、要求は
    /// 速さと同じく共有面の属性で渡る (決定 4 の追補 (2026-10-07))。名乗るのは 1 枚遅れる (#748)。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    @Test("見張りの子は、捕まえの要求を共有面に載せ、取り下げたら載せなくなる")
    func theChildPublishesTheRequest() throws {
        let facet = try makeFacet()
        defer { try? FileManager.default.removeItem(at: facet) }
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        let sketch = PointerLockLooker()
        let application = try SketchApplication(sketch: sketch, gpu: RenderDevice())
        application.onStopSignal = { Issue.record("検査は合図を送っていないのに、終わりを頼んだ") }
        application.toolInput = pipe.fileHandleForReading.fileDescriptor
        defer { application.willTerminate() }

        application.resolveOutlet(at: facet, owner: "mokume watch")
        #expect(!application.endsAfterLastWindowClosed, "共有面の経路になっていない")

        for _ in 0..<3 { application.displayLinkFired() }
        let manifest = try #require(SharedFrameSurface.readManifest(at: facet))
        let requested = try #require(SharedFrameSurface.newest(among: manifest.ids))
        #expect(SharedFrameSurface.pointerLockRequested(of: requested.id))

        sketch.releases = true
        for _ in 0..<3 { application.displayLinkFired() }
        let released = try #require(SharedFrameSurface.newest(among: manifest.ids))
        #expect(released.frame > requested.frame)
        #expect(!SharedFrameSurface.pointerLockRequested(of: released.id))
    }
}
