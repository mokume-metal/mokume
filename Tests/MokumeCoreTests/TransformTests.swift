// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

@Suite("座標変換")
struct TransformTests {
    @Test("何もしなければ点は動かない")
    func identityKeepsThePoint() {
        let moved = Transform.identity.apply(x: 3, y: 7)
        #expect(moved.x == 3)
        #expect(moved.y == 7)
    }

    @Test("平行移動")
    func translationMovesThePoint() {
        var t = Transform.identity
        t.translate(x: 10, y: -4)
        let moved = t.apply(x: 1, y: 1)
        #expect(moved.x == 11)
        #expect(moved.y == -3)
    }

    @Test("正の角度は画面の上で時計回りに見える")
    func positiveAngleTurnsClockwiseOnScreen() {
        // 縦軸が下向きなので、右向きのベクトルを 90 度回すと「下」を向く
        var t = Transform.identity
        t.rotate(by: .pi / 2)
        let moved = t.apply(x: 1, y: 0)
        #expect(abs(moved.x) < 1e-6)
        #expect(abs(moved.y - 1) < 1e-6)
    }

    @Test("拡大縮小")
    func scalingStretchesThePoint() {
        var t = Transform.identity
        t.scale(x: 2, y: 3)
        let moved = t.apply(x: 5, y: 5)
        #expect(moved.x == 10)
        #expect(moved.y == 15)
    }

    @Test("あとから指定した変換ほど図形に近い")
    func laterTransformsApplyCloserToTheShape() {
        // 移動 → 回転 は「移動した先を中心に回る」
        var moveThenTurn = Transform.identity
        moveThenTurn.translate(x: 100, y: 0)
        moveThenTurn.rotate(by: .pi / 2)
        let a = moveThenTurn.apply(x: 10, y: 0)
        #expect(abs(a.x - 100) < 1e-4)
        #expect(abs(a.y - 10) < 1e-4)

        // 回転 → 移動 は「原点で回してから移動する」— 結果が違う
        var turnThenMove = Transform.identity
        turnThenMove.rotate(by: .pi / 2)
        turnThenMove.translate(x: 100, y: 0)
        let b = turnThenMove.apply(x: 10, y: 0)
        #expect(abs(b.x) < 1e-4)
        #expect(abs(b.y - 110) < 1e-4)
    }
}

@Suite("円の分割数")
struct CircleSegmentTests {
    @Test("半径が大きいほど細かくなる")
    func largerRadiusGetsMoreSegments() {
        #expect(Canvas.segmentCount(forRadius: 10) <= Canvas.segmentCount(forRadius: 200))
    }

    // MARK: - 打ち消しと合成 (#235)

    @Test("打ち消す変換を通すと元の点へ戻る")
    func invertingATransformReturnsThePoint() throws {
        var transform = Transform.identity
        transform.translate(x: 37, y: -12)
        transform.rotate(by: .pi / 3)
        transform.scale(x: 2.5, y: 0.4)
        transform.shearX(by: .pi / 6)

        let inverse = try #require(transform.inverted)
        for point in [SIMD2<Float>(0, 0), SIMD2(100, 40), SIMD2(-25, 90)] {
            let moved = transform.apply(x: point.x, y: point.y)
            let back = inverse.apply(x: moved.x, y: moved.y)
            #expect(abs(back.x - point.x) < 0.01, "x が戻らない: \(back.x) != \(point.x)")
            #expect(abs(back.y - point.y) < 0.01, "y が戻らない: \(back.y) != \(point.y)")
        }
    }

    @Test("軸を潰した変換には打ち消しが無い")
    func aCollapsedTransformHasNoInverse() {
        var transform = Transform.identity
        transform.scale(x: 4, y: 0)  // 縦が潰れる
        #expect(transform.inverted == nil)
    }

    @Test("合成の順序が結果を変える")
    func theOrderOfCompositionMatters() {
        var moveThenTurn = Transform.identity
        moveThenTurn.translate(x: 50, y: 0)
        moveThenTurn.rotate(by: .pi / 2)

        var turnThenMove = Transform.identity
        turnThenMove.rotate(by: .pi / 2)
        turnThenMove.translate(x: 50, y: 0)

        // 移してから回すと、移した先が原点になる
        let a = moveThenTurn.apply(x: 10, y: 0)
        #expect(abs(a.x - 50) < 0.01)
        #expect(abs(a.y - 10) < 0.01)

        // 回してから移すと、回った向きへ移る
        let b = turnThenMove.apply(x: 10, y: 0)
        #expect(abs(b.x - 0) < 0.01)
        #expect(abs(b.y - 60) < 0.01)
    }

    @Test("重ねた変換は、順に掛けたものと一致する")
    func concatenationMatchesAppliedSteps() {
        var stepByStep = Transform.identity
        stepByStep.translate(x: 20, y: 30)
        stepByStep.scale(x: 2, y: 2)

        var second = Transform.identity
        second.scale(x: 2, y: 2)
        var combined = Transform.identity
        combined.translate(x: 20, y: 30)
        combined.concatenate(second)

        let a = stepByStep.apply(x: 7, y: 9)
        let b = combined.apply(x: 7, y: 9)
        #expect(abs(a.x - b.x) < 0.001)
        #expect(abs(a.y - b.y) < 0.001)
    }

    @Test("何も変換しない状態へ戻せる")
    func resetReturnsToIdentity() {
        var transform = Transform.identity
        transform.translate(x: 100, y: 100)
        transform.rotate(by: 1.2)
        transform.reset()
        #expect(transform == .identity)
    }

    // MARK: - 下限を外す (#423)

    @Test("式が返す値をそのまま使う")
    func segmentCountFollowsTheFormula() {
        // 直径 12 の円。かつては下限 32 が掛かり、必要の 3 倍の頂点を組み立てていた
        #expect(Canvas.segmentCount(forRadius: 6) == 11)
        #expect(Canvas.segmentCount(forRadius: 1) == 5)
        #expect(Canvas.segmentCount(forRadius: 20) == 20)
    }

    @Test("いちばん粗い多角形より下へは行かない")
    func segmentCountNeverFallsBelowATriangle() {
        // 隔たりが許容誤差に届かない円も、多角形としては成立させる
        #expect(Canvas.segmentCount(forRadius: 0.25) == 3)
        #expect(Canvas.segmentCount(forRadius: .nan) == 3)
        #expect(Canvas.segmentCount(forRadius: .infinity) == 3)
    }

    @Test("大きすぎる円は上で頭打ちにする")
    func segmentCountIsCappedAbove() {
        #expect(Canvas.segmentCount(forRadius: 100_000) == 128)
    }

    // 小さい側は下限 32 に隠れて一度も検査されていなかった (#423)
    @Test(
        "多角形と真円の隔たりが 0.25 画素以下に収まる",
        arguments: [Float(0.5), 1, 2, 6, 5, 20, 100, 400])
    func polygonStaysWithinAQuarterPixel(radius: Float) {
        let n = Canvas.segmentCount(forRadius: radius)
        // 隔たりがいちばん大きいのは辺の中央で、その差は r(1 − cos(π/n))
        let deviation = radius * (1 - cos(Float.pi / Float(n)))
        // 上限で頭打ちにした大きな円だけは、この保証を外れる
        if n < 128 {
            #expect(deviation <= 0.25)
        }
    }
}
