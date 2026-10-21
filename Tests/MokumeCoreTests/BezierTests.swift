// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 3 次のベジェ曲線の上の点と傾き (`bezierPoint`・`bezierTangent`) ([#2430])。GPU は要らない。
///
/// 見るのは 3 つ。**手本の値と同じ答えを出すこと** (`bezierPoint(0, 0, 100, 100, 0.5)` が 50・
/// `bezierTangent` が 150)、**端が端へちょうど戻ること**、そして**傾きが、描かれる曲線の刻みの
/// 点の差と同じ向きを指すこと**である。最後は、点の式と傾きの式のどちらかの符号を 1 つ
/// 取り違えると、数値の例が偶然合っても向きがずれて赤くなる。
///
/// [#2430]: https://github.com/mokume-metal/mokume/issues/2430
@Suite("ベジェ曲線の上の点と傾き")
struct BezierPointTests {
    private func isNear(_ one: Float, _ other: Float, within tolerance: Float = 1e-3) -> Bool {
        abs(one - other) < tolerance
    }

    /// 作例の曲線 `bezier(60, 420, 260, 60, 640, 600, 900, 160)` の x 軸と y 軸。
    private let xs: [Float] = [60, 260, 640, 900]
    private let ys: [Float] = [420, 60, 600, 160]

    @Test("手本の例どおりの値になる")
    func matchesTheReferenceExamples() {
        #expect(bezierPoint(0, 0, 100, 100, 0.5) == 50)
        #expect(bezierTangent(0, 0, 100, 100, 0.5) == 150)
        // 制御点の取り違えを拾う: 4 つの値がどれも違い、t が 0.5 でない
        // t = 0.25: u = 0.75。10·0.421875 + 40·0.421875 + 20·0.140625 + 70·0.015625
        #expect(isNear(bezierPoint(10, 40, 20, 70, 0.25), 10 * 0.421875 + 40 * 0.421875 + 20 * 0.140625 + 70 * 0.015625))
        // 手本の展開した式 3t²(−a+3b−3c+d) + 6t(a−2b+c) + 3(−a+b) と同じ値になる
        let (a, b, c, d, t): (Float, Float, Float, Float, Float) = (10, 40, 20, 70, 0.25)
        let reference = 3 * t * t * (-a + 3 * b - 3 * c + d) + 6 * t * (a - 2 * b + c) + 3 * (-a + b)
        #expect(isNear(bezierTangent(a, b, c, d, t), reference))
    }

    @Test("t が 0 なら始点、1 なら終点がちょうど返る")
    func theEndsComeBackExactly() {
        let sets: [[Float]] = [[0, 0, 100, 100], [60, 260, 640, 900], [1e8, -3.3, 7.7, 1 - 1e8], [-0.1, 0.2, -0.3, 0.7]]
        for set in sets {
            #expect(bezierPoint(set[0], set[1], set[2], set[3], 0) == set[0], "\(set)")
            #expect(bezierPoint(set[0], set[1], set[2], set[3], 1) == set[3], "\(set)")
        }
    }

    @Test("端の傾きは、端の点と隣の制御点の差の 3 倍になる")
    func theTangentAtTheEndsPointsAtTheControlPoints() {
        #expect(bezierTangent(60, 260, 640, 900, 0) == 3 * (260 - 60))
        #expect(bezierTangent(60, 260, 640, 900, 1) == 3 * (900 - 640))
        #expect(bezierTangent(420, 60, 600, 160, 0) == 3 * (60 - 420))
        #expect(bezierTangent(420, 60, 600, 160, 1) == 3 * (160 - 600))
    }

