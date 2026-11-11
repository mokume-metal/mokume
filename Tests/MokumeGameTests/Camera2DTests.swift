// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore
@testable import MokumeGame

/// 画面の幅を直に渡して、追い方と座標の変換を値で確かめる (#3590)。ウィンドウも GPU も要らない。
struct Camera2DTableTests {
    /// 面の幅 1920・画面の幅 480 のカメラで、相手の x を `targetX` にして追った後の ``Camera2D/x``。
    private func cameraX(following targetX: Float, worldWidth: Float = 1920, screenWidth: Float = 480) -> Float {
        var camera = Camera2D(worldWidth: worldWidth)
        camera.track(Vector2(targetX, 100), screenWidth: screenWidth)
        return camera.x
    }

    @Test("作った直後のカメラの x は 0")
    func startsAtTheLeftEdge() {
        #expect(Camera2D(worldWidth: 1920).x == 0)
    }

    @Test(
        "相手の x が 240 以下なら 0、240 を越えると 相手の x − 240、1680 を越えても 1440 で止まる",
        arguments: [
            (Float(0), Float(0)), (100, 0), (240, 0), (241, 1), (840, 600), (1000, 760), (1680, 1440),
            (1681, 1440), (1920, 1440), (5000, 1440), (-300, 0),
        ] as [(Float, Float)])
    func followsPastTheMiddleAndStopsAtTheEdges(targetX: Float, expected: Float) {
        #expect(cameraX(following: targetX) == expected)
    }

    @Test("相手が端から端へ動いても、カメラの x は常に 0〜1440 に収まる")
    func staysWithinTheWorld() {
        var camera = Camera2D(worldWidth: 1920)
        for step in stride(from: Float(-500), through: 2500, by: 7) {
            camera.track(Vector2(step, 0), screenWidth: 480)
            #expect((0...1440).contains(camera.x), "相手の x \(step)")
        }
    }

    @Test(
        "相手の位置が有限でなくても、カメラの x は 0〜1440 に収まる",
        arguments: [(Float.infinity, Float(1440)), (-Float.infinity, 0), (Float.nan, 0)] as [(Float, Float)])
    func nonFiniteTargetsStayWithinTheWorld(targetX: Float, expected: Float) {
        #expect(cameraX(following: targetX) == expected)
    }

    @Test("面が画面より狭い・同じ幅なら、カメラは 0 のまま動かない", arguments: [Float(300), 480])
    func aWorldNoWiderThanTheScreenNeverScrolls(worldWidth: Float) {
        for targetX in [Float(0), 240, 400, 1000] {
            #expect(cameraX(following: targetX, worldWidth: worldWidth) == 0)
        }
    }

    @Test("プレイヤーの中心 x = 840 を追ってカメラの x が 600 のとき、画面の (100, 50) は世界の (700, 50)、世界の (700, 50) は画面の (100, 50)")
    func convertsBetweenScreenAndWorld() {
        var camera = Camera2D(worldWidth: 1920)
        camera.track(Rect(center: Vector2(840, 50), width: 32, height: 32).center, screenWidth: 480)
        #expect(camera.x == 600)
        #expect(camera.toWorld(Vector2(100, 50)) == Vector2(700, 50))
        #expect(camera.toScreen(Vector2(700, 50)) == Vector2(100, 50))
    }

    @Test("変換は行って戻ると元の点に戻り、カメラが動いていなければ同じ点")
    func conversionsRoundTrip() {
        let still = Camera2D(worldWidth: 1920)
        #expect(still.toWorld(Vector2(100, 50)) == Vector2(100, 50))
        var camera = Camera2D(worldWidth: 1920)
        camera.track(Vector2(1000, 0), screenWidth: 480)
        let point = Vector2(123, -45)
        #expect(camera.toScreen(camera.toWorld(point)) == point)
        #expect(camera.toWorld(camera.toScreen(point)) == point)
    }

    @Test("カメラは隔離の外からも作れ、変換できる")
    func cameraCanBeUsedOutsideTheMainActor() async {
        let world = await Task.detached { Camera2D(worldWidth: 1920).toWorld(Vector2(1, 2)) }.value
        #expect(world == Vector2(1, 2))
    }
}

