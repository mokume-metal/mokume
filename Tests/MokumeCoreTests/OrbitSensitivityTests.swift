// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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
    /// 決めた感度で `orbitControl` を呼び、効いていた視点を控える。
    final class Turning: Sketch {
        var sensitivity = SIMD3<Float>(1, 1, 1)
        var seen: Orbit?
        init() {}
        var settings: SketchSettings { SketchSettings(width: 64, height: 48) }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            orbitControl(sensitivity.x, sensitivity.y, sensitivity.z)
            seen = orbit
        }
    }

    /// 決めた感度で、入力を 1 フレームずつ流したあとの視点。
    private func orbit(sensitivity: SIMD3<Float>, after events: [InputEvent]) throws -> Orbit {
        let sketch = Turning()
        sketch.sensitivity = sensitivity
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 })
        for event in events {
            runtime.input.enqueue(event)
            try runtime.advance()
        }
        return try #require(sketch.seen)
    }

    /// 押して、横へ 30 画素引きずったあとの水平角。
    private func yaw(sensitivityX: Float) throws -> Float {
        try orbit(
            sensitivity: SIMD3(sensitivityX, 1, 1),
            after: [.mouseDown(x: 10, y: 24, button: .left), .mouseMoved(x: 40, y: 24)]
        ).yaw
    }

    /// 押して、縦へ 10 画素引きずったあとの仰角。
    private func pitch(sensitivity: SIMD3<Float>) throws -> Float {
        try orbit(
            sensitivity: sensitivity,
            after: [.mouseDown(x: 32, y: 14, button: .left), .mouseMoved(x: 32, y: 24)]
        ).pitch
    }

    /// 寄せるスクロールを 1 度送ったあとの距離の、始まりとの対数比。
    private func zoom(sensitivityZ: Float) throws -> Float {
        // 始まりも同じ口で採る (面の大きさから組む規則を、ここで写さない)
        let start = try orbit(
            sensitivity: SIMD3(1, 1, sensitivityZ), after: [.mouseMoved(x: 1, y: 1)]
        ).distance
        let moved = try orbit(
            sensitivity: SIMD3(1, 1, sensitivityZ), after: [.scrolled(dx: 0, dy: 2)])
        return log(moved.distance / start)
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

    /// **縦の感度は 2 つ目の引数で、横の感度は縦に掛からない。** 横だけで見ていた頃は、
    /// 縦に横の感度を掛けても緑のままだった (#2287)。
    @Test("縦の感度は縦にだけ効き、横の感度は縦に効かない")
    func verticalSensitivityIsItsOwn() throws {
        let plain = try pitch(sensitivity: SIMD3(1, 1, 1))
        try #require(plain != 0)
        let doubled = try pitch(sensitivity: SIMD3(1, 2, 1))
        #expect(abs(doubled - 2 * plain) < 1e-5, "感度 1 で \(plain)、縦 2 で \(doubled)")
        let sideways = try pitch(sensitivity: SIMD3(2, 1, 1))
        #expect(abs(sideways - plain) < 1e-5, "感度 1 で \(plain)、横 2 で \(sideways)")
    }

    @Test("寄りの感度 2 なら、同じスクロールで 2 倍寄る")
    func zoomSensitivityDoublesTheZoom() throws {
        let plain = try zoom(sensitivityZ: 1)
        try #require(plain != 0)
        let doubled = try zoom(sensitivityZ: 2)
        #expect(abs(doubled - 2 * plain) < 1e-4, "感度 1 で \(plain)、感度 2 で \(doubled)")
    }
}