    /// 完了条件 2。**傾きが、刻んだ隣の点の差の向きと一致する。** 刻みの点は描画と同じ式
    /// (``Canvas/cubicPoint(_:_:_:_:_:)``) で出す。
    @Test("傾きの向きは、曲線を刻んだ隣の点の差の向きと一致する")
    func theTangentFollowsTheFlattenedPoints() {
        let p0 = SIMD2<Float>(xs[0], ys[0])
        let c1 = SIMD2<Float>(xs[1], ys[1])
        let c2 = SIMD2<Float>(xs[2], ys[2])
        let p1 = SIMD2<Float>(xs[3], ys[3])
        let steps = 40
        for step in 1..<steps {
            let t = Float(step) / Float(steps)
            let before = Canvas.cubicPoint(p0, c1, c2, p1, t - 0.5 / Float(steps))
            let after = Canvas.cubicPoint(p0, c1, c2, p1, t + 0.5 / Float(steps))
            let step = after - before
            let flattened = atan2(step.y, step.x)
            let analytic = atan2(bezierTangent(ys[0], ys[1], ys[2], ys[3], t), bezierTangent(xs[0], xs[1], xs[2], xs[3], t))
            // 角の差は ±π をまたぎうるので、単位ベクトルの距離で見る
            let gap = hypot(cos(flattened) - cos(analytic), sin(flattened) - sin(analytic))
            #expect(gap < 5e-3, "t = \(t): 刻みの向き \(flattened) と傾きの向き \(analytic) がずれている")
        }
    }

    @Test("点は、描画が刻む点と同じ位置になる")
    func thePointMatchesTheDrawnPoints() {
        let p0 = SIMD2<Float>(xs[0], ys[0])
        let c1 = SIMD2<Float>(xs[1], ys[1])
        let c2 = SIMD2<Float>(xs[2], ys[2])
        let p1 = SIMD2<Float>(xs[3], ys[3])
        for step in 0...20 {
            let t = Float(step) / 20
            let drawn = Canvas.cubicPoint(p0, c1, c2, p1, t)
            #expect(isNear(bezierPoint(xs[0], xs[1], xs[2], xs[3], t), drawn.x, within: 0.01), "t = \(t) の x")
            #expect(isNear(bezierPoint(ys[0], ys[1], ys[2], ys[3], t), drawn.y, within: 0.01), "t = \(t) の y")
        }
    }

    @Test("傾きは、点を t で微分した値と同じになる")
    func theTangentIsTheDerivativeOfThePoint() {
        let h: Float = 1e-2
        for t: Float in [0.1, 0.35, 0.5, 0.8] {
            let slope = (bezierPoint(xs[0], xs[1], xs[2], xs[3], t + h) - bezierPoint(xs[0], xs[1], xs[2], xs[3], t - h)) / (2 * h)
            #expect(isNear(bezierTangent(xs[0], xs[1], xs[2], xs[3], t), slope, within: 0.5), "t = \(t)")
        }
    }

    @Test("0…1 の外は締めずに曲線を延ばし、溢れても数でない値は返らない")
    func outsideTheUnitRangeKeepsGoing() {
        // u = -1, t = 2: 3·100·(-1)·4 + 100·8 = -400
        #expect(bezierPoint(0, 0, 100, 100, 2) == -400)
        // t = -1: u = 2。3·100·2·1 + 100·(-1) = 500
        #expect(bezierPoint(0, 0, 100, 100, -1) == 500)
        let huge = bezierPoint(0, 0, 3e38, 3e38, 3e38)
        #expect(!huge.isNaN)
        #expect(!bezierTangent(0, 3e38, -3e38, 0, 3e38).isNaN)
    }

    @Test("Int・Double の変数も、そのまま受ける")
    func acceptsAnyNumberType() {
        let a = 0
        let d = 100.0
        #expect(bezierPoint(a, a, d, 100, 0.5) == 50)
        #expect(bezierTangent(a, a, d, 100, Double(0.5)) == 150)
    }

    @Test("数でない値・無限の値が混じっても、数でない値は返らない")
    func neverReturnsNaN() {
        let bad: [Float] = [.nan, .infinity, -.infinity]
        for value in bad {
            #expect(bezierPoint(7, 1, 2, 3, value) == 7)
            #expect(bezierPoint(7, value, 2, 3, 0.5) == 7)
            #expect(bezierPoint(value, 1, 2, 3, 0.5) == 0)
            #expect(bezierTangent(7, 1, 2, 3, value) == 0)
            #expect(bezierTangent(7, 1, value, 3, 0.5) == 0)
        }
    }
}

