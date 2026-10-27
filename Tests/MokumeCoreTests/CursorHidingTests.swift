// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import IOSurface
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// `NSCursor.hide()` / `unhide()` の数を、プロセスで 1 つのものとして真似る。
///
/// ``CursorHiding`` (`noCursor()`) と ``PointerLock`` (`requestPointerLock()`) の口を**同じ数へ**
/// 繋ぐ — 食い違いは、2 つが 1 つの数を取り合うところで起きるからである。本番の口のままでは、
/// 検査を走らせている人のカーソルを隠す。
@MainActor
final class SharedCursorCount {
    private(set) var hides = 0
    private(set) var unhides = 0

    /// いまの隠しの数。**負にならない** — 隠していないものを見せると、次に隠したいときに足りなくなる。
    var hiddenCount: Int { hides - unhides }
    /// 矢印が見えているか。
    var isVisible: Bool { hiddenCount <= 0 }

    var cursorSystem: CursorHiding.System {
        CursorHiding.System(hide: { [self] in hides += 1 }, unhide: { [self] in unhides += 1 })
    }

    var lockSystem: PointerLock.System {
        PointerLock.System(
            capture: { [self] in
                hides += 1
                return true
            },
            release: { [self] in unhides += 1 })
    }
}

/// 矢印のカーソルを隠すかの判定 ([#2439](https://github.com/mokume-metal/mokume/issues/2439))。
///
/// **OS の口を記録するだけの口へ差し替えて回す。** 実際に矢印が消えるか・出るかは、窓で手で確かめる。
@Suite("矢印のカーソルを隠す")
@MainActor
struct CursorHidingTests {
    private let over = CursorHiding.Situation(isKeyWindow: true, pointerIsOverSurface: true)
    private let outside = CursorHiding.Situation(isKeyWindow: true, pointerIsOverSurface: false)
    private let behind = CursorHiding.Situation(isKeyWindow: false, pointerIsOverSurface: true)

    private func make(_ count: SharedCursorCount) -> CursorHiding {
        CursorHiding(system: count.cursorSystem)
    }

    // MARK: - 隠すとき (条件 1)

    @Test("要求が出ていなければ、窓が前でポインタが面の上にあっても隠さない")
    func noRequestNoHiding() {
        let count = SharedCursorCount()
        let hiding = make(count)
        hiding.update(requested: false, in: over)
        #expect(count.hides == 0)
        #expect(!hiding.isHiding)
    }

    @Test("要求があり、窓が前で、ポインタが面の上にあれば隠し、続けても 1 度しか頼まない")
    func hidesOnceOverTheSurface() {
        let count = SharedCursorCount()
        let hiding = make(count)
        for _ in 0..<5 { hiding.update(requested: true, in: over) }
        #expect(count.hides == 1)
        #expect(hiding.isHiding)
        #expect(!count.isVisible)
    }

    @Test("窓が前に無い・ポインタが面の外なら、要求があっても隠さない")
    func hidesOnlyOverTheSurfaceOfAFrontWindow() {
        let count = SharedCursorCount()
        let hiding = make(count)
        hiding.update(requested: true, in: outside)
        hiding.update(requested: true, in: behind)
        hiding.update(requested: true, in: .away)
        #expect(count.hides == 0)
        #expect(count.isVisible)
    }

    @Test("面の外へ出せば見え、戻せば隠れる (出入りのたびに、隠した数と見せた数は対)")
    func leavingAndReturning() {
        let count = SharedCursorCount()
        let hiding = make(count)
        hiding.update(requested: true, in: over)
        hiding.update(requested: true, in: outside)
        #expect(count.isVisible, "面の外 (窓の枠・別の窓・別の画面) へ出ても隠れたまま")
        hiding.update(requested: true, in: over)
        #expect(!count.isVisible)
        hiding.update(requested: true, in: behind)
        #expect(count.isVisible, "窓が退いても隠れたまま")
        #expect(count.hides == 2)
        #expect(count.unhides == 2)
    }

    @Test("cursor() で要求が取り下げられたら見え、要求し直せば隠れる")
    func withdrawingTheRequest() {
        let count = SharedCursorCount()
        let hiding = make(count)
        hiding.update(requested: true, in: over)
        hiding.update(requested: false, in: over)
        #expect(count.isVisible)
        #expect(!hiding.isRequested)
        hiding.update(requested: true, in: over)
        #expect(!count.isVisible)
    }

