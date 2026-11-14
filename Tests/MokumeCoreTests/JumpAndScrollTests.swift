// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import mokume

@testable import MokumeCore
@testable import reference_sketches

/// 参照スケッチ `jump-and-scroll` (#2606)。ゲーム層の 3 つの API (`Scene`・`ArcadeBody`・`Camera2D`) で書いた
/// 横スクロールが、場面・物理・カメラの約束どおりに動く。フレームの時計で 1 枚ずつ進め、入力は送った回に効く。
///
/// 描く経路を通すので GPU を使う (台帳の検査と同じ)。
@Suite(
    "参照スケッチ jump-and-scroll",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct JumpAndScrollTests {
    /// 1 枚ずつ進め、キーを押す・離すを送る。
    @MainActor
    final class Driver {
        let sketch = JumpAndScroll()
        let runtime: SketchRuntime

        init() throws {
            runtime = try SketchRuntime(
                sketch: sketch, gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60), persistsParams: false)
        }

        func frame() throws { try runtime.advance() }

        func frames(_ count: Int) throws {
            for _ in 0..<count { try runtime.advance() }
        }

        func press(_ key: Key) { runtime.input.enqueue(.keyDown(code: key, characters: "", isRepeat: false)) }
        func release(_ key: Key) { runtime.input.enqueue(.keyUp(code: key)) }

        /// `key` を押した 1 枚を進め、離す (離すのは次の枚の頭)。
        func tap(_ key: Key) throws {
            press(key)
            try frame()
            release(key)
        }

        /// タイトルで return を押し、ゲームの場面に入った最初の 1 枚まで進める。
        func startGame() throws {
            try frame()
            try tap(.enter)
            try frame()
        }

        /// 最後に描いた枚の場面。
        var scene: JumpAndScroll.Screen { sketch.screen }
        var body: ArcadeBody { sketch.player }

        /// 条件が立つまで進める。`limit` 枚で立たなければ偽。
        func advance(until done: () -> Bool, limit: Int) throws -> Bool {
            for _ in 0..<limit {
                if done() { return true }
                try frame()
            }
            return done()
        }
    }

    @Test("return でタイトル → ゲーム、3 回落ちると結果、return でタイトルへ戻る。切り替えは押した次の枚で効く")
    @MainActor
    func scenesFollowEnterAndThreeFalls() throws {
        let driver = try Driver()
        try driver.frame()
        #expect(driver.scene == .title)
        try driver.tap(.enter)
        #expect(driver.scene == .title, "押した枚は元の場面のまま")
        try driver.frame()
        #expect(driver.scene == .game)
        #expect(driver.sketch.score == 0 && driver.sketch.falls == 0)

        // 穴 (列 20・21 = x 600〜660) の上に置いて落とす。3 回目で結果になる
        for fall in 1...3 {
            driver.sketch.player = ArcadeBody(Rect(left: 621, top: 214, width: 18, height: 26))
            let fell = try driver.advance(until: { driver.sketch.falls == fall }, limit: 120)
            try #require(fell, "落ちて \(fall) 回目を数える")
            if fall < 3 {
                #expect(driver.body.rect == JumpAndScroll.start, "落ちたら始まりの位置へ戻る")
                #expect(driver.scene == .game)
            }
        }
        #expect(driver.scene == .game, "3 回目に落ちた枚は、まだゲームの場面")
        try driver.frame()
        #expect(driver.scene == .result)
        #expect(!driver.sketch.reachedGoal)

        try driver.tap(.enter)
        try driver.frame()
        #expect(driver.scene == .title)
        // もう一度始めると、落ちた回数とスコアが戻る
        try driver.tap(.enter)
        try driver.frame()
        #expect(driver.scene == .game && driver.sketch.falls == 0 && driver.sketch.score == 0)
    }

    @Test("旗に触れると結果の場面になり、ゴールとして終える")
    @MainActor
    func reachingTheFlagEndsTheGame() throws {
        let driver = try Driver()
        try driver.startGame()
        let flag = driver.sketch.flag
        driver.sketch.player = ArcadeBody(Rect(left: flag.left - 40, top: 214, width: 18, height: 26))
        driver.press(.arrowRight)
        let ended = try driver.advance(until: { driver.scene == .result }, limit: 60)
        #expect(ended && driver.sketch.reachedGoal)
    }

    @Test("足場の上で何もしない 120 枚は、playerY が変わらず接地したまま")
    @MainActor
    func standingStillStaysOnTheFloor() throws {
        let driver = try Driver()
        try driver.startGame()
        try driver.frames(2)
        let top = driver.body.rect.top
        #expect(top == JumpAndScroll.start.top)
        for _ in 0..<120 {
            try driver.frame()
            #expect(driver.body.rect.top == top)
            #expect(driver.body.isOnFloor)
        }
    }

    @Test("space を 1 回押すと跳び、空中でもう一度押しても上向きの速さは増えない")
    @MainActor
    func jumpingOnlyFromTheFloor() throws {
        let driver = try Driver()
        try driver.startGame()
        try driver.frames(2)
        try driver.tap(.space)
        let afterJump = driver.body.velocity.y
        #expect(afterJump < 0, "跳んだ: \(afterJump)")
        #expect(!driver.body.isOnFloor)
        try driver.frames(5)
        let before = driver.body.velocity.y
        try driver.tap(.space)
        let after = driver.body.velocity.y
        #expect(after > before, "空中で押しても上向きに速くならない (重力の分だけ下向きへ): \(before) → \(after)")
        #expect(abs(after - before - JumpAndScroll.gravity.y / 60) < 0.01, "重力の 1 枚分だけ増える")
        let landed = try driver.advance(until: { driver.body.isOnFloor }, limit: 120)
        #expect(landed)
        #expect(driver.body.rect.top == JumpAndScroll.start.top, "同じ足場に降りる")
    }

    @Test("壁へ向かって → を押し続けても、playerX は壁の手前で止まる")
    @MainActor
    func runningIntoTheWallStops() throws {
        let driver = try Driver()
        try driver.startGame()
        // 列 8 の壁 (x 240〜270・2 マスの高さ)。体の幅は 18
        let wall: Float = 240
        driver.press(.arrowRight)
        for _ in 0..<180 {
            try driver.frame()
            #expect(driver.body.rect.right <= wall)
        }
        #expect(driver.body.rect.left == wall - 18, "壁に接して止まる")
        #expect(driver.body.isOnFloor)
    }

    @Test("カメラは playerX が画面の中央を越えると追い、面の両端で止まる。コインに触れるとスコアが 10 ずつ増える")
    @MainActor
    func cameraFollowsAndStopsAtTheEnds() throws {
        let driver = try Driver()
        try driver.startGame()
        #expect(driver.sketch.camera.x == 0)

        // 壁の先 (列 10) から右へ走る。列 11・13・15 のコインを拾う
        driver.sketch.player = ArcadeBody(Rect(left: 306, top: 214, width: 18, height: 26))
        driver.press(.arrowRight)
        var scores: [Int] = []
        for _ in 0..<60 {
            try driver.frame()
            let center = driver.body.rect.center.x
            #expect(driver.sketch.camera.x == max(0, center - 240))
            scores.append(driver.sketch.score)
        }
        #expect(driver.sketch.camera.x > 0)
        #expect(Array(Set(scores)).sorted() == [0, 10, 20, 30], "1 枚ずつ 10 増える: \(scores)")
        driver.release(.arrowRight)

        // 右の端 (旗の手前の空き) では、面の幅 − 画面の幅 で止まる
        driver.sketch.player = ArcadeBody(Rect(left: 1866, top: 214, width: 18, height: 26))
        try driver.frames(2)
        let upper = JumpAndScroll.worldWidth - 480
        #expect(driver.sketch.camera.x == upper)
        driver.press(.arrowRight)
        try driver.frames(30)
        #expect(driver.sketch.camera.x == upper, "端を越えない")
        driver.release(.arrowRight)

        // 左の端では 0 で止まる
        driver.sketch.player = ArcadeBody(Rect(left: 36, top: 214, width: 18, height: 26))
        driver.press(.arrowLeft)
        try driver.frames(30)
        #expect(driver.body.rect.left == 30, "左の壁に接して止まる")
        #expect(driver.sketch.camera.x == 0)
    }

    @Test("同じ入力を 2 回流すと、同じ枚の playerX・playerY・score・cameraX が一致する")
    @MainActor
    func sameInputsGiveTheSameFrames() throws {
        func run() throws -> [[Float]] {
            let driver = try Driver()
            var trace: [[Float]] = []
            for frame in 1...600 {
                if frame == 2 { driver.press(.enter) }
                if frame == 3 { driver.release(.enter) }
                if frame == 10 { driver.press(.arrowRight) }
                for jump in [60, 150, 230, 330, 420] {
                    if frame == jump { driver.press(.space) }
                    if frame == jump + 1 { driver.release(.space) }
                }
                try driver.frame()
                let s = driver.sketch
                trace.append([s.player.rect.left, s.player.rect.top, Float(s.score), s.camera.x, Float(s.falls)])
            }
            return trace
        }
        let first = try run()
        let second = try run()
        #expect(first == second)
        // 見たい状況を通った (壁を越え、カメラが動き、コインを拾った)
        #expect(first.contains { $0[0] > 270 })
        #expect(first.contains { $0[3] > 0 })
        #expect(first.contains { $0[2] > 0 })
    }
}
