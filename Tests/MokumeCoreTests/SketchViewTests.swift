// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import MokumeTestSupport
import SwiftUI
import Testing

@testable import MokumeCore

/// 押している間だけ `x` が増えるスケッチ。作例 (`BricksAndBall` の `paddleX`) と同じ形で、`init()` が
/// 何回呼ばれたかを数える。
private final class EmbeddedProbe: Sketch {
    nonisolated(unsafe) static var initCount = 0
    /// 最後に作られた実体。ホストの中で作られるので、ここから読む。
    nonisolated(unsafe) static var latest: EmbeddedProbe?

    private(set) var x = 0
    private(set) var draws = 0

    var settings: SketchSettings { SketchSettings(width: 64, height: 36) }

    init() {
        Self.initCount += 1
        Self.latest = self
    }

    func draw() {
        draws += 1
        if keyboard.isPressed(.a) { x += 5 }
        expose("x", x)
        background(LinearRGBA.linear(red: 0, green: 0, blue: 0))
    }
}

/// `body` を評価し直させるための値。
@MainActor
private final class Churn: ObservableObject {
    @Published var tick = 0
}

private struct EmbeddingApp: View {
    @ObservedObject var churn: Churn
    let probe: () -> EmbeddedProbe

    var body: some View {
        VStack {
            Text("tick \(churn.tick)")
            SketchView(probe())
        }
        .frame(width: 200, height: 160)
    }
}

/// SwiftUI のアプリの中に映すビュー (#3511)。GPU と窓を使うので、1 本ずつ走らせる。
@MainActor
@Suite(
    "SketchView", .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SketchViewTests {
    /// ホストの窓を建てて、中の `SketchHostView` を取る。
    private func embed(_ root: some View) throws -> (NSWindow, SketchHostView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 160), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        hosting.layoutSubtreeIfNeeded()
        return (window, try #require(Self.hostView(in: hosting), "SketchHostView が載っていない"))
    }

    private static func hostView(in view: NSView) -> SketchHostView? {
        if let found = view as? SketchHostView { return found }
        for child in view.subviews { if let found = hostView(in: child) { return found } }
        return nil
    }

    /// 1 リフレッシュぶん進める。駆動源 (本物の display link) に任せず、検査から叩く。
    private func refresh(_ application: SketchApplication, _ times: Int) {
        for _ in 0..<times { application.displayLinkFired() }
    }

    /// **条件 1**: SwiftUI の中で動き、キーを押すと値が変わる。
    @Test("SwiftUI のアプリの中で動き、キーを押すと値が増える")
    func runsInsideAHostingView() throws {
        EmbeddedProbe.initCount = 0
        let probe = EmbeddedProbe()
        let churn = Churn()
        let (window, view) = try embed(EmbeddingApp(churn: churn) { probe })
        defer {
            view.stop()
            window.close()
        }
        let application = try #require(view.application, "走り始めていない (断られた)")
        application.windowVisibilityForTesting = true

        refresh(application, 5)
        #expect(probe.draws >= 5, "フレームが進んでいない (\(probe.draws))")
        #expect(probe.x == 0)

        window.sendEvent(
            try #require(KeyEventFixture.keyDown(in: window, characters: "a", keyCode: 0)))
        let before = probe.draws
        refresh(application, 4)
        #expect(probe.draws >= before + 4)
        #expect(probe.x >= 20, "押している間に x が増えていない (\(probe.x))")
    }

    /// **条件 2**: `body` を 10 回評価し直しても作り直さず、状態を保つ。
    @Test("body を 10 回評価し直しても、スケッチは 1 度だけ作られ、状態が保たれる")
    func theSketchIsMadeOncePerIdentity() throws {
        EmbeddedProbe.initCount = 0
        let churn = Churn()
        let (window, view) = try embed(
            EmbeddingApp(churn: churn) { EmbeddedProbe() })
        defer {
            view.stop()
            window.close()
        }
        let application = try #require(view.application)
        refresh(application, 3)
        window.sendEvent(
            try #require(KeyEventFixture.keyDown(in: window, characters: "a", keyCode: 0)))
        refresh(application, 2)

        for _ in 0..<10 {
            churn.tick += 1
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(EmbeddedProbe.initCount == 1, "評価し直すたびに作られた (\(EmbeddedProbe.initCount) 回)")
        let content = try #require(window.contentView)
        let again = try #require(Self.hostView(in: content))
        #expect(again === view, "ビューが作り直された")
        let probe = try #require(EmbeddedProbe.latest)
        #expect(probe.x >= 10, "評価し直しで状態が消えた (x = \(probe.x))")
        #expect(probe.draws >= 5)
    }

    /// 同時に動くのは 1 つ。ビューが外れたら印が外れ、次の `SketchView` が動く。
    @Test("2 つ目は走らず、先のビューを止めたら次が走る")
    func onlyOneRunsAtATime() throws {
        let (windowA, first) = try embed(EmbeddingApp(churn: Churn()) { EmbeddedProbe() })
        defer { windowA.close() }
        #expect(first.application != nil)

        let (windowB, second) = try embed(EmbeddingApp(churn: Churn()) { EmbeddedProbe() })
        defer { windowB.close() }
        #expect(second.application == nil, "1 つ走っているのに、2 つ目が走り出した")

        first.stop()
        first.stop()  // 何度呼んでもよい
        let (windowC, third) = try embed(EmbeddingApp(churn: Churn()) { EmbeddedProbe() })
        defer {
            third.stop()
            windowC.close()
        }
        #expect(third.application != nil, "先を止めても、印が外れていない")
    }

    /// 駆動源は窓に載ったときに繋ぎ、外れたら畳む。
    @Test("窓から外れると駆動源を畳み、載り直すと繋ぎ直す")
    func theDriverFollowsTheWindow() throws {
        let (window, view) = try embed(EmbeddingApp(churn: Churn()) { EmbeddedProbe() })
        defer {
            view.stop()
            window.close()
        }
        let application = try #require(view.application)
        let hosting = try #require(window.contentView)
        #expect(application.screenLink.isAttached, "窓に載っているのに繋がっていない")

        hosting.removeFromSuperview()
        #expect(!application.screenLink.isAttached, "窓から外れたのに畳まれていない")

        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        #expect(application.screenLink.isAttached, "載り直したのに繋ぎ直されていない")
    }
}
