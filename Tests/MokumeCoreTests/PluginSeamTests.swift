// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 外から機能を足す差込口 (#448)。GPU を要する。
///
/// [ADR-0024] が置いた骨格が、実際にその形で動いていることを見る。
///
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
@Suite(
    "差込口",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PluginSeamTests {

    // MARK: - 検査用の差込口

    /// 受け取った回数と中身を覚える出口。
    final class RecordingOutlet: Outlet {
        let label: String
        private(set) var opened = 0
        private(set) var closed = 0
        private(set) var received: [(frame: Int, first: (UInt8, UInt8, UInt8, UInt8))] = []
        /// `receive` が呼ばれた回数。**転んだ回も数える** — 受け取れた枚数だけでは
        /// 「外れた」と「呼ばれているが毎回転んでいる」が見分けられない
        private(set) var calls = 0
        /// 何回目の `receive` から転ぶか。`nil` なら転ばない。
        var failsFrom: Int?
        private(set) var failure: String?

        init(label: String = "out") { self.label = label }

        func open() throws { opened += 1 }

        func receive(_ frame: OutputFrame) {
            calls += 1
            if let failsFrom, received.count >= failsFrom {
                failure = "わざと転ぶ"
                return
            }
            failure = nil
            let bytes = frame.bytes()
            received.append((frame.frame, bytes[0, 0]))
        }

        func close() { closed += 1 }
    }

    /// 開くのに失敗する出口。
    final class BrokenOutlet: Outlet {
        struct Failure: Error {}
        func open() throws { throw Failure() }
        func receive(_ frame: OutputFrame) {}
    }

    /// 呼ばれた回数を数える入り口。
    final class CountingInlet: Inlet {
        private(set) var supplied = 0
        private(set) var closed = 0
        func supply() { supplied += 1 }
        func close() { closed += 1 }
    }

    /// 呼ばれた順を 1 本の並びへ書き込む差込口。
    final class OrderedOutlet: Outlet {
        let name: String
        let log: Log
        init(_ name: String, _ log: Log) {
            self.name = name
            self.log = log
        }
        func receive(_ frame: OutputFrame) { log.names.append(name) }
    }

    final class Log {
        var names: [String] = []
        /// 開く・閉じるの順 (``LifecycleOutlet`` が書く)。
        var lifecycle: [String] = []
    }

    /// 出口と入り口の**両方**を足す束 ([#438](https://github.com/mokume-metal/mokume/issues/438) が最初にそうする形)。
    struct BothPlugin: Plugin {
        let outlet: any Outlet
        let inlet: any Inlet
        func register(into registry: PluginRegistry) {
            registry.add(outlet: outlet)
            registry.add(inlet: inlet)
        }
    }

    struct OutletOnlyPlugin: Plugin {
        let outlet: any Outlet
        func register(into registry: PluginRegistry) { registry.add(outlet: outlet) }
    }

    /// 開く・閉じるの順を 1 本の並びへ書き込む出口。`failsOnOpen` なら開くのに失敗する。
    ///
    /// **転んだ側も書く。** そうすると「開いていない差込口が閉じられていない」ことを、
    /// 同じ並びの中で見られる ([#926](https://github.com/mokume-metal/mokume/issues/926))。
    final class LifecycleOutlet: Outlet {
        struct Failure: Error {}
        let name: String
        let log: Log
        let failsOnOpen: Bool

        init(_ name: String, _ log: Log, failsOnOpen: Bool = false) {
            self.name = name
            self.log = log
            self.failsOnOpen = failsOnOpen
        }

        func open() throws {
            if failsOnOpen {
                log.lifecycle.append("fail:\(name)")
                throw Failure()
            }
            log.lifecycle.append("open:\(name)")
        }

        func receive(_ frame: OutputFrame) {}
        func close() { log.lifecycle.append("close:\(name)") }
    }

    /// 開くのに失敗する入り口。
    final class BrokenInlet: Inlet {
        struct Failure: Error {}
        func open() throws { throw Failure() }
        func supply() {}
    }

    /// 出口を**複数**足す束。
    struct OutletsPlugin: Plugin {
        let outlets: [any Outlet]
        func register(into registry: PluginRegistry) {
            for outlet in outlets { registry.add(outlet: outlet) }
        }
    }

    // MARK: - 検査用のスケッチ

    final class SeamSketch: Sketch {
        /// 走らせる前に差し込む。`Sketch` は引数なしで作れる必要があるため。
        nonisolated(unsafe) static var declared: [any Plugin] = []

        var settings: SketchSettings { SketchSettings(width: 32, height: 32) }
        var plugins: [any Plugin] { Self.declared }

        func draw() {
            background(.display(red: 1, green: 0.5, blue: 0))
        }
    }

    /// **並びは `start()` まで読まれない**ので、組み立て後に消してはいけない。
    /// `Sketch` は引数なしで作れる必要があり、束を持ち込む道が静的な置き場しかない。
    private func makeRuntime(_ plugins: [any Plugin]) throws -> SketchRuntime {
        SeamSketch.declared = plugins
        return try SketchRuntime(sketch: SeamSketch(), gpu: try RenderDevice())
    }

    // MARK: - 並びと束

    @Test("1 つの束が、出口と入り口の両方へ入れる")
    func onePluginFillsBothSeams() throws {
        let outlet = RecordingOutlet()
        let inlet = CountingInlet()
        let runtime = try makeRuntime([BothPlugin(outlet: outlet, inlet: inlet)])

        try runtime.advance()
        try runtime.advance()

        #expect(outlet.opened == 1)
        #expect(outlet.received.count == 2)
        #expect(inlet.supplied == 2)
    }

    @Test("出口だけの束と両方の束が、同じ 1 本の並びに置ける")
    func oneListHoldsEveryKind() throws {
        let first = RecordingOutlet(label: "first")
        let second = RecordingOutlet(label: "second")
        let inlet = CountingInlet()
        let runtime = try makeRuntime([
            OutletOnlyPlugin(outlet: first),
            BothPlugin(outlet: second, inlet: inlet),
        ])

        try runtime.advance()

        #expect(first.received.count == 1)
        #expect(second.received.count == 1)
        #expect(inlet.supplied == 1)
    }

    @Test("呼ばれる順は宣言順")
    func orderFollowsDeclaration() throws {
        let log = Log()
        let runtime = try makeRuntime([
            OutletOnlyPlugin(outlet: OrderedOutlet("a", log)),
            OutletOnlyPlugin(outlet: OrderedOutlet("b", log)),
            OutletOnlyPlugin(outlet: OrderedOutlet("c", log)),
        ])

        try runtime.advance()

        #expect(log.names == ["a", "b", "c"])
    }

    @Test("入り口は draw() の直前に呼ばれる")
    func inletsSupplyBeforeDraw() throws {
        final class ObservingInlet: Inlet {
            var suppliedAtDraw: Bool?
            let sketchDrew: Log
            init(_ log: Log) { sketchDrew = log }
            func supply() { suppliedAtDraw = sketchDrew.names.isEmpty }
        }
        let log = Log()
        let inlet = ObservingInlet(log)

        final class DrawLoggingSketch: Sketch {
            nonisolated(unsafe) static var log = Log()
            nonisolated(unsafe) static var declared: [any Plugin] = []
            var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
            var plugins: [any Plugin] { Self.declared }
            func draw() { Self.log.names.append("draw") }
        }
        struct InletPlugin: Plugin {
            let inlet: any Inlet
            func register(into registry: PluginRegistry) { registry.add(inlet: inlet) }
        }
        DrawLoggingSketch.log = log
        DrawLoggingSketch.declared = [InletPlugin(inlet: inlet)]

        let runtime = try SketchRuntime(sketch: DrawLoggingSketch(), gpu: try RenderDevice())
        try runtime.advance()

        // 供給した時点でまだ 1 度も描かれていない = 同じフレームの draw() から見える
        #expect(inlet.suppliedAtDraw == true)
        #expect(log.names == ["draw"])
    }

    // MARK: - 受け取る絵

    @Test("出口が受け取る絵は、道から取り出したものと同じ")
    func outletsSeeTheSamePixelsAsTheRoad() throws {
        let outlet = RecordingOutlet()
        let runtime = try makeRuntime([OutletOnlyPlugin(outlet: outlet)])

        try runtime.advance()
        let fromRoad = try runtime.target.encodeToImage().read()[0, 0]

        #expect(outlet.received.count == 1)
        #expect(outlet.received[0].first == fromRoad)
    }

    @Test("出口が 2 つあっても、道を通るのは 1 フレームに 1 回")
    func theRoadRunsOncePerFrame() throws {
        let runtime = try makeRuntime([
            OutletOnlyPlugin(outlet: RecordingOutlet(label: "a")),
            OutletOnlyPlugin(outlet: RecordingOutlet(label: "b")),
        ])

        for _ in 0..<8 { try runtime.advance() }

        // 置き場を作り直していない = フレームごとに確保していない (ADR-0023 決定 5)
        #expect(runtime.target.encodedImagesMade == 1)
    }

    @Test("出口が 1 つも無ければ、道を 1 回も通らない")
    func noOutletsMeansNoRoad() throws {
        let runtime = try makeRuntime([])

        for _ in 0..<8 { try runtime.advance() }

        // 使わない機能の費用を、使っていないスケッチが払わない
        #expect(runtime.target.encodedImagesMade == 0)
    }

    // MARK: - 転んだとき (ADR-0024 決定 7)

    @Test("開くのに失敗した束だけが外れ、他の束は動き続ける")
    func onlyTheBrokenPluginIsDetached() throws {
        let healthy = RecordingOutlet()
        let runtime = try makeRuntime([
            OutletOnlyPlugin(outlet: BrokenOutlet()),
            OutletOnlyPlugin(outlet: healthy),
        ])

        try runtime.advance()

        #expect(healthy.received.count == 1)
    }

    @Test("出口と入り口の両方を持つ束は、片方が開けなければ束ごと外れる")
    func aPluginIsDetachedAsAWhole() throws {
        let inlet = CountingInlet()
        let runtime = try makeRuntime([BothPlugin(outlet: BrokenOutlet(), inlet: inlet)])

        try runtime.advance()

        // 半分だけ生きた束は、書いた人の想定にない状態である
        #expect(inlet.supplied == 0)
    }

    @Test("出口が開いた後で入り口が転ぶと、開いた出口が閉じられる")
    func openedSeamsAreClosedWhenALaterSeamFails() throws {
        let log = Log()
        let runtime = try makeRuntime([
            BothPlugin(outlet: LifecycleOutlet("a", log), inlet: BrokenInlet())
        ])

        try runtime.advance()

        // 外すのを登録簿からだけにすると、先に開けた出口が掴んだ外の資源
        // (映像の口・音の装置) が誰にも閉じられないまま残る
        #expect(log.lifecycle == ["open:a", "close:a"])
    }

    @Test("開いた逆順に閉じる。開いていない差込口は閉じない")
    func openedSeamsAreClosedInReverseOrder() throws {
        let log = Log()
        let runtime = try makeRuntime([
            OutletsPlugin(outlets: [
                LifecycleOutlet("a", log),
                LifecycleOutlet("b", log),
                LifecycleOutlet("c", log, failsOnOpen: true),
            ])
        ])

        try runtime.advance()

        // c は開いていないので閉じない。b → a と戻すのは、後から開いたものが先に
        // 開いたものに依っていても順序が壊れないため
        #expect(log.lifecycle == ["open:a", "open:b", "fail:c", "close:b", "close:a"])
    }

    @Test("続けて転んだ出口は外れる。フレームは止まらない")
    func aRepeatedlyFailingOutletIsDetached() throws {
        let failing = RecordingOutlet(label: "failing")
        failing.failsFrom = 2
        let healthy = RecordingOutlet(label: "healthy")
        let runtime = try makeRuntime([
            OutletOnlyPlugin(outlet: failing),
            OutletOnlyPlugin(outlet: healthy),
        ])

        for _ in 0..<8 { try runtime.advance() }

        // 2 枚受け取ったあと limit 回転んで外れる。**外れたら呼ばれなくなる**ので、
        // 呼ばれた回数がそこで止まる (受け取れた枚数だけを見ると、外さない実装でも
        // 同じ数になってしまい、検査として成立しない)
        #expect(failing.received.count == 2)
        #expect(failing.calls == 2 + SeamHealth.limit)
        // 他の出口とフレームは動き続ける
        #expect(healthy.received.count == 8)
    }

    @Test("1 回転んだだけでは外れない")
    func oneFailureDoesNotDetach() throws {
        final class FlakyOutlet: Outlet {
            private(set) var received = 0
            private(set) var failure: String?
            func receive(_ frame: OutputFrame) {
                received += 1
                // 2 枚目だけ転ぶ。たまたまの失敗で機能が消えてはいけない
                failure = received == 2 ? "たまたま" : nil
            }
        }
        let flaky = FlakyOutlet()
        let runtime = try makeRuntime([OutletOnlyPlugin(outlet: flaky)])

        for _ in 0..<6 { try runtime.advance() }

        #expect(flaky.received == 6)
    }

    // MARK: - 閉じる

    @Test("閉じると、開いた差込口がすべて閉じられる")
    func closingReachesEverySeam() throws {
        let outlet = RecordingOutlet()
        let inlet = CountingInlet()
        let runtime = try makeRuntime([BothPlugin(outlet: outlet, inlet: inlet)])

        try runtime.advance()
        runtime.closePlugins()

        #expect(outlet.closed == 1)
        #expect(inlet.closed == 1)
        // 閉じた後はもう呼ばれない
        try runtime.advance()
        #expect(outlet.received.count == 1)
        #expect(inlet.supplied == 1)
    }
}