/// 単発の `bezier()` が、`beginShape()`・`vertex()`・`bezierVertex()`・`endShape()` と同じ絵になること。
/// GPU を要する ([#2430])。
///
/// [#2430]: https://github.com/mokume-metal/mokume/issues/2430
@Suite(
    "単発の bezier()",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct BezierDrawTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)

    /// 1 枚の面に描いて、表示の形で読む。**比べる 2 経路は毎回新しい面に描く。**
    private func render(_ body: (Canvas) -> Void) throws -> DisplayImage {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
        try canvas.draw {
            canvas.background(black)
            body(canvas)
        }
        return try canvas.target.encodeForDisplay()
    }

    private func inkCount(_ image: DisplayImage) -> Int {
        stride(from: 0, to: image.bytes.count, by: 4).count { image.bytes[$0] != 0 || image.bytes[$0 + 1] != 0 || image.bytes[$0 + 2] != 0 }
    }

    /// 塗りと線の両方を有効にする。手本と同じく、塗りがあれば開いた形を塗る。
    private func inked(_ canvas: Canvas) {
        canvas.fill(.linear(red: 0.9, green: 0.4, blue: 0.1))
        canvas.stroke(.linear(red: 1, green: 1, blue: 1))
        canvas.strokeWeight(3)
    }

    /// 完了条件 3。`bezier(...)` が、4 つの呼び出しと同じ画素になる。
    @Test("bezier() は、beginShape・vertex・bezierVertex・endShape を並べたのと同じ画素になる")
    func drawsWhatTheFourCallsDraw() throws {
        let single = try render { canvas in
            inked(canvas)
            canvas.bezier(6, 56, 14, 6, 50, 60, 58, 10)
        }
        let spelled = try render { canvas in
            inked(canvas)
            canvas.beginShape()
            canvas.vertex(6, 56)
            canvas.bezierVertex(14, 6, 50, 60, 58, 10)
            canvas.endShape()
        }
        #expect(inkCount(single) > 50, "曲線が描かれていない")
        #expect(single == spelled)
    }

    @Test("noFill では線だけを引き、塗りを足さない")
    func noFillDrawsOnlyTheLine() throws {
        let line = try render { canvas in
            canvas.noFill()
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(2)
            canvas.bezier(6, 56, 14, 6, 50, 60, 58, 10)
        }
        let filled = try render { canvas in
            inked(canvas)
            canvas.bezier(6, 56, 14, 6, 50, 60, 58, 10)
        }
        // 塗りの色が橙なので、線だけの絵とは別の画素が増える
        #expect(inkCount(filled) > inkCount(line))
    }

    /// 組み立て中の形を捨てない: `beginShape()` で開き直すと、外の形が黙って消える。
    @Test("組み立て中の形の途中で呼んでも、その形は残り、曲線は別の 1 本として引かれる")
    func leavesTheOpenShapeAlone() throws {
        let inside = try render { canvas in
            inked(canvas)
            canvas.beginShape()
            canvas.vertex(4, 4)
            canvas.vertex(60, 4)
            canvas.bezier(6, 56, 14, 6, 50, 60, 58, 10)
            canvas.vertex(60, 20)
            canvas.endShape(.close)
        }
        // 曲線 → 三角形の順に、別々に引いたのと同じ
        let apart = try render { canvas in
            inked(canvas)
            canvas.bezier(6, 56, 14, 6, 50, 60, 58, 10)
            canvas.beginShape()
            canvas.vertex(4, 4)
            canvas.vertex(60, 4)
            canvas.vertex(60, 20)
            canvas.endShape(.close)
        }
        #expect(inside == apart)
    }

    @Test("フレームの外で呼ぶと、何も描かず 1 度だけ注意する")
    func outsideAFrameDoesNothing() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
        canvas.beginDraw()
        canvas.endDraw()
        canvas.bezier(6, 56, 14, 6, 50, 60, 58, 10)
        #expect(canvas.batches.isEmpty)
        #expect(canvas.warnings.hasWarned(.placingOutsideFrame))
    }
}
