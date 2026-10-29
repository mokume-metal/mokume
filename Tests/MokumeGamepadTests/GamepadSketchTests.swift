// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import GameController
import Testing

@testable import MokumeCore
@testable import MokumeGamepad

/// `setup()` と `draw()` で、検査が渡した手続きを走らせるスケッチ。
final class GamepadSketch: Sketch {
    nonisolated(unsafe) static var onSetup: (GamepadSketch) -> Void = { _ in }
    nonisolated(unsafe) static var onDraw: (GamepadSketch) -> Void = { _ in }
    init() {}
    var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
    func setup() { Self.onSetup(self) }
    func draw() {
        background(0, 0, 0)
        Self.onDraw(self)
    }
}

/// パッドの入り口を、走っているスケッチの中で回す (#1965)。GPU を要する。
///
/// **どの入力がどのフレームの `draw()` に届くかが、フレームの数え方だけで決まる**ことが約束で、
/// これが水準 2 を名乗れる根拠になる (ADR-0028 決定 7)。
@Suite(
    "ゲームパッドの入り口 (走っているスケッチ)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct GamepadSketchTests {
    private func run(frames: Int) throws {
        let runtime = try SketchRuntime(sketch: GamepadSketch(), gpu: try RenderDevice())
        for _ in 0..<frames { try runtime.advance() }
    }

    @Test("setup() で作った記録のパッドは、最初の draw() から 1 つずつ入力を渡し、2 度回しても同じ")
    func recordedInputsReachDrawInOrder() throws {
        let inputs: [GamepadInput?] = [
            GamepadInput(leftStick: [1, 0], pressed: [.a]), nil, GamepadInput(leftStick: [0, 1]),
        ]
        func record() throws -> [String] {
            var pad: Gamepad?
            var seen: [String] = []
            GamepadSketch.onSetup = { pad = $0.createGamepad(inputs: inputs) }
            GamepadSketch.onDraw = { _ in
                guard let pad else { return }
                seen.append("\(pad.leftStick.simd) \(pad.isPressed(.a)) \(pad.state)")
            }
            try run(frames: 4)
            return seen
        }
        let first = try record()
        #expect(
            first == [
                "SIMD2<Float>(1.0, 0.0) true running", "SIMD2<Float>(0.0, 0.0) false disconnected",
                "SIMD2<Float>(0.0, 1.0) false running", "SIMD2<Float>(1.0, 0.0) true running",
            ])
        #expect(try record() == first)
    }

    @Test("外して足し直した記録のパッドは、外さずに回したときと同じ入力を、足し直した後のフレームで受け取る (時刻どおり・#3152)")
    func reattachedRecordedPadKeepsTheTimeline() throws {
        // 要素ごとに違う入力 (傾きの x)。6 つで、10 フレームまで回すと最後まで行って最初に戻る
        let inputs: [GamepadInput?] = (0..<6).map { GamepadInput(leftStick: [Float($0 + 1) / 8, 0]) }
        func record(leaveAt: Int?, returnAt: Int?) throws -> [Float] {
            var pad: Gamepad?
            var seen: [Float] = []
            GamepadSketch.onSetup = { pad = $0.createGamepad(inputs: inputs) }
            GamepadSketch.onDraw = { sketch in
                guard let pad else { return }
                if sketch.frameCount == leaveAt { sketch.detach(pad) }
                if sketch.frameCount == returnAt { sketch.attach(pad) }
                seen.append(pad.leftStick.simd.x)
            }
            try run(frames: 10)
            return seen
        }
        let straight = try record(leaveAt: nil, returnAt: nil)
        let reattached = try record(leaveAt: 2, returnAt: 4)
        // 外さない実行では、i 番目のフレームに i 番目の入力が入り、最後まで行けば最初に戻る
        #expect(straight == [1, 2, 3, 4, 5, 6, 1, 2, 3, 4].map { Float($0) / 8 })
        // 外していた間 (3・4 フレーム目) は傾かず、足し直した後 (5 フレーム目から) は外さない実行と同じ入力
        #expect(reattached[2] == 0 && reattached[3] == 0)
        #expect(Array(reattached[4...]) == Array(straight[4...]), "\(reattached)")
    }

    @Test("外で足せなかった createGamepad(inputs:) は番号を進めず、後の setup() のパッドが recorded #1 になる")
    func outsideCallDoesNotSpendTheNumber() throws {
        let sketch = GamepadSketch()
        var id: String?
        OutsideRun.$current.withValue(OutsideRun()) {
            // init() の中に当たる外。足せないので、パッドは番号を使わない
            _ = sketch.createGamepad(inputs: [nil])
            _ = sketch.createGamepad(inputs: [nil])
        }
        GamepadSketch.onSetup = { id = $0.createGamepad(inputs: [nil]).id }
        GamepadSketch.onDraw = { _ in }
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
        try runtime.advance()
        #expect(id == "recorded #1")
    }

    @Test("一覧は毎フレーム呼んでも同じ物を返し、走っているスケッチに 1 度だけ足す")
    func listReturnsTheSamePads() throws {
        let hub = GamepadHub(watches: false)
        let controller = GCController.withExtendedGamepad()
        hub.connected(controller)
        var lists: [[ObjectIdentifier]] = []
        var states: [SourceState] = []
        GamepadSketch.onSetup = { _ in }
        GamepadSketch.onDraw = { sketch in
            let pads = GamepadRoster.roster(for: sketch).gamepads(for: sketch, from: hub, calledAs: "gamepads()")
            lists.append(pads.map(ObjectIdentifier.init))
            states.append(contentsOf: pads.map(\.state))
            // 2 フレーム目の後に抜く。3 フレーム目からは同じ物が切断を名乗る
            if lists.count == 2 { hub.disconnected(controller) }
        }
        try run(frames: 4)
        #expect(lists.count == 4)
        #expect(lists.allSatisfy { $0.count == 1 && $0 == lists[0] })
        #expect(states == [.running, .running, .disconnected, .disconnected])
    }

    @Test("外して足し直したパッドは、一覧が同じ 1 台を返し続け、同じ機材のパッドが 2 つにならない (#3122)")
    func reattachedPadStaysTheOnlyPad() throws {
        let hub = GamepadHub(watches: false)
        let controller = GCController.withExtendedGamepad()
        hub.connected(controller)
        var original: Gamepad?
        var listed: [(frame: Int, pads: [Gamepad])] = []
        GamepadSketch.onSetup = { _ in }
        GamepadSketch.onDraw = { sketch in
            let roster = GamepadRoster.roster(for: sketch)
            switch sketch.frameCount {
            case 1:
                original = roster.gamepads(for: sketch, from: hub, calledAs: "gamepads()").first
            case 3:
                // 外してから足し直すまでの間は、一覧を呼ばない (外されたパッドは一覧が作り直す約束のまま)
                if let original { sketch.detach(original) }
            case 5:
                if let original { sketch.attach(original) }
            case 6, 7:
                listed.append(
                    (sketch.frameCount, roster.gamepads(for: sketch, from: hub, calledAs: "gamepads()")))
            default:
                break
            }
        }
        try run(frames: 7)
        let pad = try #require(original)
        #expect(listed.count == 2)
        for entry in listed {
            #expect(entry.pads.count == 1)
            #expect(entry.pads.first === pad, "足し直したパッドを返す。別の 1 台を作って足さない")
        }
        #expect(!pad.isClosed)
        #expect(pad.state == .running)
    }

    @Test("外す → 一覧 → 足し直す の順でも、同じ機材のパッドは 1 台で、足し直した側が戻り、一覧が代わりに作った側は外れる (#3122)")
    func reattachedPadReplacesTheOneTheRosterMadeInTheMeantime() throws {
        let hub = GamepadHub(watches: false)
        let controller = GCController.withExtendedGamepad()
        hub.connected(controller)
        var original: Gamepad?
        var replacement: Gamepad?
        var listed: [(frame: Int, pads: [Gamepad])] = []
        GamepadSketch.onSetup = { _ in }
        GamepadSketch.onDraw = { sketch in
            let roster = GamepadRoster.roster(for: sketch)
            switch sketch.frameCount {
            case 1:
                original = roster.gamepads(for: sketch, from: hub, calledAs: "gamepads()").first
            case 3:
                if let original { sketch.detach(original) }
            case 4:
                // 外されている間に一覧を呼ぶと、外されたものの代わりを作る (既存の約束)
                replacement = roster.gamepads(for: sketch, from: hub, calledAs: "gamepads()").first
            case 5:
                if let original { sketch.attach(original) }
            case 6, 7:
                listed.append(
                    (sketch.frameCount, roster.gamepads(for: sketch, from: hub, calledAs: "gamepads()")))
            default:
                break
            }
        }
        try run(frames: 7)
        let pad = try #require(original)
        let made = try #require(replacement)
        #expect(made !== pad, "外されている間の一覧は、外されたものを返さず作り直す")
        #expect(made.isClosed, "足し直した側が戻ったので、代わりに作った側は外れる")
        #expect(made.state == .stopped)
        #expect(!pad.isClosed)
        #expect(pad.state == .running)
        #expect(listed.count == 2)
        for entry in listed {
            #expect(entry.pads.count == 1)
            #expect(entry.pads.first === pad, "その機材の 1 台は、足し直した側")
        }
    }
}
