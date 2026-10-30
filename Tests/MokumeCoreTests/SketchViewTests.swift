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

/// `setup()` で投げるスケッチ。
private final class ThrowingSetup: Sketch {
    struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
    var settings: SketchSettings { SketchSettings(width: 64, height: 36) }
    init() {}
    func setup() throws { throw Boom() }
    func draw() {}
}

/// `setup()` で、矢印を隠す・ポインタを捕まえる・ファイルを選ばせるを頼んでから投げるスケッチ。
private final class WishfulThenThrowing: Sketch {
    struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
    var settings: SketchSettings { SketchSettings(width: 64, height: 36) }
    init() {}
    func setup() throws {
        noCursor()
        requestPointerLock()
        Task { _ = await selectInput("pick") }
        throw Boom()
    }
    func draw() {}
}

/// 閉じた回数を数える差込口。
private final class CloseCounter: Inlet {
    var closes = 0
    func open() throws {}
    func supply() {}
    func close() { closes += 1 }
    var failure: String? { nil }
    var report: SourceReport? { nil }
}

private struct CounterPlugin: Plugin {
    let inlet: CloseCounter
    func register(into registry: PluginRegistry) { registry.add(inlet: inlet) }
}

/// 差込口を 1 つ足すスケッチ。
private final class WithCounter: Sketch {
    /// 検査が `init()` の前に差す。ホストの中で作られるので、ここから渡す。
    nonisolated(unsafe) static var counter = CloseCounter()
    var settings: SketchSettings { SketchSettings(width: 64, height: 36) }
    var plugins: [any Plugin] { [CounterPlugin(inlet: Self.counter)] }
    init() {}
    func draw() {}
}

