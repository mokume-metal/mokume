// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Testing

@testable import MokumeCore

/// `noLoop()` で止めた絵を 1 回描いたきりの、あるいは何かを押すたびに変わるスケッチ。
private final class StoppedSketch: Sketch {
    enum Reaction { case none, set, lock, unlock, exposure }

    var reaction = Reaction.none
    private(set) var draws = 0

    var settings: SketchSettings { SketchSettings(width: 32, height: 32) }

    func setup() { noLoop() }

    func draw() {
        draws += 1
        background(Color.linear(red: 0, green: 0, blue: 0))
        noStroke()
        fill(Color.linear(red: 0, green: 1, blue: 0))
        rect(4, 4, 8, 8)
    }

    func mousePressed() { react() }

    func keyPressed() { react() }

    private func react() {
        switch reaction {
        case .none: break
        case .set: set(20, 20, Color.linear(red: 1, green: 0, blue: 0))
        case .lock: requestPointerLock()
        case .unlock: exitPointerLock()
        case .exposure: exposure(0.5)
        }
    }
}

/// 走っているスケッチ。何も描かない回がある (道具が読む枚数は止まらない)。
private final class RunningSketch: Sketch {
    var settings: SketchSettings { SketchSettings(width: 32, height: 32) }
    func draw() {}
}

