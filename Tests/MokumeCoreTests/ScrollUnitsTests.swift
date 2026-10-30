// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics
import Foundation
import Metal
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 窓が受けたスクロールの量を点へ揃える関数。
///
/// **GPU も窓も要らない** — 見るのは機器の別と量から点を返す対応だけで、AppKit の出来事は作らない。
/// 窓がこの関数を通しているか (`scrollWheel(with:)` から呼ばれているか) は、下の「窓」の検査が見る。
/// 実機のホイールとトラックパッドで合わせた感触は、人の手で窓を回して確かめる
/// ([#2442](https://github.com/mokume-metal/mokume/issues/2442))。
@Suite("スクロールの単位")
@MainActor
struct ScrollUnitsTests {
    @Test("ホイール 1 刻み (行の機器) は、1 行の点数に換算して届く")
    func wheelLinesBecomePoints() {
        let amount = ScrollUnits.points(dx: 0, dy: 1, isPrecise: false)
        #expect(amount.dy == Float(ScrollUnits.pointsPerLine))
        #expect(amount.dx == 0)

        // 刻みを重ねた分も比例する。負 (逆向き) と横も同じ物差し
        let several = ScrollUnits.points(dx: -2, dy: -3, isPrecise: false)
        #expect(several.dx == Float(-2 * ScrollUnits.pointsPerLine))
        #expect(several.dy == Float(-3 * ScrollUnits.pointsPerLine))
    }

    @Test("トラックパッド (点の機器) の量は、そのまま届く")
    func trackpadPointsPassThrough() {
        let amount = ScrollUnits.points(dx: -4.5, dy: 12, isPrecise: true)
        #expect(amount.dx == -4.5)
        #expect(amount.dy == 12)
    }

    @Test("0 はどの機器でも 0 のまま")
    func zeroStaysZero() {
        for isPrecise in [true, false] {
            let amount = ScrollUnits.points(dx: 0, dy: 0, isPrecise: isPrecise)
            #expect(amount.dx == 0 && amount.dy == 0)
        }
    }

    @Test("1 行の点数は、点の機器の量とホイール 1 刻みが同じ桁で並ぶ値である")
    func lineIsPositiveAndTrackpadScaled() {
        // 換算の係数が 0 や負だと、ホイールが止まる・逆向きになる
        #expect(ScrollUnits.pointsPerLine > 1)
        #expect(ScrollUnits.pointsPerLine <= 40)
    }

    @Test("数でない量・無限の量は、そのまま下流の検めに渡る (ここでは捨てない)")
    func nonFiniteIsLeftToTheInputLayer() {
        // 掛け算が数でない値を有限に直してしまうと、下流 (InputState の検め) が見る前に隠れる
        let amount = ScrollUnits.points(dx: .nan, dy: .infinity, isPrecise: false)
        #expect(amount.dx.isNaN)
        #expect(amount.dy == .infinity)
    }

    /// **外から送る 2 つの実際の経路を通す。** 合流点へ直に積むだけでは、復号や運び口に換算が足されても
    /// 赤にならない (#2442 の完了条件 2・#2731 の前提)。
    @Test("外から送る scrolled (.mokume/input の要求) は、dx・dy が換算されず点のまま届く")
    func theInboxIsNotConverted() throws {
        let facet = try TestScratch.directory("mokume-input")
        try AtomicFile.write(
            Data(#"{"id":"r1","events":[{"type":"scrolled","dx":-2,"dy":1}]}"#.utf8),
            to: facet.appendingPathComponent("request.json"))
        let state = InputState()
        let report = try #require(InputInbox(directory: facet).drain(into: state))
        #expect(report.accepted == 1)
        var delivered: [InputCallback] = []
        state.beginFrame { delivered.append($0) }
        #expect(state.scrollX == -2)
        #expect(state.scrollY == 1)
        #expect(delivered.contains(.mouseWheel(deltaX: -2, deltaY: 1)))
    }

    @Test("標準入力の 1 行 (道具の窓の運び口) も、dx・dy が換算されず点のまま届く")
    func theStandardInputIsNotConverted() throws {
        let pipe = Pipe()
        let reader = StandardInputEvents(descriptor: pipe.fileHandleForReading.fileDescriptor)
        defer { try? pipe.fileHandleForWriting.close() }
        try pipe.fileHandleForWriting.write(
            contentsOf: Data(InputEvent.scrolled(dx: -2, dy: 1).wireLine.utf8))
        let state = InputState()
        reader.drain(into: state)
        #expect(reader.accepted == 1)
        var delivered: [InputCallback] = []
        state.beginFrame { delivered.append($0) }
        #expect(state.scrollX == -2)
        #expect(state.scrollY == 1)
        #expect(delivered.contains(.mouseWheel(deltaX: -2, deltaY: 1)))
    }
}

/// 窓が出来事から量を取り出して、換算の関数を通して合流点へ流すところ。
///
/// **量は OS が `CGEvent` から作る値を前提にしない。** 行の出来事の `scrollingDeltaY` が何になるかは OS の側の約束で、
/// 手元と専用機で違いうる ([#3214](https://github.com/mokume-metal/mokume/issues/3214))。見るのは、
/// 出来事が名乗った量と機器の別から、期待する点を**その場で**出して、窓が流した量と揃うことである。
/// **ただし機器の別 (`hasPreciseScrollingDeltas`) は縛る** — 行の出来事が precise を名乗る環境では、
/// 換算を外しても期待値が揃ってしまうので、そこは赤にして知らせる。
@Suite("スクロールの単位: 窓")
@MainActor
struct ScrollSurfaceTests {
    private func scrollEvent(units: CGScrollEventUnit, amount: Int32) throws -> NSEvent {
        let cg = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: amount, wheel2: 0,
                wheel3: 0))
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test(
        "窓が流す量は、出来事が名乗った量を機器の別で換算した点と揃う",
        .enabled(if: RenderDevice.isAvailable, "面を作るのに Metal の装置が要る"),
        arguments: [CGScrollEventUnit.line, .pixel])
    func theSurfaceConvertsWhatTheEventSays(units: CGScrollEventUnit) throws {
        let input = InputState()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = SketchSurface(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64), device: device, input: input,
            canvasSize: (64, 64))
        let event = try scrollEvent(units: units, amount: 3)
        // 量が 0 の出来事では、換算を外しても揃ってしまう
        try #require(event.scrollingDeltaY != 0)
        // **出来事の印を前提として縛る。** 行の出来事が precise を名乗る環境では、期待値が換算なしの量になり、
        // 換算を外しても緑のまま素通りする。環境が違えばここで赤にして知らせる (#2442 の反証)
        try #require(
            event.hasPreciseScrollingDeltas == (units == .pixel),
            "\(units) の出来事の hasPreciseScrollingDeltas が期待と違う: \(event.hasPreciseScrollingDeltas)")
        // 印と結果が揃うことを見る: 点の機器はそのまま、行の機器は 1 行の点数を掛けた量
        let scale: Double = event.hasPreciseScrollingDeltas ? 1 : ScrollUnits.pointsPerLine
        var lines: [String] = []
        surface.relay = { lines.append($0) }

        surface.scrollWheel(with: event)
        input.beginFrame()

        #expect(input.scrollY == Float(event.scrollingDeltaY * scale))
        #expect(input.scrollX == Float(event.scrollingDeltaX * scale))
        #expect(
            lines
                == [
                    InputEvent.scrolled(
                        dx: Float(event.scrollingDeltaX * scale), dy: Float(event.scrollingDeltaY * scale)
                    ).wireLine
                ])
    }
}
