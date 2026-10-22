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

    @Test("normalized() は長さ 0 の値 (0 ベクトルだけ) を、数でない値にせず変えずに返す")
    func vectorNormalizedZeroLength() {
        let zero = Vector2(0, 0).normalized()
        #expect(zero == Vector2(0, 0))
        #expect(!zero.x.isNaN && !zero.y.isNaN)
        #expect(Vector2(0, 0).length == 0)
        // 成分が 0 に近いだけの値は 0 ベクトルではない (#2935 が #2722 の「小さい値は自身を返す」を改めた)。
        // 向きを返す。詳しくは `vectorOfTinyComponentsIsMeasuredNotDropped`
        let tiny = Vector2(1e-30, 1e-30)
        #expect(tiny.length != 0)
        #expect(tiny.normalized() != tiny)
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

    // MARK: - 中間の 2 乗が溢れる・潰れる有限の値 (#2885)

    /// 期待との相対誤差が `tolerance` 以内か。
    private func close(_ actual: Vector2, _ expected: Vector2, tolerance: Float = 1e-6) -> Bool {
        let scale = max(abs(expected.x), abs(expected.y))
        return abs(actual.x - expected.x) <= scale * tolerance
            && abs(actual.y - expected.y) <= scale * tolerance
    }

    @Test("長さ・normalized()・limited(to:) は、2 乗が Float に収まらない有限の値でも正しい")
    func vectorOfLargeComponents() {
        let large = Vector2(3e20, 4e20)
        #expect(abs(large.length - 5e20) <= 5e20 * 1e-6)
        #expect(close(large.normalized(), Vector2(0.6, 0.8)))
        #expect(close(large.limited(to: 1e20), Vector2(6e19, 8e19)))
        // 上限が大きくて `simd * limit` だけが溢れる値も、向きを保つ
        #expect(close(Vector2(3, 4).limited(to: 1), Vector2(0.6, 0.8)))
        #expect(close(Vector2(3e19, 4e19).limited(to: 3e19), Vector2(1.8e19, 2.4e19)))
        // 長さそのものが Float に収まらない値でも、向きは求まる (成分は収まる)
        let huge = Vector2(3e38, -3e38)
        let direction = huge.normalized()
        #expect(close(direction, Vector2(0.70710678, -0.70710678)))
        #expect(close(huge.limited(to: 1), Vector2(0.70710678, -0.70710678)))
    }

    @Test("2 乗が 0 に潰れるほど小さい値も、length は正しい長さを返し normalized() は向きを返す (#2935 が #2722 を改めた)")
    func vectorOfTinyComponentsIsMeasuredNotDropped() {
        // #2722 は「長さが 0 に潰れる小さい値の length は 0、normalized() は自身を返す」と固定していた。
        // #2935 で改め、0 になるのは 0 ベクトルだけにした。守りたかった「数でない値を流さない」は保たれる
        let tiny = Vector2(1e-30, 1e-30)
        #expect(abs(tiny.length / 1.4142135e-30 - 1) < 1e-6)
        let direction = tiny.normalized()
        #expect(close(direction, Vector2(0.70710678, 0.70710678)))
        #expect(!direction.x.isNaN && !direction.y.isNaN)
        // 最小の非正規数のまわりでも 0 にならない
        #expect(Vector2(Float.leastNonzeroMagnitude, 0).length == Float.leastNonzeroMagnitude)
        #expect(Vector2(0, -Float.leastNonzeroMagnitude).normalized() == Vector2(0, -1))
    }

    @Test("length・mag・dist は、小さい値でも大きい値でも同じ答えを返す (#2935)")
    func theTwoLayersAgreeOnTheLength() {
        // 2 乗の和が 0 に潰れる (1e-23 未満) 値と、最小の非正規数のまわりまで。どれも 0 でない
        for e: Float in [1e-19, 1e-23, 1e-30, 1e-38, 1e-45] {
            let length = Vector2(e, e).length
            #expect(length != 0, "\(e)")
            #expect(mag(e, e) == length, "mag \(e)")
            #expect(dist(0, 0, e, e) == length, "dist \(e)")
        }
        #expect(abs(Vector2(1e-30, 1e-30).length / 1.4142135e-30 - 1) < 1e-6)
        // 大きい側も、2 の冪倍で歩いて同じ。2^-140 は成分が非正規数になる側、2^120 は溢れる手前
        let bases: [Vector2] = [Vector2(3, 4), Vector2(1, 1), Vector2(0.3, -0.7), Vector2(-5, 0), Vector2(0, 9)]
        for base in bases {
            for exponent in -140...120 {
                let v = scaled(base, by: exponent)
                #expect(mag(v.x, v.y) == v.length, "mag \(base) × 2^\(exponent)")
                #expect(dist(0, 0, v.x, v.y) == v.length, "dist \(base) × 2^\(exponent)")
            }
        }
        // 結果が Float の範囲を越えるときだけ ∞ で、どちらの層も同じ
        let top = Float.greatestFiniteMagnitude
        #expect(Vector2(top, top).length == .infinity)
        #expect(mag(top, top) == .infinity)
        #expect(dist(-top, 0, top, 0) == .infinity)
    }

    @Test("0 ベクトルの length は 0 で、mag・dist も 0 (0 になるのは 0 ベクトルだけ)")
    func zeroVectorIsTheOnlyZeroLength() {
        #expect(Vector2(0, 0).length == 0)
        #expect(Vector2(-0.0, 0).length == 0)
        #expect(Vector2(0, 0).normalized() == Vector2(0, 0))
        #expect(mag(0, 0) == 0)
        #expect(dist(2, 3, 2, 3) == 0)
        #expect(Vector2(Float.leastNonzeroMagnitude, 0).length > 0)
    }

    @Test("mag・dist は、2 乗の和が 2^-100 以上 2^100 未満の値で従来の式と 1 ビットも変わらない")
    func magAndDistOrdinaryValuesAreBitIdentical() {
        var seed: UInt64 = 0x1234_5678_9ABC_DEF1
        func next() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: seed >> 11) % 2_000_000) / 1000 - 1000
        }
        for _ in 0..<2000 {
            let (x1, y1, x2, y2) = (next(), next(), next(), next())
            let (dx, dy) = (x2 - x1, y2 - y1)
            let legacy = (dx * dx + dy * dy).squareRoot()
            #expect(mag(dx, dy) == legacy)
            #expect(dist(x1, y1, x2, y2) == legacy)
        }
        // 範囲の端の内側 (2 乗の和が 2^-100 と 2^100 の手前) でも同じ
        for exponent in [-49, -30, 0, 30, 49] {
            let v = scaled(Vector2(3, 4), by: exponent)
            let legacy = (v.x * v.x + v.y * v.y).squareRoot()
            #expect(mag(v.x, v.y) == legacy, "2^\(exponent)")
        }
    }

    @Test("普通の大きさの値は、従来の式と 1 ビットも変わらない")
    func ordinaryValuesAreBitIdentical() {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: seed >> 11) % 2_000_000) / 1000 - 1000
        }
        for _ in 0..<2000 {
            let v = Vector2(next(), next())
            let limit = abs(next()) + 0.001
            let magnitude = (v.simd * v.simd).sum().squareRoot()
            #expect(v.length == magnitude)
            if magnitude > 0 {
                #expect(v.normalized() == Vector2(v.simd / magnitude))
            }
            let expectedLimited = magnitude > limit ? Vector2(v.simd * limit / magnitude) : v
            #expect(v.limited(to: limit) == expectedLimited)

            let circle = Circle(x: next(), y: next(), radius: abs(next()))
            let other = Circle(x: next(), y: next(), radius: abs(next()))
            let gap = other.center.simd - circle.center.simd
            let reach = circle.radius + other.radius
            let expectedHit = circle.radius > 0 && other.radius > 0 && (gap * gap).sum() <= reach * reach
            #expect(circle.intersects(other) == expectedHit)
            let point = Vector2(next(), next())
            let pointGap = point.simd - circle.center.simd
            let expectedContains =
                circle.radius > 0 && (pointGap * pointGap).sum() <= circle.radius * circle.radius
            #expect(circle.contains(point) == expectedContains)
        }
    }

    @Test("大きい円どうしは、離れていれば当たらず、重なる・接するなら当たる (呼ぶ順によらない)")
    func largeCircleIntersections() {
        let a = Circle(x: 0, y: 0, radius: 1e20)
        let far = Circle(x: 4e20, y: 0, radius: 1e20)
        #expect(!a.intersects(far))
        #expect(!far.intersects(a))
        #expect(a.intersects(Circle(x: 2e20, y: 0, radius: 1e20)))  // 接する
        #expect(Circle(x: 2e20, y: 0, radius: 1e20).intersects(a))
        #expect(a.intersects(Circle(x: 1.5e20, y: 0, radius: 1e20)))  // 重なる
        #expect(!a.intersects(Circle(x: 2.1e20, y: 0, radius: 1e20)))
        #expect(a.intersects(Circle(x: 1e20, y: 1e20, radius: 1e20)))  // 斜め (距離 1.41e20)
        #expect(!a.intersects(Circle(x: 2e20, y: 2e20, radius: 1e20)))  // 斜め (距離 2.83e20)
        // 半径 0 以下は当たらない
        #expect(!a.intersects(Circle(x: 0, y: 0, radius: 0)))
        #expect(!Circle(x: 0, y: 0, radius: -1e20).intersects(a))
    }

    @Test("大きい円は、離れた矩形と点を含まず、近い矩形と点を含む (呼ぶ順によらない)")
    func largeCircleWithRectAndPoint() {
        let circle = Circle(x: 0, y: 0, radius: 1e20)
        let far = Rect(left: 4e20, top: 0, width: 1e20, height: 1e20)
        #expect(!circle.intersects(far))
        #expect(!far.intersects(circle))
        let touching = Rect(left: 1e20, top: -1e19, width: 1e20, height: 2e19)
        #expect(circle.intersects(touching))
        #expect(touching.intersects(circle))
        let beyondCorner = Rect(left: 0.9e20, top: 0.9e20, width: 1e20, height: 1e20)
        #expect(!circle.intersects(beyondCorner))  // 角までは 1.27e20
        #expect(!beyondCorner.intersects(circle))
        #expect(!circle.contains(Vector2(4e20, 0)))
        #expect(circle.contains(Vector2(1e20, 0)))  // 縁の上
        #expect(circle.contains(Vector2(0.5e20, 0.8e20)))
        #expect(!circle.contains(Vector2(0.8e20, 0.8e20)))
        #expect(!Circle(x: 0, y: 0, radius: 0).contains(Vector2(0, 0)))
    }

    @Test("小さい円の判定は、2 乗が 0 に潰れても距離と半径に従う")
    func tinyCircleHitTests() {
        let circle = Circle(x: 0, y: 0, radius: 1e-30)
        #expect(!circle.contains(Vector2(4e-30, 0)))
        #expect(circle.contains(Vector2(1e-30, 0)))  // 縁の上
        #expect(circle.contains(Vector2(0.5e-30, 0.8e-30)))
        #expect(!circle.contains(Vector2(0.8e-30, 0.8e-30)))
        #expect(circle.contains(Vector2(0, 0)))

        let far = Circle(x: 4e-30, y: 0, radius: 1e-30)
        #expect(!circle.intersects(far))
        #expect(!far.intersects(circle))
        #expect(circle.intersects(Circle(x: 2e-30, y: 0, radius: 1e-30)))  // 接する
        #expect(circle.intersects(Circle(x: 1.5e-30, y: 0, radius: 1e-30)))

        let farRect = Rect(left: 4e-30, top: 0, width: 1e-30, height: 1e-30)
        #expect(!circle.intersects(farRect))
        #expect(!farRect.intersects(circle))
        let nearRect = Rect(left: 0.5e-30, top: 0, width: 1e-30, height: 1e-30)
        #expect(circle.intersects(nearRect))
        #expect(nearRect.intersects(circle))
        // 半径 0 以下は小さくても当たらない
        #expect(!Circle(x: 0, y: 0, radius: 0).contains(Vector2(0, 0)))
        #expect(!Circle(x: 0, y: 0, radius: -1e-30).intersects(far))
    }

    // MARK: - 2 の冪倍しても答えが変わらない (#2885 の反証)

    private func scaled(_ value: Vector2, by exponent: Int) -> Vector2 {
        Vector2(scalbn(value.x, exponent), scalbn(value.y, exponent))
    }

    /// 従来の式 (2 乗を作って比べる) の答え。普通の大きさで、2 の冪倍しても変わらない基準にする。
    private func legacyWithin(_ gap: SIMD2<Float>, _ reach: Float) -> Bool {
        (gap * gap).sum() <= reach * reach
    }

    @Test("円の判定は、接する・わずかに離れる・わずかに届くのどれも、2 の冪倍しても答えが変わらない")
    func circleHitTestKeepsItsAnswerUnderPowerOfTwoScaling() {
        let triples: [(Float, Float, Float)] = [(3, 4, 5), (5, 12, 13), (8, 15, 17), (7, 24, 25), (20, 21, 29)]
        var checked = 0
        for (a, b, c) in triples {
            for multiple in 1...100 {
                let m = Float(multiple)
                for reach in [(c * m).nextDown, c * m, (c * m).nextUp] {
                    let expected = legacyWithin(SIMD2(a * m, b * m), reach)
                    for exponent in stride(from: -100, through: 100, by: 7) {
                        let gap = SIMD2(scalbn(a * m, exponent), scalbn(b * m, exponent))
                        let scaledReach = scalbn(reach, exponent)
                        #expect(
                            Vector2.isWithin(gap: gap, reach: scaledReach) == expected,
                            "\(a * m) \(b * m) reach \(reach) × 2^\(exponent)")
                        checked += 1
                    }
                }
            }
        }
        #expect(checked > 20_000)
    }

    @Test("反証の例: gap=(45, 108)·2^64 と reach=117·2^64 は接している")
    func theFalsifiersTouchingExample() {
        let scale: Float = 0x1p64
        #expect(Circle(x: 0, y: 0, radius: 117 * scale).contains(Vector2(45 * scale, 108 * scale)))
        #expect(!Circle(x: 0, y: 0, radius: (117 * scale).nextDown).contains(Vector2(45 * scale, 108 * scale)))
        let other = Circle(x: 45 * scale, y: 108 * scale, radius: 58.5 * scale)
        #expect(Circle(x: 0, y: 0, radius: 58.5 * scale).intersects(other))
        #expect(other.intersects(Circle(x: 0, y: 0, radius: 58.5 * scale)))
        // 小さい側
        let small: Float = 0x1p-64
        #expect(Circle(x: 0, y: 0, radius: 117 * small).contains(Vector2(45 * small, 108 * small)))
        #expect(!Circle(x: 0, y: 0, radius: (117 * small).nextDown).contains(Vector2(45 * small, 108 * small)))
    }

    @Test("length・normalized()・limited(to:) は、2 乗の切り替わりの前後でも 2 の冪倍の答えになる")
    func vectorKeepsItsAnswerUnderPowerOfTwoScaling() {
        let bases: [Vector2] = [Vector2(3, 4), Vector2(1, 1), Vector2(0.3, -0.7), Vector2(-5, 0), Vector2(0, 9)]
        for base in bases {
            let length = base.length
            let direction = base.normalized()
            // 2 乗が非正規数になる側 (-70 付近) から、溢れる側 (+120 付近) まで、切り替わりをまたいで歩く
            for exponent in -70...120 {
                let moved = scaled(base, by: exponent)
                #expect(moved.length == scalbn(length, exponent), "length \(base) × 2^\(exponent)")
                #expect(moved.normalized() == direction, "normalized \(base) × 2^\(exponent)")
                // 上限を半分にすると、長さが上限になる (丸めの 4 ulp 以内・向きは変わらない)
                let limit = scalbn(length, exponent) / 2
                let limited = moved.limited(to: limit)
                let expected = scaled(Vector2(base.simd * 0.5), by: exponent)
                #expect(close(limited, expected, tolerance: 4e-7), "limited \(base) × 2^\(exponent)")
            }
        }
    }

    @Test("軸に沿った値の長さは、2 乗が溢れる・潰れる境目の前後でちょうどその成分になる")
    func axisAlignedLengthAcrossTheEdges() {
        for exponent in [50, 63, 64, 100, 120, -50, -64, -70, -72] {
            let edge = scalbn(Float(1), exponent)
            for value in [edge.nextDown, edge, edge.nextUp] {
                #expect(Vector2(value, 0).length == value, "(\(value), 0)")
                #expect(Vector2(0, -value).length == value)
                #expect(Vector2(value, 0).normalized() == Vector2(1, 0))
            }
        }
    }

    @Test("成分が約 1e-19 未満の値も、2 乗が 0 に潰れる値も、normalized() は長さ 1 になる (#2935)")
    func normalizedOfSmallComponents() {
        for component: Float in [1e-19, 1e-20, 1e-21, 1e-22, 3e-23] {
            let direction = Vector2(component, component).normalized()
            #expect(abs(direction.x - 0.70710678) < 1e-6 && abs(direction.y - 0.70710678) < 1e-6, "\(component)")
        }
        // 2 乗が 0 に潰れる値も、長さ 1 になる (#2935 が #2722 の「変えずに返す」を改めた)
        for component: Float in [1e-23, 1e-30, 1e-38] {
            let direction = Vector2(component, component).normalized()
            #expect(abs(direction.x - 0.70710678) < 1e-6 && abs(direction.y - 0.70710678) < 1e-6, "\(component)")
        }
    }

    /// 長さが非正規数 (約 1.2e-38 未満) に丸められる値。**斜めの値で見る** — 軸に沿った `(0, -t)` は、
    /// 長さが成分とちょうど等しいので、丸められた長さで割っても偶然 (0, -1) になる。
    ///
    /// 長さ 1 の許容は 1e-6。結果の成分は 1 以下の正規数で、`scaledDirection` は 2 の冪で寄せて
    /// 2 乗の和・平方根・割り算を 1 回ずつ丸めるだけなので、誤差は 1 の ulp (1.2e-7) の数倍に収まる。
    /// 直す前は長さ 1.414 (`(t, t)`)・0.901 (`(2t, 3t)`)・0.990 (`(1e-44, 1e-44)`) まで外れた。
    @Test("長さが非正規数になる斜めの値も、normalized() は長さ 1 になる (#2935)")
    func normalizedOfSubnormalLengthIsOne() {
        let t = Float.leastNonzeroMagnitude
        let inputs: [Vector2] = [
            Vector2(t, t), Vector2(2 * t, 3 * t), Vector2(-3 * t, 4 * t), Vector2(1e-44, 1e-44),
            Vector2(1e-42, 1e-42), Vector2(3e-40, -4e-40), Vector2(1e-38, 1e-38), Vector2(1e-39, 0),
            Vector2(0, -t),
        ]
        for input in inputs {
            let direction = input.normalized()
            let length = (direction.x * direction.x + direction.y * direction.y).squareRoot()
            #expect(abs(length - 1) < 1e-6, "\(input) → \(direction) (長さ \(length))")
            // 向きは変わらない (外積が 0 に近い。`Double` で掛けるので非正規数の積も丸めない)
            let cross = Double(direction.x) * Double(input.y) - Double(direction.y) * Double(input.x)
            #expect(abs(cross) <= 1e-6 * (Double(abs(input.x)) + Double(abs(input.y))), "\(input) の向き")
        }
    }

    /// 上限を守る。上限も結果の成分も非正規数の刻み (1.4e-45) に丸められるので、長さは上限から刻み
    /// 2 つ分以内に収まる (成分 2 つの丸めがそれぞれ刻みの半分)。
    @Test("長さが非正規数になる値でも、limited(to:) は上限の長さに縮める (#2935)")
    func limitedOfSubnormalLength() {
        let t = Float.leastNonzeroMagnitude
        for (input, limit) in [
            (Vector2(1e-42, 1e-42), Float(5e-43)), (Vector2(3e-40, -4e-40), 1e-40),
            (Vector2(1e-44, 1e-44), 4e-45), (Vector2(2 * t, 3 * t), 2 * t),
        ] {
            let limited = input.limited(to: limit)
            // 2 乗が潰れるので `Double` で測る
            let length = Float((Double(limited.x) * Double(limited.x) + Double(limited.y) * Double(limited.y)).squareRoot())
            #expect(abs(length - limit) <= 2 * t, "\(input).limited(to: \(limit)) → \(limited) (長さ \(length))")
            #expect(limited.x.sign == input.x.sign && limited.y.sign == input.y.sign, "\(input) の向き")
        }
        // 上限以下なら変えずに返す
        #expect(Vector2(1e-42, 1e-42).limited(to: 1e-41) == Vector2(1e-42, 1e-42))
    }

    @Test("小さい値でも limited(to:) は上限を守る (2 乗の和が 0 に潰れる値も)")
    func limitedOfSmallComponents() {
        let limited = Vector2(3e-30, 4e-30).limited(to: 1e-30)
        #expect(close(limited, Vector2(0.6e-30, 0.8e-30), tolerance: 1e-6), "\(limited)")
        // 上限以下なら変えずに返す
        #expect(Vector2(3e-30, 4e-30).limited(to: 1e-29) == Vector2(3e-30, 4e-30))
        #expect(Vector2(0, 0).limited(to: 1e-30) == Vector2(0, 0))
        // 2 乗が非正規数になる値
        #expect(close(Vector2(3e-20, 4e-20).limited(to: 1e-20), Vector2(0.6e-20, 0.8e-20), tolerance: 1e-6))
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
