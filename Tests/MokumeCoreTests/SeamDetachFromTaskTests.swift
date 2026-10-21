// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 走っている実行の中で起こした `Task` から、入り口・出口を外す ([#2840])。
///
/// 止める口 (`AudioIn.stop()` など) と公開の `detach(_:)` は、外す先の実行を ``runningSketch`` で引いていたので、
/// `Task` の続き (フレームの間に走る) からは断って、機材が動き続けた。足した実行を差込口ごとに弱く控え
/// (``SeamHomes``)、走っている間は外から外せる。後片付けの後と、どの実行にも足されていないものは、今までどおり
/// 名乗るだけ。GPU を要する (``AttachProbe`` などは `SeamAttachTests` と共有)。
///
/// [#2840]: https://github.com/mokume-metal/mokume/issues/2840
@Suite(
    "走っている実行の中の Task から外す",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SeamDetachFromTaskTests {
    /// 起こした `Task` を検査へ渡す置き場。`Task` は `draw()` の中で起こす。
    @MainActor
    final class Launched {
        var task: Task<Void, Never>?
    }

    @MainActor
    private func makeRuntime(
        draw: @escaping (AttachingSketch) -> Void = { _ in },
        declared: [any Plugin] = [],
        setup: @escaping (AttachingSketch) -> Void = { _ in }
    ) throws -> SketchRuntime {
        AttachingSketch.onSetup = setup
        AttachingSketch.onDraw = draw
        AttachingSketch.declared = declared
        return try SketchRuntime(sketch: AttachingSketch(), gpu: try RenderDevice())
    }

    /// 完了条件 1・2・6。`keyPressed()` で起こした `Task` から外す形で、**警告が出ない**。変更前は
    /// `detach() is only accepted from inside …` が出て、入り口は閉じず供給され続けた。
    @MainActor
    @Test("Task の続きから公開の detach(_:) で入り口を外すと、1 度だけ閉じ、以後は供給せず、警告は出ない")
    func detachingAnInletFromATask() async throws {
        let probe = AttachProbe()
        let log = OutsideRun()
        let launched = Launched()
        let runtime = try makeRuntime(
            draw: { sketch in
                guard sketch.frameCount == 2 else { return }
                launched.task = Task { @MainActor in
                    OutsideRun.$current.withValue(log) { sketch.detach(probe) }
                }
            },
            setup: { $0.attach(probe) })
        for _ in 0..<2 { try runtime.advance() }
        await launched.task?.value
        #expect(probe.closed == 1)
        let suppliedWhenClosed = probe.supplied
        for _ in 0..<3 { try runtime.advance() }
        #expect(probe.supplied == suppliedWhenClosed, "外した後は供給しない")
        runtime.closePlugins()
        #expect(probe.closed == 1, "後片付けで 2 度閉じない")
        #expect(log.messages.isEmpty, "警告は出ない: \(log.messages)")
    }

    @MainActor
    @Test("Task の続きから公開の detach(_:) で出口を外すと、描き終えた絵を受け取ってから 1 度だけ閉じる")
    func detachingAnOutletFromATask() async throws {
        let tape = ClosingFrameOutlet()
        let log = OutsideRun()
        let launched = Launched()
        let runtime = try makeRuntime(
            draw: { sketch in
                guard sketch.frameCount == 5 else { return }
                launched.task = Task { @MainActor in
                    OutsideRun.$current.withValue(log) { sketch.detach(tape) }
                }
            },
            setup: { $0.attach(tape) })
        for _ in 0..<5 { try runtime.advance() }
        await launched.task?.value
        #expect(tape.closed == 1)
        #expect(tape.frames == Array(1...tape.frames.count), "欠けも二重も無い: \(tape.frames)")
        let received = tape.frames.count
        for _ in 0..<3 { try runtime.advance() }
        runtime.closePlugins()
        #expect(tape.frames.count == received, "外した後は受け取らない")
        #expect(tape.closed == 1)
        #expect(log.messages.isEmpty, "\(log.messages)")
    }

    /// 止める口 (`AudioIn.stop()` など) が呼ぶ口。`Task.detached` は起こした側のタスクローカルを受け継がないが、
    /// 実行は差込口が控えているので、走っている間は効く。
    @MainActor
    @Test("止める口が呼ぶ型を付けた detach も、Task.detached からも、走っている間は効く")
    func theTypedDetachWorksFromADetachedTask() async throws {
        let probe = AttachProbe()
        let log = OutsideRun()
        let runtime = try makeRuntime(setup: { $0.attach(probe) })
        let sketch = AttachingSketch()
        try runtime.advance()
        await Task.detached {
            await MainActor.run {
                OutsideRun.$current.withValue(log) { sketch.detach(probe, calledAs: "Probe.stop()") }
            }
        }.value
        #expect(probe.closed == 1)
        #expect(log.messages.isEmpty, "\(log.messages)")
        runtime.closePlugins()
        #expect(probe.closed == 1)
    }

    /// 完了条件 3。後片付けの後は、相手が既に閉じている。型を付けた名前で 1 度だけ名乗り、何もしない。
    @MainActor
    @Test("後片付けの後に呼ぶと、型を付けた名前で 1 度だけ名乗り、何もしない")
    func afterTeardownItOnlyNamesItself() throws {
        let probe = AttachProbe()
        let runtime = try makeRuntime(setup: { $0.attach(probe) })
        try runtime.advance()
        runtime.closePlugins()
        #expect(probe.closed == 1)
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let sketch = AttachingSketch()
            sketch.detach(probe, calledAs: "Probe.stop()")
            sketch.detach(probe, calledAs: "Probe.stop()")
        }
        #expect(log.messages.count == 1, "2 度呼んでも 1 行: \(log.messages)")
        #expect(log.message(for: "Probe.stop()") != nil)
        #expect(probe.closed == 1)
    }

    /// 完了条件 4。どの実行にも足されていないものは、走っている実行が在っても外す先が無い。
    @MainActor
    @Test("どの実行にも足されていない入り口は、走っている実行が在っても名乗るだけ")
    func neverAttachedOnlyNamesItself() throws {
        let attached = AttachProbe()
        let stray = AttachProbe()
        let runtime = try makeRuntime(setup: { $0.attach(attached) })
        try runtime.advance()
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            AttachingSketch().detach(stray, calledAs: "Probe.stop()")
        }
        #expect(log.message(for: "Probe.stop()") != nil)
        #expect(attached.closed == 0, "別の入り口は閉じない")
        runtime.closePlugins()
    }
}
