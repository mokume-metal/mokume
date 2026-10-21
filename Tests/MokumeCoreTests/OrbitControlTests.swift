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
        runtime.input.enqueue(.mouseDown(x: 60, y: 58, button: .left))
        try runtime.advance()

        #expect(try pixels(runtime) == before)
        #expect(sketch.seenOrbit?.yaw == beforeYaw)
    }

    // MARK: - 引きずると回る

    @Test("押したまま引きずると回り、離すと止まる")
    func draggingTurnsAndReleasingStops() throws {
        let sketch = Subject()
        let runtime = try makeRuntime(sketch)
        runtime.input.enqueue(.mouseDown(x: 32, y: 32, button: .left))
        try runtime.advance()
        let atPress = try pixels(runtime)

        runtime.input.enqueue(.mouseMoved(x: 62, y: 32))
        try runtime.advance()
        let turned = try #require(sketch.seenOrbit)
        #expect(turned.yaw < 0)
        #expect(try pixels(runtime) != atPress)

        // 離したあとは、慣性を入れていないので動かない
        runtime.input.enqueue(.mouseUp(x: 62, y: 32, button: .left))
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
            runtime.input.enqueue(.mouseDown(x: 10, y: 32, button: .left))
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
            runtime.input.enqueue(.mouseDown(x: 10, y: 32, button: .left))
            try runtime.advance()
            runtime.input.enqueue(.mouseMoved(x: 40, y: 32))
            try runtime.advance()
            return try #require(sketch.seenOrbit?.yaw)
        }

        #expect(try yaw(callsPerFrame: 1) == yaw(callsPerFrame: 2))
    }

    // MARK: - 右ドラッグ・⌥ ドラッグで平行移動 (#2461)

    /// 押して横へ 100 画素引きずった後の視点。`before` は押す前に流す出来事 (⌥ を押すなど)。
    private func orbitAfterDragging(
        _ button: MouseButton, before: [InputEvent] = []
    ) throws -> (start: Orbit, end: Orbit, moved: Bool) {
        let sketch = Subject()
        let runtime = try makeRuntime(sketch)
        for event in before { runtime.input.enqueue(event) }
        runtime.input.enqueue(.mouseDown(x: 10, y: 32, button: button))
        try runtime.advance()
        let start = try #require(sketch.seenOrbit)
        let atPress = try pixels(runtime)
        runtime.input.enqueue(.mouseMoved(x: 110, y: 32))
        try runtime.advance()
        return (start, try #require(sketch.seenOrbit), try pixels(runtime) != atPress)
    }

    /// 既定の視点では、注視点の奥行きの 1 画素が世界の 1 の長さになる (`Camera.fittingDistance`)。
    /// だから 100 画素は、画面の横 (世界の +x) の向きに 100 である。
    private func expectPannedLeft(_ start: Orbit, _ end: Orbit, _ label: String) {
        #expect(end.yaw == start.yaw, "\(label): 平行移動で回った (\(start.yaw) → \(end.yaw))")
        #expect(end.pitch == start.pitch, "\(label): 平行移動で傾いた")
        #expect(abs(end.center.x - (start.center.x - 100)) < 1e-3, "\(label): 注視点が左へ 100 動いていない: \(end.center)")
        #expect(abs(end.center.y - start.center.y) < 1e-3, "\(label): 注視点が縦に動いた")
        #expect(abs(end.center.z - start.center.z) < 1e-3, "\(label): 注視点が奥行きに動いた")
    }

    @Test("右ボタンで右へ 100 画素引くと、回らずに注視点が画面の左の向きへ 100 画素ぶん動く")
    func rightDragPans() throws {
        let (start, end, moved) = try orbitAfterDragging(.right)
        expectPannedLeft(start, end, "右ボタン")
        #expect(moved, "平行移動しても絵が変わらない")
    }

    @Test("⌥ を押したまま左ボタンで引いても、右ボタンと同じに動く")
    func optionLeftDragPans() throws {
        let (start, end, _) = try orbitAfterDragging(
            .left, before: [.keyDown(code: .option, characters: "", isRepeat: false)])
        expectPannedLeft(start, end, "⌥ + 左ボタン")
        let right = try orbitAfterDragging(.right)
        #expect(end == right.end)
    }

    @Test("⌥ を押さない左ボタンは、今までどおり 100 画素で −1 ラジアン回り、注視点は動かない")
    func plainLeftDragStillTurns() throws {
        let (start, end, _) = try orbitAfterDragging(.left)
        #expect(abs(end.yaw - (start.yaw - 100 * Orbit.radiansPerPixel)) < 1e-5)
        #expect(end.center == start.center)
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
        #expect(sketch.orbit == Orbit(center: Vector3(0, 0, 0), distance: 0))
        sketch.orbit = Orbit.fitting(width: 64, height: 64)
        #expect(sketch.orbit == Orbit(center: Vector3(0, 0, 0), distance: 0))
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
        runtime.input.enqueue(.mouseDown(x: 10, y: 10, button: .left))
        try runtime.advance()
        runtime.input.enqueue(.mouseMoved(x: 40, y: 30))
        try runtime.advance()

        #expect(sketch.projection == Camera.defaultOrthographic(width: 64, height: 64))
    }

    // MARK: - 書く口 (#2643)

    /// `orbit` を書いてから `orbitControl()` を呼ぶスケッチ。
    final class Writer: Sketch {
        var write: (inout Orbit) -> Void = { _ in }
        var seen: Orbit?
        init() {}
        var settings: SketchSettings { SketchSettings(width: 64, height: 48) }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            var value = orbit
            write(&value)
            orbit = value
            orbitControl()
            seen = orbit
        }
    }

    /// 書いた値と、倒れた先が正しいかの確かめ。
    private func written(_ write: @escaping (inout Orbit) -> Void) throws -> (Orbit, Canvas) {
        let sketch = Writer()
        sketch.write = write
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 })
        try runtime.advance()
        return (try #require(sketch.seen), runtime.canvas)
    }

    /// 既定へ倒すのは変えず、**倒したことを警告する** (ADR-0020 決定 5)。
    @Test("収めようのない値を書くと、既定へ倒して注意が出る")
    func writingUnusableValuesWarns() throws {
        let cases: [(String, (inout Orbit) -> Void, (Orbit) -> Bool)] = [
            ("yaw = .nan", { $0.yaw = .nan }, { $0.yaw == 0 }),
            ("pitch = .infinity", { $0.pitch = .infinity }, { $0.pitch == 0 }),
            ("distance = .nan", { $0.distance = .nan }, { $0.distance == $0.minimumDistance }),
            ("minimumDistance = .nan", { $0.minimumDistance = .nan }, { $0.minimumDistance == 1 }),
            ("inertia = .nan", { $0.inertia = .nan }, { $0.inertia == 0 }),
            // 見ている先は、道具の始まりと同じ面の中央へ倒す
            ("center = (.nan, 0, 0)", { $0.center = Vector3(Float.nan, 0, 0) }, { $0.center == Vector3(32, 24, 0) }),
            (
                "Orbit.fitting(width: .nan, height: 48)", { $0 = Orbit.fitting(width: Float.nan, height: 48) },
                { $0.center == Vector3(32, 24, 0) }
            ),
        ]
        for (name, write, fellBack) in cases {
            let (orbit, canvas) = try written(write)
            #expect(fellBack(orbit), "\(name) の後が \(orbit)")
            #expect(canvas.warnings.message(for: .badOrbit)?.hasPrefix("orbit:") == true, "\(name) で注意が出ない")
            // 倒した先は視点として成り立つ (呼んでもいない camera() の文面で断られない)
            #expect(!canvas.warnings.hasWarned(.badCamera), "\(name) で視点が成り立たなかった")
        }
    }

    @Test("限界の外を書いても、収めるだけなら注意は出ない")
    func writingOutOfRangeValuesDoesNotWarn() throws {
        let (orbit, canvas) = try written {
            $0.pitch = 10
            $0.distance = 1e9
        }
        #expect(orbit.pitch == Orbit.pitchLimit)
        #expect(orbit.distance == orbit.maximumDistance)
        #expect(!canvas.warnings.hasWarned(.badOrbit))
    }
}
