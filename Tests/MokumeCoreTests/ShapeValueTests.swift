// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 2D の値型 (`Vector2`・`Circle`・`Rect`) の判定と計算 (#2600 の完了条件 1・2・4・6)。
///
/// どれも値どうしの純粋な計算なので、GPU も走っているスケッチも要らない。描く口は
/// `ShapeValueDrawingTests` が見る。
@Suite("2D の値型の判定と計算")
struct ShapeValueTests {
    // MARK: - 完了条件 1: 境界まで正しく判定する

    @Test("Issue の例: 円と矩形は、矩形を 1 単位ずつ離すと当たらなくなる")
    func circleAndRectFromTheIssue() {
        let ball = Circle(x: 0, y: 0, radius: 5)
        #expect(ball.intersects(Rect(left: 4, top: -1, width: 10, height: 2)))
        #expect(ball.intersects(Rect(left: 5, top: -1, width: 10, height: 2)))  // 接する
        #expect(!ball.intersects(Rect(left: 6, top: -1, width: 10, height: 2)))
    }

    @Test("円と矩形は、角の外でも縁までの距離で決まる")
    func circleNearARectCorner() {
        // 角 (3, 4) から中心 (0, 0) までは 5
        let corner = Rect(left: 3, top: 4, width: 10, height: 10)
        #expect(Circle(x: 0, y: 0, radius: 5).intersects(corner))
        #expect(!Circle(x: 0, y: 0, radius: 4.99).intersects(corner))
        // 円を外接する正方形で近似する判定では、ここが当たってしまう
        #expect(!Circle(x: 0, y: 0, radius: 4).intersects(corner))
    }

    @Test("円が矩形の中にすっぽり入っても当たる")
    func circleInsideRect() {
        let room = Rect(left: 0, top: 0, width: 100, height: 100)
        #expect(Circle(x: 50, y: 50, radius: 5).intersects(room))
        #expect(room.intersects(Circle(x: 50, y: 50, radius: 5)))
    }

    @Test("円と円は、中心の距離が半径の和までなら当たる", arguments: [
        (Float(8), true),  // 重なる
        (Float(10), true),  // 接する
        (Float(11), false),  // 1 単位離れる
    ])
    func circleAndCircle(distance: Float, expected: Bool) {
        let a = Circle(x: 0, y: 0, radius: 4)
        let b = Circle(x: distance, y: 0, radius: 6)
        #expect(a.intersects(b) == expected)
        #expect(b.intersects(a) == expected)
    }

    @Test("矩形と矩形は、辺が接するまで当たり、1 単位離れると当たらない", arguments: [
        (Float(5), true),  // 重なる
        (Float(10), true),  // 右の辺に左の辺が接する
        (Float(11), false),  // 1 単位離れる
    ])
    func rectAndRect(left: Float, expected: Bool) {
        let a = Rect(left: 0, top: 0, width: 10, height: 10)
        let beside = Rect(left: left, top: 0, width: 10, height: 10)
        let below = Rect(left: 0, top: left, width: 10, height: 10)
        #expect(a.intersects(beside) == expected)
        #expect(beside.intersects(a) == expected)
        #expect(a.intersects(below) == expected)
    }

    @Test("円と矩形は、どちらから問うても同じ答え")
    func circleRectSymmetry() {
        for left in stride(from: Float(-20), through: 20, by: 0.5) {
            let rect = Rect(left: left, top: -3, width: 6, height: 6)
            let circle = Circle(x: 0, y: 0, radius: 5)
            #expect(rect.intersects(circle) == circle.intersects(rect))
        }
    }

    @Test("円は縁の上の点を含み、その外の点を含まない")
    func circleContainsBoundary() {
        let circle = Circle(x: 10, y: 10, radius: 5)
        #expect(circle.contains(Vector2(10, 10)))
        #expect(circle.contains(Vector2(15, 10)))
        #expect(circle.contains(Vector2(13, 14)))  // 3-4-5 の縁の上
        #expect(!circle.contains(Vector2(16, 10)))
        #expect(!circle.contains(Vector2(14, 14)))
    }

    @Test("矩形は辺の上の点を含み、その外の点を含まない")
    func rectContainsBoundary() {
        let rect = Rect(left: 10, top: 20, width: 30, height: 40)
        #expect(rect.contains(Vector2(10, 20)))
        #expect(rect.contains(Vector2(40, 60)))
        #expect(rect.contains(Vector2(25, 40)))
        #expect(!rect.contains(Vector2(9, 40)))
        #expect(!rect.contains(Vector2(41, 40)))
        #expect(!rect.contains(Vector2(25, 19)))
        #expect(!rect.contains(Vector2(25, 61)))
    }