    // MARK: - 手放すとき

    @Test("窓が畳まれる・退く (stop) と見せる。要求は残るので、戻ったら隠し直す")
    func stopShowsAndKeepsTheRequest() {
        let count = SharedCursorCount()
        let hiding = make(count)
        hiding.update(requested: true, in: over)
        hiding.stop()
        #expect(count.isVisible)
        #expect(hiding.isRequested)
        hiding.update(requested: true, in: over)
        #expect(!count.isVisible)
    }

    @Test("隠していなければ、stop は OS の口を呼ばない (見せる数が隠した数を超えない)")
    func stopOnlyUndoesWhatWasHidden() {
        let count = SharedCursorCount()
        let hiding = make(count)
        hiding.stop()
        hiding.update(requested: true, in: over)
        hiding.stop()
        hiding.stop()
        #expect(count.hides == 1)
        #expect(count.unhides == 1)
    }

    @Test("手放されたら、隠していた矢印を見せる")
    func deinitShows() {
        let count = SharedCursorCount()
        var hiding: CursorHiding? = make(count)
        hiding?.update(requested: true, in: over)
        #expect(!count.isVisible)
        hiding = nil
        #expect(count.isVisible)
        #expect(count.unhides == 1)
    }

    @Test("道具の 2 つの窓は、前に出ている窓の上でだけ隠す")
    func onlyTheFrontWindowHides() {
        let count = SharedCursorCount()
        let work = make(count)
        let preview = make(count)
        // 作品の窓が前: ポインタは作品の面の上
        work.update(requested: true, in: over)
        preview.update(requested: true, in: CursorHiding.Situation(isKeyWindow: false, pointerIsOverSurface: false))
        #expect(count.hiddenCount == 1)
        // プレビューが前へ出た: 作品の窓が退き、プレビューの面の上へ動いた
        work.update(requested: true, in: behind)
        preview.update(requested: true, in: over)
        #expect(count.hiddenCount == 1)
        // どちらも要求しなければ見える
        work.update(requested: false, in: .away)
        preview.update(requested: false, in: over)
        #expect(count.isVisible)
    }

    // MARK: - カーソルを捕まえる口と食い違わない (条件 2)

    /// `noCursor()` の後に捕まえて放す: 放した後も面の上で隠れたまま。
    @Test("noCursor() の後に requestPointerLock() → exitPointerLock() としても、放した後の矢印は隠れたまま")
    func hidingSurvivesALockAndItsRelease() {
        let count = SharedCursorCount()
        let hiding = make(count)
        let lock = PointerLock(system: count.lockSystem, arbiter: .init())
        let ready = PointerLock.Situation(isKeyWindow: true, pointerIsInside: true)

        hiding.update(requested: true, in: over)
        #expect(!count.isVisible)

        lock.notePress(in: ready)
        lock.update(requested: true, in: ready)
        #expect(lock.isLocked)
        #expect(count.hiddenCount == 2, "捕まえの隠しが重なる")

        // exitPointerLock()
        lock.update(requested: false, in: ready)
        #expect(!lock.isLocked)
        #expect(!count.isVisible, "放した後に、noCursor() の隠しが外れてしまった")
        #expect(count.hiddenCount == 1)

        // 面の外へ出すと見え、cursor() でも戻る
        hiding.update(requested: true, in: outside)
        #expect(count.isVisible)
    }

    /// 捕まえている間の cursor(): こちらの隠しだけが外れ、捕まえの隠しは残る。
    @Test("捕まえている間に cursor() を呼んでも、捕まえている間の隠しは外れない")
    func cursorWhileLockedKeepsTheLockHiding() {
        let count = SharedCursorCount()
        let hiding = make(count)
        let lock = PointerLock(system: count.lockSystem, arbiter: .init())
        let ready = PointerLock.Situation(isKeyWindow: true, pointerIsInside: true)

        hiding.update(requested: true, in: over)
        lock.notePress(in: ready)
        lock.update(requested: true, in: ready)
        #expect(count.hiddenCount == 2)

        // cursor()
        hiding.update(requested: false, in: over)
        #expect(lock.isLocked)
        #expect(!count.isVisible, "捕まえている間の隠しが外れた")
        #expect(count.hiddenCount == 1)

        // 放せば、どちらの隠しも残らない
        lock.update(requested: false, in: ready)
        #expect(count.isVisible)
        #expect(count.hiddenCount == 0)
    }

