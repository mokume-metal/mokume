// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

// **アンブレラだけを import する** ([PluginRegistrySurfaceTests](PluginRegistrySurfaceTests.swift)
// と同じ作法)。`@testable` を使わないので、ここに書けたものは**外のパッケージでもそのまま
// 書ける** — 実行中に差込口を足す口が公開の面にあることの担保である (#1988)。
import mokume

// MARK: - 検査用の差込口とスケッチ

/// 開いた・呼ばれた・閉じた回数を数える入り口。
final class AttachProbe: Inlet {
    struct Refused: Error {}

    private(set) var opened = 0
    private(set) var supplied = 0
    private(set) var closed = 0
    /// `supply()` のたびに呼ぶ。巡回の最中に頼む形を作るため。
    var onSupply: (() -> Void)?
    /// 開くのを断るか。
    var refusesToOpen = false

    func open() throws {
        opened += 1
        if refusesToOpen { throw Refused() }
    }

    func supply() {
        supplied += 1
        onSupply?()
    }

    func close() { closed += 1 }
}

/// 受け取ったフレームの番号を覚える出口。
final class FrameNumberOutlet: Outlet {
    private(set) var frames: [Int] = []
    func receive(_ frame: OutputFrame) { frames.append(frame.frame) }
}

/// 出口を 1 つ宣言で足す束。
struct DeclaredOutlet: Plugin {
    let outlet: FrameNumberOutlet
    func register(into registry: PluginRegistry) { registry.add(outlet: outlet) }
}

/// `setup()` と `draw()` で、検査が渡した手続きを走らせるスケッチ。
///
/// `Sketch` は引数なしで作る必要があるので、手続きは静的な置き場から持ち込む
/// (`PluginSeamTests.SeamSketch` と同じ形)。
final class AttachingSketch: Sketch {
    nonisolated(unsafe) static var onSetup: (AttachingSketch) -> Void = { _ in }
    nonisolated(unsafe) static var onDraw: (AttachingSketch) -> Void = { _ in }
    nonisolated(unsafe) static var declared: [any Plugin] = []

    init() {}
    var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
    var plugins: [any Plugin] { Self.declared }
    func setup() { Self.onSetup(self) }
    func draw() {
        background(0, 0, 0)
        Self.onDraw(self)
    }
}

// MARK: - 走っているスケッチへ足す・外す