    @Test("大きさが 0 以下の値は、何も含まず何とも当たらない")
    func emptyValues() {
        let room = Rect(left: -100, top: -100, width: 200, height: 200)
        let ball = Circle(x: 0, y: 0, radius: 50)
        for empty in [Circle(x: 0, y: 0, radius: 0), Circle(x: 0, y: 0, radius: -3)] {
            #expect(!empty.contains(Vector2(0, 0)))
            #expect(!empty.intersects(room))
            #expect(!empty.intersects(ball))
            #expect(!ball.intersects(empty))
            #expect(!room.intersects(empty))
        }
        for empty in [
            Rect(left: 0, top: 0, width: 0, height: 10), Rect(left: 0, top: 0, width: 10, height: -1),
        ] {
            #expect(!empty.contains(Vector2(0, 0)))
            #expect(!empty.intersects(room))
            #expect(!room.intersects(empty))
            #expect(!empty.intersects(ball))
            #expect(!ball.intersects(empty))
        }
    }

    @Test("数でない値は、何も含まず何とも当たらない")
    func notANumber() {
        let room = Rect(left: -100, top: -100, width: 200, height: 200)
        #expect(!Circle(x: Float.nan, y: 0, radius: 5).intersects(room))
        #expect(!Circle(x: 0, y: 0, radius: Float.nan).intersects(room))
        #expect(!room.contains(Vector2(Float.nan, 0)))
        #expect(!Rect(left: 0, top: 0, width: Float.nan, height: 10).contains(Vector2(0, 0)))
    }

    // MARK: - 入口と読み出し

    @Test("円は直径の入口でも中心と半径で持つ")
    func circleEntrances() {
        #expect(Circle(x: 0, y: 0, diameter: 10).radius == 5)
        #expect(Circle(x: 3, y: 4, radius: 5).diameter == 10)
        #expect(Circle(x: 3, y: 4, radius: 5) == Circle(center: Vector2(3, 4), radius: 5))
        #expect(Circle(x: 3, y: 4, diameter: 10) == Circle(center: Vector2(3, 4), radius: 5))
    }

    @Test("矩形は左上か中心で作り、辺と中心を読める")
    func rectEntrances() {
        let rect = Rect(left: 10, top: 20, width: 30, height: 40)
        #expect(rect.right == 40)
        #expect(rect.bottom == 60)
        #expect(rect.center == Vector2(25, 40))
        #expect(Rect(center: Vector2(25, 40), width: 30, height: 40) == rect)
    }

    @Test("move は値を動かし、moved は動かした値を返して元を変えない")
    func moving() {
        var ball = Circle(x: 1, y: 2, radius: 3)
        let moved = ball.moved(by: Vector2(10, -1))
        #expect(ball == Circle(x: 1, y: 2, radius: 3))
        ball.move(by: Vector2(10, -1))
        #expect(ball == moved)
        #expect(ball.center == Vector2(11, 1))

        var paddle = Rect(left: 1, top: 2, width: 3, height: 4)
        let shifted = paddle.moved(by: Vector2(-5, 6))
        #expect(paddle.left == 1)
        paddle.move(by: Vector2(-5, 6))
        #expect(paddle == shifted)
        #expect(paddle == Rect(left: -4, top: 8, width: 3, height: 4))
    }

    @Test("値が持つ塗りは初期化子とプロパティで同じものになる")
    func fillProperty() {
        let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
        var brick = Rect(left: 0, top: 0, width: 1, height: 1)
        #expect(brick.fill == nil)
        brick.fill = red
        #expect(brick == Rect(left: 0, top: 0, width: 1, height: 1, fill: red))
        #expect(Circle(x: 0, y: 0, radius: 1, fill: red).fill == red)
    }

    // MARK: - 完了条件 2: 描画のモードに依らない

    @Test("矩形の判定は rectMode に依らない (値は走っているスケッチを見ない)")
    func rectIgnoresMode() {
        // 判定は値だけの計算で、モードを読む経路を持たない。中心指定なら外れる点で確かめる
        let rect = Rect(left: 10, top: 10, width: 120, height: 40)
        #expect(rect.contains(Vector2(15, 15)))
        #expect(!rect.contains(Vector2(-40, 15)))
    }

    // MARK: - 完了条件 4: Vector2

    @Test("Int の変数をそのまま渡して組める")
    func vectorFromIntVariables() {
        let col = 3
        #expect(Vector2(col * 44, 48) == Vector2(Float(132), Float(48)))
        #expect(Vector2(1.5, 2) == Vector2(Float(1.5), Float(2)))
    }