    /// 先に捕まえて、後から noCursor() → 先に cursor() で外し、捕まえを放す、の順でも数は合う。
    @Test("捕まえた後に noCursor() を呼び、捕まえを放しても、数は合い、隠れたまま残る")
    func lockThenHidingThenRelease() {
        let count = SharedCursorCount()
        let hiding = make(count)
        let lock = PointerLock(system: count.lockSystem, arbiter: .init())
        let ready = PointerLock.Situation(isKeyWindow: true, pointerIsInside: true)

        lock.notePress(in: ready)
        lock.update(requested: true, in: ready)
        hiding.update(requested: true, in: over)
        #expect(count.hiddenCount == 2)

        lock.update(requested: false, in: ready)
        #expect(count.hiddenCount == 1)
        #expect(!count.isVisible)

        hiding.stop()
        #expect(count.hiddenCount == 0)
        #expect(count.unhides <= count.hides)
    }
}

/// 矢印を隠す要求を、子から道具へ運ぶ面の属性 ([#2439](https://github.com/mokume-metal/mokume/issues/2439))。
///
/// GPU は使わない — 属性は面 (`IOSurface`) に載るもので、絵を焼く経路とは別である。
@Suite("矢印を隠す要求を面に載せる")
@MainActor
struct CursorHiddenAttributeTests {
    private func makeSurface() throws -> IOSurfaceRef {
        try #require(IOSurfaceCreate(SharedFrameSurface.properties(width: 4, height: 4)))
    }

    @Test("載せた要求を、番号から引いた面で読める")
    func readsWhatWasPublished() throws {
        let surface = try makeSurface()
        SharedFrameSurface.publishCursorHidden(true, to: surface)
        #expect(SharedFrameSurface.cursorHiddenRequested(of: IOSurfaceGetID(surface)))
    }

    /// 面は使い回されるので、消さなければ前に載せた要求が残る。
    @Test("頼んでいない枚では属性ごと消し、前の要求を残さない")
    func clearsAStaleRequest() throws {
        let surface = try makeSurface()
        SharedFrameSurface.publishCursorHidden(true, to: surface)
        SharedFrameSurface.publishCursorHidden(false, to: surface)
        #expect(!SharedFrameSurface.cursorHiddenRequested(on: surface))
        #expect(IOSurfaceCopyValue(surface, SharedFrameSurface.cursorHiddenAttribute as CFString) == nil)
    }

    /// 古いライブラリの子は属性を載せない。**載っていないのは頼んでいないこと**として読む。
    @Test("載っていない面と引けない番号は、頼んでいないと読む")
    func absentMeansNotRequested() throws {
        let surface = try makeSurface()
        #expect(!SharedFrameSurface.cursorHiddenRequested(on: surface))
        #expect(!SharedFrameSurface.cursorHiddenRequested(of: UInt32.max))
    }

    /// 捕まえの要求と矢印の要求は別々の属性で、互いに載せ消しの影響を受けない。
    @Test("捕まえの要求と別の属性で、片方を載せ消ししても、もう片方は動かない")
    func independentOfThePointerLockAttribute() throws {
        let surface = try makeSurface()
        SharedFrameSurface.publishPointerLock(true, to: surface)
        SharedFrameSurface.publishCursorHidden(false, to: surface)
        #expect(SharedFrameSurface.pointerLockRequested(on: surface))
        #expect(!SharedFrameSurface.cursorHiddenRequested(on: surface))
        SharedFrameSurface.publishCursorHidden(true, to: surface)
        SharedFrameSurface.publishPointerLock(false, to: surface)
        #expect(SharedFrameSurface.cursorHiddenRequested(on: surface))
        #expect(!SharedFrameSurface.pointerLockRequested(on: surface))
    }
}

/// 矢印を隠すスケッチ。`setup()` で隠し、``shows`` を立てると `draw()` で戻す。
final class CursorHider: Sketch {
    var shows = false
    init() {}
    var settings: SketchSettings { SketchSettings(width: 16, height: 16) }

    func setup() { noCursor() }

    func draw() {
        background(0)
        if shows { cursor() }
    }
}

