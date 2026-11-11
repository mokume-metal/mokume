// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 通過点を結ぶ曲線の上の点と傾き (`curvePoint`・`curveTangent`) のうち、描画先を要らない所 ([#3710])。
///
/// 張りを読む先が無い — 走っている実行の外から呼ぶ — ときは、1 度だけ知らせて既定の張り 0 で求める。
/// 値の式そのものは、ここで張り 0 の値として確かめる。張りを読むことは GPU の suite (``CurveDrawTests``) が見る。
///
/// [#3710]: https://github.com/mokume-metal/mokume/issues/3710
@MainActor
@Suite("通過点を結ぶ曲線の上の点と傾き")
struct CurvePointTests {
    struct Part: SketchPart {}

    private func isNear(_ one: Float, _ other: Float, within tolerance: Float = 1e-3) -> Bool {
        abs(one - other) < tolerance
    }

    /// 完了条件 2 (張り 0) と、走っていない所からの振る舞い。
    @Test("走っていない所では、1 度だけ知らせて既定の張り 0 で求めた値を返す")
    func outsideTheRunUsesTheDefaultTightness() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let part = Part()
            #expect(part.curvePoint(60, 140, 260, 350, 0) == 140)
            #expect(part.curvePoint(60, 140, 260, 350, 1) == 260)
            // 張り 0 の真ん中: (b + c) / 2 + ((c - a) - (d - b)) / 16 = 200 + (200 - 210) / 16
            #expect(isNear(part.curvePoint(60, 140, 260, 350, 0.5), 200 - 10.0 / 16))
            // 張り 0 の端の傾きは、隣の点どうしの差の半分
            #expect(part.curveTangent(60, 140, 260, 350, 0) == (260 - 60) / 2)
            #expect(part.curveTangent(60, 140, 260, 350, 1) == (350 - 140) / 2)
            _ = part.curvePoint(1, 2, 3, 4, 0.5)
            // 口ごとに 1 行ずつで止まる
            #expect(log.messages.count == 2)
            #expect(
                log.messageForRead(of: "curvePoint(_:_:_:_:_:)")?
                    .contains("the value at the default curve tightness 0 was returned instead") == true)
            #expect(log.messageForRead(of: "curveTangent(_:_:_:_:_:)") != nil)
        }
    }

    /// 式が描く側 (``Canvas/catmullRomPoint(_:_:_:_:_:tightness:)``) と同じであること。張りを 3 通り変えて見る。
    @Test("点は、描画が刻む点と同じ位置になる")
    func thePointMatchesTheDrawnPoints() {
        let xs: [Float] = [60, 140, 260, 350]
        let ys: [Float] = [230, 80, 220, 60]
        let points = (0..<4).map { SIMD2(xs[$0], ys[$0]) }
        for tightness: Float in [-1, 0, 0.5, 1] {
            for step in 0...20 {
                let t = Float(step) / 20
                let drawn = Canvas.catmullRomPoint(points[0], points[1], points[2], points[3], t, tightness: tightness)
                let x = curvePointValue(xs[0], xs[1], xs[2], xs[3], t, tightness: tightness)
                let y = curvePointValue(ys[0], ys[1], ys[2], ys[3], t, tightness: tightness)
                #expect(isNear(x, drawn.x, within: 0.01), "張り \(tightness)・t = \(t) の x")
                #expect(isNear(y, drawn.y, within: 0.01), "張り \(tightness)・t = \(t) の y")
            }
        }
    }

    @Test("傾きは、点を t で微分した値と同じになる")
    func theTangentIsTheDerivativeOfThePoint() {
        let h: Float = 1e-2
        for tightness: Float in [-1, 0, 0.5] {
            for t: Float in [0.1, 0.35, 0.5, 0.8] {
                let slope =
                    (curvePointValue(60, 140, 260, 350, t + h, tightness: tightness)
                        - curvePointValue(60, 140, 260, 350, t - h, tightness: tightness)) / (2 * h)
                #expect(
                    isNear(curveTangentValue(60, 140, 260, 350, t, tightness: tightness), slope, within: 0.5),
                    "張り \(tightness)・t = \(t)")
            }
        }
    }

    /// 完了条件 2 の向き: `atan2(y の傾き, x の傾き)` が、描画が刻んだ隣の点の差の向きと一致する。
    @Test("傾きの向きは、曲線を刻んだ隣の点の差の向きと一致する")
    func theTangentFollowsTheFlattenedPoints() {
        let xs: [Float] = [60, 140, 260, 350]
        let ys: [Float] = [230, 80, 220, 60]
        let points = (0..<4).map { SIMD2(xs[$0], ys[$0]) }
        let steps = 40
        for step in 1..<steps {
            let t = Float(step) / Float(steps)
            let before = Canvas.catmullRomPoint(points[0], points[1], points[2], points[3], t - 0.5 / Float(steps), tightness: 0)
            let after = Canvas.catmullRomPoint(points[0], points[1], points[2], points[3], t + 0.5 / Float(steps), tightness: 0)
            let flattened = atan2(after.y - before.y, after.x - before.x)
            let analytic = atan2(
                curveTangentValue(ys[0], ys[1], ys[2], ys[3], t, tightness: 0),
                curveTangentValue(xs[0], xs[1], xs[2], xs[3], t, tightness: 0))
            let gap = hypot(cos(flattened) - cos(analytic), sin(flattened) - sin(analytic))
            #expect(gap < 5e-3, "t = \(t): 刻みの向き \(flattened) と傾きの向き \(analytic) がずれている")
        }
    }

    @Test("0…1 の外は締めずに曲線を延ばす")
    func outsideTheUnitRangeKeepsGoing() {
        // 張り 1・t = 2: b·(16 − 12 + 1) + c·(−16 + 12) = 5·140 − 4·260
        #expect(curvePointValue(60, 140, 260, 350, 2, tightness: 1) == -340)
        // t = −1: b·(−2 − 3 + 1) + c·(2 + 3) = −4·140 + 5·260
        #expect(curvePointValue(60, 140, 260, 350, -1, tightness: 1) == 740)
        #expect(!curvePointValue(0, 3e38, -3e38, 0, 3e38, tightness: 0).isNaN)
        #expect(!curveTangentValue(0, 3e38, -3e38, 0, 3e38, tightness: 0).isNaN)
    }

    /// 完了条件 3。張り (描画先の状態) が数でなくても同じ扱いにする。
    @Test("数でない値・無限の値が混じると、区間の始点 (傾きは 0) を返して 1 度だけ知らせる")
    func neverReturnsNaN() {
        let bad: [Float] = [.nan, .infinity, -.infinity]
        for value in bad {
            #expect(curvePointValue(1, 7, 2, 3, value, tightness: 0) == 7)
            #expect(curvePointValue(value, 7, 2, 3, 0.5, tightness: 0) == 7)
            #expect(curvePointValue(1, 7, 2, value, 0.5, tightness: 0) == 7)
            #expect(curvePointValue(1, value, 2, 3, 0.5, tightness: 0) == 0)
            #expect(curvePointValue(1, 7, 2, 3, 0.5, tightness: value) == 7)
            #expect(curveTangentValue(1, 7, 2, 3, value, tightness: 0) == 0)
            #expect(curveTangentValue(1, 7, value, 3, 0.5, tightness: 0) == 0)
            #expect(curveTangentValue(1, 7, 2, 3, 0.5, tightness: value) == 0)
        }
        #expect(NumberValues.warnings.hasWarned(.notANumber(.curvePoint)))
        #expect(NumberValues.warnings.message(for: .notANumber(.curvePoint))?.hasPrefix("curvePoint()") == true)
        #expect(NumberValues.warnings.hasWarned(.notANumber(.curveTangent)))
        #expect(NumberValues.warnings.message(for: .notANumber(.curveTangent))?.hasPrefix("curveTangent()") == true)
    }

    @Test("Int・Double の変数も、そのまま受ける")
    func acceptsAnyNumberType() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let part = Part()
            let a = 60
            let d = 350.0
            #expect(part.curvePoint(a, 140, 260, d, 0) == 140)
            #expect(part.curveTangent(a, 140, 260, d, Double(0)) == 100)
        }
    }
}

