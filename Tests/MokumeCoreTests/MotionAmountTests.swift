// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 動いた量 — フレーム合計 (``InputState/movedX``) と、1 件ぶん (`mouseMoved(deltaX:deltaY:)`) —
/// と、位置を持たない移動 (`mouseMovedBy`)。窓も GPU も使わない
/// ([#1144](https://github.com/mokume-metal/mokume/issues/1144))。
///
/// 捕まえている間の窓は位置ではなく量を送るので、合流点は「位置の差」だけで量を作れない。
/// 量の約束は、捕まえているかによらず同じ 1 つ (描く解像度の画素・縦軸は下向き・押下は移動
/// ではない) で、ここではそれを窓の外から固める。
@Suite("動いた量")
struct MotionAmountTests {
    /// 溜めて 1 フレームぶん流し込み、配られた呼び出しの並びを返す。
    private func callbacks(from events: [InputEvent], into state: InputState = InputState())
        -> [InputCallback]
    {
        for event in events { state.enqueue(event) }
        var seen: [InputCallback] = []
        state.beginFrame { seen.append($0) }
        return seen
    }

    /// 1 件ぶんの量 — 押していない側 (`mouseMoved(deltaX:deltaY:)`) と押している側
    /// (`mouseDragged(deltaX:deltaY:)`) — を、配られた順に抜き出す。
    private func amounts(_ seen: [InputCallback]) -> (moved: [(Float, Float)], dragged: [(Float, Float)]) {
        var moved: [(Float, Float)] = []
        var dragged: [(Float, Float)] = []
        for callback in seen {
            switch callback {
            case .mouseMovedBy(let deltaX, let deltaY): moved.append((deltaX, deltaY))
            case .mouseDragged(let deltaX, let deltaY): dragged.append((deltaX, deltaY))
            default: break
            }
        }
        return (moved, dragged)
    }

    // MARK: - 位置を持たない移動 (条件 5)

    @Test("位置を持たない移動は、位置を動かさず、動いた量にだけ足す")
    func relativeMotionLeavesThePositionAlone() {
        let state = InputState()
        state.enqueue(.mouseMoved(x: 100, y: 60))
        state.beginFrame()

        state.enqueue(.mouseMovedBy(dx: 7, dy: -3))
        state.enqueue(.mouseMovedBy(dx: 5, dy: 9))
        state.beginFrame()

        #expect(state.x == 100)
        #expect(state.y == 60)
        #expect(state.previousX == 100, "前のフレームの位置も動かない")
        #expect(state.movedX == 12)
        #expect(state.movedY == 6)
        #expect(state.dragX == 0, "押していないので引きずりではない")
    }

    /// **`x - before.x` だけで量を作ると 0 になる** — 位置は動かないので。押したまま届いた
    /// 量は、引きずった量としてそのまま渡る。
    @Test("押したまま届いた位置を持たない移動は、引きずった量になり 0 にならない")
    func relativeMotionWhileHeldIsADrag() {
        let seen = callbacks(from: [
            .mouseDown(x: 40, y: 30, button: .left),
            .mouseMovedBy(dx: 6, dy: 8),
        ])
        #expect(seen == [.mousePressed, .mouseDragged(deltaX: 6, deltaY: 8)])
    }

    @Test("押したまま届いた位置を持たない移動は、引きずった量と動いた量の両方に足す")
    func relativeMotionWhileHeldCountsAsBoth() {
        let state = InputState()
        state.enqueue(.mouseDown(x: 40, y: 30, button: .left))
        state.enqueue(.mouseMovedBy(dx: 6, dy: 8))
        state.enqueue(.mouseMovedBy(dx: -2, dy: 1))
        state.beginFrame()

        #expect(state.dragX == 4)
        #expect(state.dragY == 9)
        #expect(state.movedX == 4)
        #expect(state.movedY == 9)
        #expect(state.x == 40, "押したままでも位置は動かない")
    }

    // MARK: - 1 件ぶんの呼び出し (条件 3)

