// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore
@testable import MokumeGame

/// 刻みを直に渡して、重力・接地・めり込みの解消を値で確かめる (#3589)。ウィンドウも GPU も要らない。
///
/// 刻みは `clock: .frames` の 60 fps と同じ 1/60 秒。
struct ArcadeBodyTableTests {
    private static let dt: Float = 1.0 / 60
    private static let gravity = Vector2(0, 900)
    /// 完了条件の足場。上面は y = 200。
    private static let floor = Rect(left: 0, top: 200, width: 480, height: 20)

    @Test("作った直後は、渡した矩形の位置で、速さ 0・接地は偽")
    func startsAtRest() {
        let body = ArcadeBody(Rect(left: 40, top: 100, width: 16, height: 24))
        #expect(body.rect == Rect(left: 40, top: 100, width: 16, height: 24))
        #expect(body.velocity == Vector2(0, 0))
        #expect(!body.isOnFloor)
    }

    @Test("足場の上に置いた体は、何も押さずに 120 歩進めても y が変わらず、接地は真のまま")
    func restsOnTheFloor() {
        var body = ArcadeBody(Rect(left: 40, top: 176, width: 16, height: 24))
        for step in 1...120 {
            body.advance(by: Self.dt, gravity: Self.gravity, solids: [Self.floor])
            #expect(body.rect.top == 176, "歩 \(step)")
            #expect(body.isOnFloor, "歩 \(step)")
            #expect(body.velocity == Vector2(0, 0), "歩 \(step)")
        }
    }

    @Test("足場より上の体は、重力で速さが増しながら落ち、上面で止まって接地が真になる。めり込まない")
    func fallsAndLandsOnTheFloor() {
        var body = ArcadeBody(Rect(left: 40, top: 100, width: 16, height: 24))
        var previousSpeed: Float = 0
        var landedAt: Int?
        for step in 1...120 {
            body.advance(by: Self.dt, gravity: Self.gravity, solids: [Self.floor])
            #expect(body.rect.bottom <= 200, "歩 \(step): めり込まない")
            if landedAt == nil {
                if body.isOnFloor {
                    landedAt = step
                } else {
                    #expect(body.velocity.y > previousSpeed, "歩 \(step): 落ちる速さが増す")
                    previousSpeed = body.velocity.y
                }
            }
        }
        #expect(landedAt.map { $0 > 1 } == true, "落ちてから着地する: \(String(describing: landedAt))")
        #expect(body.rect.top == 176, "上面 200 に足が乗る")
        #expect(body.isOnFloor)
        #expect(body.velocity.y == 0)
    }

    @Test("壁へ向けて速さを与え続けても、壁の手前で止まる (めり込まない)", arguments: [Float(120), -120])
    func stopsAtAWall(speed: Float) {
        let wall = speed > 0
            ? Rect(left: 300, top: 100, width: 20, height: 100)
            : Rect(left: 0, top: 100, width: 20, height: 100)
        var body = ArcadeBody(Rect(left: 150, top: 176, width: 16, height: 24))
        for step in 1...240 {
            body.velocity.x = speed
            body.advance(by: Self.dt, gravity: Self.gravity, solids: [Self.floor, wall])
            // 接するのは止まった姿 (intersects は接しても真なので、めり込みは辺の位置で見る)
            #expect(speed > 0 ? body.rect.right <= 300 : body.rect.left >= 20, "歩 \(step)")
        }
        #expect(speed > 0 ? body.rect.right == 300 : body.rect.left == 20, "壁に接して止まる")
        #expect(body.velocity.x == 0)
        #expect(body.isOnFloor, "壁の前でも足場に立ったまま")
    }

