// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 引きずって回す道具を、**入力から絵まで通して**見る検査。GPU を要する。
///
/// 計算そのものは ``OrbitTests`` が固めている。ここで見るのは、合流点から読んだ量が
/// 視点になって絵に出るところ — 取りこぼしと重複はこの継ぎ目で起きる。
@Suite(
    "視点を操る道具",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct OrbitControlTests {

    /// 回すと見え方が変わる形を 1 つ置くだけのスケッチ。
    final class Subject: Sketch {
        /// `orbitControl()` を 1 フレームに何回呼ぶか。
        var callsPerFrame = 1
        /// 呼ばない (比較のため)。
        var usesOrbit = true
        /// 直近のフレームで効いていた視点。
        var seenOrbit: Orbit?

        init() {}
        var settings: SketchSettings { SketchSettings(width: 64, height: 64) }

        func draw() {
            background(.display(red: 0.05, green: 0.06, blue: 0.08))
            if usesOrbit {
                for _ in 0..<callsPerFrame { orbitControl() }
                seenOrbit = orbit
            }
            lights()
            noStroke()
            fill(.display(red: 0.95, green: 0.55, blue: 0.3))
            push()
            translate(width / 2, height / 2, 0)
            box(30, 30, 30)
            pop()
        }
    }

    private func makeRuntime(_ sketch: Subject) throws -> SketchRuntime {
        try SketchRuntime(sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 })
    }

    private func pixels(_ runtime: SketchRuntime) throws -> [UInt8] {
        try runtime.target.encodeForDisplay().bytes
    }

    // MARK: - 足しただけでは動かない

    @Test("orbitControl() を足しただけでは、絵が変わらない")
    func addingOrbitControlDoesNotMoveThePicture() throws {
        // 始まりが既定の視点と違うと、道具を足した瞬間に絵が飛ぶ
        let plain = Subject()
        plain.usesOrbit = false
        let plainRuntime = try makeRuntime(plain)
        try plainRuntime.advance()

        let orbiting = Subject()
        let orbitingRuntime = try makeRuntime(orbiting)
        try orbitingRuntime.advance()

        #expect(try pixels(plainRuntime) == pixels(orbitingRuntime))
    }

    // MARK: - 押しただけでは動かない

    @Test("押した瞬間には、カメラが動かない")
    func pressingDoesNotMoveTheCamera() throws {
        let sketch = Subject()
        let runtime = try makeRuntime(sketch)
        // まず離れた場所へカーソルを置く
        runtime.input.enqueue(.mouseMoved(x: 4, y: 4))
        try runtime.advance()
        let before = try pixels(runtime)
        let beforeYaw = try #require(sketch.seenOrbit?.yaw)

        // 遠く離れた場所で押す。位置の差 (mouseX - pmouseX) は大きいが、押下は移動ではない
        runtime.input.enqueue(.mouseDown(x: 60, y: 58, button: 0))
        try runtime.advance()

        #expect(try pixels(runtime) == before)
        #expect(sketch.seenOrbit?.yaw == beforeYaw)
    }

    // MARK: - 引きずると回る

    @Test("押したまま引きずると回り、離すと止まる")
    func draggingTurnsAndReleasingStops() throws {
        let sketch = Subject()
        let runtime = try makeRuntime(sketch)
        runtime.input.enqueue(.mouseDown(x: 32, y: 32, button: 0))
        try runtime.advance()
        let atPress = try pixels(runtime)

        runtime.input.enqueue(.mouseMoved(x: 62, y: 32))
        try runtime.advance()
        let turned = try #require(sketch.seenOrbit)
        #expect(turned.yaw < 0)
        #expect(try pixels(runtime) != atPress)

        // 離したあとは、慣性を入れていないので動かない
        runtime.input.enqueue(.mouseUp(x: 62, y: 32, button: 0))
        try runtime.advance()
        let afterRelease = try pixels(runtime)
        try runtime.advance()
        #expect(try pixels(runtime) == afterRelease)
    }

    @Test("1 フレームにまとめて届いた移動も、全部積まれる")
    func movementsThatArriveTogetherAllCount() throws {
        func yaw(splitInto steps: Int) throws -> Float {
            let sketch = Subject()
            let runtime = try makeRuntime(sketch)
            runtime.input.enqueue(.mouseDown(x: 10, y: 32, button: 0))
            try runtime.advance()
            // 同じ 30 px を、1 フレームでまとめて / 複数フレームに分けて送る
            let stride = Float(30) / Float(steps)
            for index in 1...steps {
                runtime.input.enqueue(.mouseMoved(x: 10 + stride * Float(index), y: 32))
                if steps == 1 || index % max(1, steps / 3) == 0 { try runtime.advance() }
            }
            try runtime.advance()
            return try #require(sketch.seenOrbit?.yaw)
        }

        #expect(try abs(yaw(splitInto: 1) - yaw(splitInto: 6)) < 1e-5)
    }

    @Test("1 フレームに 2 回呼んでも、2 倍回らない")
    func callingTwiceInAFrameDoesNotDoubleTheTurn() throws {
        func yaw(callsPerFrame: Int) throws -> Float {
            let sketch = Subject()
            sketch.callsPerFrame = callsPerFrame
            let runtime = try makeRuntime(sketch)
            runtime.input.enqueue(.mouseDown(x: 10, y: 32, button: 0))
            try runtime.advance()
            runtime.input.enqueue(.mouseMoved(x: 40, y: 32))
            try runtime.advance()
            return try #require(sketch.seenOrbit?.yaw)
        }

        #expect(try yaw(callsPerFrame: 1) == yaw(callsPerFrame: 2))
    }

    // MARK: - 寄る

    @Test("スクロールすると寄り、絵が変わる")
    func scrollingZoomsIn() throws {
        let sketch = Subject()
        let runtime = try makeRuntime(sketch)
        try runtime.advance()
        let before = try pixels(runtime)
        let startDistance = try #require(sketch.seenOrbit?.distance)

        runtime.input.enqueue(.scrolled(dx: 0, dy: 6))
        try runtime.advance()

        #expect(try #require(sketch.seenOrbit?.distance) < startDistance)
        #expect(try pixels(runtime) != before)
    }

    // MARK: - 手で置く

    @Test("手で書いた視点が効き、限界へ収められる")
    func handWrittenOrbitTakesEffect() throws {
        let sketch = Subject()
        let runtime = try makeRuntime(sketch)
        try runtime.advance()
        let before = try pixels(runtime)

        runtime.orbit = {
            var orbit = Orbit.fitting(width: 64, height: 64)
            orbit.yaw = 0.8
            orbit.pitch = 99  // 限界の外
            return orbit
        }()
        try runtime.advance()

        let seen = try #require(sketch.seenOrbit)
        #expect(abs(seen.yaw - 0.8) < 1e-6)
        #expect(seen.pitch == Orbit.pitchLimit)
        #expect(try pixels(runtime) != before)
    }

    @Test("走っていなければ、読んでも空が返り、書いても落ちない")
    func readingOutsideARuntimeIsSafe() {
        let sketch = Subject()
        #expect(sketch.orbit == Orbit(center: .zero, distance: 0))
        sketch.orbit = Orbit.fitting(width: 64, height: 64)
        #expect(sketch.orbit == Orbit(center: .zero, distance: 0))
    }

    // MARK: - 投影を書き換えない

    @Test("視点を操っても、投影は書き換わらない")
    func orbitingKeepsTheProjection() throws {
        final class Ortho: Sketch {
            var projection: Camera.Projection?
            init() {}
            var settings: SketchSettings { SketchSettings(width: 64, height: 64) }
            func draw() {
                background(.display(red: 0, green: 0, blue: 0))
                ortho()
                orbitControl()
                projection = canvas.currentCamera.projection
            }
        }
        let sketch = Ortho()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 })
        runtime.input.enqueue(.mouseDown(x: 10, y: 10, button: 0))
        try runtime.advance()
        runtime.input.enqueue(.mouseMoved(x: 40, y: 30))
        try runtime.advance()

        #expect(sketch.projection == Camera.defaultOrthographic(width: 64, height: 64))
    }
}
