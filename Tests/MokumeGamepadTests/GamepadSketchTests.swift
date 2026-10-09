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
                seen.append("\(pad.leftStick) \(pad.isPressed(.a)) \(pad.state)")
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

    @Test("一覧は毎フレーム呼んでも同じ物を返し、走っているスケッチに 1 度だけ足す")
    func listReturnsTheSamePads() throws {
        let hub = GamepadHub(watches: false)
        let controller = GCController.withExtendedGamepad()
        hub.connected(controller)
        var lists: [[ObjectIdentifier]] = []
        var states: [SourceState] = []
        GamepadSketch.onSetup = { _ in }
        GamepadSketch.onDraw = { sketch in
            let pads = GamepadRoster.roster(for: sketch).gamepads(for: sketch, from: hub)
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
}