/// `Camera2D` を走っているスケッチの中で回す (#3590)。GPU を要する。
///
/// 画面の幅はスケッチの `width` (480) から読む。フレームの時計に注入した右矢印で相手を動かし、各フレームの
/// カメラの x を見る。2 回流しても同じ。
@Suite(
    "カメラの追従 (走っているスケッチ)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct Camera2DSketchTests {
    /// 右矢印を押している間、相手を右へ動かし、カメラで追う横スクロール。
    final class Runner: Sketch {
        var camera = Camera2D(worldWidth: 1920)
        var player = Rect(left: 0, top: 0, width: 32, height: 16)
        /// 各フレームで追った (相手の中心の x, カメラの x)。
        nonisolated(unsafe) static var seen: [(center: Float, camera: Float)] = []
        init() {}
        var settings: SketchSettings { SketchSettings(width: 480, height: 16, clock: .frames) }
        func draw() {
            if keyboard.isPressed(.arrowRight) { player.left += 1800 * deltaTime }
            if keyboard.isPressed(.arrowLeft) { player.left -= 1800 * deltaTime }
            camera.follow(player.center)
            Self.seen.append((player.center.x, camera.x))
            background(0, 0, 0)
            translate(-camera.x, 0)
            player.draw()
        }
    }

    private static func key(_ code: Key, down: Bool, _ characters: String) -> InputEvent {
        down ? .keyDown(code: code, characters: characters, isRepeat: false) : .keyUp(code: code)
    }

    /// フレーム 1〜`frames` を流す。`inputs` のフレームの頭で、その入力を注入する。
    private func play(frames: Int, inputs: [Int: [InputEvent]]) throws -> [(center: Float, camera: Float)] {
        Runner.seen = []
        let runtime = try SketchRuntime(
            sketch: Runner(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 })
        for frame in 1...frames {
            for event in inputs[frame] ?? [] { runtime.input.enqueue(event) }
            try runtime.advance()
        }
        return Runner.seen
    }

    /// 右へ 60 フレーム走り、少し戻る入力の列。
    private static let rightThenBack: [Int: [InputEvent]] = [
        1: [key(.arrowRight, down: true, "\u{F703}")],
        61: [key(.arrowRight, down: false, "\u{F703}"), key(.arrowLeft, down: true, "\u{F702}")],
        70: [key(.arrowLeft, down: false, "\u{F702}")],
    ]

    @Test("画面の幅を width (480) から読み、中央を越えたら追い、面の端 (1440) で止まる")
    func followsWithTheSketchWidth() throws {
        let seen = try play(frames: 72, inputs: Self.rightThenBack)
        #expect(seen.count == 72)
        for (frame, step) in seen.enumerated() {
            let expected = min(1440, max(0, step.center - 240))
            #expect(step.camera == expected, "フレーム \(frame + 1): 相手の x \(step.center)")
        }
        #expect(seen.prefix(5).allSatisfy { $0.camera == 0 }, "走り出しは中央の手前で 0")
        #expect(seen[59].camera == 1440, "右端まで走ると 1440 で止まる")
        #expect(seen[59].center > 1680)
        #expect(seen[71].camera < 1440, "戻ると、また追う")
    }

    @Test("同じ入力を 2 回流すと、各フレームのカメラの x が一致する")
    func theSameInputsGiveTheSameCamera() throws {
        let first = try play(frames: 72, inputs: Self.rightThenBack)
        let second = try play(frames: 72, inputs: Self.rightThenBack)
        #expect(first.count == 72)
        #expect(first.map(\.camera) == second.map(\.camera))
        #expect(Set(first.map(\.camera)).count > 10, "動かないカメラどうしを比べて一致させていない")
    }

    @Test("陰性対照: 入力が無ければ、カメラは 0 のまま")
    func withoutInputTheCameraStays() throws {
        let seen = try play(frames: 10, inputs: [:])
        #expect(seen.map(\.camera) == Array(repeating: 0, count: 10))
    }
}