/// `setup()` で `selectInput` を頼む (`Task` から) スケッチ。
private final class SelectAsker: Sketch {
    var settings: SketchSettings { SketchSettings(width: 64, height: 36) }
    var result: String??
    init() {}
    func setup() {
        Task { result = .some(await selectInput("pick")) }
    }
    func draw() {}
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
    @Test("2 つ目は待ち、理由をプロセスで 1 度だけ名乗り、先のビューが止まると始まる")
    func theSecondWaitsAndStartsWhenTheFirstEnds() async throws {
        SketchApplication.resetEmbeddedAnnouncementsForTesting()
        try await Diagnostics.$digest.withValue(WarningDigest()) {
            let (windowA, first) = try embed(EmbeddingApp(churn: Churn()) { EmbeddedProbe() })
            defer {
                first.stop()
                windowA.close()
            }
            #expect(first.application != nil)

            let churn = Churn()
            let (windowB, second) = try embed(EmbeddingApp(churn: churn) { EmbeddedProbe() })
            // 3 つ目も待つ。理由は、待つビューの数によらず 1 度だけ
            let (windowC, third) = try embed(EmbeddingApp(churn: Churn()) { EmbeddedProbe() })
            defer {
                second.stop()
                third.stop()
                windowB.close()
                windowC.close()
            }
            #expect(second.application == nil, "1 つ走っているのに、2 つ目が走り出した")
            #expect(second.isWaiting && third.isWaiting)
            // 待っている間にホストが評価し直しても、理由は言い直さない
            for _ in 0..<10 {
                churn.tick += 1
                windowB.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            let said = Diagnostics.takeUnreported()
            #expect(
                said.filter { $0.contains(SketchApplication.embeddedWaitNotice) }.count == 1,
                "待つ理由がプロセスで 1 度だけ出ていない: \(said)")
            #expect(
                !said.contains { $0.contains(SketchApplication.secondRunRefusal) },
                "run() の断りの文面を言った (SketchView は断られず待つ)")

            first.stop()
            first.stop()  // 何度呼んでもよい
            #expect(second.application == nil, "止めた呼び出しの中で、待っているものを起こした (次の回へ送る)")
            #expect(await eventually { second.application != nil }, "先を止めても、2 つ目が始まらない")
            let started = try #require(second.application)
            #expect(!second.isWaiting)
            #expect(started.screenLink.isAttached, "窓に載っているのに駆動源が繋がっていない")
            #expect(third.application == nil && third.isWaiting, "先頭が走り始めたのに、次も始まった")
            #expect(
                Diagnostics.takeUnreported().isEmpty, "始まるときに、余計な警告を言った")
        }
    }

    /// 起こされた側の組み立てが言う警告は、送った側 (先を止めた側) の溜め場へ載る。起こす仕事は `DispatchQueue.main.async` の
    /// 中で走り、タスクローカル値が切れるので、送る時点で持って行く。
    @Test("起こされたビューが組み立てで言う警告は、先を止めた側の溜め場に載る")
    func aWokenViewWarnsIntoTheSendersDigest() async throws {
        try await Diagnostics.$digest.withValue(WarningDigest()) {
            let first = SketchHostView(sketch: EmbeddedProbe())
            // 全画面を頼むスケッチは、組み立てで 1 度警告する (``SketchRuntime/embeddedFullScreenNotice``)
            let waiting = SketchHostView(sketch: FullScreenProbe())
            defer {
                first.stop()
                waiting.stop()
            }
            #expect(waiting.isWaiting)
            _ = Diagnostics.takeUnreported()

            first.stop()
            #expect(await eventually { waiting.application != nil }, "待っていたビューが始まらない")
            let said = Diagnostics.takeUnreported()
            #expect(
                said.filter { $0 == SketchRuntime.embeddedFullScreenNotice }.count == 1,
                "起こされた側の警告が、送った側の溜め場に載っていない: \(said)")
        }
    }

    /// 順番は待ち始めた順で、待ちながら外れたビューは飛ばされる。
    @Test("待っているビューは待ち始めた順に始まり、待ちながら外れたものは始まらない")
    func waitersStartInOrderAndALeavingOneIsSkipped() async throws {
        try await Diagnostics.$digest.withValue(WarningDigest()) {
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
            #expect(await eventually { b.application != nil }, "先頭の待ちが始まらない")
            #expect(c.application == nil, "外れたビューが始まった")
            #expect(d.application == nil && d.isWaiting, "先頭が走り始めたのに、次も始まった")

            b.stop()
            #expect(await eventually { d.application != nil }, "次の待ちが始まらない")
            #expect(c.application == nil)
        }
    }

    /// 起こす仕事を次の回へ送っている間に出た新しい `SketchView` は、待っているものを追い越さない。
    @Test("起こす仕事が送られている間に出た新しいビューは、待っているものの後ろに並ぶ")
    func aNewcomerDoesNotJumpTheQueue() async throws {
        try await Diagnostics.$digest.withValue(WarningDigest()) {
            let first = SketchHostView(sketch: EmbeddedProbe())
            let waiting = SketchHostView(sketch: EmbeddedProbe())
            defer {
                first.stop()
                waiting.stop()
            }
            #expect(first.application != nil && waiting.isWaiting)

            first.stop()
            // 走っているものは空だが、待っているものを起こす仕事が送られている
            let newcomer = SketchHostView(sketch: EmbeddedProbe())
            defer { newcomer.stop() }
            #expect(newcomer.application == nil && newcomer.isWaiting, "待っているものを追い越して始まった")
            #expect(await eventually { waiting.application != nil }, "待っていたものが始まらない")
            #expect(newcomer.application == nil && newcomer.isWaiting)
        }
    }

    /// 起こす仕事を送った後に、待っていたビューが止められても、次が起こされる。
    @Test("起こす仕事を送った後に待っていたビューを止めても、次のビューが始まる")
    func stoppingAWaiterAfterTheWakeWasScheduled() async throws {
        try await Diagnostics.$digest.withValue(WarningDigest()) {
            let first = SketchHostView(sketch: EmbeddedProbe())
            let second = SketchHostView(sketch: EmbeddedProbe())
            let third = SketchHostView(sketch: EmbeddedProbe())
            defer {
                first.stop()
                second.stop()
                third.stop()
            }
            first.stop()
            second.stop()  // 起こされる前に外れた
            #expect(await eventually { third.application != nil }, "外れたビューの次が始まらない")
            #expect(second.application == nil, "止めたビューが始まった")
        }
    }

    /// 走っているのが `run()` (`Sketch.main()`) なら、待っても始まらないので、待たずに 1 度だけそう言う。
    @Test("走っているのが run() なら、SketchView は待たず、始まらない理由を 1 度だけ言う")
    func aRunningWindowIsNotWaitedFor() throws {
        SketchApplication.resetEmbeddedAnnouncementsForTesting()
        try Diagnostics.$digest.withValue(WarningDigest()) {
            let windowed = try SketchApplication(sketch: EmbeddedProbe(), gpu: RenderDevice())
            windowed.markRunningForTesting()
            defer { windowed.unmarkRunningForTesting() }

            let first = SketchHostView(sketch: EmbeddedProbe())
            let second = SketchHostView(sketch: EmbeddedProbe())
            defer {
                first.stop()
                second.stop()
            }
            #expect(first.application == nil && !first.isWaiting, "待っても始まらないのに、待った")
            #expect(second.application == nil && !second.isWaiting)
            let said = Diagnostics.takeUnreported()
            #expect(
                said.filter { $0.contains(SketchApplication.embeddedRefusalNotice) }.count == 1,
                "始まらない理由が 1 度だけ出ていない: \(said)")
            #expect(!said.contains { $0.contains(SketchApplication.embeddedWaitNotice) })

            // run() が終われば、次の SketchView は始まる
            windowed.unmarkRunningForTesting()
            let third = SketchHostView(sketch: EmbeddedProbe())
            defer { third.stop() }
            #expect(third.application != nil)
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

    private func surface(of view: SketchHostView) throws -> SketchSurface {
        try #require(view.subviews.compactMap { $0 as? SketchSurface }.first)
    }

    /// ホストの窓に、`SketchHostView` を直に並べる (SwiftUI を介さない)。
    private func hostWindow() -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 160), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 160))
        window.contentView = container
        window.orderFront(nil)
        return (window, container)
    }

    /// 指摘 1: 起こされた面が据わる。止めた面が第一応答者のままだと、次の面にキーが来ない。
    @Test("先のビューを止めると第一応答者を手放し、起こされた次の面がキーを受ける")
    func theNextSurfaceTakesTheKeysAfterTheFirstEnds() async throws {
        try await Diagnostics.$digest.withValue(WarningDigest()) {
            let (window, container) = hostWindow()
            let first = SketchHostView(sketch: EmbeddedProbe())
            let second = SketchHostView(sketch: EmbeddedProbe())
            container.addSubview(first)
            container.addSubview(second)
            defer {
                first.stop()
                second.stop()
                window.close()
            }
            let firstSurface = try surface(of: first)
            #expect(window.firstResponder === firstSurface, "先の面が第一応答者になっていない")

            first.stop()
            #expect(window.firstResponder !== firstSurface, "止めた面が第一応答者のまま")
            #expect(await eventually { second.application != nil })
            #expect(window.firstResponder === (try surface(of: second)), "起こされた面にキーが来ない")
        }
    }

    /// 指摘 4: 止めたら、開いているファイルのシートを閉じる。
    @Test("止めたら、開いているファイルを選ぶシートを閉じ、取り消しとして結果を渡す")
    func stoppingClosesTheOpenFileSheet() async throws {
        try await Diagnostics.$digest.withValue(WarningDigest()) {
            let (window, container) = hostWindow()
            let asker = SelectAsker()
            let view = SketchHostView(sketch: asker)
            container.addSubview(view)
            defer {
                view.stop()
                window.close()
            }
            let application = try #require(view.application)
            application.windowVisibilityForTesting = true
            let picker = FakeFilePicker()
            application.filePicker = picker
            var lines: [String] = []
            try surface(of: view).relay = { lines.append($0) }

            #expect(
                await eventually {
                    application.displayLinkFired()
                    return !picker.shown.isEmpty
                }, "頼んだシートが出ていない")
            #expect(picker.dismissals == 0)

            view.stop()
            #expect(picker.dismissals == 1, "止めてもシートが開いたまま")
            let cancelled = InputEvent.fileSelected(path: nil, serial: 1).wireLine
            #expect(lines.contains(cancelled), "取り消しの結果を渡していない: \(lines)")
            // スケッチ側の待ちは、取り消しの nil で終わる (待ち続けない)
            #expect(await eventually { asker.result != nil }, "スケッチの selectInput が終わらない")
            #expect(asker.result == .some(nil), "取り消しの nil で終わっていない: \(String(describing: asker.result))")
        }
    }

    /// 指摘 4: 止めたら、捕まえているポインタと隠している矢印を戻す。
    @Test("止めたら、捕まえているポインタと隠している矢印を戻す")
    func stoppingReleasesThePointerAndTheCursor() throws {
        var releases = 0
        var shown = 0
        let lock = PointerLock(
            system: .init(capture: { true }, release: { releases += 1 }),
            arbiter: PointerLock.Arbiter())
        let hiding = CursorHiding(system: .init(hide: { shown -= 1 }, unhide: { shown += 1 }))
        let application = try SketchApplication(
            sketch: EmbeddedProbe(), gpu: RenderDevice(), embedded: true)
        let surface = try #require(
            application.startEmbedded(pointerLock: lock, cursorHiding: hiding))
        defer { application.stopEmbedded() }

        lock.notePress(in: .init(isKeyWindow: true, pointerIsInside: true))
        lock.update(requested: true, in: .init(isKeyWindow: true, pointerIsInside: true))
        hiding.update(requested: true, in: .init(isKeyWindow: true, pointerIsOverSurface: true))
        #expect(lock.isLocked && hiding.isHiding, "検査の前提: 捕まえて隠している")
        _ = surface

        application.stopEmbedded()
        #expect(!lock.isLocked, "ポインタを捕まえたまま")
        #expect(releases == 1)
        #expect(!hiding.isHiding && shown == 0, "矢印を隠したまま")
    }

    /// 指摘 5: 埋め込みで `setup()` が投げても、ホストのアプリごと落とさない。
    @Test("埋め込みで setup() が投げても、プロセスを終わらせず、理由を警告してそのビューだけを止める")
    func aThrowingSetupDoesNotEndTheHost() async throws {
        try await Diagnostics.$digest.withValue(WarningDigest()) {
            let (window, container) = hostWindow()
            let failing = SketchHostView(sketch: ThrowingSetup())
            let next = SketchHostView(sketch: EmbeddedProbe())
            container.addSubview(failing)
            container.addSubview(next)
            defer {
                failing.stop()
                next.stop()
                window.close()
            }
            let application = try #require(failing.application)
            application.windowVisibilityForTesting = true
            var exits: [Int32] = []
            application.exitProcess = { exits.append($0) }
            _ = Diagnostics.takeUnreported()

            application.displayLinkFired()
            #expect(exits.isEmpty, "ホストのアプリごと終わらせた (\(exits))")
            let said = Diagnostics.takeUnreported()
            #expect(
                said.contains { $0.contains("SketchView could not start the sketch") && $0.contains("boom") },
                "理由を警告していない: \(said)")
            #expect(await eventually { next.application != nil }, "止めた後、次の待ちが始まらない")
        }
    }

    /// 指摘 6: `dismantleNSView` を通らずに消えても、走っているものの印を外す。
    @Test("後始末を通らずに消えたビューも、走っている印を外し、待っていたビューが始まる")
    func aViewThatVanishesWithoutDismantlingFreesTheSlot() async throws {
        try await Diagnostics.$digest.withValue(WarningDigest()) {
            weak var weakFirst: SketchHostView?
            var second: SketchHostView!
            // stop() を呼ばずに手放す。自動解放の置き場を抜けて、解放まで済ませる
            autoreleasepool {
                let first = SketchHostView(sketch: EmbeddedProbe())
                second = SketchHostView(sketch: EmbeddedProbe())
                weakFirst = first
                #expect(first.application != nil && second.isWaiting)
            }
            defer { second.stop() }
            #expect(weakFirst == nil, "検査の前提: ビューが解放された")
            #expect(await eventually { second.application != nil }, "消えたビューの印が外れず、待ちが起こされない")
        }
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

    /// 根 1: `setup()` が投げた回の続きが、止めた面に触れない。矢印・ポインタを戻した後に頼み直さない。
    @Test("埋め込みで setup() が、矢印・ポインタ・ファイルを頼んでから投げても、止めた後は面に触れない")
    func nothingTouchesTheSurfaceAfterASetupFailureStops() async throws {
        try await Diagnostics.$digest.withValue(WarningDigest()) {
            var shownCursor = 0
            var releases = 0
            let lock = PointerLock(
                system: .init(capture: { true }, release: { releases += 1 }),
                arbiter: PointerLock.Arbiter())
            let hiding = CursorHiding(system: .init(hide: { shownCursor -= 1 }, unhide: { shownCursor += 1 }))
            let (window, container) = hostWindow()
            let view = SketchHostView(
                sketch: WishfulThenThrowing(), pointerLock: lock, cursorHiding: hiding)
            container.addSubview(view)
            defer {
                view.stop()
                window.close()
            }
            let application = try #require(view.application)
            application.windowVisibilityForTesting = true
            application.exitProcess = { _ in Issue.record("ホストのアプリごと終わらせた") }
            let picker = FakeFilePicker()
            application.filePicker = picker
            // setup() が起こした `Task` (selectInput) を走らせてから、最初のフレームを回す
            try await Task.sleep(for: .milliseconds(30))

            application.displayLinkFired()
            // 止めた回の続きが、頼みを面へ渡し直していない
            #expect(!hiding.isRequested, "止めた後に、矢印を隠す頼みを面へ渡し直した")
            #expect(!lock.isRequested, "止めた後に、ポインタを捕まえる頼みを面へ渡し直した")
            #expect(!hiding.isHiding && shownCursor == 0, "矢印を隠したまま")
            #expect(!lock.isLocked)
            #expect(picker.shown.isEmpty, "止めた後に、ファイルを選ばせるシートを出した")
            // 次のリフレッシュ (駆動源は畳まれていて来ないが、来ても) も同じ
            application.displayLinkFired()
            #expect(!hiding.isRequested && !lock.isRequested && picker.shown.isEmpty)
        }
    }

    /// 根 2: 起こす仕事が送られている間に `run()` が席を取ったら、待っているビューは永久に待たず、
    /// 「待っても始まらない」と 1 度だけ言って何も映さない。
    @Test("起こす仕事が送られている間に run() が席を取ったら、待っていたビューは断る側へ倒れる")
    func aRunTakingTheSeatWhileTheWakeIsPendingTurnsTheWaiterAway() async throws {
        SketchApplication.resetEmbeddedAnnouncementsForTesting()
        try await Diagnostics.$digest.withValue(WarningDigest()) {
            let first = SketchHostView(sketch: EmbeddedProbe())
            let waiting = SketchHostView(sketch: EmbeddedProbe())
            let windowed = try SketchApplication(sketch: EmbeddedProbe(), gpu: RenderDevice())
            defer {
                first.stop()
                waiting.stop()
                windowed.unmarkRunningForTesting()
            }
            #expect(first.application != nil && waiting.isWaiting)

            first.stop()  // 待っているものを起こす仕事が送られた
            #expect(
                SketchApplication.admission(for: .embedded) == .wait,
                "送られている間の新しい SketchView は、追い越さずに待つ")
            #expect(
                !SketchApplication.refusesSecondRun(), "送られている間の run() は席を取れる (断らない)")
            windowed.markRunningForTesting()

            #expect(await eventually { !waiting.isWaiting }, "待っていたビューが、永久に待ち続けている")
            #expect(waiting.application == nil, "run() が走っているのに SketchView が始まった")
            let said = Diagnostics.takeUnreported()
            #expect(
                said.filter { $0.contains(SketchApplication.embeddedRefusalNotice) }.count == 1,
                "待っても始まらない理由が 1 度だけ出ていない: \(said)")
            #expect(!said.contains { $0.contains(SketchApplication.secondRunRefusal) })
        }
    }

    /// 旧 `onlyOneRunsAtATime` が見ていた組の裏: SketchView が走っているとき、`run()` (`Sketch.main()`) は断られる。
    @Test("SketchView が走っているときの run() は断られ、断りを 1 度だけ言い、SketchView は止まらない")
    func aSecondRunIsRefusedWhileASketchViewRuns() throws {
        SketchApplication.resetEmbeddedAnnouncementsForTesting()
        try Diagnostics.$digest.withValue(WarningDigest()) {
            let (window, view) = try embed(EmbeddingApp(churn: Churn()) { EmbeddedProbe() })
            defer {
                view.stop()
                window.close()
            }
            let application = try #require(view.application)
            #expect(SketchApplication.admission(for: .run) == .refuse)
            #expect(SketchApplication.refusesSecondRun(), "SketchView が走っているのに、run() を断らなかった")
            #expect(SketchApplication.refusesSecondRun())
            let said = Diagnostics.takeUnreported()
            #expect(
                said.filter { $0.contains(SketchApplication.secondRunRefusal) }.count == 1,
                "断りが 1 度だけ出ていない: \(said)")
            // 走っている SketchView は何も変わらない
            #expect(view.application === application)
            #expect(application.screenLink.isAttached, "断った拍子に、走っている SketchView の駆動源が畳まれた")
            #expect(SketchApplication.admission(for: .run) == .refuse, "断った拍子に、席が空いた")
            refresh(application, 2)
        }
    }

    /// K5: ホストのアプリが終わるとき (`SwiftUI` は `dismantleNSView` を通らない)、後始末が 1 度だけ走る。
    @Test("ホストのアプリが終わる知らせで、走っている SketchView の後始末が 1 度だけ走り、席が空く")
    func theHostTerminatingRunsTheCleanupOnce() async throws {
        try await Diagnostics.$digest.withValue(WarningDigest()) {
            let counter = CloseCounter()
            WithCounter.counter = counter
            let first = SketchHostView(sketch: WithCounter())
            let waiting = SketchHostView(sketch: EmbeddedProbe())
            defer {
                first.stop()
                waiting.stop()
            }
            let running = try #require(first.application)
            #expect(waiting.isWaiting)
            refresh(running, 2)  // 差込口は最初のフレームで開く
            #expect(counter.closes == 0)

            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            #expect(counter.closes == 1, "ホストの終了で、差込口が閉じられていない")
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            first.stop()  // dismantle が後から来ても、2 度は閉じない
            #expect(counter.closes == 1, "後始末が重ねて走った (\(counter.closes) 回)")
            #expect(await eventually { waiting.application != nil }, "席が空かず、待っているビューが始まらない")
        }
    }

    /// K6: ホストの窓が見えていない間は、ファイルを選ばせるシートを出さない (独立したパネルになり、ホストを前面へ出す)。
    @Test("ホストの窓が見えない間はシートを出さず、見えたリフレッシュで出す")
    func theSheetWaitsForAVisibleHostWindow() async throws {
        try await Diagnostics.$digest.withValue(WarningDigest()) {
            let (window, container) = hostWindow()
            let view = SketchHostView(sketch: SelectAsker())
            container.addSubview(view)
            defer {
                view.stop()
                window.close()
            }
            let application = try #require(view.application)
            application.windowVisibilityForTesting = true
            let picker = FakeFilePicker()
            application.filePicker = picker

            window.orderOut(nil)
            #expect(!window.isVisible, "検査の前提: ホストの窓が見えない")
            // 頼み (Task) が届くまで、見えないまま何度か回す
            for _ in 0..<8 {
                application.displayLinkFired()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(picker.shown.isEmpty, "見えない窓の頼みを、シートでない形で出した")

            window.orderFront(nil)
            #expect(
                await eventually {
                    application.displayLinkFired()
                    return !picker.shown.isEmpty
                }, "窓が見えても、頼みが出ない")
            #expect(picker.shown.count == 1)
        }
    }

    /// K7: ビューが窓から外れただけ (dismantle されない) でも、シートは閉じる。載り直した最初のフレームが取り消しを汲む。
    @Test("窓から外れたらシートを取り消しで閉じ、載り直すとスケッチの待ちが nil で終わる")
    func detachingFromTheWindowClosesTheSheet() async throws {
        try await Diagnostics.$digest.withValue(WarningDigest()) {
            let (window, container) = hostWindow()
            let asker = SelectAsker()
            let view = SketchHostView(sketch: asker)
            container.addSubview(view)
            defer {
                view.stop()
                window.close()
            }
            let application = try #require(view.application)
            application.windowVisibilityForTesting = true
            let picker = FakeFilePicker()
            application.filePicker = picker
            var lines: [String] = []
            try surface(of: view).relay = { lines.append($0) }
            #expect(
                await eventually {
                    application.displayLinkFired()
                    return !picker.shown.isEmpty
                }, "頼んだシートが出ていない")

            view.removeFromSuperview()
            #expect(picker.dismissals == 1, "窓から外れても、シートが元の窓に残った")
            #expect(
                lines.contains(InputEvent.fileSelected(path: nil, serial: 1).wireLine),
                "取り消しの結果を渡していない: \(lines)")

            container.addSubview(view)
            #expect(
                await eventually {
                    application.displayLinkFired()
                    return asker.result != nil
                }, "載り直しても、スケッチの待ちが終わらない")
            #expect(asker.result == .some(nil))
            #expect(picker.shown.count == 1, "取り消した頼みを出し直した")
        }
    }
}
