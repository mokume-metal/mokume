// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Metal
import Testing
import simd

@testable import MokumeCore

/// トラックパッドのピンチと、押した回数 (ダブルクリック)
/// ([#2762](https://github.com/mokume-metal/mokume/issues/2762))。
///
/// 量 (倍率の差分・押した回数) が窓から外から同じ線を通って合流点へ届くこと、`orbitControl` がその量で
/// 寄る・戻ることを、入力と計算の側で固める。GPU を要するのは最後の 1 組 (`orbitControl` を絵まで通す)
/// だけで、実際のトラックパッドの身振りは窓での手の確認に回る (PR 本文の手順)。
@Suite("ピンチと押した回数: 合流点")
@MainActor
struct PinchAndClickCountInputTests {
    /// 1 フレーム分を流して、配った呼び出しを返す。
    @discardableResult
    private func run(_ state: InputState, _ events: [InputEvent]) -> [InputCallback] {
        for event in events { state.enqueue(event) }
        var seen: [InputCallback] = []
        state.beginFrame { seen.append($0) }
        return seen
    }

    @Test("ピンチの量は、そのフレームの合計として読める。送らない次のフレームは 0")
    func pinchIsTheFrameTotal() {
        let state = InputState()
        run(state, [.pinched(amount: 0.1)])
        #expect(state.pinch == 0.1)
        run(state, [])
        #expect(state.pinch == 0, "次のフレームへ持ち越した")

        run(state, [.pinched(amount: 0.1), .pinched(amount: 0.1)])
        #expect(abs(state.pinch - 0.2) < 1e-6, "同じフレームの 2 件が合計にならない: \(state.pinch)")

        run(state, [.pinched(amount: -0.3)])
        #expect(state.pinch == -0.3, "閉じる向きが負にならない")
    }

    @Test("ピンチは呼び出しを配らない (読むのはフレームの合計だけ)")
    func pinchDispatchesNothing() {
        let state = InputState()
        #expect(run(state, [.pinched(amount: 0.5)]).isEmpty)
    }

    @Test("数でない・無限のピンチは、当てずに捨てて 1 度だけ言う", arguments: [Float.nan, .infinity, -.infinity])
    func nonFinitePinchIsDropped(_ amount: Float) {
        let state = InputState()
        run(state, [.pinched(amount: 0.1)])
        run(state, [.pinched(amount: amount), .pinched(amount: 0.2)])
        #expect(state.pinch == 0.2, "捨てなかった: \(state.pinch)")
        #expect(state.warnings.hasWarned(.nonFiniteEvent))
    }

    @Test("当てると合計が有限でなくなるピンチは、その 1 件だけ捨てる")
    func aPinchThatOverflowsTheTotalIsDropped() {
        let state = InputState()
        let big = Float.greatestFiniteMagnitude / 2 + 1e37
        run(state, [.pinched(amount: big), .pinched(amount: big), .pinched(amount: 1)])
        #expect(state.pinch.isFinite)
        #expect(state.pinch >= big, "最初の 1 件が当たっていない")
        #expect(state.warnings.hasWarned(.nonFiniteEvent))
    }

    @Test("左の 2 回目の押下だけが、ダブルクリックとして数えられる。フレームの頭で 0 に戻る")
    func onlyTheSecondLeftPressCountsAsADoubleClick() {
        let state = InputState()
        run(state, [.mouseDown(x: 1, y: 1, button: .left, clickCount: 1)])
        #expect(state.leftDoubleClicks == 0)
        run(state, [.mouseDown(x: 1, y: 1, button: .right, clickCount: 2)])
        #expect(state.leftDoubleClicks == 0, "右ボタンを数えた")
        run(state, [.mouseDown(x: 1, y: 1, button: .left, clickCount: 3)])
        #expect(state.leftDoubleClicks == 0, "3 回目を数えた")
        run(state, [.mouseDown(x: 1, y: 1, button: .left, clickCount: 2)])
        #expect(state.leftDoubleClicks == 1)
        run(state, [])
        #expect(state.leftDoubleClicks == 0, "次のフレームへ持ち越した")
    }