    @Test("SIMD との往復で値が変わらない")
    func vectorSIMDRoundTrip() {
        let simd = SIMD2<Float>(1.25, -7.5)
        #expect(Vector2(simd).simd == simd)
        let vector = Vector2(3, -4)
        #expect(Vector2(vector.simd) == vector)
    }

    @Test("配列リテラルから作れる")
    func vectorArrayLiteral() {
        let vector: Vector2 = [300, 200]
        #expect(vector == Vector2(300, 200))
        let points: [Vector2] = [[1, 2], [3, 4]]
        #expect(points == [Vector2(1, 2), Vector2(3, 4)])
    }

    @Test("成分の読み書きと四則演算と長さ")
    func vectorArithmetic() {
        var vector = Vector2(3, 4)
        #expect(vector.x == 3)
        #expect(vector.y == 4)
        #expect(vector.length == 5)
        #expect(vector + Vector2(1, 2) == Vector2(4, 6))
        #expect(vector - Vector2(1, 2) == Vector2(2, 2))
        #expect(-vector == Vector2(-3, -4))
        #expect(vector * 2 == Vector2(6, 8))
        #expect(2 * vector == Vector2(6, 8))
        #expect(vector * 0.5 == Vector2(1.5, 2))
        #expect(vector / 2 == Vector2(1.5, 2))
        vector += Vector2(1, 1)
        #expect(vector == Vector2(4, 5))
        vector -= Vector2(2, 3)
        #expect(vector == Vector2(2, 2))
        vector *= 3
        #expect(vector == Vector2(6, 6))
        vector /= 2
        #expect(vector == Vector2(3, 3))
        vector.x = 10
        vector.y = -1
        #expect(vector == Vector2(10, -1))
    }

    // MARK: - 向きと上限 (#2722)

    @Test("normalized() は向きを保ったまま長さを 1 にする")
    func vectorNormalized() {
        #expect(Vector2(3, 4).normalized() == Vector2(0.6, 0.8))
        #expect(Vector2(-3, 4).normalized() == Vector2(-0.6, 0.8))
        #expect(Vector2(0, -7).normalized() == Vector2(0, -1))
        let tilted = Vector2(1, 1).normalized()
        #expect(abs(tilted.length - 1) < 1e-6)
        #expect(tilted.x == tilted.y)
        // 元の値は変わらない
        let original = Vector2(3, 4)
        _ = original.normalized()
        #expect(original == Vector2(3, 4))
    }

    @Test("normalized() は長さ 0 の値を、数でない値にせず変えずに返す")
    func vectorNormalizedZeroLength() {
        let zero = Vector2(0, 0).normalized()
        #expect(zero == Vector2(0, 0))
        #expect(!zero.x.isNaN && !zero.y.isNaN)
        // 2 乗が 0 に潰れて length が 0 になるほど小さい値も、変えずに返す
        let tiny = Vector2(1e-30, 1e-30)
        #expect(tiny.length == 0)
        #expect(tiny.normalized() == tiny)
    }

    @Test("limited(to:) は上限を越えるときだけ、向きを保って長さを上限にする")
    func vectorLimited() {
        #expect(Vector2(6, 8).limited(to: 5) == Vector2(3, 4))
        #expect(Vector2(-6, 8).limited(to: 5) == Vector2(-3, 4))
        #expect(Vector2(1, 1).limited(to: 5) == Vector2(1, 1))
        // 長さがちょうど上限のときも変わらない
        #expect(Vector2(3, 4).limited(to: 5) == Vector2(3, 4))
        // 引数は Int・Double の変数もそのまま渡せる (ADR-0035)
        let intLimit = 5
        let doubleLimit = 5.0
        #expect(Vector2(6, 8).limited(to: intLimit) == Vector2(3, 4))
        #expect(Vector2(6, 8).limited(to: doubleLimit) == Vector2(3, 4))
        // 元の値は変わらない
        let original = Vector2(6, 8)
        _ = original.limited(to: 5)
        #expect(original == Vector2(6, 8))
    }

    @Test("limited(to:) は上限が 0 以下なら Vector2(0, 0) にする (Processing の limit() は負で反転する)")
    func vectorLimitedNonPositiveMaximum() {
        #expect(Vector2(6, 8).limited(to: 0) == Vector2(0, 0))
        #expect(Vector2(6, 8).limited(to: -5) == Vector2(0, 0))
        // 上限が 0 以下なら、長さが 0 の値も、越えない値も同じ
        #expect(Vector2(0, 0).limited(to: -1) == Vector2(0, 0))
        #expect(Vector2(1, 1).limited(to: -5) == Vector2(0, 0))
        // 数でない上限も 0 以下と同じに扱い、数でない値を絵に流さない
        let none = Vector2(6, 8).limited(to: Float.nan)
        #expect(none == Vector2(0, 0))
    }