    @Test("1 歩で通り過ぎるほど速くても、薄い壁と足場を越えない")
    func fastBodiesDoNotTunnel() {
        let thinWall = Rect(left: 300, top: 100, width: 2, height: 100)
        var runner = ArcadeBody(Rect(left: 150, top: 176, width: 16, height: 24))
        runner.velocity.x = 60_000  // 1 歩で 1000 進む
        runner.advance(by: Self.dt, gravity: Self.gravity, solids: [Self.floor, thinWall])
        #expect(runner.rect.right == 300)

        let thinFloor = Rect(left: 0, top: 200, width: 480, height: 1)
        var faller = ArcadeBody(Rect(left: 40, top: 0, width: 16, height: 24))
        faller.velocity.y = 60_000
        faller.advance(by: Self.dt, gravity: Self.gravity, solids: [thinFloor])
        #expect(faller.rect.bottom == 200)
        #expect(faller.isOnFloor)
    }

    @Test("立っているときに上向きの速さを与えると跳び、空中では接地が偽。天井に頭を打つと止まる")
    func jumpsOnlyFromTheFloorAndHitsTheCeiling() {
        let ceiling = Rect(left: 0, top: 100, width: 480, height: 10)
        var body = ArcadeBody(Rect(left: 40, top: 176, width: 16, height: 24))
        body.advance(by: Self.dt, gravity: Self.gravity, solids: [Self.floor, ceiling])
        #expect(body.isOnFloor)
        // 作例の書き方: 跳べるのは立っているときだけ
        func press(_ body: inout ArcadeBody) { if body.isOnFloor { body.velocity.y = -600 } }
        press(&body)
        body.advance(by: Self.dt, gravity: Self.gravity, solids: [Self.floor, ceiling])
        #expect(!body.isOnFloor, "跳んだ歩は空中")
        let rising = body.velocity.y
        #expect(rising < 0)
        press(&body)  // 空中でもう一度押しても
        #expect(body.velocity.y == rising, "上向きの速さは増えない")
        for _ in 1...30 { body.advance(by: Self.dt, gravity: Self.gravity, solids: [Self.floor, ceiling]) }
        #expect(body.rect.top >= 110, "天井の下面 110 を越えない")
    }

    @Test("同じ高さに並べた足場の継ぎ目で引っかからずに歩いて移れる")
    func walksAcrossTileSeams() {
        let tiles = (0..<6).map { Rect(left: Float($0) * 80, top: 200, width: 80, height: 20) }
        var body = ArcadeBody(Rect(left: 10, top: 176, width: 16, height: 24))
        for _ in 1...120 {
            body.velocity.x = 120
            body.advance(by: Self.dt, gravity: Self.gravity, solids: tiles)
            #expect(body.isOnFloor)
            #expect(body.rect.top == 176)
        }
        #expect(body.rect.left > 200, "継ぎ目を 2 つ以上越えた")
    }

    @Test("足場の端から歩き出ると、接地が偽になって落ちる")
    func walksOffALedge() {
        let ledge = Rect(left: 0, top: 200, width: 100, height: 20)
        var body = ArcadeBody(Rect(left: 60, top: 176, width: 16, height: 24))
        for _ in 1...60 {
            body.velocity.x = 120
            body.advance(by: Self.dt, gravity: Self.gravity, solids: [ledge])
        }
        #expect(!body.isOnFloor)
        #expect(body.rect.top > 176)
    }

    @Test("刻みが 0 なら動かず、立っていれば接地は真のまま")
    func aZeroStepDoesNotMove() {
        var body = ArcadeBody(Rect(left: 40, top: 176, width: 16, height: 24))
        body.velocity.x = 120
        body.advance(by: 0, gravity: Self.gravity, solids: [Self.floor])
        #expect(body.rect.left == 40 && body.rect.top == 176)
        #expect(body.isOnFloor)
    }

    @Test("体は隔離の外からも作れる")
    func bodyCanBeCreatedOutsideTheMainActor() async {
        let body = await Task.detached { ArcadeBody(Rect(left: 1, top: 2, width: 3, height: 4)) }.value
        #expect(body.rect.left == 1)
    }
}