    @Test("押した回数を省いた押下は、これまでどおり単発 (1) で、呼び出しも変わらない")
    func aPressWithoutACountIsASinglePress() {
        let event = InputEvent.mouseDown(x: 5, y: 6, button: .left)
        #expect(event == .mouseDown(x: 5, y: 6, button: .left, clickCount: 1))
        let state = InputState()
        #expect(run(state, [event, .mouseUp(x: 5, y: 6, button: .left)]) == [.mousePressed, .mouseReleased, .mouseClicked])
    }

    @Test("位置が有限でない押下も、押した回数は残る")
    func aNonFinitePositionKeepsTheCount() {
        let state = InputState()
        run(state, [.mouseDown(x: .nan, y: 0, button: .left, clickCount: 2)])
        #expect(state.leftDoubleClicks == 1)
        #expect(state.warnings.message(for: .nonFinitePosition)?.contains("clickCount: 2") == true)
    }
}

@Suite("ピンチと押した回数: 線")
struct PinchAndClickCountWireTests {
    private func decode(_ json: String) throws -> RawInputEvent {
        try JSONDecoder().decode(RawInputEvent.self, from: Data(json.utf8))
    }

    @Test("ピンチは線へ書いて読み戻すと同じ量になり、外から送る形でも読める")
    func pinchSurvivesTheWire() throws {
        let event = InputEvent.pinched(amount: 0.125)
        #expect(try decode(event.wireLine).event == event)
        #expect(try decode(#"{"type": "pinched", "amount": 0.1}"#).event == .pinched(amount: 0.1))
    }

    @Test("量の無いピンチは読めない 1 件で、何も動かさない")
    func aPinchWithoutAnAmountIsUnreadable() throws {
        #expect(try decode(#"{"type": "pinched"}"#).event == nil)
        #expect(try decode(#"{"type": "pinched", "amount": null}"#).event == nil)
    }

    @Test("押した回数を持つ押下は、線を往復しても同じ出来事になる")
    func clickCountSurvivesTheWire() throws {
        let event = InputEvent.mouseDown(x: 12.5, y: 30, button: .left, clickCount: 2)
        #expect(event.wireLine.contains(#""clickCount":2"#))
        #expect(try decode(event.wireLine).event == event)
        #expect(
            try decode(#"{"type": "mouseDown", "x": 100, "y": 100, "clickCount": 2}"#).event
                == .mouseDown(x: 100, y: 100, button: .left, clickCount: 2))
    }

    @Test("単発の押下の線は、押した回数を載せない (これまでと同じ 1 行)")
    func aSinglePressKeepsTheOldLine() throws {
        let line = InputEvent.mouseDown(x: 1, y: 2, button: .right).wireLine
        #expect(line == #"{"type":"mouseDown","x":1.0,"y":2.0,"button":1}"# + "\n")
        #expect(
            try decode(#"{"type": "mouseDown", "x": 1, "y": 2}"#).event
                == .mouseDown(x: 1, y: 2, button: .left, clickCount: 1), "省いた押下は単発")
        #expect(
            try decode(#"{"type": "mouseDown", "x": 1, "y": 2, "clickCount": null}"#).event
                == .mouseDown(x: 1, y: 2, button: .left, clickCount: 1), "null は省いたのと同じ")
    }

    @Test("負の押した回数は読めない 1 件、整数でない回数は解けない 1 件")
    func badClickCountsAreRefused() throws {
        #expect(try decode(#"{"type": "mouseDown", "x": 1, "y": 2, "clickCount": -1}"#).event == nil)
        #expect(throws: DecodingError.self) {
            try decode(#"{"type": "mouseDown", "x": 1, "y": 2, "clickCount": 2.5}"#)
        }
        #expect(throws: DecodingError.self) {
            try decode(#"{"type": "mouseDown", "x": 1, "y": 2, "clickCount": "2"}"#)
        }
    }

