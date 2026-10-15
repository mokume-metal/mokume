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
        /// 置けば、`sensitivity` の代わりに `Double` で渡す。
        var doubles: SIMD3<Double>?
        /// 置けば、次のフレームの頭で慣性に書く (1 度だけ)。
        var inertia: Float?
        /// 同じフレームで、続けて既定の感度でも呼ぶ。
        var thenPlain = false
        var seen: Orbit?
        init() {}
        var settings: SketchSettings { SketchSettings(width: 64, height: 48) }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            if let inertia {
                orbit.inertia = inertia
                self.inertia = nil
            }
            if let doubles {
                orbitControl(doubles.x, doubles.y, doubles.z)
            } else {
                orbitControl(sensitivity.x, sensitivity.y, sensitivity.z)
            }
            if thenPlain { orbitControl() }
            seen = orbit
        }
    }

    private func makeRuntime(_ sketch: Turning) throws -> SketchRuntime {
        try SketchRuntime(sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 })
    }

    /// 入力を 1 件ずつ、1 フレームずつ流す。
    private func feed(_ runtime: SketchRuntime, _ events: [InputEvent]) throws {
        for event in events {
            runtime.input.enqueue(event)
            try runtime.advance()
        }
    }

    /// 決めた感度で、入力を 1 フレームずつ流したあとの視点。
    private func orbit(sensitivity: SIMD3<Float>, after events: [InputEvent]) throws -> Orbit {
        let sketch = Turning()
        sketch.sensitivity = sensitivity
        try feed(try makeRuntime(sketch), events)
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

    // MARK: - 数でない・無限の感度 (#2643)

    /// 受け取れない感度の渡し方。`Float` と `Double` の両方の受け口を通す (#2644 で
    /// `some ScalarConvertible` になった)。
    nonisolated enum Unusable: Sendable, CustomTestStringConvertible {
        case float(SIMD3<Float>)
        case double(SIMD3<Double>)

        var testDescription: String {
            switch self {
            case .float(let s): "Float (\(s.x), \(s.y), \(s.z))"
            case .double(let s): "Double (\(s.x), \(s.y), \(s.z))"
            }
        }

        @MainActor func apply(to sketch: Turning) {
            switch self {
            case .float(let s): sketch.sensitivity = s
            case .double(let s): sketch.doubles = s
            }
        }

        static let all: [Unusable] = [
            .float(SIMD3(.nan, 1, 1)), .float(SIMD3(1, .infinity, 1)), .float(SIMD3(1, 1, -.infinity)),
            .double(SIMD3(.nan, 1, 1)), .double(SIMD3(1, .infinity, 1)),
            .double(SIMD3(1, 1, -.infinity)),
            // `Float` へ写すと無限になる有限の `Double`
            .double(SIMD3(1, 1, 1e300)),
        ]
    }

    /// 感度 1 で回して寄せる入力。始まりの視点 (角 0) から動かしておかないと、角を 0 へ
    /// 倒されても「動かなかった」と見分けが付かない。
    private let turnAndZoom: [InputEvent] = [
        .mouseDown(x: 10, y: 14, button: .left), .mouseMoved(x: 40, y: 24),
        .scrolled(dx: 0, dy: 2),
    ]
    /// 続けて引きずり、寄せる入力。
    private let moreTurnAndZoom: [InputEvent] = [
        .mouseMoved(x: 50, y: 34), .scrolled(dx: 0, dy: 2),
    ]

    @Test("感度が数でない・無限なら、引きずっても寄せても視点が進まず、注意が出る", arguments: Unusable.all)
    func unusableSensitivityLeavesTheView(_ unusable: Unusable) throws {
        let sketch = Turning()
        let runtime = try makeRuntime(sketch)
        try feed(runtime, turnAndZoom)
        let before = try #require(sketch.seen)
        // 動かしてあることを先に確かめる。動いていなければ、下の比較は何も見ていない
        try #require(before.yaw != 0 && before.pitch != 0)
        try #require(!runtime.canvas.warnings.hasWarned(.badOrbitSensitivity), "受け取れる感度で注意が出た")

        unusable.apply(to: sketch)
        try feed(runtime, moreTurnAndZoom)
        let after = try #require(sketch.seen)

        #expect(after == before, "進まないはずの視点が \(before) から \(after) へ動いた")
        #expect(
            runtime.canvas.warnings.message(for: .badOrbitSensitivity)?.hasPrefix("orbitControl()") == true)
    }

    /// 進めなかった呼び出しは引きずった量を食わない — 同じフレームで受け取れる感度で
    /// 呼び直せば、そちらが食う。
    @Test("感度が受け取れない呼び出しは、引きずった量を食わない")
    func unusableCallLeavesTheDragForTheNext() throws {
        let plain = try orbit(
            sensitivity: SIMD3(1, 1, 1),
            after: [.mouseDown(x: 10, y: 24, button: .left), .mouseMoved(x: 40, y: 24)])
        try #require(plain.yaw != 0)

        let sketch = Turning()
        sketch.sensitivity = SIMD3(.nan, 1, 1)
        sketch.thenPlain = true
        try feed(
            try makeRuntime(sketch),
            [.mouseDown(x: 10, y: 24, button: .left), .mouseMoved(x: 40, y: 24)])
        let retried = try #require(sketch.seen)
        #expect(retried == plain, "呼び直しで \(retried)、1 度だけ呼んで \(plain)")
    }

    /// 慣性があると、非有限の速さが残れば離したあとも毎フレーム角を 0 へ戻す。
    @Test("慣性があっても、感度が受け取れない間に非有限の速さが残らない")
    func unusableSensitivityLeavesNoUnusableSpeed() throws {
        let sketch = Turning()
        sketch.inertia = 0.9
        let runtime = try makeRuntime(sketch)
        try feed(runtime, [.mouseDown(x: 10, y: 14, button: .left), .mouseMoved(x: 40, y: 24)])
        let turned = try #require(sketch.seen)
        try #require(turned.yaw != 0 && turned.inertia == 0.9)

        sketch.sensitivity = SIMD3(.nan, .nan, 1)
        try feed(runtime, [.mouseMoved(x: 60, y: 34)])
        sketch.sensitivity = SIMD3(1, 1, 1)
        try feed(
            runtime,
            [.mouseUp(x: 60, y: 34, button: .left), .mouseMoved(x: 61, y: 34), .mouseMoved(x: 62, y: 34)])
        let drifted = try #require(sketch.seen)

        #expect(drifted.yawSpeed.isFinite && drifted.pitchSpeed.isFinite, "速さが \(drifted.yawSpeed), \(drifted.pitchSpeed)")
        // 離したあとは、引きずっていた向きへ流れ続ける (0 へ戻されない)
        #expect(drifted.yaw.isFinite && abs(drifted.yaw) > abs(turned.yaw), "水平角が \(turned.yaw) から \(drifted.yaw)")
    }
}
