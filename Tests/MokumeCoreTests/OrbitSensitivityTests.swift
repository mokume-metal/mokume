// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// ``Sketch/orbitControl(_:_:_:)`` の感度の引数が、回る量に効くこと。GPU を要する。
///
/// 回す計算は ``Orbit`` にあり、`OrbitTests` と `OrbitControlTests` が固めている。
/// ただし**どちらも感度 1 でしか呼んでいない**ので、口が感度を渡し忘れても、横と縦の
/// 感度を取り違えても緑のままだった ([#1386](https://github.com/mokume-metal/mokume/issues/1386))。
///
/// 期待値は口の約束から導く — 「横に引きずったときの効き。負にすると回る向きが逆に
/// なる」。効きは掛け算なので、2 なら同じ手の動きで 2 倍回る。
@Suite(
    "視点を操る道具の感度",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct OrbitSensitivityTests {
    /// 決めた感度で `orbitControl` を呼び、効いていた水平角を控える。
    final class Turning: Sketch {
        var sensitivityX: Float = 1
        var seenYaw: Float?
        init() {}
        var settings: SketchSettings { SketchSettings(width: 64, height: 48) }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            orbitControl(sensitivityX)
            seenYaw = orbit.yaw
        }
    }

    /// 押して、横へ 30 画素引きずったあとの水平角。
    private func yaw(sensitivityX: Float) throws -> Float {
        let sketch = Turning()
        sketch.sensitivityX = sensitivityX
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 })
        runtime.input.enqueue(.mouseDown(x: 10, y: 24, button: 0))
        try runtime.advance()
        runtime.input.enqueue(.mouseMoved(x: 40, y: 24))
        try runtime.advance()
        return try #require(sketch.seenYaw)
    }

    @Test("感度 2 なら、同じ引きずりで 2 倍回る")
    func doubleSensitivityDoublesTheTurn() throws {
        let plain = try yaw(sensitivityX: 1)
        // 感度 1 で回っていなければ、比べても何も見ていない
        try #require(plain != 0)
        let doubled = try yaw(sensitivityX: 2)
        #expect(abs(doubled - 2 * plain) < 1e-5, "感度 1 で \(plain)、感度 2 で \(doubled)")
    }

    @Test("感度を負にすると、回る向きが逆になる")
    func negativeSensitivityTurnsTheOtherWay() throws {
        let plain = try yaw(sensitivityX: 1)
        try #require(plain != 0)
        let reversed = try yaw(sensitivityX: -1)
        #expect(abs(reversed + plain) < 1e-5, "感度 1 で \(plain)、感度 -1 で \(reversed)")
    }
}