    /// 外から送る要求では、読めない 1 件だけが `ignored` に数えられ、残りは通る。
    @Test("外から送る要求でも、不正な押した回数の 1 件だけが ignored に数えられる")
    func theRequestCountsTheBadOneAsIgnored() throws {
        let json = """
            {"id": "a", "events": [
              {"type": "pinched", "amount": 0.25},
              {"type": "mouseDown", "x": 1, "y": 2, "clickCount": 2.5},
              {"type": "mouseDown", "x": 1, "y": 2, "clickCount": -1},
              {"type": "mouseDown", "x": 1, "y": 2, "clickCount": 2}
            ]}
            """
        let request = try JSONDecoder().decode(InputRequest.self, from: Data(json.utf8))
        let events = request.events.compactMap { $0.event }
        #expect(
            events == [.pinched(amount: 0.25), .mouseDown(x: 1, y: 2, button: .left, clickCount: 2)],
            "\(events)")
    }
}

@Suite("ピンチと押した回数: 視点の計算")
struct PinchAndClickCountViewMathTests {
    private func fitting() -> Orbit { Orbit.fitting(width: 640, height: 480) }

    private func pinch(_ orbit: inout Orbit, _ amount: Float, z: Float = 1) -> Orbit.HeldAxes {
        orbit.advance(
            dragX: 0, dragY: 0, scroll: 0, pinch: amount, isDragging: false,
            sensitivity: SIMD3(1, 1, z))
    }

    @Test("開いたピンチ 0.25 は、距離を 1 / 1.25 倍にする。閉じれば遠ざかる")
    func pinchingOutMovesCloserByTheInverseOfTheScale() {
        var orbit = fitting()
        let start = orbit.distance
        #expect(pinch(&orbit, 0.25) == Orbit.HeldAxes())
        #expect(abs(orbit.distance - start / 1.25) < 1e-3)

        var closing = fitting()
        _ = pinch(&closing, -0.2)
        #expect(abs(closing.distance - start / 0.8) < 1e-3)
    }

    @Test("ピンチで寄っても、寄れる限界と引ける限界を越えない")
    func pinchStopsAtTheLimits() {
        var near = fitting()
        _ = pinch(&near, 1e6)
        #expect(near.distance == near.minimumDistance)
        var far = fitting()
        _ = pinch(&far, -0.999_999)
        #expect(far.distance == far.maximumDistance)
    }

    @Test("1 + p が 0 以下のピンチは進めず、寄りの軸が進まなかったと知らせる", arguments: [Float(-1), -2, -1e30])
    func aPinchBelowMinusOneHolds(_ amount: Float) {
        var orbit = fitting()
        let start = orbit.distance
        let held = pinch(&orbit, amount)
        #expect(held.zoom)
        #expect(orbit.distance == start, "距離が動いた: \(orbit.distance)")
    }

    @Test("数でない・無限のピンチも進めない", arguments: [Float.nan, .infinity, -.infinity])
    func unusablePinchHolds(_ amount: Float) {
        var orbit = fitting()
        let start = orbit.distance
        #expect(pinch(&orbit, amount).zoom)
        #expect(orbit.distance == start)
        #expect(orbit.distance.isFinite)
    }

    @Test("寄りの感度はピンチの量に掛かり、数でない感度なら進めない")
    func theZoomSensitivityScalesThePinch() {
        var orbit = fitting()
        let start = orbit.distance
        _ = pinch(&orbit, 0.25, z: 2)
        #expect(abs(orbit.distance - start / 1.5) < 1e-3)
        var broken = fitting()
        #expect(pinch(&broken, 0.25, z: .nan).zoom)
        #expect(broken.distance == start)
    }