/// 走っていないスケッチから呼んでも止まらない。GPU は使わない
/// ([#2265](https://github.com/mokume-metal/mokume/issues/2265) の決定に従う)。
@Suite("走っていないときの矢印の要求")
@MainActor
struct CursorHidingOutsideRunTests {
    @Test("走っていないときに隠しても戻しても、止まらず、口ごとに 1 度だけ警告する")
    func warnsOnceAndDoesNothing() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            #expect(runningSketch == nil)
            let sketch = CursorHider()
            sketch.noCursor()
            sketch.noCursor()
            sketch.cursor()
            sketch.cursor()
            #expect(log.messages.count == 2)
            #expect(log.message(for: "noCursor()") != nil)
            #expect(log.message(for: "cursor()") != nil)
        }
    }
}

/// 矢印を隠す要求が、窓の無い実行と見張りの子の出口でどう扱われるか。GPU を要する。
@Suite(
    "矢印を隠すスケッチを走らせる",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct CursorHidingSketchTests {
    private func makeFacet() throws -> URL {
        let facet = try TestScratch.directory("mokume-cursor-hiding")
        return facet
    }

    /// 書き出し (`mokume render`・参照スケッチの `--render`) と同じく、窓を持たない実行。
    /// 要求は覚えるが、読む窓が無いので何も起きない — 止まらず、描き続ける (条件 4)。
    @Test("窓の無い実行で隠しても、止まらずに描き、要求は cursor() まで残る")
    func aWindowlessRunKeepsDrawing() throws {
        let sketch = CursorHider()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil)
        #expect(!runtime.cursorHidingRequested)

        for _ in 0..<3 { try runtime.advance() }
        #expect(runtime.cursorHidingRequested)

        sketch.shows = true
        try runtime.advance()
        #expect(!runtime.cursorHidingRequested)
    }

    /// 保存で作り直したスケッチが `noCursor()` を呼ばなければ戻る (条件 3)。作り直しは新しい実行で、
    /// 要求は実行ごとに持つので、前の世代の要求は持ち越さない。
    @Test("作り直した実行は、noCursor() を呼ばなければ隠さない")
    func aRebuiltRunStartsVisible() throws {
        let first = try SketchRuntime(
            sketch: CursorHider(), gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil)
        try first.advance()
        #expect(first.cursorHidingRequested)

        let silent = PointerLockLooker()  // noCursor() を呼ばない
        let second = try SketchRuntime(
            sketch: silent, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil)
        try second.advance()
        #expect(!second.cursorHidingRequested)
    }

    /// 見張りの子は窓を持たない ([ADR-0032] 決定 1)。隠すのは道具の窓なので、要求は共有面の属性で渡る。
    /// 名乗るのは 1 枚遅れる (#748)。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    @Test("見張りの子は、矢印を隠す要求を共有面に載せ、cursor() で戻したら載せなくなる")
    func theChildPublishesTheRequest() throws {
        let facet = try makeFacet()
        defer { try? FileManager.default.removeItem(at: facet) }
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        let sketch = CursorHider()
        let gpu = try RenderDevice()
        let application = try SketchApplication(sketch: sketch, gpu: gpu)
        application.onStopSignal = { Issue.record("検査は合図を送っていないのに、終わりを頼んだ") }
        application.toolInput = pipe.fileHandleForReading.fileDescriptor
        defer { application.willTerminate() }

        application.resolveOutlet(at: facet, owner: "mokume watch")
        #expect(!application.endsAfterLastWindowClosed, "共有面の経路になっていない")

        // 子は焼きの結末を見てから名乗る (#2735) ので、結末が届くのを待つ (PointerLockSketchTests と同じ)
        func refresh() {
            application.displayLinkFired()
            _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
        }
        for _ in 0..<3 { refresh() }
        let manifest = try #require(SharedFrameSurface.readManifest(at: facet))
        let hidden = try #require(SharedFrameSurface.newest(among: manifest.ids))
        #expect(SharedFrameSurface.cursorHiddenRequested(of: hidden.id))
        #expect(!SharedFrameSurface.pointerLockRequested(of: hidden.id), "捕まえの要求まで載せた")

        sketch.shows = true
        for _ in 0..<3 { refresh() }
        let shown = try #require(SharedFrameSurface.newest(among: manifest.ids))
        #expect(shown.frame > hidden.frame)
        #expect(!SharedFrameSurface.cursorHiddenRequested(of: shown.id))
    }
}