    @Test("長さ 0 の値に limited(to:) を掛けても変わらない")
    func vectorLimitedZeroLength() {
        #expect(Vector2(0, 0).limited(to: 5) == Vector2(0, 0))
    }

    @Test("数でない成分を渡しても落ちない (扱いは四則と同じく決めていない)")
    func vectorNonFiniteComponentsDoNotTrap() {
        // 範囲の外 (#2722): 値の約束はしない。止まらず、返ってくることだけを見る
        let nan = Vector2(Float.nan, 0)
        _ = nan.normalized()
        _ = nan.limited(to: 5)
        let infinite = Vector2(Float.infinity, 0)
        _ = infinite.normalized()
        _ = infinite.limited(to: 5)
    }

    /// 通信の完了ハンドラのような main actor の外の文脈。**ここが組めることが検査である**
    /// (`Vector2` が既定の隔離のままなら、この関数の中の呼び出しはコンパイルエラーになる)。
    nonisolated static func steerOutsideTheMainActor() -> Vector2 {
        let velocity = Vector2(1, 0) + Vector2(3, 4).normalized() * 2
        return velocity.limited(to: 1.5)
    }

    @Test("normalized() と limited(to:) は main actor の外から呼べる")
    func steeringUsableOutsideTheMainActor() async {
        let result = await Task.detached { Self.steerOutsideTheMainActor() }.value
        // (1, 0) + (0.6, 0.8) * 2 = (2.2, 1.6) は長さ 2.72 なので、1.5 に縮む
        #expect(abs(result.length - 1.5) < 1e-5)
        #expect(abs(result.x / result.y - 2.2 / 1.6) < 1e-5)
    }

    // MARK: - 完了条件 6: 隔離の外で使える

    /// 通信の完了ハンドラのような、main actor の外の文脈。**ここが組めることが検査である** —
    /// 値型が既定の隔離 (main actor) のままだと、この関数の中の呼び出しはどれもコンパイルエラーになる。
    nonisolated static func useOutsideTheMainActor() throws -> (Bool, Data, Int) {
        let hit = Circle(x: 0, y: 0, radius: 5).intersects(Rect(left: 0, top: 0, width: 10, height: 10))
        let encoded = try JSONEncoder().encode(Vector2(1, 2))
        let set: Set<Rect> = [
            Rect(left: 0, top: 0, width: 1, height: 1, fill: .linear(red: 1, green: 0, blue: 0)),
            Rect(left: 0, top: 0, width: 1, height: 1, fill: .linear(red: 1, green: 0, blue: 0)),
        ]
        return (hit, encoded, set.count)
    }

    @Test("main actor の外から判定し、符号化し、比べられる")
    func usableOutsideTheMainActor() async throws {
        let (hit, encoded, count) = try await Task.detached { try Self.useOutsideTheMainActor() }.value
        #expect(hit)
        #expect(count == 1)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Double]
        #expect(object == ["x": 1, "y": 2])
    }

    @Test("Codable で往復して値が変わらない")
    func codableRoundTrip() throws {
        let fill = LinearRGBA(straightRed: 0.9, green: 0.3, blue: 0.3, alpha: 0.5)
        let circle = Circle(x: 1.5, y: -2, radius: 3, fill: fill)
        let rect = Rect(left: 4, top: 5, width: 6, height: 7)
        let vector = Vector2(-1, 0.25)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(Circle.self, from: encoder.encode(circle)) == circle)
        #expect(try decoder.decode(Rect.self, from: encoder.encode(rect)) == rect)
        #expect(try decoder.decode(Vector2.self, from: encoder.encode(vector)) == vector)
        #expect(try decoder.decode(LinearRGBA.self, from: encoder.encode(fill)) == fill)
    }

    // MARK: - 走っていないとき

    @Test("走っていないときに描くと、落ちずに 1 度だけ警告する")
    func drawingOutsideTheRunWarnsOnce() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            Rect(left: 0, top: 0, width: 10, height: 10).draw()
            Rect(left: 0, top: 0, width: 10, height: 10).draw()
            Circle(x: 0, y: 0, radius: 5).draw()
        }
        #expect(log.messages.count == 2)
        #expect(log.messages.first?.hasPrefix("Rect.draw() only works inside setup()") == true)
        #expect(log.messages.last?.hasPrefix("Circle.draw() only works inside setup()") == true)
    }
}