    @Test("戻すと注視点・距離・角が戻り、慣性の速さは 0 になる。慣性の設定と限界は変わらない")
    func returningRestoresTheViewOnly() {
        let home = Orbit(
            center: Vector3(10, 20, 30), distance: 250, yaw: 0.3, pitch: 0.2,
            minimumDistance: 25, maximumDistance: 2500)
        var orbit = home
        orbit.inertia = 0.9
        orbit.center = Vector3(0, 0, 0)
        orbit.yaw = -1
        orbit.pitch = -0.4
        orbit.distance = 90
        orbit.advance(
            dragX: 5, dragY: 5, scroll: 0, isDragging: true, sensitivity: SIMD3(1, 1, 1))
        #expect(orbit.yawSpeed != 0)

        orbit.returnView(to: home)

        #expect(orbit.center == home.center)
        #expect(orbit.distance == home.distance)
        #expect(orbit.yaw == home.yaw)
        #expect(orbit.pitch == home.pitch)
        #expect(orbit.yawSpeed == 0 && orbit.pitchSpeed == 0, "慣性の速さが残った")
        #expect(orbit.inertia == 0.9, "作者が変えた慣性まで戻した")
        #expect(orbit.minimumDistance == 25 && orbit.maximumDistance == 2500)
    }
}

/// `orbitControl()` を入力から絵まで通す。GPU を要する (単発で 1 回だけ走らせる)。
@Suite(
    "ピンチと押した回数: orbitControl",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PinchAndClickCountOrbitControlTests {
    /// `setup()` で置いた視点から始める、`orbitControl()` だけのスケッチ。
    final class Subject: Sketch {
        var seenOrbit: Orbit?
        /// `setup()` が置く視点。
        let start = Orbit(
            center: Vector3(10, 20, 30), distance: 300, yaw: 0.3, pitch: 0.2,
            minimumDistance: 30, maximumDistance: 3000)

        init() {}
        var settings: SketchSettings { SketchSettings(width: 64, height: 64) }

        func setup() { orbit = start }

        func draw() {
            background(.display(red: 0.05, green: 0.06, blue: 0.08))
            orbitControl()
            seenOrbit = orbit
        }
    }

    private func makeRuntime(_ sketch: Subject) throws -> SketchRuntime {
        try SketchRuntime(sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 })
    }

    @Test("ピンチ 0.25 で、そのフレームの距離が 1 / 1.25 倍になる。送らないフレームでは動かない")
    func pinchingMovesTheDistance() throws {
        let sketch = Subject()
        let runtime = try makeRuntime(sketch)
        try runtime.advance()
        let start = try #require(sketch.seenOrbit).distance
        #expect(start == 300, "setup() で置いた視点から始まっていない")

        runtime.input.enqueue(.pinched(amount: 0.25))
        try runtime.advance()
        #expect(abs(try #require(sketch.seenOrbit).distance - start / 1.25) < 1e-3)

        let after = try #require(sketch.seenOrbit).distance
        try runtime.advance()
        #expect(try #require(sketch.seenOrbit).distance == after, "送らないフレームで動いた")
    }

    @Test("引きずって回した後、左の 2 回目の押下で setup() の視点へ戻る。1 回目の押下では戻らない")
    func doubleClickReturnsToTheFirstView() throws {
        let sketch = Subject()
        let runtime = try makeRuntime(sketch)
        try runtime.advance()
        let home = try #require(sketch.seenOrbit)

        runtime.input.enqueue(.mouseDown(x: 10, y: 32, button: .left))
        try runtime.advance()
        runtime.input.enqueue(.mouseMoved(x: 110, y: 32))
        try runtime.advance()
        runtime.input.enqueue(.mouseUp(x: 110, y: 32, button: .left))
        runtime.input.enqueue(.pinched(amount: 0.5))
        try runtime.advance()
        let turned = try #require(sketch.seenOrbit)
        #expect(abs(turned.yaw - (home.yaw - 1)) < 1e-4, "水平角が約 -1 ラジアン回っていない: \(turned.yaw)")
        #expect(turned.distance != home.distance)

        // 1 回目の押下では戻らない
        runtime.input.enqueue(.mouseDown(x: 110, y: 32, button: .left, clickCount: 1))
        try runtime.advance()
        runtime.input.enqueue(.mouseUp(x: 110, y: 32, button: .left))
        try runtime.advance()
        let stillTurned = try #require(sketch.seenOrbit)
        #expect(stillTurned.yaw == turned.yaw && stillTurned.distance == turned.distance)

        // 右ボタンの 2 回目の押下でも戻らない
        runtime.input.enqueue(.mouseDown(x: 110, y: 32, button: .right, clickCount: 2))
        runtime.input.enqueue(.mouseUp(x: 110, y: 32, button: .right))
        try runtime.advance()
        #expect(try #require(sketch.seenOrbit).yaw == turned.yaw)

        runtime.input.enqueue(.mouseDown(x: 110, y: 32, button: .left, clickCount: 2))
        try runtime.advance()
        let back = try #require(sketch.seenOrbit)
        #expect(back.yaw == home.yaw)
        #expect(back.pitch == home.pitch)
        #expect(back.distance == home.distance)
        #expect(back.center == home.center)
    }

    @Test("戻したフレームの引きずりは食わず、戻った先から動かない")
    func theReturningFrameDoesNotAlsoDrag() throws {
        let sketch = Subject()
        let runtime = try makeRuntime(sketch)
        try runtime.advance()
        let home = try #require(sketch.seenOrbit)
        runtime.input.enqueue(.mouseDown(x: 10, y: 32, button: .left))
        try runtime.advance()
        // 同じフレームに 2 回目の押下と、その後の引きずりが届く
        runtime.input.enqueue(.mouseUp(x: 10, y: 32, button: .left))
        runtime.input.enqueue(.mouseDown(x: 10, y: 32, button: .left, clickCount: 2))
        runtime.input.enqueue(.mouseMoved(x: 80, y: 32))
        runtime.input.enqueue(.scrolled(dx: 0, dy: 10))
        try runtime.advance()
        let back = try #require(sketch.seenOrbit)
        #expect(back.yaw == home.yaw && back.distance == home.distance)
    }
}