/// 単発の `curve()` と、描画先の張りを読む `curvePoint()`・`curveTangent()`。GPU を要する ([#3710])。
///
/// [#3710]: https://github.com/mokume-metal/mokume/issues/3710
@MainActor
@Suite(
    "単発の curve()",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CurveDrawTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)

    /// 条件 1 の 4 点 (60, 230)・(140, 80)・(260, 220)・(350, 60) を 64×64 へ縮めたもの。
    private let p1 = Vector2(4, 58)
    private let p2 = Vector2(18, 8)
    private let p3 = Vector2(46, 56)
    private let p4 = Vector2(60, 6)

    /// 1 枚の面に描いて、表示の形で読む。**比べる経路は毎回新しい面に描く。**
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

    /// 塗りと線の両方を有効にし、端の形・刻み・張りも既定から変える。
    private func styled(_ canvas: Canvas) {
        canvas.fill(.linear(red: 0.9, green: 0.4, blue: 0.1))
        canvas.stroke(.linear(red: 1, green: 1, blue: 1))
        canvas.strokeWeight(3)
        canvas.strokeCap(.square)
        canvas.curveDetail(7)
        canvas.curveTightness(-0.5)
    }

    private func spelled(_ canvas: Canvas) {
        canvas.beginShape()
        canvas.curveVertex(p1.x, p1.y)
        canvas.curveVertex(p2.x, p2.y)
        canvas.curveVertex(p3.x, p3.y)
        canvas.curveVertex(p4.x, p4.y)
        canvas.endShape()
    }

    /// 完了条件 1。
    @Test("curve() は、beginShape・curveVertex を 4 回・endShape を並べたのと同じ画素になる")
    func drawsWhatTheSixCallsDraw() throws {
        let single = try render { canvas in
            styled(canvas)
            canvas.curve(p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, p4.x, p4.y)
        }
        let spelled = try render { canvas in
            styled(canvas)
            self.spelled(canvas)
        }
        #expect(inkCount(single) > 50, "曲線が描かれていない")
        #expect(single == spelled)
    }

    /// 刻みと張りが効いていること (上の一致が、どちらも効かないまま一致しているのでないこと)。
    @Test("刻みと張りを変えると、curve() の絵も変わる")
    func detailAndTightnessTakeEffect() throws {
        let plain = try render { canvas in
            canvas.noFill()
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(2)
            canvas.curve(p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, p4.x, p4.y)
        }
        let coarse = try render { canvas in
            canvas.noFill()
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(2)
            canvas.curveDetail(2)
            canvas.curve(p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, p4.x, p4.y)
        }
        let tight = try render { canvas in
            canvas.noFill()
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(2)
            canvas.curveTightness(1)
            canvas.curve(p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, p4.x, p4.y)
        }
        #expect(plain != coarse)
        #expect(plain != tight)
    }

    /// 完了条件への追加: `curve(from: p2, control1: p1, control2: p4, to: p3)` は p2 から p3 までを描く。
    @Test("ラベル付きの形は、位置引数の形と同じ画素になる")
    func theLabelledFormDrawsTheSameCurve() throws {
        let positional = try render { canvas in
            styled(canvas)
            canvas.curve(p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, p4.x, p4.y)
        }
        let labelled = try render { canvas in
            styled(canvas)
            canvas.curve(from: p2, control1: p1, control2: p4, to: p3)
        }
        #expect(inkCount(labelled) > 50, "曲線が描かれていない")
        #expect(labelled == positional)
    }

    /// 完了条件 4。
    @Test("組み立て中の形の途中で呼んでも、その形は残り、曲線は別の 1 本として引かれる")
    func leavesTheOpenShapeAlone() throws {
        let inside = try render { canvas in
            styled(canvas)
            canvas.beginShape()
            canvas.vertex(4, 4)
            canvas.vertex(60, 4)
            canvas.curve(p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, p4.x, p4.y)
            canvas.vertex(60, 20)
            canvas.endShape(.close)
        }
        let apart = try render { canvas in
            styled(canvas)
            canvas.curve(p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, p4.x, p4.y)
            canvas.beginShape()
            canvas.vertex(4, 4)
            canvas.vertex(60, 4)
            canvas.vertex(60, 20)
            canvas.endShape(.close)
        }
        #expect(inside == apart)
    }

    /// 組み立て中の `curveVertex` の並びも、間に挟んだ `curve()` に切られない。
    @Test("curveVertex の並びの途中で呼んでも、並びは続く")
    func leavesTheCurveSequenceAlone() throws {
        let inside = try render { canvas in
            canvas.noFill()
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(2)
            canvas.beginShape()
            canvas.curveVertex(p1.x, p1.y)
            canvas.curveVertex(p2.x, p2.y)
            canvas.curve(4, 4, 10, 30, 30, 30, 60, 60)
            canvas.curveVertex(p3.x, p3.y)
            canvas.curveVertex(p4.x, p4.y)
            canvas.endShape()
        }
        let apart = try render { canvas in
            canvas.noFill()
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(2)
            canvas.curve(4, 4, 10, 30, 30, 30, 60, 60)
            spelled(canvas)
        }
        #expect(inside == apart)
    }

    @Test("フレームの外で呼ぶと、何も描かず 1 度だけ注意する")
    func outsideAFrameDoesNothing() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
        canvas.beginDraw()
        canvas.endDraw()
        canvas.curve(p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, p4.x, p4.y)
        #expect(canvas.batches.isEmpty)
        #expect(canvas.warnings.hasWarned(.placingOutsideFrame))
    }

    /// 完了条件 2 の張り 1。**描画先の張りを読む** — 別の描画先の張りは効かない。
    @Test("curvePoint・curveTangent は、その描画先の curveTightness を読む")
    func readsTheTightnessOfItsCanvas() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
        let other = try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
        #expect(canvas.curvePoint(60, 140, 260, 350, 0) == 140)
        #expect(canvas.curvePoint(60, 140, 260, 350, 1) == 260)
        let loose = canvas.curvePoint(60, 140, 260, 350, 0.5)
        canvas.curveTightness(1)
        #expect(canvas.curvePoint(60, 140, 260, 350, 0.5) == 200)
        #expect(loose != 200)
        // 張り 1 は接線の長さが 0 なので、傾きは (c − b)·6t(1 − t): 端で 0、真ん中で 1.5 倍
        #expect(canvas.curveTangent(60, 140, 260, 350, 0) == 0)
        #expect(canvas.curveTangent(60, 140, 260, 350, 0.5) == 180)
        #expect(other.curvePoint(60, 140, 260, 350, 0.5) == loose)
        #expect(other.curveTangent(60, 140, 260, 350, 0) == 100)
    }
}
