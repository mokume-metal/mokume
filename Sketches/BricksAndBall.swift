// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// ブロック崩し。**ゲームの書き味に要る口が、そろって書けることを示す** ([#2598] の作例)。
///
/// 矢印 (← →) でパドルを動かし、球でブロックを消す。消すたびにスコアが 10 増え、球を落とすと
/// 1 秒置いてから同じ所から出直す。球は 3 つで、尽きるか全部消したら return で最初から。
///
/// 使う口は子の Issue で入れたものだけである: 図形の値 (`Rect`・`Circle`・`Vector2` と当たり判定)・
/// キーボードの問い (`keyboard.isPressed`・`justPressed`)・フレームの時計 (`clock: .frames`)・
/// `Countdown`。**押下の印も当たり判定も自分では書かない** — 壁も `Rect` で置いて `intersects` で当てる。
///
/// ## 3 段で読む
///
/// コードは教える順の 3 段 ([#2580] の A4) に分けて、`// MARK:` で段を名乗る。
///
/// 1. **関数で描く** — 面とスコアを、`background`・`text` をそのまま呼んで描く
/// 2. **値で判定し、描くときは `fill()` に従わせる** — パドルと球を値で持ち、`intersects` で当て、
///    `fill(236); paddle.draw()` のように描く
/// 3. **物体ごとに見た目を持たせる** — ブロックごとに `Rect(…, fill:)` で色を持たせ、`brick.draw()`
///    だけで描く
///
/// ## フレームの時計で回す
///
/// `clock: .frames` なので、`draw()` 1 回がちょうど 1/60 秒になる。パドルは押している 1 枚ごとに
/// 5 進み、球を落としてから出直すまでは何度走らせても 60 枚である。重い枚では絵を抜かずに遅くなる。
///
/// ## 音は使い回す
///
/// 当たった音は合成音で鳴らす (音声のファイルは置かない)。**音源と包絡は `setup()` で 1 つずつ作り、
/// 当たるたびに包絡をかけ直す。** 当たるたびに `createTriOsc()` で作ると、作れる 64 個を使い切って
/// 黙って鳴らなくなる ([#2763])。
///
/// ## 外から確かめる
///
/// `expose` で `score`・`paddleX`・`ballY`・`balls` を差し出している。`mokume watch` と MCP の
/// `input` で → を押したまま、`observe` でフレームごとの値を読むと、押している枚だけ `paddleX` が
/// 5 ずつ増える。
///
/// [#2580]: https://github.com/mokume-metal/mokume/issues/2580
/// [#2598]: https://github.com/mokume-metal/mokume/issues/2598
/// [#2763]: https://github.com/mokume-metal/mokume/issues/2763
final class BricksAndBall: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 480, height: 270, title: "bricks and ball", clock: .frames)
    }

    /// 当たったときに鳴らす音。**作るのは `setup()` の 1 回だけ** (上の「音は使い回す」)。
    var tone: TriOsc?
    var envelope: Env?

    func setup() {
        tone = createTriOsc()
        tone?.amp(0.3)
        envelope = createEnv()
        layBricks()
    }

    func draw() {
        if keyboard.justPressed(.enter), isOver { startOver() }
        movePaddle()
        if !isOver, respawn.isFinished { moveBall() }
        expose("score", score)
        expose("paddleX", paddle.left)
        expose("ballY", ball.center.y)
        expose("balls", balls)

        drawBoard()
        drawBricks()
        drawPaddleAndBall()
    }

    /// 球が尽きたか、ブロックを全部消したか。どちらでも球は止まり、return を待つ。
    var isOver: Bool { balls == 0 || bricks.isEmpty }

    /// 最初の状態へ戻す。
    func startOver() {
        score = 0
        balls = 3
        layBricks()
        serve()
    }

    /// 球を出す所へ戻し、1 秒数え直す。
    func serve() {
        ball.center = Self.serveAt
        velocity = Self.serveVelocity
        respawn.restart()
    }

    /// 当たった音を鳴らす。同じ音源に包絡をかけ直すので、音源は増えない。
    func beep(_ frequency: Float) {
        guard let tone, let envelope else { return }
        tone.freq(frequency)
        envelope.play(tone, 0.002, 0.03, 0.6, 0.08)
    }

    // MARK: - 段 1「関数で描く」: 面とスコアは、描く関数をそのまま呼んで描く

    var score = 0
    var balls = 3

    func drawBoard() {
        background(18, 20, 28)
        noStroke()
        fill(200)
        textSize(14)
        text("SCORE \(score)", 24, 28)
        text("BALLS \(balls)", width - 96, 28)
        if isOver {
            fill(255, 238, 88)
            text(bricks.isEmpty ? "CLEAR!  PRESS RETURN" : "GAME OVER  PRESS RETURN", 150, 170)
        }
    }

    // MARK: - 段 2「値で判定し、描くときは fill() に従わせる」: パドルと球を値で持って当てる

    static let serveAt = Vector2(240, 200)
    static let serveVelocity = Vector2(2.5, -2.5)

    var paddle = Rect(left: 196, top: 240, width: 88, height: 10)
    var ball = Circle(center: BricksAndBall.serveAt, radius: 5)
    var velocity = BricksAndBall.serveVelocity
    /// 球を落としてから出直すまでの 1 秒。作った値はスケッチの時間の原点から数えるので、
    /// 始まってすぐの 1 秒も球は待つ。
    var respawn = Countdown(seconds: 1)

    /// 壁と天井。**面の外側に沿わせた細い矩形**で、球が触れたら跳ね返す。
    let leftWall = Rect(left: -10, top: 0, width: 10, height: 270)
    let rightWall = Rect(left: 480, top: 0, width: 10, height: 270)
    let ceiling = Rect(left: 0, top: -10, width: 480, height: 10)

    /// 押している枚ごとに 5 進む (フレームの時計なので、1 秒で 300)。面の外へは出さない。
    func movePaddle() {
        if keyboard.isPressed(.arrowLeft) { paddle.move(by: Vector2(-5, 0)) }
        if keyboard.isPressed(.arrowRight) { paddle.move(by: Vector2(5, 0)) }
        paddle.left = constrain(paddle.left, 0, width - paddle.width)
    }

    func moveBall() {
        ball.move(by: velocity)
        // 跳ね返す向きは符号で決める。触れている枚が続いても、向きが行き来しない
        if ball.intersects(leftWall) { velocity.x = abs(velocity.x); beep(330) }
        if ball.intersects(rightWall) { velocity.x = -abs(velocity.x); beep(330) }
        if ball.intersects(ceiling) { velocity.y = abs(velocity.y); beep(330) }
        if ball.intersects(paddle) {
            // パドルの端で受けるほど横へ振れる。真ん中なら真上へ
            let offset = (ball.center.x - paddle.center.x) / (paddle.width / 2)
            velocity = Vector2(offset * 3.5, -abs(velocity.y))
            beep(220)
        }
        if let i = bricks.firstIndex(where: { ball.intersects($0) }) {
            bricks.remove(at: i)
            velocity.y = -velocity.y
            score += 10
            beep(660)
        }
        if ball.center.y > height {
            balls -= 1
            if balls > 0 { serve() }
        }
    }

    func drawPaddleAndBall() {
        noStroke()
        fill(236)
        paddle.draw()
        fill(255)
        ball.draw()
    }

    // MARK: - 段 3「物体ごとに見た目を持たせる」: ブロックは自分の色を持ち、draw() だけで描かれる

    let palette = [
        color(239, 83, 80), color(255, 167, 38), color(255, 238, 88), color(102, 187, 106),
        color(66, 165, 245),
    ]
    var bricks: [Rect] = []

    /// 5 段 × 10 列。段ごとの色を、ブロックの値に持たせる。
    func layBricks() {
        bricks = []
        for row in 0..<5 {
            for col in 0..<10 {
                bricks.append(
                    Rect(left: 24 + col * 44, top: 48 + row * 18, width: 40, height: 14, fill: palette[row]))
            }
        }
    }

    func drawBricks() {
        noStroke()
        for brick in bricks { brick.draw() }  // 各ブロックが自分の色で描かれる。fill() は要らない
    }
}
