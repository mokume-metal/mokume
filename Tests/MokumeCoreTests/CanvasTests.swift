// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 2D 描画の検査。GPU を要する。
///
/// 見るのは**書き出した絵の画素**で、内部の頂点ではない。頂点を数えても
/// 「指定した場所に指定した色で出たか」は分からない。
@Suite(
    "2D 描画",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CanvasTests {
    private let black = LinearRGBA.opaque(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.opaque(red: 1, green: 1, blue: 1)

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    // MARK: - 背景

    @Test("背景は面全体を塗る")
    func backgroundCoversEverything() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        try canvas.draw { canvas.background(.display(red: 1, green: 0, blue: 0)) }

        let image = try pixels(of: canvas)
        for y in 0..<8 {
            for x in 0..<8 {
                #expect(image[x, y] == (255, 0, 0, 255))
            }
        }
    }

    @Test("背景はそれまでに積んだ図形を消す")
    func backgroundWipesShapesDrawnBefore() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        try canvas.draw {
            canvas.fill(white)
            canvas.rect(0, 0, 8, 8)
            canvas.background(black)
        }

        #expect(try pixels(of: canvas)[4, 4] == (0, 0, 0, 255))
    }

    // MARK: - 図形 (ひととおり)

    @Test("正方形は、幅と高さに同じ値を渡した矩形と同じ")
    func squareIsARectangleWithEqualSides() throws {
        let square = try makeCanvas()
        try square.draw {
            square.background(black)
            square.fill(white)
            square.square(10, 10, 20)
        }
        let rectangle = try makeCanvas()
        try rectangle.draw {
            rectangle.background(black)
            rectangle.fill(white)
            rectangle.rect(10, 10, 20, 20)
        }
        #expect(try pixels(of: square).bytes == pixels(of: rectangle).bytes)
    }

    @Test("楕円は横と縦で違う半径を持つ")
    func ellipseStretchesIndependently() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.ellipse(32, 32, 48, 16)  // 横に平たい
        }
        let image = try pixels(of: canvas)
        #expect(image[32, 32] == (255, 255, 255, 255))  // 中心
        #expect(image[52, 32] == (255, 255, 255, 255))  // 横は半径 24 の内側
        #expect(image[32, 52] == (0, 0, 0, 255))  // 縦は半径 8 なので外
    }

    @Test("円弧は指定した向きだけを塗る")
    func arcFillsOnlyTheRequestedSweep() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            // 右向きが 0、増える向きは画面の上で時計回り = 右下の 4 分の 1
            canvas.arc(32, 32, 40, 40, 0, .pi / 2)
        }
        let image = try pixels(of: canvas)
        #expect(image[40, 40] == (255, 255, 255, 255))  // 右下は扇の中
        #expect(image[24, 24] == (0, 0, 0, 255))  // 左上は扇の外
        #expect(image[24, 40] == (0, 0, 0, 255))  // 左下も外
    }

    @Test("三角形は 3 頂点の内側だけを塗る")
    func triangleFillsItsInterior() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.triangle(32, 8, 56, 56, 8, 56)
        }
        let image = try pixels(of: canvas)
        #expect(image[32, 40] == (255, 255, 255, 255))  // 内側
        #expect(image[10, 12] == (0, 0, 0, 255))  // 左上の角の外
    }

    @Test("四角形は頂点を与えた順に結ぶ")
    func quadFollowsTheOrderOfItsVertices() throws {
        let square = try makeCanvas()
        try square.draw {
            square.background(black)
            square.fill(white)
            square.quad(12, 12, 52, 12, 52, 52, 12, 52)
        }
        // 3 番目と 4 番目を入れ替えると、辺が交差して砂時計になる
        let crossed = try makeCanvas()
        try crossed.draw {
            crossed.background(black)
            crossed.fill(white)
            crossed.quad(12, 12, 52, 12, 12, 52, 52, 52)
        }
        // 右上の角は、正方形なら内側・砂時計なら (交差した辺の外へ出るので) 背景
        #expect(try pixels(of: square)[48, 20] == (255, 255, 255, 255))
        #expect(try pixels(of: crossed)[48, 20] == (0, 0, 0, 255))
        #expect(try pixels(of: square).bytes != pixels(of: crossed).bytes)
    }

    @Test("点は線の色と太さで打たれる")
    func pointUsesTheStrokeColorAndWeight() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(.display(red: 0, green: 1, blue: 0))  // 塗りの色は使われない
            canvas.stroke(white)
            canvas.strokeWeight(12)
            canvas.point(32, 32)
        }
        let image = try pixels(of: canvas)
        #expect(image[32, 32] == (255, 255, 255, 255))  // 線の色で打たれる
        #expect(image[32, 42] == (0, 0, 0, 255))  // 半径 6 の外
    }

    // MARK: - 積み降ろし (#235)

    @Test("変換とスタイルは独立に積める")
    func transformAndStyleStackIndependently() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.pushMatrix()  // 変換だけ積む
            canvas.translate(20, 20)
            canvas.fill(blue)  // 積んでいないので、戻しても残る
            canvas.popMatrix()
            canvas.rect(8, 8, 16, 16)  // 変換は戻り、塗りは青のまま
        }
        let image = try pixels(of: canvas)
        #expect(image[16, 16].red < 60)  // 青のまま (白なら red が 255)
        #expect(image[16, 16].blue > 200)
        #expect(image[36, 36] == (0, 0, 0, 255))  // 変換が戻っているので、ずれた場所には出ない
    }

    @Test("スタイルだけを積むと、変換は戻らない")
    func styleStackLeavesTheTransformAlone() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.pushStyle()
            canvas.fill(blue)
            canvas.translate(20, 20)  // 積んでいないので、戻しても残る
            canvas.popStyle()
            canvas.fill(white)
            canvas.rect(8, 8, 16, 16)
        }
        // 変換が残っているので (28, 28) 起点に出る
        #expect(try pixels(of: canvas)[36, 36].red == 255)
    }

    @Test("両方を積むと、両方が戻る")
    func pushRestoresBothAtOnce() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.push()
            canvas.translate(20, 20)
            canvas.fill(blue)
            canvas.pop()
            canvas.rect(8, 8, 16, 16)
        }
        let image = try pixels(of: canvas)
        #expect(image[16, 16].red == 255)  // 塗りが白へ戻っている (青なら red が 0)
        #expect(image[36, 36] == (0, 0, 0, 255))  // 変換も戻っている
    }

    @Test("何も積んでいない状態で降ろしても落ちない")
    func poppingAnEmptyStackIsHarmless() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.pop()
            canvas.popMatrix()
            canvas.popStyle()
            canvas.noStroke()
            canvas.fill(white)
            canvas.rect(8, 8, 16, 16)
        }
        #expect(try pixels(of: canvas)[16, 16].red == 255)
    }

    @Test("積んだスタイルは次のフレームへ漏れない")
    func styleDoesNotLeakIntoTheNextFrame() throws {
        let canvas = try makeCanvas()
        // 1 フレーム目: 積んだまま降ろさずに終える
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.push()
            canvas.fill(blue)
            canvas.translate(20, 20)
        }
        // 2 フレーム目: 積んだものは残っているが、戻せば 1 フレーム目の手前へ帰る
        try canvas.draw {
            canvas.background(black)
            canvas.pop()
            canvas.rect(8, 8, 16, 16)
        }
        let image = try pixels(of: canvas)
        #expect(image[16, 16].red == 255)  // 塗りは白 (1 フレーム目で積んだ値)
        #expect(image[36, 36] == (0, 0, 0, 255))  // 変換も戻っている
    }

    @Test("積んだ変換を捨てても、戻す先は残る")
    func resetMatrixKeepsTheStack() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.translate(30, 30)
            canvas.pushMatrix()
            canvas.resetMatrix()  // いまの変換だけ捨てる
            canvas.rect(4, 4, 8, 8)  // 原点基準で出る
            canvas.popMatrix()
            canvas.rect(4, 4, 8, 8)  // 積んでおいた (30, 30) が戻る
        }
        let image = try pixels(of: canvas)
        #expect(image[8, 8].red == 255)
        #expect(image[38, 38].red == 255)
    }

    @Test("斜めに歪めると、まっすぐな辺が傾く")
    func shearTiltsStraightEdges() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.shearX(.pi / 4)  // 45 度なら y のぶんだけ x がずれる
            canvas.rect(8, 8, 8, 24)
        }
        let image = try pixels(of: canvas)
        #expect(image[20, 12].red == 255)  // y=12 では x が 12 ぶんずれる
        #expect(image[12, 12].red == 0)  // ずれる前の位置には無い
    }

    @Test("点が変換でどこへ移るかを引ける")
    func screenCoordinatesFollowTheTransform() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.translate(20, 10)
            canvas.scale(2, 3)
            #expect(canvas.screenX(5, 5) == 30)  // 20 + 5*2
            #expect(canvas.screenY(5, 5) == 25)  // 10 + 5*3
        }
    }

    // MARK: - 輪郭 (#234)

    private let blue = LinearRGBA.display(red: 0, green: 0.4, blue: 1)
    private let red = LinearRGBA.display(red: 1, green: 0, blue: 0)

    @Test("図形は塗りと輪郭の両方を出す")
    func shapesCarryBothFillAndStroke() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(blue)
            canvas.stroke(red)
            canvas.strokeWeight(4)
            canvas.rect(16, 16, 32, 32)
        }
        let image = try pixels(of: canvas)
        #expect(image[32, 32].blue > 200)  // 内側は塗りの色
        #expect(image[16, 32].red > 200)  // 縁は線の色
        #expect(image[16, 32].blue < 60)
    }

    @Test("塗りを止めると輪郭だけが残る")
    func noFillLeavesOnlyTheOutline() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(blue)
            canvas.noFill()
            canvas.stroke(red)
            canvas.strokeWeight(4)
            canvas.rect(16, 16, 32, 32)
        }
        let image = try pixels(of: canvas)
        #expect(image[32, 32] == (0, 0, 0, 255))  // 内側は背景のまま
        #expect(image[16, 32].red > 200)  // 縁は残る
    }

    @Test("線を止めると塗りだけが残る")
    func noStrokeLeavesOnlyTheFill() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(blue)
            canvas.stroke(red)
            canvas.noStroke()
            canvas.strokeWeight(4)
            canvas.rect(16, 16, 32, 32)
        }
        let image = try pixels(of: canvas)
        #expect(image[32, 32].blue > 200)
        #expect(image[16, 32].red < 60)  // 縁に線の色は無い
    }

    @Test("塗りの色を指定し直すと、止めた塗りが戻る")
    func fillResumesWhenAColorIsGivenAgain() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.fill(blue)  // 呼んだ時点でまた塗るようになる
            canvas.noStroke()
            canvas.rect(16, 16, 32, 32)
        }
        #expect(try pixels(of: canvas)[32, 32].blue > 200)
    }

    // MARK: - 端の形

    /// 太さ 12 の線を (10, 32)-(50, 32) に引いたときの、端の外の画素。
    private func endOfThickLine(cap: StrokeCap, probe: (x: Int, y: Int)) throws -> UInt8 {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.stroke(white)
            canvas.strokeWeight(12)
            canvas.strokeCap(cap)
            canvas.line(10, 32, 50, 32)
        }
        return try pixels(of: canvas)[probe.x, probe.y].red
    }

    @Test("端を切る形は、線の長さちょうどで止まる")
    func squareCapStopsAtTheGivenLength() throws {
        #expect(try endOfThickLine(cap: .square, probe: (52, 32)) == 0)
        #expect(try endOfThickLine(cap: .square, probe: (48, 32)) == 255)
    }

    @Test("出っ張らせる形は、太さの半分だけ伸びる")
    func projectCapExtendsByHalfTheWeight() throws {
        #expect(try endOfThickLine(cap: .project, probe: (52, 32)) == 255)  // 56 まで伸びる
        #expect(try endOfThickLine(cap: .project, probe: (58, 32)) == 0)
    }

    @Test("丸める形は、四角い端では届く角に届かない")
    func roundCapCutsTheCorners() throws {
        // (55, 36) は中心 (50, 32) から 6.4 画素 — 半径 6 の円の外、四角の内
        #expect(try endOfThickLine(cap: .round, probe: (55, 36)) == 0)
        #expect(try endOfThickLine(cap: .project, probe: (55, 36)) == 255)
        #expect(try endOfThickLine(cap: .round, probe: (54, 32)) == 255)  // 真横は円の内
    }

    // MARK: - 折れ目の形

    /// 直角に折れた線の、外側の角の画素。
    private func outerCornerOfBend(join: StrokeJoin) throws -> UInt8 {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(12)
            canvas.strokeJoin(join)
            // 直角の角を持つ閉じた形
            canvas.rect(20, 20, 24, 24)
        }
        // 左上の角の、いちばん外側 (角から 6 画素ぶん外へ)
        return try pixels(of: canvas)[15, 15].red
    }

    @Test("角を丸めると、四角い角には出る画素が出ない")
    func roundJoinCutsTheOuterCorner() throws {
        #expect(try outerCornerOfBend(join: .round) == 0)
        #expect(try outerCornerOfBend(join: .bevel) == 255)
    }

    @Test("尖らせる形は、いまは削ぐ形と同じ")
    func miterMatchesBevelForNow() throws {
        // 伸びの限界を持つ尖りはまだ実装していない (StrokeJoin.miter の注記)。
        // 作り込んだときにこの検査が赤くなり、意図した変更として扱える
        #expect(try outerCornerOfBend(join: .miter) == outerCornerOfBend(join: .bevel))
    }

    @Test("閉じた図形の輪郭に隙間が無い")
    func closedOutlinesHaveNoGaps() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(6)
            canvas.strokeJoin(.bevel)
            canvas.triangle(32, 12, 52, 48, 12, 48)
        }
        let image = try pixels(of: canvas)
        // 3 つの頂点そのものが塗られている (帯を線分ごとに置くだけだと角が欠ける)
        #expect(image[32, 12].red == 255)
        #expect(image[52, 48].red == 255)
        #expect(image[12, 48].red == 255)
    }

    // MARK: - 描けない線

    @Test("太さを持たない線は何も描かない", arguments: [0, -4] as [Float])
    func linesWithoutWeightDrawNothing(_ weight: Float) throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.stroke(white)
            canvas.strokeWeight(weight)
            canvas.line(8, 32, 56, 32)
            canvas.point(32, 8)
        }
        let image = try pixels(of: canvas)
        #expect(image[32, 32] == (0, 0, 0, 255))
        #expect(image[32, 8] == (0, 0, 0, 255))
    }

    @Test("長さのない線でも落ちず、端の形だけが残る")
    func zeroLengthLineLeavesOnlyItsCaps() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.stroke(white)
            canvas.strokeWeight(10)
            canvas.strokeCap(.round)
            canvas.line(32, 32, 32, 32)  // 同じ点
        }
        // 帯は出ないが、端の形は両端ぶん置かれる
        #expect(try pixels(of: canvas)[32, 32].red == 255)
    }

    // MARK: - 位置の基準

    @Test("読み方が違えば、同じ矩形を別の引数で書ける")
    func everyRectModeCanExpressTheSameRectangle() throws {
        // どれも左上 (20, 20) から 20x20 を指す
        let cases: [(ShapeMode, (Float, Float, Float, Float))] = [
            (.corner, (20, 20, 20, 20)),
            (.corners, (20, 20, 40, 40)),
            (.center, (30, 30, 20, 20)),
            (.radius, (30, 30, 10, 10)),
        ]
        var images: [DisplayImage] = []
        for (mode, args) in cases {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.rectMode(mode)
                canvas.rect(args.0, args.1, args.2, args.3)
            }
            images.append(try pixels(of: canvas))
        }
        for image in images.dropFirst() {
            #expect(image.bytes == images[0].bytes)
        }
        #expect(images[0][25, 25] == (255, 255, 255, 255))
        #expect(images[0][45, 45] == (0, 0, 0, 255))
    }

    @Test("同じ引数でも、読み方が変われば別の場所に出る")
    func theSameArgumentsLandElsewhereUnderAnotherMode() throws {
        let corner = try makeCanvas()
        try corner.draw {
            corner.background(black)
            corner.fill(white)
            corner.rect(20, 20, 20, 20)  // 既定 = corner
        }
        let center = try makeCanvas()
        try center.draw {
            center.background(black)
            center.fill(white)
            center.rectMode(.center)
            center.rect(20, 20, 20, 20)  // 中心 (20, 20) なので左上へ寄る
        }
        #expect(try pixels(of: corner)[36, 36] == (255, 255, 255, 255))
        #expect(try pixels(of: center)[36, 36] == (0, 0, 0, 255))
        #expect(try pixels(of: center)[14, 14] == (255, 255, 255, 255))
    }

    @Test("楕円の読み方は円にも効く")
    func circleFollowsTheEllipseMode() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.ellipseMode(.radius)
            canvas.circle(32, 32, 10)  // 半径として読むので直径 20
        }
        let image = try pixels(of: canvas)
        #expect(image[32, 32] == (255, 255, 255, 255))
        #expect(image[40, 32] == (255, 255, 255, 255))  // 半径 10 の内側
        #expect(image[32, 46] == (0, 0, 0, 255))  // 外側
    }

    // MARK: - 描けない指定

    @Test("角度が逆向きの円弧は何も描かない")
    func reversedArcDrawsNothing() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.arc(32, 32, 40, 40, .pi, 0)
        }
        let image = try pixels(of: canvas)
        for y in stride(from: 0, to: 64, by: 8) {
            for x in stride(from: 0, to: 64, by: 8) {
                #expect(image[x, y] == (0, 0, 0, 255))
            }
        }
    }

    @Test("大きさを持たない図形は何も描かない", arguments: [0, -20] as [Float])
    func degenerateShapesDrawNothing(_ size: Float) throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.rect(20, 20, size, size)
            canvas.circle(32, 32, size)
            canvas.ellipse(32, 32, size, 20)
        }
        let image = try pixels(of: canvas)
        for y in stride(from: 0, to: 64, by: 8) {
            for x in stride(from: 0, to: 64, by: 8) {
                #expect(image[x, y] == (0, 0, 0, 255))
            }
        }
    }

    // MARK: - 図形

    @Test("矩形は指定した場所に、指定した大きさで出る")
    func rectangleLandsWhereItWasAsked() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.noStroke()  // ここで見るのは塗りの位置と大きさ
            canvas.rect(10, 20, 4, 8)
        }

        let image = try pixels(of: canvas)
        // 内側の 4x8 が塗られている
        for y in 20..<28 {
            for x in 10..<14 {
                #expect(image[x, y].red == 255, "(\(x), \(y)) が塗られていない")
            }
        }
        // 1 画素外は塗られていない
        #expect(image[9, 24].red == 0)
        #expect(image[14, 24].red == 0)
        #expect(image[12, 19].red == 0)
        #expect(image[12, 28].red == 0)
    }

    @Test("円は中心が指定した場所で、直径ぶんの広がりを持つ")
    func circleIsCenteredWhereItWasAsked() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.circle(32, 32, 20)
        }

        let image = try pixels(of: canvas)
        #expect(image[32, 32].red == 255)
        // 半径 10 の内側と外側
        #expect(image[32 + 8, 32].red == 255)
        #expect(image[32, 32 - 8].red == 255)
        #expect(image[32 + 12, 32].red == 0)
        #expect(image[32, 32 + 12].red == 0)
    }

    @Test("太さ 1 の線は、整数の座標では 1 画素に収まる")
    func hairlineCoversExactlyOneColumn() throws {
        // 座標の約束のうち、半画素のずらしが効いているかを見る唯一の検査。
        // ずらしが無いと、隣の列が塗られるか 2 列にまたがる。
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.stroke(white)
            canvas.strokeWeight(1)
            canvas.line(10, 0, 10, 64)
        }

        let image = try pixels(of: canvas)
        #expect(image[10, 32].red == 255, "指定した列が塗られていない")
        #expect(image[9, 32].red == 0, "左隣まで塗られている")
        #expect(image[11, 32].red == 0, "右隣まで塗られている")
    }

    @Test("線の太さは指定した画素数になる")
    func strokeWeightWidensTheLine() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.stroke(white)
            canvas.strokeWeight(4)
            canvas.line(20, 0, 20, 64)
        }

        let image = try pixels(of: canvas)
        let painted = (0..<64).filter { image[$0, 32].red == 255 }
        #expect(painted == [18, 19, 20, 21])
    }

    // MARK: - 変換

    @Test("平行移動は図形をずらす")
    func translateMovesShapes() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.translate(10, 5)
            canvas.rect(0, 0, 4, 4)
        }

        let image = try pixels(of: canvas)
        #expect(image[10, 5].red == 255)
        #expect(image[13, 8].red == 255)
        #expect(image[0, 0].red == 0)
    }

    @Test("拡大は図形を伸ばす")
    func scaleStretchesShapes() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.noStroke()  // ここで見るのは塗りの伸び方
            canvas.scale(4, 1)
            canvas.rect(2, 10, 2, 4)
        }

        let image = try pixels(of: canvas)
        // x は 4 倍されて 8…15、y は変わらず 10…13
        #expect(image[8, 11].red == 255)
        #expect(image[15, 11].red == 255)
        #expect(image[16, 11].red == 0)
        #expect(image[8, 14].red == 0)
    }

    @Test("積んだ変換へ戻せる")
    func pushAndPopRestoreTheTransform() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.push()
            canvas.translate(30, 30)
            canvas.rect(0, 0, 4, 4)
            canvas.pop()
            // 戻したので、次の矩形は原点に出る
            canvas.rect(0, 0, 4, 4)
        }

        let image = try pixels(of: canvas)
        #expect(image[31, 31].red == 255)
        #expect(image[1, 1].red == 255)
    }

    @Test("積んでいないのに戻しても壊れない")
    func popWithoutPushIsHarmless() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        try canvas.draw {
            canvas.background(black)
            canvas.pop()
            canvas.fill(white)
            canvas.rect(0, 0, 8, 8)
        }
        #expect(try pixels(of: canvas)[4, 4].red == 255)
    }

    // MARK: - 色

    @Test("見た目で指定した色が、そのまま出る")
    func displayColorSurvivesTheRoundTrip() throws {
        // 入口で線形へ戻し、出口で同じ変換を掛けるので、往復すれば元の見た目に戻る
        // (ADR-0011 決定 3 の入口と出口が対になっていることの確認)。
        //
        // **ぴたりとは戻らない。** 途中の作業空間は半精度浮動小数なので、線形へ
        // 落として戻す間に最下位の桁が動く。8 bit にした後の許容を 1 段に取るのは
        // そのため — ここを 0 段にすると、精度の話でしか落ちない検査になる。
        let canvas = try makeCanvas(width: 4, height: 4)
        try canvas.draw {
            canvas.background(.display(red: 0.25, green: 0.5, blue: 0.75))
        }

        let pixel = try pixels(of: canvas)[0, 0]
        #expect(abs(Int(pixel.red) - 64) <= 1)
        #expect(abs(Int(pixel.green) - 128) <= 1)
        #expect(abs(Int(pixel.blue) - 191) <= 1)
        #expect(pixel.alpha == 255)
    }

    @Test("半透明の図形は下の色と混ざる")
    func translucentShapesBlendWithWhatIsBelow() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        try canvas.draw {
            canvas.background(black)
            canvas.fill(LinearRGBA(straightRed: 1, green: 1, blue: 1, alpha: 0.5))
            canvas.rect(0, 0, 8, 8)
        }

        // 線形で 0.5 の灰色 → 出力段を経て 188
        #expect(try pixels(of: canvas)[4, 4] == (188, 188, 188, 255))
    }
}