@Suite("ピンチと押した回数: 窓")
@MainActor
struct PinchAndClickCountSurfaceTests {
    private func makeSurface(_ input: InputState) throws -> SketchSurface {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return SketchSurface(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64), device: device,
            input: input, canvasSize: (64, 64))
    }

    @Test(
        "窓が運んだピンチは、合流点へも運び先の 1 行へも行く",
        .enabled(if: RenderDevice.isAvailable, "面を作るのに Metal の装置が要る"))
    func theSurfaceRelaysAPinch() throws {
        let input = InputState()
        let surface = try makeSurface(input)
        var lines: [String] = []
        surface.relay = { lines.append($0) }
        surface.deliver(.pinched(amount: 0.25))
        input.beginFrame()
        #expect(input.pinch == 0.25)
        #expect(lines == [InputEvent.pinched(amount: 0.25).wireLine])
    }

    /// 窓が拾った押下は、`NSEvent.clickCount` をそのまま運ぶ。
    @Test(
        "窓の押下は、押した回数を運ぶ",
        .enabled(if: RenderDevice.isAvailable, "面を作るのに Metal の装置が要る"))
    func theSurfaceCarriesTheClickCount() throws {
        let input = InputState()
        let surface = try makeSurface(input)
        surface.wantsLayer = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.titled],
            backing: .buffered, defer: true)
        // 素の `NSWindow` は閉じたら自分を解放する。こちらが強い参照を持ったまま閉じると過剰に解放される (#705)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = surface
        var lines: [String] = []
        surface.relay = { lines.append($0) }
        for count in [1, 2] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: surface.convert(NSPoint(x: 32, y: 32), to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: count, pressure: 1))
            surface.mouseDown(with: event)
            input.beginFrame()
        }
        #expect(lines.count == 2)
        #expect(!lines[0].contains("clickCount"), "単発の押下が回数を載せた: \(lines[0])")
        #expect(lines[1].contains(#""clickCount":2"#), "2 回目の押下が回数を運ばない: \(lines[1])")
        #expect(input.leftDoubleClicks == 1)
    }
}