/// 実行中に差込口を足し・外す口 (#1988・ADR-0042 決定 2)。GPU を要する。
@Suite(
    "実行中に差込口を足す・外す",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SeamAttachTests {
    private func makeRuntime(
        setup: @escaping (AttachingSketch) -> Void = { _ in },
        draw: @escaping (AttachingSketch) -> Void = { _ in },
        declared: [any Plugin] = []
    ) throws -> SketchRuntime {
        AttachingSketch.onSetup = setup
        AttachingSketch.onDraw = draw
        AttachingSketch.declared = declared
        return try SketchRuntime(sketch: AttachingSketch(), gpu: try RenderDevice())
    }

    @Test("setup() で足すと、最初のフレームから毎フレーム 1 回ずつ供給する")
    func attachedInSetupSuppliesFromTheFirstFrame() throws {
        let probe = AttachProbe()
        let runtime = try makeRuntime(setup: { $0.attach(probe) })
        for _ in 0..<3 { try runtime.advance() }
        #expect(probe.opened == 1)
        #expect(probe.supplied == 3)
        runtime.closePlugins()
        #expect(probe.closed == 1)
    }

    @Test("draw() で足すと、次のフレームから供給する")
    func attachedInDrawSuppliesFromTheNextFrame() throws {
        let probe = AttachProbe()
        let runtime = try makeRuntime(draw: { sketch in
            if sketch.frameCount == 1 { sketch.attach(probe) }
        })
        for _ in 0..<3 { try runtime.advance() }
        // フレーム 1 の supply() は draw() より前に済んでいる。2 と 3 で呼ばれる
        #expect(probe.supplied == 2)
        runtime.closePlugins()
    }

    @Test("同じものを 2 度足しても、開くのも供給するのも 1 回ずつ")
    func attachingTwiceKeepsOne() throws {
        let probe = AttachProbe()
        let runtime = try makeRuntime(setup: { sketch in
            #expect(sketch.attach(probe))
            #expect(sketch.attach(probe))
        })
        try runtime.advance()
        #expect(probe.opened == 1)
        #expect(probe.supplied == 1)
        runtime.closePlugins()
    }

    @Test("外すと 1 度だけ閉じ、以後は供給しない")
    func detachingClosesOnceAndStopsSupplying() throws {
        let probe = AttachProbe()
        let runtime = try makeRuntime(
            setup: { $0.attach(probe) },
            draw: { sketch in
                if sketch.frameCount == 2 { sketch.detach(probe) }
            })
        for _ in 0..<4 { try runtime.advance() }
        #expect(probe.supplied == 2)
        #expect(probe.closed == 1)
        // スケッチの終わりでもう一度閉じない (`close()` は一度だけ)
        runtime.closePlugins()
        #expect(probe.closed == 1)
    }

    /// 巡回は並びを `inout` で渡しているので、`supply()` の中から同じ並びへ足すと、
    /// 巡回の終わりの書き戻しで消える (保留を外すと、客の供給が 3 回から 2 回に減った)。
    /// 頼みは巡回の後へ回る。
    @Test("supply() の中で別の入り口を足し、自分を外しても取りこぼさない")
    func attachingAndDetachingDuringSupplyIsDeferred() throws {
        let host = AttachProbe()
        let guest = AttachProbe()
        var sketch: AttachingSketch?
        let runtime = try makeRuntime(setup: { running in
            sketch = running
            running.attach(host)
        })
        host.onSupply = {
            switch host.supplied {
            case 1: #expect(sketch?.attach(guest) == true)
            case 2: sketch?.detach(host)
            default: break
            }
        }
        for _ in 0..<4 { try runtime.advance() }
        // 客はフレーム 1 の巡回の後に入り、2・3・4 で呼ばれる
        #expect(guest.opened == 1)
        #expect(guest.supplied == 3)
        // 主はフレーム 2 の巡回の後に外れる
        #expect(host.supplied == 2)
        #expect(host.closed == 1)
        runtime.closePlugins()
        #expect(guest.closed == 1)
    }

    @Test("開くのを断られたら false を返し、並びに入れない")
    func refusingToOpenIsNotAttached() throws {
        let probe = AttachProbe()
        probe.refusesToOpen = true
        var accepted: Bool?
        let runtime = try makeRuntime(setup: { accepted = $0.attach(probe) })
        for _ in 0..<2 { try runtime.advance() }
        #expect(accepted == false)
        #expect(probe.supplied == 0)
        runtime.closePlugins()
        // 開けなかったものは閉じない (開いていない)
        #expect(probe.closed == 0)
    }

    @Test("閉じた後に足そうとしても開かずに断る")
    func attachingAfterCloseIsRefused() throws {
        let probe = AttachProbe()
        let runtime = try makeRuntime()
        try runtime.advance()
        runtime.closePlugins()
        #expect(runtime.attach(probe) == false)
        #expect(probe.opened == 0)
    }

    /// 配るのは 1 枚遅れなので、そのままだと `draw()` の中で足した出口は、足す前に描いた
    /// 絵を同じフレームのうちに受け取る。
    @Test("draw() の中で足した出口は、足したフレームより前の絵を受け取らない")
    func outletAttachedInDrawStartsFromItsOwnFrame() throws {
        let early = FrameNumberOutlet()
        let late = FrameNumberOutlet()
        let runtime = try makeRuntime(
            draw: { sketch in
                if sketch.frameCount == 3 { sketch.attach(late) }
            },
            declared: [DeclaredOutlet(outlet: early)])
        for _ in 0..<5 { try runtime.advance() }
        // 宣言したほうは 1 から受け取っている — 控えはフレーム 3 の時点で在った
        #expect(early.frames == [1, 2, 3, 4])
        #expect(late.frames == [3, 4])
        runtime.closePlugins()
    }
}

// MARK: - スケッチの外から

/// 走っていないスケッチに頼んでも、開かずに断る。GPU は要らない。
@Suite("実行中に差込口を足す・外す (スケッチの外から)")
struct SeamAttachOutsideTests {
    @Test("走っていないときは開かずに false")
    func refusesOutsideTheSketch() {
        let probe = AttachProbe()
        #expect(AttachingSketch().attach(probe) == false)
        #expect(probe.opened == 0)
        // 外すほうも何もしない
        AttachingSketch().detach(probe)
        #expect(probe.closed == 0)
    }
}

// MARK: - 外から届くものの入れ物

/// ``ExternalInput`` の入れ物としての約束 (ADR-0028 決定 2 の「最新の 1 つ」)。GPU は要らない。
@Suite("外から届く値の入れ物")
struct ExternalInputTests {
    @Test("新しく入ったものだけを 1 度返す")
    func takesOnlyWhatIsNew() {
        let input = ExternalInput<Int>(name: "probe", state: .running)
        #expect(input.take() == nil)
        input.send(1, hostTime: 10)
        #expect(input.take() == 1)
        #expect(input.take() == nil)
        #expect(input.lastArrival?.hostTime == 10)
    }

    @Test("取り出す前に届いた古いものは、新しいものに上書きされる")
    func keepsOnlyTheLatest() {
        let input = ExternalInput<Int>(name: "probe", state: .running)
        input.send(1, hostTime: 10)
        input.send(2, hostTime: 20)
        #expect(input.take() == 2)
        #expect(input.lastArrival?.hostTime == 20)
        #expect(input.take() == nil)
    }

    @Test("状態と最後に届いたものが名乗りに載る")
    func reportCarriesStateAndArrival() {
        let input = ExternalInput<Int>(name: "probe", state: .waitingForPermission)
        #expect(input.report == SourceReport(name: "probe", state: .waitingForPermission, lastArrival: nil))
        input.setState(.running)
        input.send(7, hostTime: 30)
        _ = input.take()
        #expect(input.report.state == .running)
        #expect(input.report.lastArrival?.hostTime == 30)
    }

    @Test("別のスレッドから同時に入れても壊れず、最後の 1 つが残る")
    func survivesConcurrentSenders() async {
        let input = ExternalInput<Int>(name: "probe", state: .running)
        await withTaskGroup(of: Void.self) { group in
            for sender in 0..<8 {
                group.addTask {
                    for index in 0..<1000 { input.send(sender * 1000 + index, hostTime: UInt64(index)) }
                }
            }
        }
        let taken = input.take()
        #expect(taken != nil)
        #expect(taken.map { $0 % 1000 == 999 } == true)
        #expect(input.take() == nil)
    }
}
