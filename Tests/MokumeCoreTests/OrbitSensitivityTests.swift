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

        /// `Float` へ写した後で使えない軸 (横・縦・寄り)。
        var unusableAxes: (x: Bool, y: Bool, z: Bool) {
            let s: SIMD3<Float> =
                switch self {
                case .float(let s): s
                case .double(let s): SIMD3(Float(s.x), Float(s.y), Float(s.z))
                }
            return (!s.x.isFinite, !s.y.isFinite, !s.z.isFinite)
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

    private func hasWarned(_ runtime: SketchRuntime, _ warning: Canvas.Warning) -> Bool {
        runtime.canvas.warnings.hasWarned(warning)
    }

    /// 使えない感度は**その軸だけ**効かせない。他の軸は、感度 1 のまま続けたときと同じに進む。
    @Test("感度が数でない・無限なら、その軸だけ効かず、他の軸は進み、注意が出る", arguments: Unusable.all)
    func unusableSensitivityHoldsOnlyItsAxis(_ unusable: Unusable) throws {
        let plainSketch = Turning()
        try feed(try makeRuntime(plainSketch), turnAndZoom + moreTurnAndZoom)
        let plain = try #require(plainSketch.seen)

        let sketch = Turning()
        let runtime = try makeRuntime(sketch)
        try feed(runtime, turnAndZoom)
        let before = try #require(sketch.seen)
        // 動かしてあることを先に確かめる。動いていなければ、下の比較は何も見ていない
        try #require(before.yaw != 0 && before.pitch != 0)
        try #require(plain.yaw != before.yaw && plain.pitch != before.pitch && plain.distance != before.distance)
        try #require(!hasWarned(runtime, .badOrbitSensitivity), "受け取れる感度で注意が出た")

        unusable.apply(to: sketch)
        try feed(runtime, moreTurnAndZoom)
        let after = try #require(sketch.seen)
        let held = unusable.unusableAxes

        #expect(after.yaw == (held.x ? before.yaw : plain.yaw), "水平角が \(before.yaw) から \(after.yaw)")
        #expect(after.pitch == (held.y ? before.pitch : plain.pitch), "仰角が \(before.pitch) から \(after.pitch)")
        #expect(
            after.distance == (held.z ? before.distance : plain.distance),
            "距離が \(before.distance) から \(after.distance)")
        #expect(after.yawSpeed.isFinite && after.pitchSpeed.isFinite)
        #expect(runtime.canvas.warnings.message(for: .badOrbitSensitivity)?.hasPrefix("orbitControl()") == true)
        // 感度の注意で足りる。溢れの注意を重ねない
        #expect(!hasWarned(runtime, .orbitStepHeld))
    }

    /// 有限の感度でも、引きずった量との積が溢れれば角が 0 へ倒れていた。
    @Test("有限の感度でも積が溢れた軸は進まず、角を 0 へ倒さず、注意が出る")
    func overflowingTurnHoldsTheAxis() throws {
        let sketch = Turning()
        let runtime = try makeRuntime(sketch)
        try feed(runtime, [.mouseDown(x: 10, y: 14, button: .left), .mouseMoved(x: 40, y: 24)])
        let before = try #require(sketch.seen)
        try #require(before.yaw != 0)

        // 1e37 × 40 画素は Float で溢れる
        sketch.sensitivity = SIMD3(1e37, 1, 1)
        try feed(runtime, [.mouseMoved(x: 80, y: 24)])
        let after = try #require(sketch.seen)

        #expect(after.yaw == before.yaw, "水平角が \(before.yaw) から \(after.yaw)")
        #expect(after.yawSpeed == 0)
        #expect(runtime.canvas.warnings.message(for: .orbitStepHeld)?.hasPrefix("orbitControl()") == true)
        #expect(!hasWarned(runtime, .badOrbitSensitivity))
    }

    /// 引きずり中に感度が使えなくなっても、非有限の速さが残って、離したあと毎フレーム
    /// 角を 0 へ戻すことはない。進めなかったフレームの速さは捨てる (止めてから離したのと同じ)。
    @Test("慣性があっても、感度が受け取れない間に非有限の速さが残らない")
    func unusableSensitivityLeavesNoUnusableSpeed() throws {
        let sketch = Turning()
        sketch.inertia = 0.9
        let runtime = try makeRuntime(sketch)
        try feed(runtime, [.mouseDown(x: 10, y: 14, button: .left), .mouseMoved(x: 40, y: 24)])
        let turned = try #require(sketch.seen)
        try #require(turned.yaw != 0 && turned.pitch != 0 && turned.inertia == 0.9)

        sketch.sensitivity = SIMD3(.nan, .nan, 1)
        try feed(runtime, [.mouseMoved(x: 60, y: 34)])
        sketch.sensitivity = SIMD3(1, 1, 1)
        try feed(
            runtime,
            [.mouseUp(x: 60, y: 34, button: .left), .mouseMoved(x: 61, y: 34), .mouseMoved(x: 62, y: 34)])
        let released = try #require(sketch.seen)

        #expect(released.yawSpeed.isFinite && released.pitchSpeed.isFinite)
        #expect(released.yaw == turned.yaw, "水平角が \(turned.yaw) から \(released.yaw)")
        #expect(released.pitch == turned.pitch, "仰角が \(turned.pitch) から \(released.pitch)")
    }

    /// 離したあとの流れは感度を使わないので、感度が使えなくても止めない。
    @Test("感度が受け取れなくても、離したあとの慣性の流れは止まらない")
    func unusableSensitivityKeepsTheCoast() throws {
        let sketch = Turning()
        sketch.inertia = 0.9
        let runtime = try makeRuntime(sketch)
        try feed(
            runtime,
            [.mouseDown(x: 10, y: 24, button: .left), .mouseMoved(x: 40, y: 24), .mouseUp(x: 40, y: 24, button: .left)])
        let released = try #require(sketch.seen)
        try #require(released.yawSpeed != 0)

        sketch.sensitivity = SIMD3(.nan, .nan, .nan)
        try feed(runtime, [.mouseMoved(x: 41, y: 24), .mouseMoved(x: 42, y: 24)])
        let coasted = try #require(sketch.seen)
        #expect(abs(coasted.yaw) > abs(released.yaw), "水平角が \(released.yaw) から \(coasted.yaw)")
    }

    /// 慣性 0 なら速さを毎フレーム捨てる。感度が使えないフレームでも捨てないと、あとで
    /// 慣性を上げた瞬間に、取っておいた速さで勝手に回り出す。
    @Test("感度が受け取れないフレームでも、慣性 0 なら速さを捨てる")
    func unusableSensitivityStillDropsTheSpeedWithoutInertia() throws {
        let sketch = Turning()
        let runtime = try makeRuntime(sketch)
        try feed(runtime, [.mouseDown(x: 10, y: 24, button: .left), .mouseMoved(x: 40, y: 24)])
        try #require(try #require(sketch.seen).yawSpeed != 0)

        sketch.sensitivity = SIMD3(.nan, .nan, .nan)
        try feed(runtime, [.mouseUp(x: 40, y: 24, button: .left)])
        let released = try #require(sketch.seen)

        sketch.sensitivity = SIMD3(1, 1, 1)
        sketch.inertia = 0.9
        try feed(runtime, [.mouseMoved(x: 41, y: 24)])
        let later = try #require(sketch.seen)
        #expect(later.yaw == released.yaw, "慣性を上げた瞬間に、水平角が \(released.yaw) から \(later.yaw) へ回った")
    }
}
