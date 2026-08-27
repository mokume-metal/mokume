// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

@Suite("座標変換")
struct Transform2DTests {
    @Test("何もしなければ点は動かない")
    func identityKeepsThePoint() {
        let moved = Transform2D.identity.apply(x: 3, y: 7)
        #expect(moved.x == 3)
        #expect(moved.y == 7)
    }

    @Test("平行移動")
    func translationMovesThePoint() {
        var t = Transform2D.identity
        t.translate(x: 10, y: -4)
        let moved = t.apply(x: 1, y: 1)
        #expect(moved.x == 11)
        #expect(moved.y == -3)
    }

    @Test("正の角度は画面の上で時計回りに見える")
    func positiveAngleTurnsClockwiseOnScreen() {
        // 縦軸が下向きなので、右向きのベクトルを 90 度回すと「下」を向く
        var t = Transform2D.identity
        t.rotate(by: .pi / 2)
        let moved = t.apply(x: 1, y: 0)
        #expect(abs(moved.x) < 1e-6)
        #expect(abs(moved.y - 1) < 1e-6)
    }

    @Test("拡大縮小")
    func scalingStretchesThePoint() {
        var t = Transform2D.identity
        t.scale(x: 2, y: 3)
        let moved = t.apply(x: 5, y: 5)
        #expect(moved.x == 10)
        #expect(moved.y == 15)
    }

    @Test("あとから指定した変換ほど図形に近い")
    func laterTransformsApplyCloserToTheShape() {
        // 移動 → 回転 は「移動した先を中心に回る」
        var moveThenTurn = Transform2D.identity
        moveThenTurn.translate(x: 100, y: 0)
        moveThenTurn.rotate(by: .pi / 2)
        let a = moveThenTurn.apply(x: 10, y: 0)
        #expect(abs(a.x - 100) < 1e-4)
        #expect(abs(a.y - 10) < 1e-4)

        // 回転 → 移動 は「原点で回してから移動する」— 結果が違う
        var turnThenMove = Transform2D.identity
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

    @Test("上下で頭打ちにする")
    func segmentCountIsBounded() {
        #expect(Canvas.segmentCount(forRadius: 0.5) == 32)
        #expect(Canvas.segmentCount(forRadius: 1) == 32)
        #expect(Canvas.segmentCount(forRadius: 100_000) == 128)
    }

    @Test("多角形と真円の隔たりが 0.25 画素以下に収まる", arguments: [Float(5), 20, 100, 400])
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
