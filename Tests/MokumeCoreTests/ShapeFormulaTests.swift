// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 曲線・座標の読み方・形の合成の自己判定。GPU を要する ([#1383])。
///
/// 期待値は 2 通りに導く。保存した画像は使わない ([ADR-0019] 決定 4):
///
/// - **曲線の点は CPU で式から出す。** 3 次のベジェは Bernstein 多項式、Catmull-Rom は
///   行列の形で書く。実装 (``Canvas/cubicPoint(_:_:_:_:_:)`` / ``Canvas/catmullRomPoint(_:_:_:_:_:tightness:)``)
///   は Hermite の形で書いてあるので、写したのでは同じ誤りを 2 度書くだけになる
/// - **「同じ絵になるはず」の約束は、2 経路で同じ大きさの面に描いてバイトで比べる。**
///   取り違えると絵が変わる値を選ぶ — 幅と高さを違え、左右と上下で違う位置に置き、
///   重なる 2 色や非対称な三角形を使う。対称な値では、取り違えても一致してしまう
///
/// ## 点が線の色になる理由
///
/// 点を見る検査は、式の点に最も近い画素が**線の色そのもの**になることを見る。
/// そう言い切れるのは 3 つが揃うからである:
///
/// 1. **線の中心は、整数の座標で画素の中心に乗る** ([ADR-0039] 決定 2)。だから点 P に
///    最も近い画素 (P を丸めた画素) の中心は、P から各軸 0.5 以内 = 0.71 以内にある
/// 2. **曲線は刻みの数だけの折れ線で引かれ、見る t は折れ線の頂点そのものである。**
///    刻みを 20 に置けば t = 0.25 / 0.5 / 0.75 は 5・10・15 番目の頂点になるので、
///    折れ線による近似のずれが入らない
/// 3. **三角形の経路は縁の AA を持たない** ([ADR-0039] 決定 3)。画素は中心が線の内側に
///    あれば線の色で塗られ、外なら塗られない。太さ 4 の線は、帯も折れ目の埋めも頂点から
///    太さの半分 = 2 までを覆うので、0.71 以内の中心は縁から 1.29 画素内側にある
///
/// [#1383]: https://github.com/mokume-metal/mokume/issues/1383
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
/// [ADR-0039]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0039-pixel-grid-and-edge-antialiasing.md
@Suite(
    "曲線の式と、2 経路の一致",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShapeFormulaTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    /// 1 枚の面に描いて、表示の形で読む。**比べる 2 経路は毎回新しい面に描く** —
    /// 同じ面に続けて描くと、前の描画の状態 (座標の読み方・色掛け) が残りうる。
    private func render(width: Int = 64, height: Int = 64, _ body: (Canvas) throws -> Void)
        throws -> DisplayImage
    {
        let canvas = try makeCanvas(width: width, height: height)
        var failure: (any Error)?
        try canvas.draw {
            canvas.background(black)
            do { try body(canvas) } catch { failure = error }
        }
        if let failure { throw failure }
        return try pixels(of: canvas)
    }

    /// 違うバイトを持つ画素の数。0 以外なら、どこが違うかを 1 つ添えて報告できる。
    private func differingPixels(_ a: DisplayImage, _ b: DisplayImage) -> Int {
        var count = 0
        for y in 0..<a.height {
            for x in 0..<a.width where a[x, y] != b[x, y] { count += 1 }
        }
        return count
    }

    /// 背景 (黒) でない画素の数。**比べる前に、比べる絵に何か出ていることを確かめる** —
    /// 両方とも何も描かれていなければ、一致は何も見ていない。
    private func inkedPixels(_ image: DisplayImage) -> Int {
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width where image[x, y] != (0, 0, 0, 255) { count += 1 }
        }
        return count
    }

    /// 点に最も近い画素。線の中心は整数の座標で画素の中心に乗るので、丸めた値がそのまま
    /// 画素の番号になる (型の説明の「点が線の色になる理由」1)。
    private static func nearestPixel(_ point: SIMD2<Double>) -> (x: Int, y: Int) {
        (Int(point.x.rounded()), Int(point.y.rounded()))
    }

    // MARK: - 式 (CPU)

    /// 3 次のベジェの点。**Bernstein 多項式** B(t) = Σ C(3, i) (1 − t)^(3 − i) t^i P_i で求める。
    ///
    /// t = 0.5 では重みが 1/8・3/8・3/8・1/8 になり、(P0 + 3 P1 + 3 P2 + P3) / 8 に畳まれる。
    private static func bezierPoint(_ points: [SIMD2<Double>], _ t: Double) -> SIMD2<Double> {
        let binomial: [Double] = [1, 3, 3, 1]
        var point = SIMD2<Double>(0, 0)
        for (i, control) in points.enumerated() {
            point += control * (binomial[i] * pow(1 - t, Double(3 - i)) * pow(t, Double(i)))
        }
        return point
    }

    /// Catmull-Rom の点 (張り具合 0)。**行列の形** P(t) = ½ [1 t t² t³] M [P0 P1 P2 P3]ᵀ で求める。
    ///
    /// M の各行が t の 0〜3 乗の係数で、4 点のうち P1 から P2 までを引く。t = 0.5 では
    /// (−P0 + 9 P1 + 9 P2 − P3) / 16 に畳まれる。
    private static func catmullRomPoint(_ points: [SIMD2<Double>], _ t: Double) -> SIMD2<Double> {
        let basis: [[Double]] = [
            [0, 2, 0, 0],
            [-1, 0, 1, 0],
            [2, -5, 4, -1],
            [-1, 3, -3, 1],
        ]
        let powers = [1, t, t * t, t * t * t]
        var point = SIMD2<Double>(0, 0)
        for (row, power) in zip(basis, powers) {
            for (weight, control) in zip(row, points) {
                point += control * (0.5 * power * weight)
            }
        }
        return point
    }

    // MARK: - 曲線の点

    /// 完了条件 1。**t = 0.5 だけでは 2 つの制御点を取り違えても同じ点になる** (重みが
    /// 3/8 ずつ) ので、t = 0.25 / 0.75 も見る。4 点は左右にも上下にも対称でない。
    @Test("3 次の曲線は Bernstein 多項式の点を通り、弦の中点は通らない")
    func bezierPassesThroughTheBernsteinPoints() throws {
        let points: [SIMD2<Double>] = [SIMD2(8, 44), SIMD2(12, 4), SIMD2(44, 12), SIMD2(56, 52)]
        let image = try render { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(4)
            canvas.curveDetail(20)
            canvas.beginShape()
            canvas.vertex(points[0].x, points[0].y)
            canvas.bezierVertex(
                points[1].x, points[1].y, points[2].x, points[2].y, points[3].x, points[3].y)
            canvas.endShape()
        }

        // 式の t = 0.5 の点は、(P0 + 3 P1 + 3 P2 + P3) / 8 = (29, 18) (整数に選んだ)
        let middle = Self.bezierPoint(points, 0.5)
        #expect(middle == SIMD2(29, 18))

        for t in [0.25, 0.5, 0.75] {
            let pixel = Self.nearestPixel(Self.bezierPoint(points, t))
            #expect(
                image[pixel.x, pixel.y] == (255, 255, 255, 255),
                "t = \(t) の点 \(pixel) が線の色でない")
        }
        // 弦の中点 (32, 48) は曲線から 30 画素ほど離れている
        #expect(image[32, 48] == (0, 0, 0, 255), "弦の中点に線が引かれている")
    }

    /// 完了条件 2。4 点は一直線でなく、t = 0.5 の点は弦の中点 (32, 20) から 4 画素ふくらむ。
    /// **t = 0.5 では端の 2 点 (P0 と P3) を取り違えても同じ点になる**ので、t = 0.25 / 0.75 も見る。
    @Test("通過点を結ぶ曲線は、Catmull-Rom の式の点を通る")
    func curveVerticesPassThroughTheCatmullRomPoints() throws {
        let points: [SIMD2<Double>] = [SIMD2(8, 48), SIMD2(20, 16), SIMD2(44, 24), SIMD2(56, 56)]
        let image = try render { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(4)
            canvas.curveDetail(20)
            canvas.beginShape()
            for point in points { canvas.curveVertex(point.x, point.y) }
            canvas.endShape()
        }

        // 式の t = 0.5 の点は、(−P0 + 9 P1 + 9 P2 − P3) / 16 = (32, 16) (整数に選んだ)
        let middle = Self.catmullRomPoint(points, 0.5)
        #expect(middle == SIMD2(32, 16))

        for t in [0.25, 0.5, 0.75] {
            let pixel = Self.nearestPixel(Self.catmullRomPoint(points, t))
            #expect(
                image[pixel.x, pixel.y] == (255, 255, 255, 255),
                "t = \(t) の点 \(pixel) が線の色でない")
        }
    }

    // MARK: - 張り具合と刻み

    /// 完了条件 3。``Sketch/curveTightness(_:)`` の説明は「1 にすると点と点が直線で
    /// 結ばれる」と約束している。
    ///
    /// **刻みは既定の 20 で引く。** 張り具合 1 なら刻みの点はどれも辺の上に乗る。張り具合が
    /// 効いていなければ (0 のまま)、最初の辺を決める 4 点は (A, A, B, C) なので、10 番目の
    /// 刻み (t = 0.5) は Catmull-Rom の (8A + 9B − C) / 16 = (24, 10) へ 2 画素ふくらむ
    /// (A〜D は下の `corners`)。刻み 1 は t = 1 の点 (次の通過点) しか置かないので、
    /// 張り具合によらず折れ線になり、この検査には使えない。
    ///
    /// **刻みの継ぎ目は角ではないので円板で埋まり、辺の上では帯と端点の内側に収まる**
    /// ([#1409])。通過点 (B と C) は置いた点なので、折れ線と同じ角の形で埋まる。かつては
    /// 刻みの継ぎ目も角と同じ正方形で埋めていたため、始点から 0.23 画素の所の継ぎ目の
    /// 正方形が丸い端点の外へ出て (2 画素違う)、この検査は刻み 2 (継ぎ目が辺の中点の
    /// 1 つだけ) でしか見られなかった。
    ///
    /// **3 本の辺を軸に沿わせ、太さを奇数 (3) にする。** 帯の縁は画素の境目に乗る —
    /// どの画素の中心も縁の上に来ないので、経路の違う 2 つの絵が縁の判定で割れない。
    ///
    /// [#1409]: https://github.com/mokume-metal/mokume/issues/1409
    @Test("張り具合 1 の通過点の曲線は、同じ点を vertex で結んだ折れ線と同じ絵になる")
    func fullTightnessMatchesThePolyline() throws {
        let corners: [SIMD2<Float>] = [SIMD2(8, 12), SIMD2(40, 12), SIMD2(40, 44), SIMD2(56, 44)]
        func style(_ canvas: Canvas) {
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(3)
        }
        let curved = try render { canvas in
            style(canvas)
            canvas.curveDetail(20)
            canvas.curveTightness(1)
            canvas.beginShape()
            // 端まで引くために端の点を 2 度置く (``Sketch/curveVertex(_:_:)`` の説明)
            canvas.curveVertex(corners[0].x, corners[0].y)
            for corner in corners { canvas.curveVertex(corner.x, corner.y) }
            canvas.curveVertex(corners[3].x, corners[3].y)
            canvas.endShape()
        }
        let straight = try render { canvas in
            style(canvas)
            canvas.beginShape()
            for corner in corners { canvas.vertex(corner.x, corner.y) }
            canvas.endShape()
        }
        #expect(inkedPixels(straight) > 0)
        #expect(differingPixels(curved, straight) == 0)
    }

    /// 完了条件 4。刻み 1 の曲線は、端点を 1 本の直線で結ぶ。制御点は弦から大きく
    /// 外してある — 刻みが効いていなければ曲線が引かれ、絵が変わる。
    @Test("刻み 1 の 3 次の曲線は、端点を vertex で結んだ直線と同じ絵になる")
    func singleStepBezierMatchesTheStraightLine() throws {
        func style(_ canvas: Canvas) {
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(3)
        }
        let curved = try render { canvas in
            style(canvas)
            canvas.curveDetail(1)
            canvas.beginShape()
            canvas.vertex(8, 40)
            canvas.bezierVertex(16, 4, 50, 60, 56, 20)
            canvas.endShape()
        }
        let straight = try render { canvas in
            style(canvas)
            canvas.beginShape()
            canvas.vertex(8, 40)
            canvas.vertex(56, 20)
            canvas.endShape()
        }
        #expect(inkedPixels(straight) > 0)
        #expect(differingPixels(curved, straight) == 0)
    }

    // MARK: - 通過点の曲線の並びの切れ目 (#1449)

    /// 起票 ([#1449]) の再現の輪。8 点の輪を 11 個の通過点で一巡りする — 最初と最後の
    /// 3 点が重なるので、並びの両端の区間も輪の上に乗り、輪は閉じる。
    ///
    /// [#1449]: https://github.com/mokume-metal/mokume/issues/1449
    private static func ringGuides(radius: Float, reversed: Bool) -> [SIMD2<Float>] {
        let order = reversed ? Array((0..<11).reversed()) : Array(0..<11)
        return order.map { i in
            let angle = Float(i % 8) / 8 * 2 * .pi
            return SIMD2(80 + radius * cos(angle), 80 + radius * sin(angle))
        }
    }

    /// 外周を `vertex` で組んだ長方形 (160×160 の面)。
    private static let frameCorners: [SIMD2<Float>] = [
        SIMD2(10, 10), SIMD2(150, 10), SIMD2(150, 150), SIMD2(10, 150),
    ]

    /// 端点を 2 度置いた、閉じない通過点の曲線。**外周の長方形と逆回り**に並べてある
    /// (穴の頂点の並べ方 — ``Sketch/beginContour()``)。穴の中の最初の区間の始点は 2 つ目に
    /// 置いた (40, 40) で、輪と違って終わりが始点に重ならない — 始点が欠けると絵に出る。
    private static let openCurveGuides: [SIMD2<Float>] = [
        SIMD2(40, 40), SIMD2(40, 40), SIMD2(40, 120), SIMD2(120, 120), SIMD2(120, 40),
        SIMD2(120, 40),
    ]

    /// #1449 の完了条件 1。**穴は外周から独立した輪郭として始まる** — 穴を ``Canvas/beginContour()``
    /// の中で描いた絵は、外周だけの形を塗ってから同じ曲線を独立した形として下地の色で塗った
    /// 絵と一致する。直す前は、穴の最初の区間が外周の点を端点にして引かれ、穴の環が外周の上
    /// から始まっていた (塗りで 63 画素違う)。線も引く組では、穴の輪郭が外周まで伸びた線に
    /// なっていた。
    @Test(
        "曲線の外周に曲線の穴を開けた絵は、外周を塗ってから穴を下地の色で塗った絵と同じになる",
        arguments: [false, true])
    func curvedHoleStartsOnItsOwn(stroked: Bool) throws {
        let outer = Self.ringGuides(radius: 70, reversed: false)
        let hole = Self.ringGuides(radius: 30, reversed: true)
        func style(_ canvas: Canvas) {
            canvas.fill(white)
            if stroked {
                canvas.stroke(.linear(red: 1, green: 0, blue: 0))
                canvas.strokeWeight(3)
            } else {
                canvas.noStroke()
            }
        }
        let withHole = try render(width: 160, height: 160) { canvas in
            style(canvas)
            canvas.beginShape()
            for guide in outer { canvas.curveVertex(guide.x, guide.y) }
            canvas.beginContour()
            for guide in hole { canvas.curveVertex(guide.x, guide.y) }
            canvas.endContour()
            canvas.endShape(.close)
        }
        let paintedOver = try render(width: 160, height: 160) { canvas in
            style(canvas)
            canvas.beginShape()
            for guide in outer { canvas.curveVertex(guide.x, guide.y) }
            canvas.endShape(.close)
            canvas.fill(black)
            canvas.beginShape()
            for guide in hole { canvas.curveVertex(guide.x, guide.y) }
            canvas.endShape(.close)
        }
        #expect(inkedPixels(paintedOver) > 0)
        #expect(differingPixels(withHole, paintedOver) == 0)
    }

    /// #1449 の完了条件 2。**穴の中で最初に引く区間は、その始点 (2 つ目に置いた点) を穴に置く。**
    /// 形の中で最初に引く区間と同じ扱いである。直す前は外周の点の有無を見ていたので、
    /// 外周に点がある穴では始点が落ち、穴は 1 刻み目から始まっていた (塗りで 91 画素違う)。
    ///
    /// 外周を `vertex` で組むので、曲線の並びは穴の中の点だけでできている — 並びを切るだけの
    /// 直し方では、この検査は赤いまま残る。
    @Test(
        "外周を vertex で組んだ形に閉じない曲線の穴を開けても、穴を下地の色で塗った絵と同じになる",
        arguments: [false, true])
    func openCurvedHoleKeepsItsStart(stroked: Bool) throws {
        func style(_ canvas: Canvas) {
            canvas.fill(white)
            if stroked {
                canvas.stroke(.linear(red: 1, green: 0, blue: 0))
                canvas.strokeWeight(3)
            } else {
                canvas.noStroke()
            }
        }
        var holeStart: SIMD2<Float>?
        let withHole = try render(width: 160, height: 160) { canvas in
            style(canvas)
            canvas.beginShape()
            for corner in Self.frameCorners { canvas.vertex(corner.x, corner.y) }
            canvas.beginContour()
            for guide in Self.openCurveGuides { canvas.curveVertex(guide.x, guide.y) }
            holeStart = canvas.holePoints?.first.map { SIMD2($0.position.x, $0.position.y) }
            canvas.endContour()
            canvas.endShape(.close)
        }
        let paintedOver = try render(width: 160, height: 160) { canvas in
            style(canvas)
            canvas.beginShape()
            for corner in Self.frameCorners { canvas.vertex(corner.x, corner.y) }
            canvas.endShape(.close)
            canvas.fill(black)
            canvas.beginShape()
            for guide in Self.openCurveGuides { canvas.curveVertex(guide.x, guide.y) }
            canvas.endShape(.close)
        }
        #expect(holeStart == Self.openCurveGuides[1], "穴の最初の点が、最初の区間の始点でない")
        #expect(inkedPixels(paintedOver) > 0)
        #expect(differingPixels(withHole, paintedOver) == 0)
    }

    /// #1449 の完了条件 3。**`curveVertex` 以外で点を置いたら、通過点の曲線の並びは切れる** —
    /// 次の区間は、また 4 つ揃ってから引かれる。だから挟んだ後の `curveVertex` 1 つは何も
    /// 引かず、置かない形と同じ絵になる。直す前は、挟む前の並びの続きとして区間を引き、
    /// 挟んだ点から前の曲線の終わり (40, 20) の脇へ逆戻りしていた。
    @Test(
        "通過点の曲線は vertex / bezierVertex / quadraticVertex を挟むと並びが切れ、前の点へ戻らない",
        arguments: ["vertex", "bezierVertex", "quadraticVertex"])
    func curveSequenceBreaksAtOtherVertices(interruption: String) throws {
        func draw(_ canvas: Canvas, resuming: Bool) {
            canvas.fill(.linear(red: 0.2, green: 0.4, blue: 0.8))
            canvas.stroke(white)
            canvas.strokeWeight(3)
            canvas.beginShape()
            for guide: SIMD2<Float> in [SIMD2(10, 50), SIMD2(20, 20), SIMD2(40, 20), SIMD2(50, 50)] {
                canvas.curveVertex(guide.x, guide.y)
            }
            switch interruption {
            case "vertex": canvas.vertex(60, 60)
            case "bezierVertex": canvas.bezierVertex(50, 66, 66, 64, 60, 56)
            default: canvas.quadraticVertex(64, 66, 60, 56)
            }
            if resuming { canvas.curveVertex(70, 20) }
            canvas.endShape()
        }
        let resumed = try render(width: 80, height: 72) { draw($0, resuming: true) }
        let stopped = try render(width: 80, height: 72) { draw($0, resuming: false) }
        #expect(inkedPixels(stopped) > 0)
        #expect(differingPixels(resumed, stopped) == 0)
    }

    /// #1449 の完了条件 3 (穴の境目)。**穴を閉じたら、並びは切れる** — 閉じた後に外周へ置いた
    /// `curveVertex` 1 つは何も引かない。直す前は穴の中の点を並びの続きにして区間を引き、
    /// 外周の環に穴の点の間の曲線が積まれていた。
    @Test("穴を閉じた後に外周へ curveVertex を 1 つ足しても、足さない形と同じ絵になる")
    func curveSequenceBreaksAtEndContour() throws {
        func draw(_ canvas: Canvas, resuming: Bool) {
            canvas.fill(white)
            canvas.stroke(.linear(red: 1, green: 0, blue: 0))
            canvas.strokeWeight(3)
            canvas.beginShape()
            for corner in Self.frameCorners { canvas.vertex(corner.x, corner.y) }
            canvas.beginContour()
            for guide in Self.openCurveGuides { canvas.curveVertex(guide.x, guide.y) }
            canvas.endContour()
            if resuming { canvas.curveVertex(80, 150) }
            canvas.endShape(.close)
        }
        let resumed = try render(width: 160, height: 160) { draw($0, resuming: true) }
        let stopped = try render(width: 160, height: 160) { draw($0, resuming: false) }
        #expect(inkedPixels(stopped) > 0)
        #expect(differingPixels(resumed, stopped) == 0)
    }

    /// #1449 の完了条件 4。**穴の最初の `bezierVertex` / `quadraticVertex` は何もしない** —
    /// 形の中で手前に点が無いときと同じ扱い (``Sketch/bezierVertex(_:_:_:_:_:_:)`` の説明)。
    /// 直す前は外周の最後の点 (10, 150) から曲線を引き、その刻みが穴の環に積まれていた。
    @Test(
        "穴の最初の bezierVertex / quadraticVertex は、外周の最後の点から曲線を引かない",
        arguments: ["bezierVertex", "quadraticVertex"])
    func curveOpeningAHoleDrawsNothing(opening: String) throws {
        var placedByOpening: Int?
        func draw(_ canvas: Canvas, opened: Bool) {
            canvas.fill(white)
            canvas.stroke(.linear(red: 1, green: 0, blue: 0))
            canvas.strokeWeight(3)
            canvas.beginShape()
            for corner in Self.frameCorners { canvas.vertex(corner.x, corner.y) }
            canvas.beginContour()
            if opened {
                if opening == "bezierVertex" {
                    canvas.bezierVertex(40, 130, 90, 140, 100, 100)
                } else {
                    canvas.quadraticVertex(60, 140, 100, 100)
                }
                placedByOpening = canvas.holePoints?.count
            }
            canvas.vertex(60, 60)
            canvas.vertex(60, 100)
            canvas.vertex(100, 100)
            canvas.endContour()
            canvas.endShape(.close)
        }
        let opened = try render(width: 160, height: 160) { draw($0, opened: true) }
        let plain = try render(width: 160, height: 160) { draw($0, opened: false) }
        #expect(placedByOpening == 0, "穴の最初の \(opening) が穴に点を置いた")
        #expect(inkedPixels(plain) > 0)
        #expect(differingPixels(opened, plain) == 0)
    }

    // MARK: - 座標の読み方

    /// 完了条件 5。どれも中心 (30, 22)・幅 36・高さ 20 の楕円を指す。**幅と高さを違え、
    /// 中心を面の真ん中から外す** — 縦横や x と y を取り違えると別の楕円になる。
    @Test(
        "楕円の読み方を変えても、同じ楕円を指せば同じ絵になる",
        arguments: [
            (ShapeMode.corner, SIMD4<Float>(12, 12, 36, 20)),
            (ShapeMode.corners, SIMD4<Float>(12, 12, 48, 32)),
            (ShapeMode.radius, SIMD4<Float>(30, 22, 18, 10)),
        ])
    func ellipseModesAgreeWithCenter(mode: ShapeMode, box: SIMD4<Float>) throws {
        func style(_ canvas: Canvas) {
            canvas.fill(white)
            canvas.stroke(.linear(red: 1, green: 0, blue: 0))
            canvas.strokeWeight(2)
        }
        let reference = try render { canvas in
            style(canvas)
            canvas.ellipseMode(.center)
            canvas.ellipse(30, 22, 36, 20)
        }
        let other = try render { canvas in
            style(canvas)
            canvas.ellipseMode(mode)
            canvas.ellipse(box.x, box.y, box.z, box.w)
        }
        #expect(inkedPixels(reference) > 0)
        #expect(differingPixels(other, reference) == 0)
    }

    /// 2×2 の、4 画素とも色の違う絵。**上下左右のどれを取り違えても絵が変わる。**
    /// どの色も黒 (背景) でなく、赤の色掛けで変わる成分 (緑か青) を持つ。
    private func quadrantImage(_ canvas: Canvas) throws -> Image {
        let picture = try canvas.createImage(2, 2)
        picture.set(0, 0, .linear(red: 1, green: 0.25, blue: 0.25))
        picture.set(1, 0, .linear(red: 0.25, green: 1, blue: 0.25))
        picture.set(0, 1, .linear(red: 0.25, green: 0.25, blue: 1))
        picture.set(1, 1, .linear(red: 1, green: 1, blue: 1))
        return picture
    }

    /// 完了条件 6。どれも左上 (10, 12)・幅 36・高さ 20 の矩形を指す。
    ///
    /// **墨の外接も見る。** 4 種が揃って同じ向きにずれていれば、一致を見るだけでは
    /// 分からない。画像は塗りと同じく整数の座標で画素の境目に乗る ([ADR-0039] 決定 2)
    /// ので、墨は (10, 12) から (46, 32) の手前までの 36×20 画素に収まる。
    ///
    /// [ADR-0039]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0039-pixel-grid-and-edge-antialiasing.md
    @Test("絵の置き方を変えても、同じ矩形を指せば同じ絵になり、墨は指した矩形に収まる")
    func imageModesAgreeAndInkFillsTheBox() throws {
        let cases: [(ShapeMode, SIMD4<Float>)] = [
            (.corner, SIMD4(10, 12, 36, 20)),
            (.corners, SIMD4(10, 12, 46, 32)),
            (.center, SIMD4(28, 22, 36, 20)),
            (.radius, SIMD4(28, 22, 18, 10)),
        ]
        var images: [DisplayImage] = []
        for (mode, box) in cases {
            images.append(
                try render { canvas in
                    let picture = try quadrantImage(canvas)
                    canvas.imageMode(mode)
                    canvas.image(picture, box.x, box.y, box.z, box.w)
                })
        }
        for (index, image) in images.enumerated().dropFirst() {
            #expect(differingPixels(image, images[0]) == 0, "\(cases[index].0) が .corner と違う")
        }

        // 墨 = 背景 (黒) でない画素。外接を [左, 右) × [上, 下) で出す
        let corner = images[0]
        var left = Int.max
        var top = Int.max
        var right = Int.min
        var bottom = Int.min
        for y in 0..<corner.height {
            for x in 0..<corner.width where corner[x, y] != (0, 0, 0, 255) {
                left = min(left, x)
                top = min(top, y)
                right = max(right, x + 1)
                bottom = max(bottom, y + 1)
            }
        }
        #expect(left == 10 && top == 12 && right == 46 && bottom == 32, "墨の外接 (\(left), \(top))〜(\(right), \(bottom))")
    }

    /// 完了条件 7。**色掛けが効いていることも先に確かめる** — 赤を掛けても絵が
    /// 変わらないなら、外したかどうかを絵で見分けられない。
    @Test("色掛けを外すと、色掛けをしなかった絵に戻る")
    func noTintRestoresTheUntintedPicture() throws {
        func place(_ canvas: Canvas) throws {
            canvas.image(try quadrantImage(canvas), 10, 12, 36, 20)
        }
        let plain = try render { canvas in try place(canvas) }
        let tinted = try render { canvas in
            canvas.tint(.linear(red: 1, green: 0, blue: 0))
            try place(canvas)
        }
        let restored = try render { canvas in
            canvas.tint(.linear(red: 1, green: 0, blue: 0))
            canvas.noTint()
            try place(canvas)
        }
        #expect(differingPixels(tinted, plain) > 0, "赤の色掛けが絵に出ていない")
        #expect(differingPixels(restored, plain) == 0)
    }

    // MARK: - 形の合成

    /// 完了条件 8。**2 つは色が違い、重なっている** — 並べる順を取り違えると、重なりの
    /// 色が変わる。
    @Test("形の足し算は、同じ順に組にした形と同じ絵になる")
    func addingShapesMatchesGroupingThem() throws {
        func pieces(_ canvas: Canvas) -> (Shape, Shape) {
            let a = canvas.createShape {
                canvas.noStroke()
                canvas.fill(.linear(red: 1, green: 0, blue: 0))
                canvas.rect(8, 8, 30, 24)
            }
            let b = canvas.createShape {
                canvas.noStroke()
                canvas.fill(.linear(red: 0, green: 0, blue: 1))
                canvas.rect(20, 16, 30, 30)
            }
            return (a, b)
        }
        let added = try render { canvas in
            let (a, b) = pieces(canvas)
            canvas.shape(a + b)
        }
        let grouped = try render { canvas in
            let (a, b) = pieces(canvas)
            canvas.shape(Shape.group([a, b]))
        }
        #expect(differingPixels(added, grouped) == 0)
        // 重なり (20…38, 16…32) には後から足した青が乗る
        #expect(added[28, 24] == (0, 0, 255, 255))
    }

    /// 完了条件 9。整えずに読む (`normalize: false`) ので、ファイルの座標がそのまま面の
    /// 座標になる。三角形は 2 枚とも非対称で、上下や左右を取り違えると別の絵になる。
    ///
    /// **光を点けない。** 陰影の質は絵全体を目で見るもので ([#1379] の E)、ここで比べるのは
    /// どこにどの三角形が出るかである。
    ///
    /// [#1379]: https://github.com/mokume-metal/mokume/issues/1379
    @Test("読み込んだモデルは、同じ三角形を並べた形と同じ絵になる")
    func aModelMatchesTheSameTriangles() throws {
        let triangles: [SIMD3<Float>] = [
            SIMD3(8, 6, 0), SIMD3(50, 14, 0), SIMD3(20, 40, 0),
            SIMD3(44, 30, 0), SIMD3(58, 56, 0), SIMD3(12, 52, 0),
        ]
        let text =
            triangles.map { "v \($0.x) \($0.y) \($0.z)" }.joined(separator: "\n")
            + "\nf 1 2 3\nf 4 5 6\n"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("two-triangles.obj")
        try text.write(to: file, atomically: true, encoding: .utf8)

        func style(_ canvas: Canvas) {
            canvas.noStroke()
            canvas.fill(.linear(red: 0.9, green: 0.7, blue: 0.4))
        }
        let loaded = try render { canvas in
            let model = try canvas.loadModel(file.path, normalize: false)
            style(canvas)
            canvas.model(model)
        }
        let placed = try render { canvas in
            style(canvas)
            canvas.beginShape(.triangles)
            for corner in triangles { canvas.vertex(corner.x, corner.y, corner.z) }
            canvas.endShape()
        }
        #expect(inkedPixels(placed) > 0, "並べた三角形が 1 画素も出ていない")
        #expect(differingPixels(loaded, placed) == 0)
    }
}
