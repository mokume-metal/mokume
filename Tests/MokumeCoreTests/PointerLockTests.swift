// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import IOSurface
import Testing

@testable import MokumeCore

/// カーソルを捕まえるかの判定 ([#1144](https://github.com/mokume-metal/mokume/issues/1144))。
///
/// **OS の口を記録するだけの口へ差し替えて回す。** 本番の口 (`NSCursor.hide()` と
/// `CGAssociateMouseAndMouseCursorPosition`) を呼ぶと、検査を走らせている人のカーソルを奪う。
/// 実際に捕まって手の動きが届くかは、窓で手で確かめる (#1144 の手順)。
@Suite("カーソルを捕まえる")
@MainActor
struct PointerLockTests {
    /// OS の口の代わり。呼ばれた順を控える。
    final class FakeSystem {
        enum Call: Equatable { case capture, release }
        var calls: [Call] = []
        /// 捕まえを断らせる。
        var refuses = false

        var system: PointerLock.System {
            PointerLock.System(
                capture: { [self] in
                    guard !refuses else { return false }
                    calls.append(.capture)
                    return true
                },
                release: { [self] in calls.append(.release) })
        }
    }

    /// 前に出ていて、ポインタが面の上にある窓。
    private let ready = PointerLock.Situation(isKeyWindow: true, pointerIsInside: true)

    private func make(_ fake: FakeSystem, arbiter: PointerLock.Arbiter = .init()) -> PointerLock {
        PointerLock(system: fake.system, arbiter: arbiter)
    }

    // MARK: - 掛かるとき (条件 8)

    @Test("要求が出ていても、面が押されるまでは捕まえない")
    func requestAloneDoesNotCapture() {
        let fake = FakeSystem()
        let lock = make(fake)
        for _ in 0..<3 { lock.update(requested: true, in: ready) }
        #expect(!lock.isLocked)
        #expect(fake.calls.isEmpty)

        lock.notePress(in: ready)
        #expect(lock.isLocked)
        #expect(fake.calls == [.capture])
    }

    /// 手本の書き方 (`mouseClicked()` の中で要求する)。押しが先に来て、要求は次のリフレッシュで
    /// 届く — その 1 回の押しで捕まる。
    @Test("押した後に要求が届けば、その押しで捕まる")
    func pressThenRequestCaptures() {
        let fake = FakeSystem()
        let lock = make(fake)
        lock.update(requested: false, in: ready)
        lock.notePress(in: ready)
        #expect(!lock.isLocked, "要求が無いのに捕まえた")

        lock.update(requested: true, in: ready)
        #expect(lock.isLocked)
        #expect(fake.calls == [.capture])
    }

    @Test("窓が前に無い・ポインタが面の外なら、要求と押しが揃っても捕まえない")
    func capturesOnlyInAReadyWindow() {
        let unready = [
            PointerLock.Situation(isKeyWindow: false, pointerIsInside: true),
            PointerLock.Situation(isKeyWindow: true, pointerIsInside: false),
            PointerLock.Situation(isKeyWindow: false, pointerIsInside: false),
        ]
        for situation in unready {
            let fake = FakeSystem()
            let lock = make(fake)
            lock.update(requested: true, in: situation)
            lock.notePress(in: situation)
            lock.update(requested: true, in: situation)
            #expect(!lock.isLocked, "\(situation) で捕まえた")
            #expect(fake.calls.isEmpty)

            // 窓が前に出て、ポインタが面の上に来れば、押し直さずに捕まえる
            lock.update(requested: true, in: ready)
            #expect(lock.isLocked, "\(situation) の後、揃っても捕まえない")
        }
    }

    @Test("要求し続けても、捕まえは 1 度しか頼まない")
    func capturesOnce() {
        let fake = FakeSystem()
        let lock = make(fake)
        lock.notePress(in: ready)
        for _ in 0..<5 { lock.update(requested: true, in: ready) }
        lock.notePress(in: ready)
        #expect(fake.calls == [.capture])
    }

    // MARK: - 外れるとき (条件 10・11)

    /// **Escape の後は、毎フレーム要求し続けるスケッチでも押すまで掛け直さない。** 掛け直すと、
    /// `draw()` から要求するスケッチで Escape が効かなくなる。
    @Test("利用者が外した後は、要求し続けても押すまで掛け直さず、押せば掛け直す")
    func userReleaseWaitsForAPress() {
        let fake = FakeSystem()
        let lock = make(fake)
        lock.update(requested: true, in: ready)
        lock.notePress(in: ready)
        #expect(lock.isLocked)

        lock.releaseByUser()
        #expect(!lock.isLocked)
        for _ in 0..<5 { lock.update(requested: true, in: ready) }
        #expect(!lock.isLocked, "押していないのに掛け直した")

        lock.notePress(in: ready)
        #expect(lock.isLocked)
        #expect(fake.calls == [.capture, .release, .capture])
    }