/// `ArcadeBody` を走っているスケッチの中で回す (#3589)。GPU を要する。
///
/// 刻みはスケッチの `deltaTime` から読む。フレームの時計に注入した入力で、2 回流しても各歩の位置と速さが同じ。
@Suite(
    "アーケード物理 (走っているスケッチ)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ArcadeBodySketchTests {
    /// 作例どおり: 矢印で左右に歩き、スペースで跳ぶ。
    final class Platformer: Sketch {
        var player = ArcadeBody(Rect(left: 40, top: 100, width: 16, height: 24))
        let solids: [Rect] = [
            Rect(left: 0, top: 200, width: 480, height: 20),
            Rect(left: 300, top: 120, width: 20, height: 80),
        ]
        /// 各歩の後の (位置, 速さ, 接地)。
        nonisolated(unsafe) static var seen: [(position: Vector2, velocity: Vector2, onFloor: Bool)] = []
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, clock: .frames) }
        func draw() {
            player.velocity.x = keyboard.isPressed(.arrowRight) ? 120 : keyboard.isPressed(.arrowLeft) ? -120 : 0
            if keyboard.justPressed(.space) && player.isOnFloor { player.velocity.y = -300 }
            player.step(gravity: Vector2(0, 900), solids: solids)
            Self.seen.append((Vector2(player.rect.left, player.rect.top), player.velocity, player.isOnFloor))
            background(0, 0, 0)
        }
    }

    private static func down(_ code: Key, _ characters: String) -> InputEvent {
        .keyDown(code: code, characters: characters, isRepeat: false)
    }

    /// 落ちて着地し、右へ歩き、跳び、空中でまた押し、壁に当たる入力の列。
    private static let inputs: [Int: [InputEvent]] = [
        40: [down(.arrowRight, "\u{F703}")],
        60: [down(.space, " ")],
        66: [.keyUp(code: .space), down(.space, " ")],
        67: [.keyUp(code: .space)],
    ]

    private func play(frames: Int, inputs: [Int: [InputEvent]]) throws -> [(position: Vector2, velocity: Vector2, onFloor: Bool)] {
        Platformer.seen = []
        let runtime = try SketchRuntime(
            sketch: Platformer(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 })
        for frame in 1...frames {
            for event in inputs[frame] ?? [] { runtime.input.enqueue(event) }
            try runtime.advance()
        }
        return Platformer.seen
    }

    @Test("刻みを deltaTime から読み、落ちて足場に立ち、跳び、壁の手前で止まる")
    func playsTheExample() throws {
        let seen = try play(frames: 240, inputs: Self.inputs)
        #expect(seen.count == 240, "1 フレームで 1 歩")
        // 1 歩目: 刻み 1/60 秒で重力 900 → 速さ 15、位置は 15/60 = 0.25 下がる
        #expect(seen[0].velocity.y == 900 * (Float(1) / 60))
        #expect(seen[0].position.y > 100)
        #expect(!seen[0].onFloor)
        #expect(seen[38].onFloor && seen[38].position.y == 176, "40 フレーム目までに着地")
        #expect(!seen[59].onFloor && seen[59].velocity.y < 0, "60 フレーム目のスペースで跳ぶ")
        #expect(seen[65].velocity.y > seen[64].velocity.y, "空中で押しても上向きの速さは増えない (重力で減るだけ)")
        let last = seen[239]
        #expect(last.position.x == 300 - 16, "壁の手前で止まる")
        #expect(last.onFloor && last.position.y == 176)
        #expect(seen.allSatisfy { $0.position.y <= 176 }, "足場にめり込まない")
    }

    @Test("同じ入力を 2 回流すと、各歩の位置と速さが一致する")
    func theSameInputsGiveTheSameSteps() throws {
        let first = try play(frames: 240, inputs: Self.inputs)
        let second = try play(frames: 240, inputs: Self.inputs)
        #expect(first.count == 240)
        #expect(first.map(\.position) == second.map(\.position))
        #expect(first.map(\.velocity) == second.map(\.velocity))
        #expect(first.map(\.onFloor) == second.map(\.onFloor))
        #expect(Set(first.map(\.position)).count > 50, "止まった体どうしを比べて一致させていない")
    }
}