    @Test("押していない移動は、移動の直後にその量が続く")
    func movingIsFollowedByItsAmount() {
        let seen = callbacks(from: [
            .mouseMoved(x: 10, y: 20),
            .mouseMovedBy(dx: 3, dy: -4),
        ])
        #expect(
            seen == [
                .mouseMoved, .mouseMovedBy(deltaX: 10, deltaY: 20),
                .mouseMoved, .mouseMovedBy(deltaX: 3, deltaY: -4),
            ])
    }

    @Test("押している間は、移動もその量も呼ばれない")
    func draggingCallsNeitherMovedCallback() {
        let seen = callbacks(from: [
            .mouseDown(x: 0, y: 0, button: .left),
            .mouseMoved(x: 5, y: 5),
            .mouseMovedBy(dx: 1, dy: 1),
            .mouseUp(x: 5, y: 5, button: .left),
        ])
        #expect(!seen.contains(.mouseMoved))
        #expect(amounts(seen).moved.isEmpty)
    }

    // MARK: - フレーム合計と 1 件ぶんの和 (条件 2・4)

    /// **#807 の罠を新しい量で開かない。** 1 フレームに 3 件届いたとき、1 件ぶんの和は
    /// フレーム合計と一致し、部分累計を足し込んだ `3a + 2b + c` にはならない。
    @Test(
        "1 フレームに 3 件届いても、1 件ずつの量の和がフレーム合計と一致する",
        arguments: [false, true])
    func amountsSumToTheFrameTotal(relative: Bool) {
        let state = InputState()
        state.enqueue(.mouseMoved(x: 10, y: 10))
        state.beginFrame()

        // a = (2, 1)、b = (5, -3)、c = (-1, 4)。押していない 2 件と、押したままの 1 件
        let steps: [(Float, Float)] = [(2, 1), (5, -3), (-1, 4)]
        var x: Float = 10
        var y: Float = 10
        var events: [InputEvent] = []
        for (index, step) in steps.enumerated() {
            if index == 2 { events.append(.mouseDown(x: x, y: y, button: .left)) }
            x += step.0
            y += step.1
            events.append(relative ? .mouseMovedBy(dx: step.0, dy: step.1) : .mouseMoved(x: x, y: y))
        }
        let seen = callbacks(from: events, into: state)
        let (moved, dragged) = amounts(seen)

        #expect(moved.count == 2)
        #expect(dragged.count == 1)
        let all = moved + dragged
        #expect(all.map(\.0).reduce(0, +) == state.movedX)
        #expect(all.map(\.1).reduce(0, +) == state.movedY)
        #expect(dragged.map(\.0).reduce(0, +) == state.dragX)
        #expect(dragged.map(\.1).reduce(0, +) == state.dragY)
        #expect(state.movedX == 6)
        #expect(state.movedY == 2)
        // 部分累計を足し込んでいれば 3a + 2b + c = 6 + 10 - 1 = 15 になる
        #expect(state.movedX != 15)
    }

    /// **押下は移動ではない** (``InputState/dragX`` と同じ約束)。位置の差としては現れても、
    /// 手を動かした量ではない。
    @Test("押下と解放で位置が飛んだぶんは、動いた量に数えない")
    func pressJumpsAreNotMotion() {
        let state = InputState()
        state.enqueue(.mouseMoved(x: 10, y: 10))
        state.beginFrame()

        state.enqueue(.mouseDown(x: 200, y: 150, button: .left))
        state.enqueue(.mouseUp(x: 300, y: 50, button: .left))
        state.beginFrame()
        #expect(state.movedX == 0)
        #expect(state.movedY == 0)

        // 次の移動は、解放した位置からの差だけを数える
        state.enqueue(.mouseMoved(x: 305, y: 52))
        state.beginFrame()
        #expect(state.movedX == 5)
        #expect(state.movedY == 2)
    }

    @Test("動いた量は、フレームが変われば 0 から数え直す")
    func motionIsPerFrame() {
        let state = InputState()
        state.enqueue(.mouseMovedBy(dx: 3, dy: 4))
        state.beginFrame()
        #expect(state.movedX == 3)

        state.beginFrame()
        #expect(state.movedX == 0)
        #expect(state.movedY == 0)
    }
}

@Suite("外から送る、位置を持たない移動")
struct RelativeMotionInboxTests {
    private func makeFacet() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func send(_ events: String, to facet: URL) throws {
        try AtomicFile.write(
            Data(#"{"id":"r1","events":[\#(events)]}"#.utf8),
            to: facet.appendingPathComponent("request.json"))
    }

    /// 捕まえたスケッチも外から動かせる — 送れなければ、捕まえた途端にエージェントの手が
    /// 届かなくなる (ADR-0001 原則 3)。
    @Test("送った量が合流点へ入り、位置は動かない")
    func deliversTheAmount() throws {
        let facet = try makeFacet()
        let state = InputState()
        try send(
            #"{"type":"mouseMoved","x":50,"y":40},{"type":"mouseMovedBy","dx":12,"dy":-4}"#,
            to: facet)

        let report = try #require(InputInbox(directory: facet).drain(into: state))
        #expect(report.accepted == 2)
        #expect(report.ignored == 0)
        state.beginFrame()
        #expect(state.x == 50)
        #expect(state.y == 40)
        #expect(state.movedX == 62, "位置の移動 (0→50) と量 (12) の和")
        #expect(state.movedY == 36)
    }

    /// `dx` / `dy` の 0 は「動いていない」と読めるので、`scrolled` と同じく省ける。
    @Test("量を省いた 1 件も通り、省いた向きは 0 になる")
    func fillsInAMissingAmount() throws {
        let facet = try makeFacet()
        let state = InputState()
        try send(#"{"type":"mouseMovedBy"},{"type":"mouseMovedBy","dx":5}"#, to: facet)

        #expect(InputInbox(directory: facet).drain(into: state)?.accepted == 2)
        state.beginFrame()
        #expect(state.movedX == 5)
        #expect(state.movedY == 0)
    }

    @Test("量の型が違う 1 件だけが捨てられ、残りは通る")
    func skipsOnlyTheBrokenAmount() throws {
        let facet = try makeFacet()
        let state = InputState()
        try send(#"{"type":"mouseMovedBy","dx":"5"},{"type":"mouseMovedBy","dx":2,"dy":3}"#, to: facet)

        let report = try #require(InputInbox(directory: facet).drain(into: state))
        #expect(report.accepted == 1)
        #expect(report.ignored == 1)
        state.beginFrame()
        #expect(state.movedX == 2)
        #expect(state.movedY == 3)
    }
}