    /// 窓が退いた知らせ (``SketchSurface`` の `didResignKey`) を取りこぼしても、次のリフレッシュで
    /// 外す。外れ方は利用者が外したときと同じで、戻っても押すまで掛け直さない。
    @Test("窓が前から退いたら外れ、前に戻っても押すまで掛け直さない")
    func losingKeyReleasesUntilAPress() {
        let fake = FakeSystem()
        let lock = make(fake)
        lock.update(requested: true, in: ready)
        lock.notePress(in: ready)

        lock.update(requested: true, in: .init(isKeyWindow: false, pointerIsInside: true))
        #expect(!lock.isLocked)
        lock.update(requested: true, in: ready)
        #expect(!lock.isLocked, "前に戻っただけで掛け直した")

        lock.notePress(in: ready)
        #expect(lock.isLocked)
    }

    @Test("要求が取り下げられたら外れ、要求し直しても押すまで掛けない")
    func exitReleasesUntilARequestAndAPress() {
        let fake = FakeSystem()
        let lock = make(fake)
        lock.update(requested: true, in: ready)
        lock.notePress(in: ready)

        lock.update(requested: false, in: ready)
        #expect(!lock.isLocked)
        // 要求が無いままなら、押しても掛けない
        lock.notePress(in: ready)
        lock.update(requested: false, in: ready)
        #expect(!lock.isLocked)
        // 要求し直せば、いま受けた押しで掛かる
        lock.update(requested: true, in: ready)
        #expect(lock.isLocked)
        #expect(fake.calls == [.capture, .release, .capture])
    }

    @Test("取り下げた直後に要求し直しても、押すまでは掛け直さない")
    func exitThenImmediateRequestWaitsForAPress() {
        let fake = FakeSystem()
        let lock = make(fake)
        lock.update(requested: true, in: ready)
        lock.notePress(in: ready)
        lock.update(requested: false, in: ready)
        lock.update(requested: true, in: ready)
        #expect(!lock.isLocked)
    }

    @Test("窓が畳まれたら外れる")
    func tearDownReleases() {
        let fake = FakeSystem()
        let lock = make(fake)
        lock.update(requested: true, in: ready)
        lock.notePress(in: ready)
        lock.tearDown()
        #expect(!lock.isLocked)
        #expect(fake.calls == [.capture, .release])
    }

    /// 窓が閉じる知らせを取りこぼしても、面ごと手放せば放す。
    @Test("手放されたら、捕まえていたカーソルを放す")
    func deinitReleases() {
        let fake = FakeSystem()
        var lock: PointerLock? = make(fake)
        lock?.update(requested: true, in: ready)
        lock?.notePress(in: ready)
        #expect(fake.calls == [.capture])
        lock = nil
        #expect(fake.calls == [.capture, .release])
    }

    /// **隠すのは数を数える仕組み** (`hide` と `unhide` の対) なので、捕まえていないのに放すと
    /// 数がずれ、後で捕まえたときに隠れなくなる。
    @Test("捕まえていないときに外しても、OS の口は呼ばない")
    func releasesOnlyWhatWasCaptured() {
        let fake = FakeSystem()
        let lock = make(fake)
        lock.releaseByUser()
        lock.tearDown()
        lock.update(requested: false, in: ready)
        #expect(fake.calls.isEmpty)
    }

    @Test("OS が断ったら捕まえたことにせず、押し直すまで試し直さない")
    func refusalIsNotACapture() {
        let fake = FakeSystem()
        fake.refuses = true
        let lock = make(fake)
        lock.update(requested: true, in: ready)
        lock.notePress(in: ready)
        #expect(!lock.isLocked)
        lock.releaseByUser()
        lock.tearDown()
        #expect(fake.calls.isEmpty, "捕まえていないのに放した")

        fake.refuses = false
        lock.update(requested: true, in: ready)
        #expect(!lock.isLocked, "押し直していないのに試し直した")
        lock.notePress(in: ready)
        #expect(lock.isLocked)
    }

    // MARK: - 窓が 2 つ (条件 13)

    /// 道具は作品の窓とプレビューを出す。**押された窓が捕まえ、2 つが同時に捕まえることは
    /// ない** — 鍵を持つ窓は 1 つなので普通は起きないが、通知の順に頼らずに構造で守る。
    @Test("同じプロセスの 2 つの面は、同時に捕まえない")
    func twoSurfacesNeverHoldAtOnce() {
        let fake = FakeSystem()
        let arbiter = PointerLock.Arbiter()
        let artwork = make(fake, arbiter: arbiter)
        let preview = make(fake, arbiter: arbiter)
        artwork.update(requested: true, in: ready)
        preview.update(requested: true, in: ready)

        artwork.notePress(in: ready)
        #expect(artwork.isLocked)
        // 退いた知らせが届く前に、もう一方が押されて前に出た
        preview.notePress(in: ready)
        #expect(preview.isLocked)
        #expect(!artwork.isLocked, "2 つが同時に捕まえている")
        #expect(fake.calls == [.capture, .release, .capture])

        // 先に外された側は、押し直すまで掛け直さない
        artwork.update(requested: true, in: ready)
        #expect(!artwork.isLocked)
    }

