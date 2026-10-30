// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import MokumeDiagnostics
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

/// 全画面を頼むスケッチ。描く大きさは 64 × 36 (全画面ならディスプレイの大きさになる)。
private final class FullScreenProbe: Sketch {
    var settings: SketchSettings {
        var settings = SketchSettings(width: 64, height: 36)
        settings.fullScreenDisplay = 1
        return settings
    }

    init() {}

    func draw() {
        background(LinearRGBA.linear(red: 0, green: 0, blue: 0))
    }
}

/// 作者の時計と実時間を、検査から進める。
private final class TimeBox {
    var author = 0.0
    var real = 0.0
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

    /// **条件 1**: 別の `SketchView` が映っている間に出た 2 つ目は、始めず、理由を 1 度だけ言う。先が消えると始まる。
    @Test("2 つ目は待ち、理由を 1 度だけ名乗り、先のビューが止まると始まる")
    func theSecondWaitsAndStartsWhenTheFirstEnds() throws {
        try Diagnostics.$digest.withValue(WarningDigest()) {
            let (windowA, first) = try embed(EmbeddingApp(churn: Churn()) { EmbeddedProbe() })
            defer {
                first.stop()
                windowA.close()
            }
            #expect(first.application != nil)

            let churn = Churn()
            let (windowB, second) = try embed(EmbeddingApp(churn: churn) { EmbeddedProbe() })
            defer {
                second.stop()
                windowB.close()
            }
            #expect(second.application == nil, "1 つ走っているのに、2 つ目が走り出した")
            #expect(second.isWaiting)
            // 待っている間にホストが評価し直しても、理由は言い直さない
            for _ in 0..<10 {
                churn.tick += 1
                windowB.contentView?.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            let said = Diagnostics.takeUnreported()
            #expect(
                said.filter { $0.contains(SketchApplication.embeddedWaitNotice) }.count == 1,
                "待つ理由が 1 度だけ出ていない: \(said)")
            #expect(
                !said.contains { $0.contains(SketchApplication.secondRunRefusal) },
                "run() の断りの文面を言った (SketchView は断られず待つ)")

            first.stop()
            first.stop()  // 何度呼んでもよい
            let started = try #require(second.application, "先を止めても、2 つ目が始まらない")
            #expect(!second.isWaiting)
            #expect(started.screenLink.isAttached, "窓に載っているのに駆動源が繋がっていない")
            #expect(
                Diagnostics.takeUnreported().isEmpty, "始まるときに、余計な警告を言った")
        }
    }

    /// 順番は待ち始めた順で、待ちながら外れたビューは飛ばされる。
    @Test("待っているビューは待ち始めた順に始まり、待ちながら外れたものは始まらない")
    func waitersStartInOrderAndALeavingOneIsSkipped() throws {
        try Diagnostics.$digest.withValue(WarningDigest()) {
            var windows: [NSWindow] = []
            var views: [SketchHostView] = []
            for _ in 0..<4 {
                let (window, view) = try embed(EmbeddingApp(churn: Churn()) { EmbeddedProbe() })
                windows.append(window)
                views.append(view)
            }
            defer {
                views.forEach { $0.stop() }
                windows.forEach { $0.close() }
            }
            let (a, b, c, d) = (views[0], views[1], views[2], views[3])
            #expect(a.application != nil)
            #expect([b, c, d].allSatisfy { $0.application == nil && $0.isWaiting })

            c.stop()  // 待ちながら外れた
            a.stop()
            #expect(b.application != nil, "先頭の待ちが始まらない")
            #expect(c.application == nil, "外れたビューが始まった")
            #expect(d.application == nil && d.isWaiting, "先頭が走り始めたのに、次も始まった")

            b.stop()
            #expect(d.application != nil, "次の待ちが始まらない")
            #expect(c.application == nil)
        }
    }

    /// **条件 2**: `SketchView` ではメニューバーの名乗りを出さない。
    @Test("埋め込みでは、猶予を越えて走っても名乗りを出さない")
    func noPresenceInsideTheHost() throws {
        let time = TimeBox()
        let runtime = try SketchRuntime(
            sketch: EmbeddedProbe(), gpu: RenderDevice(), clock: .wallClock,
            now: { time.author }, presenceClock: { time.real }, embedded: true)
        try runtime.advance()
        time.author += 100 * SketchPresence.grace
        time.real += 100 * SketchPresence.grace
        try runtime.advance()
        #expect(!runtime.isPresenceAnnounced, "ホストの中で名乗りを出した")
    }

    /// 対照: 同じ時計の進みで、窓で走るなら名乗る長さに達する (上の検査が空振りでないことの裏)。名乗りそのものは
    /// 起こさない — 2 度目の `advance()` を呼ばず、経過だけを読む。
    @Test("対照: 窓で走るなら、同じ時計の進みで名乗る長さに達する")
    func theSameClocksWouldAnnounceInAWindow() throws {
        let time = TimeBox()
        let runtime = try SketchRuntime(
            sketch: EmbeddedProbe(), gpu: RenderDevice(), clock: .wallClock,
            now: { time.author }, presenceClock: { time.real })
        try runtime.advance()
        time.author += 100 * SketchPresence.grace
        time.real += 100 * SketchPresence.grace
        #expect(SketchPresence.shouldAnnounce(runningFor: runtime.presenceElapsed))
        #expect(!runtime.isPresenceAnnounced)
    }

    /// `SketchView` が組むランタイムが、埋め込みの組み方になっている (名乗り・全画面を外す印が立つ)。
    @Test("SketchView が走らせるものは、埋め込みの組み方である")
    func theHostRunsTheEmbeddedWay() throws {
        let (window, view) = try embed(EmbeddingApp(churn: Churn()) { EmbeddedProbe() })
        defer {
            view.stop()
            window.close()
        }
        #expect(try #require(view.application).runsEmbedded)
    }

    /// **条件 2**: `fullScreen(_:)` を読まず、1 度だけ警告する。
    @Test("埋め込みでは、全画面を頼んでも、ディスプレイの一覧を読まず、設定の大きさのまま 1 度だけ警告する")
    func fullScreenIsNotReadInsideTheHost() throws {
        try Diagnostics.$digest.withValue(WarningDigest()) {
            let runtime = try SketchRuntime(
                sketch: FullScreenProbe(), gpu: RenderDevice(), clock: nil, now: { 0 },
                displays: {
                    Issue.record("ディスプレイの一覧を読んだ")
                    return []
                }, embedded: true)
            #expect(runtime.fullScreenDisplay == nil)
            #expect(runtime.target.width == 64 && runtime.target.height == 36)
            let said = Diagnostics.takeUnreported()
            #expect(said == [SketchRuntime.embeddedFullScreenNotice], "警告が 1 度だけ出ていない: \(said)")
        }
    }

    /// 対照: 埋め込みでなければ、同じ頼みでディスプレイを選びに行く (読まない検査が空振りでないことの裏)。
    @Test("対照: 窓で開くなら、全画面を頼むとディスプレイの一覧を読み、選べなければ断る")
    func fullScreenIsReadOutsideTheHost() throws {
        var read = 0
        #expect(throws: RenderFailure.self) {
            _ = try SketchRuntime(
                sketch: FullScreenProbe(), gpu: RenderDevice(), clock: nil, now: { 0 },
                displays: {
                    read += 1
                    return []
                })
        }
        #expect(read == 1)
    }

    /// 同じことを、ホストの窓の中で通して: 窓は変わらず、絵の大きさは設定のまま、警告は 1 度だけ。
    @Test("SketchView に全画面のスケッチを載せても、ホストの窓は変わらず、警告は 1 度だけ")
    func aFullScreenSketchLeavesTheHostWindowAlone() throws {
        try Diagnostics.$digest.withValue(WarningDigest()) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 160), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: SketchView(FullScreenProbe()))
            window.contentView = hosting
            window.orderFront(nil)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let frame = window.frame
            let view = try #require(Self.hostView(in: hosting))
            defer {
                view.stop()
                window.close()
            }
            let application = try #require(view.application)
            refresh(application, 5)

            #expect(!window.styleMask.contains(.fullScreen), "ホストの窓を全画面にした")
            #expect(window.frame == frame, "ホストの窓の大きさを変えた")
            let surface = try #require(view.subviews.compactMap { $0 as? SketchSurface }.first)
            #expect(surface.canvasWidth == 64, "描く大きさがディスプレイの大きさになった")
            let said = Diagnostics.takeUnreported()
            #expect(
                said.filter { $0 == SketchRuntime.embeddedFullScreenNotice }.count == 1,
                "警告が 1 度だけ出ていない: \(said)")
        }
    }

    /// 決定 (2026-10-30): 埋め込みの面はファイルのドロップを受けない (ホスト側のドロップと取り合わない)。
    @Test("埋め込みの面は、ファイルのドロップを受けるよう登録しない")
    func theEmbeddedSurfaceDoesNotAcceptFileDrops() throws {
        let (window, view) = try embed(EmbeddingApp(churn: Churn()) { EmbeddedProbe() })
        defer {
            view.stop()
            window.close()
        }
        let surface = try #require(view.subviews.compactMap { $0 as? SketchSurface }.first)
        #expect(surface.registeredDraggedTypes.isEmpty, "ドロップを受けるよう登録している")
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