/// 止まっている間は、絵が変わらない限り窓にも出口にも出し直さない ([#2367])。
///
/// 見るのは**投入の本数と、共有面が名乗る枚数**である。変わったときは必ず 1 回だけ出ること
/// (出し忘れると、止めた絵が窓にも道具にも出なくなる) を対で見る。
///
/// [#2367]: https://github.com/mokume-metal/mokume/issues/2367
@Suite(
    "止まっている間の差し出し",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct StoppedSketchOutletTests {
    private func makeFacet() throws -> URL {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-stopped-outlet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        return facet
    }

    /// 共有面へ差し出す子と、それを動かす道具立て。
    private struct Child {
        let application: SketchApplication
        let gpu: RenderDevice
        let facet: URL
        let pipe: Pipe

        /// 1 リフレッシュ。結末が届くまでの間合いを作る (本番のリフレッシュの間には届いている・#2735)。
        func refresh(_ times: Int = 1) {
            for _ in 0..<times {
                application.displayLinkFired()
                _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
            }
        }

        /// 道具の窓が拾った出来事を送る。
        func click() throws {
            try pipe.fileHandleForWriting.write(
                contentsOf: Data(InputEvent.mouseDown(x: 5, y: 5, button: .left).wireLine.utf8))
        }

        /// 共有面が名乗っている最新の枚数。まだ 1 枚も名乗っていなければ 0。
        var namedFrame: Int {
            guard let manifest = SharedFrameSurface.readManifest(at: facet) else { return 0 }
            return SharedFrameSurface.newest(among: manifest.ids)?.frame ?? 0
        }

        var pointerLockOnNewest: Bool? {
            guard let manifest = SharedFrameSurface.readManifest(at: facet),
                let newest = SharedFrameSurface.newest(among: manifest.ids)
            else { return nil }
            return SharedFrameSurface.pointerLockRequested(of: newest.id)
        }
    }

    private func withChild(
        _ sketch: any Sketch, _ body: (Child) throws -> Void
    ) throws {
        let facet = try makeFacet()
        defer { try? FileManager.default.removeItem(at: facet) }
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        let gpu = try RenderDevice()
        let application = try SketchApplication(sketch: sketch, gpu: gpu)
        application.onStopSignal = { Issue.record("検査は合図を送っていないのに、終わりを頼んだ") }
        application.toolInput = pipe.fileHandleForReading.fileDescriptor
        defer { application.willTerminate() }
        application.resolveOutlet(at: facet, owner: "mokume watch")
        try #require(!application.endsAfterLastWindowClosed, "共有面の経路になっていない")
        try body(
            Child(application: application, gpu: gpu, facet: facet, pipe: pipe))
    }

    /// 止まって落ち着くまで回す。**最後に描いた後の 1 回を焼き、次のリフレッシュで名乗らせる**までに
    /// 足りる回数。
    private func settle(_ child: Child) {
        child.refresh(8)
    }

    // MARK: - 飛ばす

    @Test("noLoop() で 1 枚描いたスケッチは、止まった後の投入も、共有面の枚数も増えない")
    func aStoppedSketchStopsSubmittingAndNaming() throws {
        let sketch = StoppedSketch()
        try withChild(sketch) { child in
            settle(child)
            try #require(sketch.draws == 1, "検査の前提: 1 枚だけ描いて止まっている")
            let named = child.namedFrame
            try #require(named >= 1, "最後に変わった後の控えを名乗っていない")
            let submissions = child.gpu.submissionCount

            child.refresh(60)

            #expect(
                child.gpu.submissionCount == submissions,
                "止まっているのに、60 リフレッシュで \(child.gpu.submissionCount - submissions) 本投入した")
            #expect(child.namedFrame == named, "止まっているのに、共有面の枚数が進んだ")
        }
    }

    /// 走っているスケッチは、描かない回も毎リフレッシュ出す。道具が読む速さ・時刻は枚数が上がった
    /// ときだけ更新されるので、止まっていないのに飛ばすと止まって見える。
    @Test("走っているスケッチは、何も描かない回も毎リフレッシュ出す")
    func aRunningSketchStillWritesEveryRefresh() throws {
        try withChild(RunningSketch()) { child in
            settle(child)
            let named = child.namedFrame
            try #require(named >= 1)

            child.refresh(20)

            #expect(child.namedFrame >= named + 15, "走っているのに枚数が進まない (\(named) → \(child.namedFrame))")
        }
    }

    // MARK: - 変わったら 1 回だけ出す

    @Test("止まっている間に画素を書くと、次のリフレッシュ以後に 1 回だけ出る")
    func aPixelWrittenWhileStoppedIsHandedOverOnce() throws {
        let sketch = StoppedSketch()
        sketch.reaction = .set
        try withChild(sketch) { child in
            settle(child)
            let named = child.namedFrame
            let submissions = child.gpu.submissionCount

            try child.click()
            child.refresh(8)

            #expect(child.namedFrame == named + 1, "書いた画素が出口に出ていない / 2 回出た (\(named) → \(child.namedFrame))")
            let afterWrite = child.gpu.submissionCount
            #expect(afterWrite > submissions, "投入が 1 本も無い")

            child.refresh(30)
            #expect(child.gpu.submissionCount == afterWrite, "書いた後も出し続けている")
            #expect(child.namedFrame == named + 1)
        }
    }

    /// 捕まえの要求は絵と一緒に面に載る (#1144)。止まっている間に変わっても、絵が変わらないので
    /// 番号だけでは出ない — 鍵に入っていなければ、止めたスケッチがカーソルを捕まえる・放すのが
    /// 道具に届かない。
    @Test("止まっている間に捕まえの要求が変わると、次のリフレッシュ以後に 1 回だけ面に載る")
    func aPointerLockChangedWhileStoppedReachesTheTool() throws {
        let sketch = StoppedSketch()
        try withChild(sketch) { child in
            settle(child)
            try #require(child.pointerLockOnNewest == false)
            let named = child.namedFrame

            sketch.reaction = .lock
            try child.click()
            child.refresh(8)
            #expect(child.pointerLockOnNewest == true, "頼んだ捕まえが面に載っていない")
            #expect(child.namedFrame == named + 1)

            sketch.reaction = .unlock
            try child.click()
            child.refresh(8)
            #expect(child.pointerLockOnNewest == false, "取り下げた捕まえが面に残っている")
            #expect(child.namedFrame == named + 2)
        }
    }

    /// 明るさの設定は出力段で絵を変える。止まっている間に変えても出し直す。
    @Test("止まっている間に明るさを変えると、次のリフレッシュ以後に 1 回だけ出る")
    func aBrightnessChangedWhileStoppedIsHandedOver() throws {
        let sketch = StoppedSketch()
        sketch.reaction = .exposure
        try withChild(sketch) { child in
            settle(child)
            let named = child.namedFrame

            try child.click()
            child.refresh(8)

            #expect(child.namedFrame == named + 1, "明るさの変更が出口に出ていない (\(named) → \(child.namedFrame))")
        }
    }

    /// 焼きを GPU が打ち切ると、名乗られないまま捨てられる。止まっている間は次の書き込みが来ないので、
    /// 焼き直さなければ道具は前の絵を出し続ける (走っている間は次の書き込みが自然に直す・#2735)。
    @Test("止まっている間に焼きを GPU が打ち切っても、次のリフレッシュ以後に焼き直して名乗る")
    func aDroppedBurnWhileStoppedIsBurntAgain() throws {
        let sketch = StoppedSketch()
        sketch.reaction = .exposure
        try withChild(sketch) { child in
            settle(child)
            let named = child.namedFrame

            // 明るさを変える回は、描き直さないので最初の投入が焼きである
            child.gpu.dropsNextSubmissionForTesting = "dropped for the test"
            try child.click()
            child.refresh(12)

            // 枚数は書き込みの通し番号なので、打ち切られた焼きの番号は飛ぶ
            #expect(child.namedFrame > named, "打ち切られた焼きが焼き直されていない (\(named) → \(child.namedFrame))")
            let recovered = child.namedFrame
            let submissions = child.gpu.submissionCount
            child.refresh(30)
            #expect(child.namedFrame == recovered, "焼き直した後も出し続けている")
            #expect(child.gpu.submissionCount == submissions)
        }
    }

    // MARK: - 窓の経路

    /// 窓を開いて回す。present は窓が見えているときだけ通る (見えていない間は出さない・#223) ので、
    /// 見えていることにして (``SketchApplication/windowVisibilityForTesting``)、最初の数回に present が
    /// 実際に出ていること (投入が増えること) を前提に確かめる。
    @Test("窓の経路でも、止まった後は present を出さず、変わったら 1 回だけ出す")
    func aStoppedWindowStopsPresenting() throws {
        let sketch = StoppedSketch()
        sketch.reaction = .exposure
        let gpu = try RenderDevice()
        let application = try SketchApplication(sketch: sketch, gpu: gpu)
        application.onStopSignal = { Issue.record("検査は合図を送っていないのに、終わりを頼んだ") }
        // 検査のプロセスは前面ではないので、窓は見えていることにならない
        application.windowVisibilityForTesting = true
        application.didFinishLaunching()
        defer { application.willTerminate() }
        let window = try #require(application.window)

        func refresh(_ times: Int) {
            for _ in 0..<times {
                application.displayLinkFired()
                _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
            }
        }
        let started = gpu.submissionCount
        refresh(8)
        try #require(gpu.submissionCount > started, "検査の前提: present が 1 本も出ていない")
        let submissions = gpu.submissionCount

        refresh(60)
        #expect(
            gpu.submissionCount == submissions,
            "止まっているのに、60 リフレッシュで \(gpu.submissionCount - submissions) 本投入した")

        // 明るさを変える (描き直さない)。出力段の設定は present の絵を変える
        let before = gpu.submissionCount
        window.sendEvent(
            try #require(KeyEventFixture.keyDown(in: window, characters: "a", keyCode: 0)))
        refresh(8)
        #expect(gpu.submissionCount == before + 1, "明るさの変更が 1 回だけ present されていない (\(gpu.submissionCount - before) 本)")
    }

    // MARK: - 番号

    /// 内容の変更番号は、GPU への書き込みでも CPU の画素の書き込みでも上がる。CPU の書き込みは、
    /// 面に着く前 (書き戻される前) から数える。**数えそびれると、書いてすぐの回は出ない。**
    @Test("画素への書き込みは、書き戻される前から内容の変更番号を上げる")
    func aPixelWriteBumpsTheRevisionBeforeItReachesTheSurface() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 8, height: 8)
        try target.fill(with: .linear(red: 0, green: 0, blue: 0))

        let afterFill = target.contentRevision
        _ = target.pixels  // 写しを作る
        #expect(target.contentRevision == afterFill, "読んだだけで番号が上がった")

        target.pixels[1, 1] = .linear(red: 1, green: 0, blue: 0)
        let afterSet = target.contentRevision
        #expect(afterSet > afterFill, "画素の書き込みで番号が上がらない")
        target.pixels[2, 2] = .linear(red: 1, green: 0, blue: 0)
        #expect(target.contentRevision > afterSet, "続けて書いても番号が上がらない")

        let beforeFill = target.contentRevision
        target.pixels.fill(.linear(red: 0, green: 0, blue: 1))
        #expect(target.contentRevision > beforeFill, "全面を埋めても番号が上がらない")

        let beforeGPU = target.contentRevision
        try target.fill(with: .linear(red: 0, green: 1, blue: 0))
        #expect(target.contentRevision > beforeGPU, "GPU への書き込みで番号が上がらない")
    }

    /// 別の面への投入では上がらない — 番号は、この面の絵が変わったことの印である。
    @Test("別の面への投入では、内容の変更番号は上がらない")
    func anotherSurfaceDoesNotBumpTheRevision() throws {
        let gpu = try RenderDevice()
        let a = try RenderTarget(gpu: gpu, width: 8, height: 8)
        let b = try RenderTarget(gpu: gpu, width: 8, height: 8)
        let revision = a.contentRevision
        try b.fill(with: .linear(red: 1, green: 0, blue: 0))
        _ = try b.readPixels()
        #expect(a.contentRevision == revision)
    }
}