    /// 押さずに前へ出しただけの窓 (窓の切り替えのキーで前へ出した、など) は捕まえない。
    @Test("押された窓だけが捕まえ、押さずに前へ出た窓は捕まえない")
    func onlyThePressedSurfaceCaptures() {
        let fake = FakeSystem()
        let arbiter = PointerLock.Arbiter()
        let artwork = make(fake, arbiter: arbiter)
        let preview = make(fake, arbiter: arbiter)
        let behind = PointerLock.Situation(isKeyWindow: false, pointerIsInside: false)
        artwork.update(requested: true, in: behind)
        preview.update(requested: true, in: ready)
        preview.notePress(in: ready)
        #expect(preview.isLocked)
        #expect(!artwork.isLocked)

        // 押さずに作品の窓を前へ出した。プレビューは退いたので外れる
        preview.releaseByUser()
        artwork.update(requested: true, in: ready)
        #expect(!artwork.isLocked, "押していない窓が捕まえた")
        #expect(!preview.isLocked)
    }
}

/// 窓が移動 1 件を何として流すか ([#1144](https://github.com/mokume-metal/mokume/issues/1144))。
@Suite("捕まえている間の移動")
@MainActor
struct LockedMotionTests {
    @Test("捕まえていなければ、位置を送る")
    func sendsThePositionWhenFree() {
        let event = SketchSurface.motion(
            isLocked: false, location: (120, 80), delta: (3, 4))
        #expect(event == .mouseMoved(x: 120, y: 80))
    }

    /// 位置を送ると、カーソルが動かないので差が 0 になる (#1144 の条件 5)。
    @Test("捕まえている間は、位置ではなく量を送る")
    func sendsTheAmountWhenLocked() {
        let event = SketchSurface.motion(
            isLocked: true, location: (120, 80), delta: (3, -4))
        #expect(event == .mouseMovedBy(dx: 3, dy: -4))
    }

    @Test("捕まえている間に量が 0 の 1 件は送らない")
    func dropsAStillEvent() {
        #expect(SketchSurface.motion(isLocked: true, location: (1, 1), delta: (0, 0)) == nil)
    }

    @Test("写せない 1 件は送らない")
    func dropsWhatCannotBeMapped() {
        #expect(SketchSurface.motion(isLocked: true, location: (1, 1), delta: nil) == nil)
        #expect(SketchSurface.motion(isLocked: false, location: nil, delta: (1, 1)) == nil)
    }
}

/// 捕まえの要求を、子から道具へ運ぶ面の属性 ([#1144](https://github.com/mokume-metal/mokume/issues/1144))。
///
/// GPU は使わない — 属性は面 (`IOSurface`) に載るもので、絵を焼く経路とは別である。
@Suite("捕まえの要求を面に載せる")
@MainActor
struct PointerLockAttributeTests {
    private func makeSurface() throws -> IOSurfaceRef {
        try #require(IOSurfaceCreate(SharedFrameSurface.properties(width: 4, height: 4)))
    }

    @Test("載せた要求を、番号から引いた面で読める")
    func readsWhatWasPublished() throws {
        let surface = try makeSurface()
        SharedFrameSurface.publishPointerLock(true, to: surface)
        #expect(SharedFrameSurface.pointerLockRequested(of: IOSurfaceGetID(surface)))
    }

    /// 面は使い回されるので、消さなければ前に載せた要求が残る。
    @Test("頼んでいない枚では属性ごと消し、前の要求を残さない")
    func clearsAStaleRequest() throws {
        let surface = try makeSurface()
        SharedFrameSurface.publishPointerLock(true, to: surface)
        SharedFrameSurface.publishPointerLock(false, to: surface)
        #expect(!SharedFrameSurface.pointerLockRequested(on: surface))
        #expect(IOSurfaceCopyValue(surface, SharedFrameSurface.pointerLockAttribute as CFString) == nil)
    }

    /// 古いライブラリの子は属性を載せない。**載っていないのは頼んでいないこと**として読む。
    @Test("載っていない面と引けない番号は、頼んでいないと読む")
    func absentMeansNotRequested() throws {
        let surface = try makeSurface()
        #expect(!SharedFrameSurface.pointerLockRequested(on: surface))
        #expect(!SharedFrameSurface.pointerLockRequested(of: UInt32.max))
    }
}
