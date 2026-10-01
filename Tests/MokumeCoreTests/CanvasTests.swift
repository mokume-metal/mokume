// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
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
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    // MARK: - 背景

    @Test("背景は面全体を塗る")
    func backgroundCoversEverything() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        // 作業空間の原色で塗る。純色のまま 255 / 0 に出るので、全画素を完全一致で読める
        try canvas.draw { canvas.background(.linear(red: 1, green: 0, blue: 0)) }

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
            canvas.arc(32, 32, 40, 40, 0, Float.pi / 2)
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

    // MARK: - 頂点を並べて描く (#237)

    @Test("凹んだ形が、へこみの外へはみ出さずに塗られる")
    func concaveShapesDoNotBulge() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            // 上辺の真ん中が深くへこんだ形
            canvas.beginShape()
            canvas.vertex(8, 8)
            canvas.vertex(32, 48)
            canvas.vertex(56, 8)
            canvas.vertex(56, 56)
            canvas.vertex(8, 56)
            canvas.endShape(.close)
        }
        let image = try pixels(of: canvas)
        #expect(image[32, 52].red == 255)  // 下の広い部分は塗られる
        #expect(image[32, 16] == (0, 0, 0, 255))  // へこみの中は塗られない
        #expect(image[12, 50].red == 255)  // へこみの左脇は形の内側
        // 左上の角は V 字の腕の外側。扇状に分けるとここまではみ出す
        #expect(image[12, 12] == (0, 0, 0, 255))
    }

    @Test("穴が開く")
    func contoursPunchHoles() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.beginShape()
            canvas.vertex(8, 8)
            canvas.vertex(56, 8)
            canvas.vertex(56, 56)
            canvas.vertex(8, 56)
            canvas.beginContour()
            canvas.vertex(24, 24)
            canvas.vertex(24, 40)
            canvas.vertex(40, 40)
            canvas.vertex(40, 24)
            canvas.endContour()
            canvas.endShape(.close)
        }
        let image = try pixels(of: canvas)
        #expect(image[32, 32] == (0, 0, 0, 255))  // 穴の中は背景
        #expect(image[14, 32].red == 255)  // 穴の外側は塗られている
        #expect(image[48, 32].red == 255)
    }

    /// 閉じ忘れた穴は ``Canvas/endShape(_:)`` が畳む。**次の穴を開いたときも同じ規則で畳む**
    /// ([#1528])。直す前は、開いていた穴の点を捨てて新しい穴を始めていたので、1 つ目の穴が
    /// 描かれなかった。
    ///
    /// [#1528]: https://github.com/mokume-metal/mokume/issues/1528
    @Test("穴を開いたまま次の穴を開いても、前の穴は畳まれて空く")
    func reopeningAContourKeepsTheOpenHole() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.beginShape()
            canvas.vertex(4, 4)
            canvas.vertex(60, 4)
            canvas.vertex(60, 60)
            canvas.vertex(4, 60)
            canvas.beginContour()  // 閉じ忘れる
            canvas.vertex(10, 16)
            canvas.vertex(10, 48)
            canvas.vertex(28, 32)
            canvas.beginContour()
            canvas.vertex(36, 16)
            canvas.vertex(36, 48)
            canvas.vertex(54, 32)
            canvas.endContour()
            canvas.endShape(.close)
        }
        let image = try pixels(of: canvas)
        #expect(image[16, 32] == (0, 0, 0, 255))  // 1 つ目の穴の中は背景
        #expect(image[42, 32] == (0, 0, 0, 255))  // 2 つ目の穴の中も背景
        #expect(image[32, 32].red == 255)  // 2 つの穴の間は塗られている
        #expect(image[32, 8].red == 255)
        for key in [Canvas.Warning.vertexOutsideShape, .contourNotBegun, .curveWithoutStart] {
            #expect(!canvas.warnings.hasWarned(key), "閉じ忘れを畳むだけの形で \(key) を言った")
        }
    }

    @Test("点の列として読むと、点が並ぶ")
    func pointsKindPlacesDots() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.stroke(white)
            canvas.strokeWeight(6)
            canvas.beginShape(.points)
            canvas.vertex(16, 32)
            canvas.vertex(48, 32)
            canvas.endShape()
        }
        let image = try pixels(of: canvas)
        #expect(image[16, 32].red == 255)
        #expect(image[48, 32].red == 255)
        #expect(image[32, 32] == (0, 0, 0, 255))  // 点の間は繋がらない
    }

    @Test("線の列として読むと、2 点ずつ独立した線になる")
    func linesKindPairsPoints() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.stroke(white)
            canvas.strokeWeight(4)
            canvas.beginShape(.lines)
            canvas.vertex(8, 16)
            canvas.vertex(24, 16)
            canvas.vertex(40, 48)
            canvas.vertex(56, 48)
            canvas.endShape()
        }
        let image = try pixels(of: canvas)
        #expect(image[16, 16].red == 255)
        #expect(image[48, 48].red == 255)
        #expect(image[32, 32] == (0, 0, 0, 255))  // 2 本目の始点へは繋がらない
    }

    @Test("三角形の列として読むと、3 点ずつ独立した三角形になる")
    func trianglesKindGroupsThree() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.beginShape(.triangles)
            canvas.vertex(8, 8)
            canvas.vertex(24, 8)
            canvas.vertex(16, 24)
            canvas.vertex(40, 40)
            canvas.vertex(56, 40)
            canvas.vertex(48, 56)
            canvas.endShape()
        }
        let image = try pixels(of: canvas)
        #expect(image[16, 14].red == 255)
        #expect(image[48, 46].red == 255)
        #expect(image[32, 32] == (0, 0, 0, 255))  // 間は埋まらない
    }

    @Test("帯として読むと、直前の 2 点を使い回した三角形が繋がる")
    func triangleStripReusesTheLastTwoPoints() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            // 上下に交互に置いた 5 点。使い回しが効けば 3 枚が隙間なく繋がる
            canvas.beginShape(.triangleStrip)
            canvas.vertex(8, 8)
            canvas.vertex(8, 56)
            canvas.vertex(32, 8)
            canvas.vertex(32, 56)
            canvas.vertex(56, 8)
            canvas.endShape()
        }
        let image = try pixels(of: canvas)
        #expect(image[16, 32].red == 255)  // 1 枚目
        #expect(image[28, 32].red == 255)  // 2 枚目 (直前の 2 点を使い回す)
        // 3 枚目。5 点を 3 点ずつ独立に読んだのなら、ここまでは届かない
        #expect(image[40, 20].red == 255)
        #expect(image[48, 14].red == 255)
        #expect(image[50, 50] == (0, 0, 0, 255))  // 帯の外
    }

    @Test("扇として読むと、最初の 1 点をすべての三角形が共有する")
    func triangleFanSharesTheFirstPoint() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            // 左下の要から右上へ開く 4 点。3 点目からは要と直前の点を使い回す
            canvas.beginShape(.triangleFan)
            canvas.vertex(8, 56)
            canvas.vertex(8, 8)
            canvas.vertex(32, 8)
            canvas.vertex(56, 8)
            canvas.endShape()
        }
        let image = try pixels(of: canvas)
        #expect(image[14, 24].red == 255)  // 1 枚目 (要のそば)
        // 2 枚目。4 点を 3 点ずつ独立に読んだのなら 1 枚しか出ないので、ここは黒のまま
        #expect(image[32, 24].red == 255)
        #expect(image[50, 50] == (0, 0, 0, 255))  // 扇の外
    }

    @Test("帯も扇も、3 点に満たなければ何も描かれない")
    func reusingKindsNeedThreePoints() throws {
        for kind in [VertexKind.triangleStrip, .triangleFan] {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.fill(white)
                canvas.beginShape(kind)
                canvas.vertex(8, 8)
                canvas.vertex(56, 56)
                canvas.endShape()
            }
            let image = try pixels(of: canvas)
            #expect(image[32, 32] == (0, 0, 0, 255), "\(kind) が 2 点で何かを描いた")
        }
    }

    // MARK: - 四角の列

    /// 頂点を並べて `body` で描き、絵を返す。下地は黒・輪郭なし・塗りは白から始める。
    private func renderShape(_ body: (Canvas) -> Void) throws -> DisplayImage {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            body(canvas)
        }
        return try pixels(of: canvas)
    }

    @Test("四角の列として読むと、4 点ずつ独立した四角になる")
    func quadsKindGroupsFour() throws {
        let image = try renderShape { canvas in
            canvas.beginShape(.quads)
            canvas.vertex(4, 4)
            canvas.vertex(28, 4)
            canvas.vertex(28, 28)
            canvas.vertex(4, 28)
            canvas.vertex(36, 36)
            canvas.vertex(60, 36)
            canvas.vertex(60, 60)
            canvas.vertex(36, 60)
            canvas.endShape()
        }
        // どちらの四角も、対角線の両側が塗られる。3 点ずつ読むと片側の三角形しか出ない
        #expect(image[22, 10].red == 255)
        #expect(image[10, 22].red == 255)
        #expect(image[54, 42].red == 255)
        #expect(image[42, 54].red == 255)
        #expect(image[32, 32] == (0, 0, 0, 255))  // 2 つの四角の間は繋がらない
        #expect(image[8, 50] == (0, 0, 0, 255))
    }

    @Test("四角の列は、4 点に満たない余りを描かない")
    func quadsDropTheRemainder() throws {
        let corners: [(Float, Float)] = [
            (4, 4), (28, 4), (28, 28), (4, 28), (36, 36), (60, 36), (48, 60),
        ]
        func render(points: Int) throws -> DisplayImage {
            try renderShape { canvas in
                canvas.beginShape(.quads)
                for corner in corners.prefix(points) { canvas.vertex(corner.0, corner.1) }
                canvas.endShape()
            }
        }
        // 7 点なら 1 つ目の四角だけが出て、余りの 3 点が作る三角形の中は下地のまま
        let seven = try render(points: 7)
        #expect(seven[22, 10].red == 255)
        #expect(seven[10, 22].red == 255)
        #expect(seven[48, 42] == (0, 0, 0, 255))
        // 3 点だけなら何も描かれない
        let three = try render(points: 3)
        #expect(three[22, 10] == (0, 0, 0, 255))
        #expect(three[16, 16] == (0, 0, 0, 255))
    }

    @Test(
        "凸の四角は、`.triangles` で `[0, 1, 2, 0, 2, 3]` と書いた絵と一致する",
        arguments: [false, true])
    func convexQuadsSplitAlongTheFirstDiagonal(_ reversed: Bool) throws {
        // 4 隅の色は 0 と 2 が白、1 と 3 が黒。対角線 0–2 で割れば中心は白く、1–3 で割れば黒い。
        // 並べる向きで割り方が変わらないことを、時計回りと反時計回りの両方で見る
        let corners: [(Float, Float)] =
            reversed ? [(8, 8), (8, 56), (56, 56), (56, 8)] : [(8, 8), (56, 8), (56, 56), (8, 56)]
        func place(_ canvas: Canvas, _ order: [Int]) {
            for index in order {
                canvas.fill(index.isMultiple(of: 2) ? white : black)
                canvas.vertex(corners[index].0, corners[index].1)
            }
        }
        let byQuads = try renderShape { canvas in
            canvas.beginShape(.quads)
            place(canvas, [0, 1, 2, 3])
            canvas.endShape()
        }
        let byTriangles = try renderShape { canvas in
            canvas.beginShape(.triangles)
            place(canvas, [0, 1, 2, 0, 2, 3])
            canvas.endShape()
        }
        #expect(byQuads == byTriangles)
        #expect(byQuads[31, 31].red > 200, "中心が対角線 0–2 の上にない")
    }

    @Test("読み取り位置も、平行四辺形でない四角では対角線 0–2 を境に移る")
    func quadsReadThePictureAlongTheFirstDiagonal() throws {
        // 平行四辺形でない四角では、読み取り位置が三角形ごとに線形に写るので、対角線の選び方が
        // 継ぎ目として絵に出る
        let corners: [(Float, Float)] = [(8, 6), (58, 10), (50, 58), (12, 52)]
        let coordinates: [(Float, Float)] = [(0, 0), (8, 0), (8, 8), (0, 8)]
        func render(_ kind: VertexKind, _ order: [Int]) throws -> DisplayImage {
            let canvas = try makeCanvas()
            let picture = try canvas.createImage(8, 8)
            for y in 0..<8 {
                for x in 0..<8 {
                    picture.set(
                        x, y,
                        .display(
                            red: Float(x) / 7, green: Float(y) / 7,
                            blue: (x + y).isMultiple(of: 2) ? 1 : 0))
                }
            }
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.texture(picture)
                canvas.beginShape(kind)
                for index in order {
                    canvas.vertex(
                        corners[index].0, corners[index].1, coordinates[index].0,
                        coordinates[index].1)
                }
                canvas.endShape()
            }
            return try pixels(of: canvas)
        }
        let byQuads = try render(.quads, [0, 1, 2, 3])
        #expect(byQuads == (try render(.triangles, [0, 1, 2, 0, 2, 3])))
        #expect(byQuads != (try render(.triangles, [1, 2, 3, 1, 3, 0])), "対角線を変えても絵が動かない")
    }

    @Test(
        "縮退した四角は、隣り合う 2 点が重なれば三角形として塗り、4 点が一直線なら塗らない",
        arguments: [0, 1, 2, 3], [false, true])
    func degenerateQuadsAreHarmless(_ doubled: Int, _ hasDepth: Bool) throws {
        func place(_ canvas: Canvas, _ corner: (Float, Float)) {
            if hasDepth { canvas.vertex(corner.0, corner.1, 0) } else { canvas.vertex(corner.0, corner.1) }
        }
        let square: [(Float, Float)] = [(8, 8), (56, 8), (56, 56), (8, 56)]

        // doubled 番目の点を次の点に重ねた四角は、残りの 3 点の三角形と同じ絵になる
        var overlapped = square
        overlapped[(doubled + 1) % 4] = square[doubled]
        let byQuads = try renderShape { canvas in
            canvas.beginShape(.quads)
            for corner in overlapped { place(canvas, corner) }
            canvas.endShape()
        }
        let remaining = [square[doubled], square[(doubled + 2) % 4], square[(doubled + 3) % 4]]
        let byTriangle = try renderShape { canvas in
            canvas.beginShape(.triangles)
            for corner in remaining { place(canvas, corner) }
            canvas.endShape()
        }
        #expect(byQuads == byTriangle)
        let centre = (
            remaining.reduce(0) { $0 + $1.0 } / 3, remaining.reduce(0) { $0 + $1.1 } / 3
        )
        #expect(byQuads[Int(centre.0), Int(centre.1)].red == 255, "三角形が塗られていない")

        // 4 点が一直線なら面積が無く、何も塗られない
        let flat = try renderShape { canvas in
            canvas.beginShape(.quads)
            for step in 0..<4 { place(canvas, (8 + Float(step) * 16, 8 + Float(step) * 16)) }
            canvas.endShape()
        }
        #expect(flat == (try renderShape { _ in }))
    }

    @Test("四角の線は 4 辺の輪郭になり、対角線は引かない")
    func quadsOutlineHasNoDiagonal() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(.linear(red: 1, green: 0, blue: 0))
            canvas.stroke(white)
            canvas.strokeWeight(4)
            canvas.beginShape(.quads)
            canvas.vertex(8, 8)
            canvas.vertex(56, 8)
            canvas.vertex(56, 56)
            canvas.vertex(8, 56)
            canvas.endShape()
        }
        let image = try pixels(of: canvas)
        // 4 辺の上は線の色
        for (x, y) in [(32, 8), (56, 32), (32, 56), (8, 32)] {
            #expect(image[x, y] == (255, 255, 255, 255), "(\(x), \(y)) が辺の上で線の色でない")
        }
        // 対角線 (辺から十分に離れた所) は塗りの色のまま。三角形ごとに輪郭を引くと線が通る
        for (x, y) in [(32, 32), (20, 20), (44, 44)] {
            #expect(image[x, y] == (255, 0, 0, 255), "(\(x), \(y)) が対角線の上で塗りの色でない")
        }
    }

    @Test("四角の列も、切り抜いた外へは描かれない")
    func quadsStayInsideTheClip() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.clip(0, 0, 32, 64)
            canvas.beginShape(.quads)
            canvas.vertex(8, 8)
            canvas.vertex(56, 8)
            canvas.vertex(56, 56)
            canvas.vertex(8, 56)
            canvas.endShape()
        }
        let image = try pixels(of: canvas)
        #expect(image[16, 32].red == 255)
        #expect(image[48, 32] == (0, 0, 0, 255))
    }

    @Test("四角の列は、途中から記録して別の場所へ置き直しても、その場で描いた絵と同じになる")
    func retainedQuadsMatchImmediate() throws {
        // 保持の経路にしか無い食い違いを狙う。**前に別の図形があると、記録の区間は溜め場の途中から
        // 始まる** — 記録は区間の頭を形自身の 0 起点へ引き戻すので、引き戻しを誤ると別の頂点を
        // 指す。しかも別の場所へ置き直すので、置き直しの変換も絵に出る
        func decoy(_ canvas: Canvas) {
            canvas.fill(white)
            canvas.quad(40, 2, 62, 2, 62, 14, 40, 14)
        }
        func quads(_ canvas: Canvas) {
            canvas.beginShape(.quads)
            canvas.fill(.linear(red: 1, green: 0.2, blue: 0.1))
            canvas.vertex(6, 8)
            canvas.fill(.linear(red: 0.1, green: 1, blue: 0.2))
            canvas.vertex(30, 6)
            canvas.fill(.linear(red: 0.2, green: 0.1, blue: 1))
            canvas.vertex(28, 30)
            canvas.fill(.linear(red: 1, green: 1, blue: 0.1))
            canvas.vertex(8, 26)
            // 凹んだ四角と、余りの 2 点
            canvas.vertex(36, 36)
            canvas.vertex(58, 44)
            canvas.vertex(36, 58)
            canvas.vertex(44, 44)
            canvas.vertex(6, 40)
            canvas.vertex(20, 50)
            canvas.endShape()
        }
        let immediate = try makeCanvas()
        try immediate.draw {
            immediate.background(black)
            immediate.noStroke()
            decoy(immediate)
            immediate.push()
            immediate.translate(5, 3)
            quads(immediate)
            immediate.pop()
        }
        let retained = try makeCanvas()
        try retained.draw {
            retained.background(black)
            retained.noStroke()
            decoy(retained)
            let held = retained.createShape { quads(retained) }
            retained.shape(held, 5, 3)
        }
        let picture = try pixels(of: immediate)
        #expect(picture == (try pixels(of: retained)))
        #expect(picture[23, 21].red > 0, "空の絵を比べている")
        #expect(picture[50, 8].red == 255, "前の図形が描かれていない")
    }

    @Test("番号で指した四角の列は、範囲外の番号を含む四角だけが落ち、区切りはずれない")
    func indexedQuadsDropOnlyTheOutOfRangeQuad() throws {
        func render(_ numbers: [Int]) throws -> DisplayImage {
            try renderShape { canvas in
                canvas.beginShape(.quads)
                for corner in [
                    (4, 4), (28, 4), (28, 28), (4, 28), (36, 36), (60, 36), (60, 60), (36, 60),
                ] as [(Float, Float)] {
                    canvas.vertex(corner.0, corner.1)
                }
                for number in numbers { canvas.index(number) }
                canvas.endShape()
            }
        }
        // 2 つ目の四角が範囲外の番号を含む → 1 つ目だけが出る
        let first = try render([0, 1, 2, 3, 4, 5, 6, 99])
        #expect(first[22, 10].red == 255)
        #expect(first[54, 42] == (0, 0, 0, 255))
        // 1 つ目が範囲外の番号を含む → 2 つ目だけが出る (3 点ずつ・4 点ずつの区切りがずれない)
        let second = try render([0, 1, 2, 99, 4, 5, 6, 7])
        #expect(second[22, 10] == (0, 0, 0, 255))
        #expect(second[54, 42].red == 255)
        #expect(second[42, 54].red == 255)
        // 6 個なら 1 つ目の四角と余りの 2 個で、余りは捨てる
        let remainder = try render([0, 1, 2, 3, 4, 5])
        #expect(remainder[22, 10].red == 255)
        #expect(remainder[54, 42] == (0, 0, 0, 255))
    }

    @Test("閉じない指定では、最後の点から最初へ戻らない")
    func openShapesDoNotCloseTheOutline() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(4)
            canvas.beginShape()
            canvas.vertex(16, 16)
            canvas.vertex(48, 16)
            canvas.vertex(48, 48)
            canvas.endShape(.open)
        }
        // 戻り道 (48,48)-(16,16) の途中には何も無い
        #expect(try pixels(of: canvas)[30, 30] == (0, 0, 0, 255))
    }

    @Test("曲線は、分割数を上げると滑らかになる")
    func curveDetailChangesSmoothness() throws {
        func render(detail: Int) throws -> DisplayImage {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noFill()
                canvas.stroke(white)
                canvas.strokeWeight(2)
                canvas.curveDetail(detail)
                canvas.beginShape()
                canvas.vertex(8, 56)
                canvas.bezierVertex(8, 8, 56, 8, 56, 56)
                canvas.endShape()
            }
            return try pixels(of: canvas)
        }
        let coarse = try render(detail: 2)
        let fine = try render(detail: 40)
        #expect(coarse.bytes != fine.bytes)  // 近似の粗さが絵に出る
        // どちらも両端は通る
        #expect(fine[8, 56].red > 0 || fine[9, 55].red > 0)
    }

    @Test("2 次の曲線も引ける")
    func quadraticCurvesAreDrawn() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(3)
            canvas.beginShape()
            canvas.vertex(8, 48)
            canvas.quadraticVertex(32, 8, 56, 48)
            canvas.endShape()
        }
        let image = try pixels(of: canvas)
        #expect(image[32, 28].red > 0)  // 山の頂点あたりを通る
        #expect(image[32, 48] == (0, 0, 0, 255))  // 弦の上は通らない
    }

    @Test("通過点を結ぶ曲線は、内側の点を通る")
    func curveVerticesPassThroughTheMiddlePoints() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(5)
            canvas.beginShape()
            canvas.curveVertex(8, 32)  // 曲がり方を決めるだけ
            canvas.curveVertex(20, 32)
            canvas.curveVertex(44, 32)
            canvas.curveVertex(56, 32)  // 曲がり方を決めるだけ
            canvas.endShape()
        }
        let image = try pixels(of: canvas)
        #expect(image[32, 32].red == 255)  // 内側の 2 点の間は引かれる
    }

    @Test("並べ始めていないのに頂点を置いても落ちない")
    func strayVerticesAreIgnored() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.vertex(10, 10)
            canvas.bezierVertex(1, 2, 3, 4, 5, 6)
            canvas.endContour()
            canvas.endShape()
            canvas.noStroke()
            canvas.fill(white)
            canvas.rect(8, 8, 16, 16)
        }
        #expect(try pixels(of: canvas)[16, 16].red == 255)
    }

    @Test("点が 2 つに満たない形でも落ちない", arguments: [0, 1])
    func degenerateShapesAreHarmless(_ count: Int) throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.beginShape()
            for index in 0..<count { canvas.vertex(Float(index) * 8 + 16, 32) }
            canvas.endShape(.close)
        }
        #expect(try pixels(of: canvas)[8, 8] == (0, 0, 0, 255))
    }

    // MARK: - 切り抜き

    @Test("切り抜いた外へは描かれない")
    func clippingKeepsPaintInside() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.clip(16, 16, 32, 32)
            canvas.rect(0, 0, 64, 64)
        }
        let image = try pixels(of: canvas)
        #expect(image[32, 32].red == 255)  // 内側
        #expect(image[8, 8] == (0, 0, 0, 255))  // 外側
        #expect(image[56, 56] == (0, 0, 0, 255))
    }

    @Test("切り抜きをやめると、また全体へ描ける")
    func noClipRestoresTheWholeSurface() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.clip(16, 16, 8, 8)
            canvas.noClip()
            canvas.rect(0, 0, 64, 64)
        }
        #expect(try pixels(of: canvas)[56, 56].red == 255)
    }

    @Test("切り抜きは積み降ろしで戻る")
    func clippingIsRestoredByTheStyleStack() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.pushStyle()
            canvas.clip(16, 16, 16, 16)
            canvas.popStyle()
            canvas.rect(0, 0, 64, 64)
        }
        #expect(try pixels(of: canvas)[56, 56].red == 255)  // 切り抜きが戻っている
    }

    @Test("面の外を指しても落ちない", arguments: [
        (Float(-100), Float(-100), Float(500), Float(500)),
        (Float(200), Float(200), Float(10), Float(10)),
        (Float(10), Float(10), Float(-5), Float(-5)),
    ])
    func outOfBoundsClipsAreHarmless(_ box: (Float, Float, Float, Float)) throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.clip(box.0, box.1, box.2, box.3)
            canvas.rect(0, 0, 64, 64)
        }
        _ = try pixels(of: canvas)  // 落ちないことが要件
    }

    @Test(
        "有限でない切り抜きは、落とさずに 1 度だけ知らせる (#1302)",
        arguments: [
            (Float.nan, Float(0), Float(32), Float(32)),
            (Float(0), Float.nan, Float(32), Float(32)),
            (Float(0), Float(0), Float.infinity, Float(32)),
            (Float(0), Float(0), Float(32), -Float.infinity),
        ])
    func nonFiniteClipsAreRefused(_ box: (Float, Float, Float, Float)) throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.clip(box.0, box.1, box.2, box.3)
            canvas.rect(0, 0, 64, 64)
        }
        #expect(canvas.warnings.hasWarned(.badClip))
        #expect(canvas.warnings.message(for: .badClip)?.hasPrefix("clip()") == true)
        // 切り抜きは書き換わっていない。面の全体へ描けたままである
        #expect(try pixels(of: canvas)[56, 56].red == 255)
    }

    /// 並びは (x, y, 幅, 高さ, 収めた先が面を覆うか)。**有限なので知らせる事情ではなく、
    /// 収める側**である。
    @Test(
        "`Int` に収まらない大きさの切り抜きは、落ちずに面の内側へ収まる (#1302)",
        arguments: [
            (Float(0), Float(0), Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, true),
            (
                Float(-1e38), Float(-1e38), Float.greatestFiniteMagnitude,
                Float.greatestFiniteMagnitude, true
            ),
            // 右下の端が原点まで戻ってくるので、面には 1 画素も残らない
            (
                -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude,
                Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, false
            ),
            // 面の先から始まる
            (
                Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float(16), Float(16),
                false
            ),
        ])
    func hugeClipsAreClamped(_ box: (Float, Float, Float, Float, Bool)) throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.clip(box.0, box.1, box.2, box.3)
            canvas.rect(0, 0, 64, 64)
        }
        #expect(!canvas.warnings.hasWarned(.badClip))
        #expect(try pixels(of: canvas)[56, 56].red == (box.4 ? 255 : 0))
    }

    @Test("指定が有限でも、読み方を解く算術が溢れたら収める (#1302)")
    func clipsThatOverflowWhileResolvingAreClamped() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            // 半径の読み方は幅を 2 倍するので、有限の指定のまま +∞ へ溢れる
            canvas.rectMode(.radius)
            canvas.clip(32, 32, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
            canvas.rect(0, 0, 64, 64)
        }
        #expect(!canvas.warnings.hasWarned(.badClip))
        #expect(try pixels(of: canvas)[56, 56].red == 255)
    }

    @Test("切り抜きを変えても、その前に置いた図形は影響を受けない")
    func changingTheClipClosesTheRunSoFar() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.rect(0, 0, 16, 16)  // 切り抜き無しで置く
            canvas.clip(32, 32, 16, 16)
            canvas.rect(32, 32, 16, 16)
        }
        let image = try pixels(of: canvas)
        #expect(image[8, 8].red == 255)  // 後から切り抜いても消えない
        #expect(image[40, 40].red == 255)
    }

    // MARK: - 混ぜ方 (#236)

    /// 下地の上に色を 1 つ塗り、真ん中の画素を返す。
    private func blended(
        mode: BlendMode, base: LinearRGBA, top: LinearRGBA
    ) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(base)
            canvas.noStroke()
            canvas.blendMode(mode)
            canvas.fill(top)
            canvas.rect(0, 0, 16, 16)
        }
        return try pixels(of: canvas)[8, 8]
    }

    @Test(
        "置き換える (replace) 以外のどの混ぜ方でも、アルファ 0 の色は下地を変えない",
        arguments: BlendMode.allCases.filter { $0 != .replace })
    func fullyTransparentColorsNeverDisturbTheBackground(_ mode: BlendMode) throws {
        let base = LinearRGBA.display(red: 0.4, green: 0.3, blue: 0.2)
        let untouched = try blended(
            mode: .blend, base: base, top: .display(red: 0, green: 0, blue: 0, alpha: 0))
        let painted = try blended(
            mode: mode, base: base, top: .display(red: 0.25, green: 0.55, blue: 0.15, alpha: 0))
        #expect(painted == untouched, "\(mode) がアルファ 0 で下地を変えた")
    }

    // MARK: 置き換える混ぜ方の例外 (#1542)

    /// 白い下地に `color` を置き換えで置き、真ん中の画素を作業空間の値 (線形・乗算済み) で返す。
    ///
    /// **置き換える列の断片は経路ごとに別である** — 基本図形 (`rect`) は
    /// `mokume_formFragmentReplace`、三角形の経路 (`quad`) は `mokume_fragmentDirect` で描く
    /// (一覧は `ShapePipeline.BlendStates` の doc)。片方だけがアルファ 0 を捨てるように
    /// なっても気付けるよう、両方で置く。
    private func replaced(with color: LinearRGBA, throughForms: Bool) throws -> LinearRGBA {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(white)
            canvas.noStroke()
            canvas.blendMode(.replace)
            canvas.fill(color)
            if throughForms {
                canvas.rect(0, 0, 16, 16)
            } else {
                canvas.quad(0, 0, 16, 0, 16, 16, 0, 16)
            }
        }
        return try canvas.target.readPixels()[8, 8]
    }

    /// **置き換える混ぜ方は、形が掛かる画素を置いた色でアルファごと置き換える。** アルファ 0
    /// の色なら、その画素は透明になる — 「アルファ 0 の色は下地を変えない」の唯一の例外で、
    /// 面の一部を透明にする手段でもある。
    ///
    /// 置く色は成分を持たせたアルファ 0 にする。乗算済みの 4 成分がすべて 0 になるので、
    /// 白い下地 (1, 1, 1, 1) が 1 成分でも残れば落ちる。
    @Test("置き換える混ぜ方は下地を見ず、アルファ 0 の色なら透明に置き換える", arguments: [true, false])
    func replaceIgnoresWhatIsUnderneath(_ throughForms: Bool) throws {
        let result = try replaced(
            with: .display(red: 0.25, green: 0.55, blue: 1, alpha: 0), throughForms: throughForms)
        #expect(
            result == LinearRGBA(premultipliedRed: 0, green: 0, blue: 0, alpha: 0),
            "アルファ 0 の色で置き換えたのに、透明になっていない: \(result)")
    }

    /// **アルファ 0 とその 1 段上の間に継ぎ目が無い。** アルファ 1/255 の色で置き換えれば
    /// ほぼ透明になり、下地 (アルファ 1) へは戻らない。アルファを 0 へ下げていく動きで、
    /// 最後の 1 段だけ下地がいきなり現れる振る舞いを見張る。
    @Test("置き換える混ぜ方で、アルファ 1/255 の色はほぼ透明に置き換わる", arguments: [true, false])
    func replaceWithANearlyTransparentColorStaysNearlyTransparent(_ throughForms: Bool) throws {
        let step: Float = 1 / 255
        let result = try replaced(
            with: .display(red: 0.25, green: 0.55, blue: 1, alpha: step), throughForms: throughForms)
        #expect(
            abs(result.alpha - step) <= step,
            "アルファ 1/255 で置き換えた画素のアルファが \(result.alpha) になった")
    }

    /// **絵を置き換えで貼ると、絵の透けた画素がそのまま透明として写る。** 絵の α 0 の画素を
    /// 数え、貼った結果で同じ位置が 1 つ残らず透明になっていることと、絵の外の下地が
    /// 1 画素も透けないことを見る (絵を貼る列も三角形の経路の断片で描く)。
    @Test("透けた所を持つ絵を置き換えで貼ると、絵の透けた画素がそのまま透明になる")
    func replacingWithAPictureCopiesItsTransparentPixels() throws {
        let canvas = try makeCanvas(width: 160, height: 160)
        let pad = try canvas.createGraphics(80, 80)
        pad.beginDraw()
        pad.noStroke()
        pad.fill(white)
        pad.circle(40, 40, 40)
        pad.endDraw()
        let picture = try pad.target.readPixels()
        try canvas.draw {
            canvas.background(red)
            canvas.blendMode(.replace)
            canvas.image(pad, 40, 40)
        }
        let placed = try canvas.target.readPixels()

        let clear = LinearRGBA(premultipliedRed: 0, green: 0, blue: 0, alpha: 0)
        var clearInPicture = 0
        var clearWhenPlaced = 0
        for y in 0..<80 {
            for x in 0..<80 where picture[x, y].alpha == 0 {
                clearInPicture += 1
                if placed[40 + x, 40 + y] == clear { clearWhenPlaced += 1 }
            }
        }
        // 円の外の四隅が透けている (直径 40 の円を 80×80 の絵に描いた)
        try #require(clearInPicture > 80 * 80 / 2)
        #expect(clearWhenPlaced == clearInPicture, "絵の透けた画素のうち、貼った結果で透明でないものがある")

        var seeThroughOutside = 0
        for y in 0..<160 {
            for x in 0..<160 where !(40..<120).contains(x) || !(40..<120).contains(y) {
                if placed[x, y].alpha < 1 { seeThroughOutside += 1 }
            }
        }
        #expect(seeThroughOutside == 0, "絵の外で下地が透けた")
    }

    @Test("掛ける混ぜ方は暗いほうへ寄る")
    func multiplyDarkens() throws {
        let result = try blended(
            mode: .multiply,
            base: .display(red: 1, green: 1, blue: 1),
            top: .display(red: 0.5, green: 0.5, blue: 0.5))
        let plain = try blended(
            mode: .blend,
            base: .display(red: 1, green: 1, blue: 1),
            top: .display(red: 0.5, green: 0.5, blue: 0.5))
        // 白に掛けるので、そのまま塗ったのと同じ明るさになる
        #expect(abs(Int(result.red) - Int(plain.red)) <= 1)

        let onGray = try blended(
            mode: .multiply,
            base: .display(red: 0.5, green: 0.5, blue: 0.5),
            top: .display(red: 0.5, green: 0.5, blue: 0.5))
        #expect(onGray.red < plain.red)  // 灰色どうしなら暗くなる
    }

    @Test("明るいほうを採る混ぜ方と、暗いほうを採る混ぜ方が逆に働く")
    func lightestAndDarkestPickOppositeSides() throws {
        let base = LinearRGBA.display(red: 0.8, green: 0.2, blue: 0.2)
        let top = LinearRGBA.display(red: 0.2, green: 0.8, blue: 0.2)
        let lightest = try blended(mode: .lightest, base: base, top: top)
        let darkest = try blended(mode: .darkest, base: base, top: top)
        #expect(lightest.red > darkest.red)
        #expect(lightest.green > darkest.green)
    }

    @Test("足す混ぜ方は明るくなり、引く混ぜ方は暗くなる")
    func addBrightensAndSubtractDarkens() throws {
        let base = LinearRGBA.display(red: 0.4, green: 0.4, blue: 0.4)
        let top = LinearRGBA.display(red: 0.3, green: 0.3, blue: 0.3)
        let added = try blended(mode: .add, base: base, top: top)
        let subtracted = try blended(mode: .subtract, base: base, top: top)
        let plain = try blended(mode: .blend, base: base, top: base)
        #expect(added.red > plain.red)
        #expect(subtracted.red < plain.red)
    }

    @Test("差を採る混ぜ方は、同じ色どうしで黒になる")
    func differenceOfEqualColorsIsBlack() throws {
        let color = LinearRGBA.display(red: 0.6, green: 0.4, blue: 0.8)
        let result = try blended(mode: .difference, base: color, top: color)
        #expect(result.red <= 1)
        #expect(result.green <= 1)
        #expect(result.blue <= 1)
    }

    /// **合成の出口では切らない。** 作業空間は 1.0 超を保ち、畳むのは出力段だけである
    /// ([ADR-0011] 決定 1・決定 3)。下の
    /// ``outOfRangeComponentsAreSaturatedByTheOutputStage`` と**対で読む** — あちらが
    /// 「出力段が畳む」側、こちらが「作業空間には残る」側である。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    @Test("足す混ぜ方は、光を重ねるほど明るさを積み上げられる")
    func addingLightAccumulatesBeyondTheDisplayRange() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.blendMode(.add)
            canvas.fill(.linear(red: 0.6, green: 0, blue: 0))
            canvas.rect(0, 0, 16, 16)
            canvas.rect(0, 0, 16, 16)  // 同じところへもう 1 枚重ねる
        }
        // 0.6 を 2 回足せば 1.2。合成の出口で飽和させていると 1.0 で頭打ちになる
        #expect(canvas.get(8, 8).red > 1.1)
    }

    /// **飽和の担い手は出力段である** (`OutputStage` の `clampToStandardRange`)。
    ///
    /// もとは #258 の「範囲の外の成分を渡しても下地が壊れない」という表題だったが、
    /// 見ているのは `pixels(of:)` を通した 8 bit の画素なので、実際に守られているのは
    /// 「**出力**が壊れない」である。合成の出口には飽和が無い (上の
    /// ``addingLightAccumulatesBeyondTheDisplayRange`` が作業空間の側を見る) ので、
    /// 名前が担い手を名乗るようにした ([#1057])。**#258 が守っていた保証は減っていない。**
    ///
    /// [#1057]: https://github.com/mokume-metal/mokume/issues/1057
    @Test("範囲の外の成分を渡しても、出力段が飽和させるので絵が壊れない")
    func outOfRangeComponentsAreSaturatedByTheOutputStage() throws {
        let result = try blended(
            mode: .add,
            base: .display(red: 0.5, green: 0.5, blue: 0.5),
            top: LinearRGBA(straightRed: 8, green: -4, blue: 0.5, alpha: 1))
        #expect(result.red == 255)  // 上へ飽和
        #expect(result.green == 0)  // 下へ飽和 (負の値が巻き返さない)
    }

    @Test("透明な下地を作れる")
    func aTransparentBackgroundCanBeMade() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(.display(red: 0, green: 0, blue: 0, alpha: 0))
        }
        #expect(try pixels(of: canvas)[8, 8].alpha == 0)
    }

    @Test("透明な下地の上に半透明を重ねられる")
    func semiTransparentPaintLandsOnATransparentBackground() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(.display(red: 0, green: 0, blue: 0, alpha: 0))
            canvas.noStroke()
            canvas.fill(.display(red: 1, green: 0, blue: 0, alpha: 0.5))
            canvas.rect(0, 0, 16, 16)
        }
        let center = try pixels(of: canvas)[8, 8]
        #expect(center.alpha > 100 && center.alpha < 160)  // おおよそ半分
        #expect(center.red > 200)  // 色は戻して出る (暗く沈まない)
    }

    @Test("混ぜ方を変えると、その前に置いた図形は影響を受けない")
    func changingTheModeClosesTheRunSoFar() throws {
        let canvas = try makeCanvas(width: 32, height: 16)
        try canvas.draw {
            canvas.background(.display(red: 1, green: 1, blue: 1))
            canvas.noStroke()
            canvas.fill(.display(red: 0.5, green: 0.5, blue: 0.5))
            canvas.rect(0, 0, 16, 16)  // 重ねる (白の上に灰色 = 灰色)
            canvas.blendMode(.multiply)
            canvas.rect(16, 0, 16, 16)  // 掛ける (白に掛けるので灰色)
        }
        let image = try pixels(of: canvas)
        // 左は「重ねる」で描かれたまま。後から掛ける指定に変えても影響しない
        #expect(abs(Int(image[8, 8].red) - Int(image[24, 8].red)) <= 1)
    }

    @Test("積み降ろしは混ぜ方も戻す")
    func styleStackCarriesTheBlendMode() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(.display(red: 0.5, green: 0.5, blue: 0.5))
            canvas.noStroke()
            canvas.pushStyle()
            canvas.blendMode(.add)
            canvas.popStyle()
            canvas.fill(.display(red: 0.3, green: 0.3, blue: 0.3))
            canvas.rect(0, 0, 16, 16)
        }
        // 戻っているので「重ねる」で描かれ、塗った色そのものになる
        let plain = try blended(
            mode: .blend,
            base: .display(red: 0.5, green: 0.5, blue: 0.5),
            top: .display(red: 0.3, green: 0.3, blue: 0.3))
        #expect(try pixels(of: canvas)[8, 8].red == plain.red)
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
        // **積んだ履歴はフレームを越えない** (ADR-0021 決定 4 の追補)。スタイルそのもの
        // (塗り) は越えるが、「積んだ」という事実は次のフレームへ渡らない。
        //
        // **この検査は以前、逆のことを見ていた** ([#925]) — 2 フレーム目の `pop()` が
        // 1 フレーム目の値へ戻ることを期待し、「積んだものは残っているが、戻せば
        // 1 フレーム目の手前へ帰る」とコメントまで置いて、`styleStack` だけが越える
        // という割れを契約として固定していた
        //
        // [#925]: https://github.com/mokume-metal/mokume/issues/925
        let canvas = try makeCanvas()
        // 1 フレーム目: 積んだまま降ろさずに終える
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.push()
            canvas.fill(blue)
            canvas.translate(20, 20)
        }
        // 2 フレーム目: 積んだものはもう無いので、降ろしても何も戻らない
        try canvas.draw {
            canvas.background(black)
            canvas.pop()
            canvas.rect(8, 8, 16, 16)
        }
        let image = try pixels(of: canvas)
        // 塗りは青のまま — **スタイルそのものは越える**ので、1 フレーム目の最後の値が残る
        #expect(image[16, 16].blue > 200)
        #expect(image[16, 16].red < 60)
        #expect(image[36, 36] == (0, 0, 0, 255))  // 変換も (フレームの頭で) 戻っている
    }

    @Test("釣り合わない pushStyle は、毎フレーム積み上がらない")
    func unbalancedPushStyleDoesNotGrow() throws {
        // `Style` は 25 フィールドあり、60 fps で 1 時間積み続ければ 21 万個になる
        // ([#925])。**伸びていないことは絵からは分からない**ので、降ろせるかで見る
        let canvas = try makeCanvas()
        for _ in 0..<3 {
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.fill(white)
                canvas.pushStyle()  // 降ろさずに終える
                canvas.fill(blue)
            }
        }
        // 3 フレームぶん積み上がっていれば、ここで降ろせてしまう
        try canvas.draw {
            canvas.background(black)
            canvas.popStyle()
            canvas.rect(8, 8, 16, 16)
        }
        let image = try pixels(of: canvas)
        #expect(image[16, 16].blue > 200, "前のフレームで積んだスタイルが降ろせてしまう")
        #expect(image[16, 16].red < 60)
    }

    @Test("閉じ忘れた beginShape() は、フレームをまたいで点を積み続けない (#1591)")
    func unclosedShapeDoesNotGrowAcrossFrames() throws {
        // 組み立て中の形はフレームに属する (ADR-0021 決定 4 の追補 (2026-09-27))。直す前は
        // 開いた印が境目で下りず、毎フレームの `vertex()` が同じ形へ積まれ続けた — 何も
        // 描かれないまま、点のぶんだけ記憶が増える ([#1591])。`setup()` で開いた形を模して、
        // フレームの外の持ち越しの区間で開く (頭の側で捨てることを見る)。区間の外では形を
        // 開くこと自体を断る ([#1672])
        //
        // [#1591]: https://github.com/mokume-metal/mokume/issues/1591
        // [#1672]: https://github.com/mokume-metal/mokume/issues/1672
        let canvas = try makeCanvas()
        canvas.carriesOver = true
        canvas.beginShape()
        canvas.carriesOver = false
        for frame in 1...30 {
            var placedInFrame = 0
            try canvas.draw {
                for index in 0..<1000 {
                    canvas.vertex(Float(index % 64), Float(index / 16))
                }
                placedInFrame = canvas.shapePoints.count
            }
            // フレームの中でも積まれていない — 頭で捨てている。終わりだけで捨てると、
            // `setup()` で開いた形に 1 枚目の点が積まれる
            try #require(placedInFrame == 0, "\(frame) 枚目の中で \(placedInFrame) 点が積まれた")
            try #require(!canvas.isBuildingShape, "\(frame) 枚目の後も形が開いたまま")
            try #require(
                canvas.shapePoints.isEmpty,
                "\(frame) 枚目の後に \(canvas.shapePoints.count) 点が残っている")
            #expect(canvas.shapeIndices.isEmpty)
            #expect(canvas.shapeHoles.isEmpty)
            #expect(canvas.curveGuides.isEmpty)
            #expect(canvas.holePoints == nil)
        }
        #expect(canvas.warnings.hasWarned(.shapeNotEnded))
        // 捨てた後のフレームの `vertex()` は形の外なので、そちらの注意も言う
        #expect(canvas.warnings.hasWarned(.vertexOutsideShape))
    }

    @Test("フレームをまたいで組んだ形は描かれない (#1591)")
    func shapeBuiltAcrossFramesIsNotDrawn() throws {
        // 1 枚目で開いて 2 点、2 枚目 (塗り直さない) で 1 点足して閉じる。直す前は 2 枚目に
        // 三角形が出ていた — 閉じ忘れた形を、次のフレームが続きとして描いていた
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.beginShape()
            canvas.vertex(4, 4)
            canvas.vertex(60, 4)
        }
        try canvas.draw {
            canvas.vertex(32, 60)
            canvas.endShape(.close)
        }
        let image = try pixels(of: canvas)
        #expect(image[32, 16] == (0, 0, 0, 255), "前のフレームで開いた形が描かれた")
        #expect(canvas.warnings.hasWarned(.shapeNotEnded))
        #expect(canvas.warnings.hasWarned(.shapeNotBegun))
    }

    @Test("push() の片肺が無い — 変換とスタイルは揃って戻らない")
    func pushRestoresNeitherHalfAcrossFrames() throws {
        // 以前は `push()` だけ書いて `pop()` を忘れると、次のフレームで**変換だけ**が
        // 戻り、スタイルは戻らなかった ([#925])。同じ 1 つの呼び出しの結果が、フレームを
        // またいだ瞬間に半分だけ効かなくなる形である
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.push()  // 降ろさずに終える
            canvas.fill(blue)
            canvas.translate(20, 20)
        }
        try canvas.draw {
            canvas.background(black)
            canvas.pop()  // どちらの半分も戻らない
            canvas.rect(8, 8, 16, 16)
        }
        let image = try pixels(of: canvas)
        #expect(image[16, 16].blue > 200, "スタイルだけが戻っている")
        #expect(image[36, 36] == (0, 0, 0, 255), "変換だけが戻っている")
    }

    // MARK: - スタイルの一式 (#780)

    /// 全フィールドが既定と違うスタイル。**`Canvas.Style` にフィールドを足したらここにも
    /// 足す** — 足し忘れると `styleRoundTripsEveryField` が、既定のままのフィールドを
    /// 名乗って赤になる (既定のままでは往復したかどうかを見分けられない)。
    private func distinctStyle(on canvas: Canvas) -> Canvas.Style {
        var style = Canvas.Style()
        style.fill = .linear(red: 0.1, green: 0.2, blue: 0.3)
        style.stroke = .linear(red: 0.4, green: 0.5, blue: 0.6)
        style.strokeWeight = 3
        style.strokeCap = .square
        style.strokeJoin = .bevel
        style.hasFill = false
        style.hasStroke = false
        style.rectMode = .center
        style.ellipseMode = .corner
        style.blendMode = .add
        style.clip = MTLScissorRect(x: 1, y: 2, width: 3, height: 4)
        style.fontName = "Helvetica"
        style.textSize = 30
        style.textStyle = .bold
        style.horizontalTextAlign = .right
        style.verticalTextAlign = .top
        style.textLeading = 40
        style.textWrap = .character
        style.imageMode = .center
        style.tint = .linear(red: 0.7, green: 0.8, blue: 0.9)
        style.picture = .drawn(canvas.target)
        style.material.shininess = 8
        style.castsShadow = false
        style.receivesShadow = false
        return style
    }

    /// フィールドごとの名前と値の綴り。**並びを `Mirror` から取る**ので、ここは宣言に
    /// フィールドが増えても書き足さなくてよい。
    private func fields(of style: Canvas.Style) -> [(name: String, value: String)] {
        Mirror(reflecting: style).children.map {
            (name: $0.label ?? "?", value: String(describing: $0.value))
        }
    }

    @Test("積み降ろしも形の組み立ても、スタイルの全フィールドを往復させる")
    func styleRoundTripsEveryField() throws {
        // 以前はフィールドの並びが宣言・写し取り・戻しの 3 か所にあり、1 か所落としても
        // 型も検査も通った ([#780])。落としたフィールドは「その設定だけ戻らない」形で
        // 絵がそれらしく壊れるので、全フィールドを並べて見る
        let canvas = try makeCanvas()
        let distinct = distinctStyle(on: canvas)
        let expected = fields(of: distinct)
        for (plain, marked) in zip(fields(of: Canvas.Style()), expected) {
            #expect(
                plain.value != marked.value,
                "\(marked.name) が既定のままなので、往復したかを見分けられない (distinctStyle に足す)")
        }

        func expectRestored(_ path: String) {
            for (actual, wanted) in zip(fields(of: canvas.currentStyle), expected) {
                #expect(actual.value == wanted.value, "\(path) で \(wanted.name) が戻らない")
            }
        }
        try canvas.draw {
            canvas.currentStyle = distinct
            canvas.pushStyle()
            canvas.currentStyle = Canvas.Style()
            canvas.popStyle()
            expectRestored("pushStyle / popStyle")

            // 組み立ては積み降ろしを使わず、写し取って戻す (`Canvas.createShape`)
            _ = canvas.createShape { canvas.currentStyle = Canvas.Style() }
            expectRestored("createShape")
        }
    }

    /// 持ち越しを約束する区間 (本体の `setup()` と止まっている間のコールバック) を模して
    /// `body` を走らせる ([#1672])。区間の印を立てるのは、製品ではランタイムだけである。
    ///
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    private func carryingOver(_ canvas: Canvas, _ body: () -> Void) {
        canvas.carriesOver = true
        defer { canvas.carriesOver = false }
        body()
    }

    // MARK: - フレームの境目で戻す状態 (#1671)

    /// フレームの境目の越え方。**境目の関数はどれを通っても、同じ状態を戻す。**
    enum FrameBoundary: CaseIterable, CustomTestStringConvertible {
        /// 描き切って閉じ、次を始める (`endDraw()` → `beginDraw()`)。
        case endDraw
        /// 閉じ忘れたまま次を始める (`beginDraw()` を重ねる・[#1622])。描き切らないので、
        /// 溜めたものを flush が片付けてくれない。
        case beginDrawAgain
        /// 描き切りに失敗して閉じる ([#342])。flush は溜めたものに触れずに投げる。
        case failedEndDraw
        /// 閉じ忘れたまま、次のフレームを `draw { }` で始める。捨てるのは入口ではなく
        /// フレームの始まりなので、こちらの入口でも同じに捨てる。
        case drawAfterBeginDraw
        /// 描き場所で閉じ忘れたまま、本体の次のフレームが始まる ([#1834])。本体の頭が描かずに
        /// 捨て、描き場所はフレームの外に出る。描き切らないので、溜めたものを flush が片付けて
        /// くれない。**汚す面は描き場所** (``usesLayer``)。
        ///
        /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
        case mainFrameAfterBeginDraw
        /// 本体の通常の経路 (`draw { }` → `draw { }`)。
        case drawThenDraw
        /// `setup()` にあたるフレームの外 (持ち越しの区間・``Canvas/carriesOver``) で汚し、最初の
        /// `draw { }` を始める。外で書けるものは限られる (シーンの記述は断られる) ので、見るのは
        /// 頭で戻すものだけ (``FrameReset``)。区間の外では形も開けない (#1672)。
        case outsideThenDraw

        var testDescription: String { "\(self)" }

        /// 汚すのがフレームの外か。
        var dirtiesOutside: Bool { self == .outsideThenDraw }

        /// 汚す面が、本体 (`host`) から作った描き場所か。
        var usesLayer: Bool { self == .mainFrameAfterBeginDraw }

        /// 汚したフレームを閉じる越え方か。閉じた直後にも、終わりで戻すものを見る。本体の頭で
        /// 捨てた描き場所は、捨てた直後にフレームの外に居るので、閉じたものとして見る。
        var closes: Bool {
            [.endDraw, .failedEndDraw, .drawThenDraw, .mainFrameAfterBeginDraw].contains(self)
        }

        /// 汚すフレームを開いて `dirty` を走らせ、境目を越える。閉じる越え方なら閉じた直後に
        /// `closed` を、次のフレームの中で `inspect` を呼ぶ。`host` は ``usesLayer`` の越え方で、
        /// `canvas` を作った本体である。
        func run(
            _ canvas: Canvas, host: Canvas, dirty: () -> Void, closed: () -> Void,
            inspect: () -> Void
        ) throws {
            switch self {
            case .mainFrameAfterBeginDraw:
                try host.draw {
                    canvas.beginDraw()
                    dirty()
                }
                try host.draw { closed() }
                canvas.beginDraw()
                inspect()
                canvas.endDraw()
            case .endDraw, .failedEndDraw:
                canvas.beginDraw()
                dirty()
                if self == .failedEndDraw { canvas.failureForTesting = .deviceUnavailable }
                canvas.endDraw()
                canvas.failureForTesting = nil
                closed()
                canvas.beginDraw()
                inspect()
                canvas.endDraw()
            case .beginDrawAgain:
                canvas.beginDraw()
                dirty()
                canvas.beginDraw()
                inspect()
                canvas.endDraw()
            case .drawAfterBeginDraw:
                canvas.beginDraw()
                dirty()
                try canvas.draw { inspect() }
            case .drawThenDraw:
                try canvas.draw { dirty() }
                closed()
                try canvas.draw { inspect() }
            case .outsideThenDraw:
                canvas.carriesOver = true
                dirty()
                canvas.carriesOver = false
                try canvas.draw { inspect() }
            }
        }
    }

    /// フレームに属する状態を、境目のどちらの側で戻すか。
    ///
    /// **終わりの側で戻すものは、閉じた直後にも見る。** 止まっている間のコールバックと
    /// 描き場所の `endDraw()` の後はフレームの外で、そこで置いた図形や読んだ座標に前の
    /// フレームのものが効かないようにする ([#1472]・[#1504])。頭の側だけで見ていると、
    /// 終わりの戻しを頭へ移しても緑のままになる。
    ///
    /// [#1472]: https://github.com/mokume-metal/mokume/issues/1472
    /// [#1504]: https://github.com/mokume-metal/mokume/issues/1504
    enum FrameReset {
        /// 頭でだけ戻す。閉じた直後は汚れたままでよい (次のフレームの前に読まれない)。
        case head
        /// 終わりで戻す。フレームの外で汚したもの (`setup()` で置いた図形) は、最初の
        /// フレームへ持ち越すのが約束なので、頭では戻さない。
        case end
        /// 頭と終わりの両方で戻す。
        case both

        var atHead: Bool { self != .end }
        var atEnd: Bool { self != .head }
    }

    /// 境目を越えるときに開いている列。**列は同時に 1 本しか開かない**ので、開いたまま
    /// 越える列の種類を引数で回す (``frameState`` の `openIn`)。
    enum OpenBatch: CaseIterable, CustomTestStringConvertible {
        /// 貼る絵の矩形を 2 つ置いて畳み始めた、平面の雛形。
        case flatTemplate
        /// 基本図形の列。
        case form
        /// 立体の列。
        case solid

        var testDescription: String { "\(self)" }
    }

    /// 境目を越える前に、フレームを汚すのに使う道具。
    struct FrameFixture {
        let sheet: Image
        let other: Canvas
        let computation: Computation
        let numbers: Numbers
        let particles: Particles
        /// 開いたまま越える列。
        let openBatch: OpenBatch
        /// 貼る絵の矩形を 1 つ置いた直後の、畳む相手の控え (``Canvas/pendingFlat``)。
        var pendingFlat: Canvas.PendingFlat?
    }

    /// **フレームに属する状態と、それを汚す手順** ([ADR-0021] 決定 4 と追補・[#1671])。
    ///
    /// ここに載る状態は、どの境目を越えた後も (次の `beginFrame()` の後で見て) 既定へ
    /// 戻っていなければならない。**頭でしか戻さないもの** (`pendingEffects`・積み履歴・
    /// `passesThisFrame`・`hasLoadedPixels`・`lightStorage`) もあるので、見るのは次の
    /// フレームを始めた後である。
    ///
    /// 手順は上から順に通す。**塗り直し (`background`) と途中の描き切り (`loadPixels`) は
    /// 溜めたものを捨てるので先頭に置く。** 手順が本当に汚したかは検査が確かめる
    /// (既定のままの状態は、戻ったかどうかを見分けられない)。
    ///
    /// `openIn` はその状態が汚れる開いた列の種類。**開いている列は 1 本だけ**
    /// (``OpenBatch``) なので、列の組と、それに付いて動く状態だけが種類を持つ。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    /// [#1671]: https://github.com/mokume-metal/mokume/issues/1671
    private var frameState:
        [(
            name: String, reset: FrameReset, openIn: Set<OpenBatch>,
            dirty: (Canvas, inout FrameFixture) -> Void
        )]
    {
        let all = Set(OpenBatch.allCases)
        let head = FrameReset.head
        let end = FrameReset.end
        let both = FrameReset.both
        return [
            // 途中の描き切りと塗り直しは、溜めたものを捨てるので先に通す
            ("passesThisFrame", head, all, { c, _ in c.loadPixels() }),
            ("hasLoadedPixels", head, all, { c, _ in c.loadPixels() }),
            // 奥行きを残した描き切りが何かを描くと立つ。**フレームの頭では戻さない** — 止まっている間や
            // `setup()` で描き切った奥行きを、次のフレームの最初の描き切りが受け取る (#1888)
            ("depthIsHeld", end, all, { c, _ in
                c.rect(10, 10, 4, 4)
                c.loadPixels()
            }),
            // 描く先 (`target`) の中の、フレームに属する状態 (#1678)。書く口は溜めた図形があれば
            // 描き切るので、塗り直しと図形より先に書く。読み方は ``nestedFrameState``
            ("target.pixelMirror.hasPendingWrites", end, all, { c, _ in
                c.set(1, 1, .linear(red: 1, green: 0, blue: 0))
            }),
            ("pendingBackground", end, all, { c, _ in c.background(.linear(red: 0, green: 0, blue: 0)) }),
            // シーンの記述
            ("cameraStorage", end, all, { c, _ in c.perspective() }),
            ("transform", both, all, { c, _ in c.translate(5, 5) }),
            ("transformStack", head, all, { c, _ in c.pushMatrix() }),
            ("styleStack", head, all, { c, _ in c.pushStyle() }),
            ("activeLights", both, all, { c, _ in c.ambientLight(.linear(red: 0.2, green: 0.2, blue: 0.2)) }),
            ("activeSurroundings", both, all, { c, _ in c.surroundings(.sky) }),
            ("shadowsEnabled", end, all, { c, _ in c.shadows(true) }),
            ("shadowRangeValue", end, all, { c, _ in c.shadowRange(50) }),
            ("shadowDetailValue", end, all, { c, _ in c.shadowDetail(ShadowMap.detailRange.lowerBound) }),
            ("shadowBiasValue", end, all, { c, _ in c.shadowBias(0.5) }),
            ("pendingEffects", head, all, { c, _ in c.effects([.invert()]) }),
            ("pendingComputations", end, all, { c, f in c.compute(f.computation, over: 1, writes: [f.numbers]) }),
            // 溜めたもの。立体は光を置いた後に置くので、列を閉じたときに光の置き場へ写る
            ("solidVertices", end, all, { c, _ in c.box(4) }),
            ("solidMeshRanges", end, all, { c, _ in c.box(4) }),
            ("solidInstances", end, all, { c, _ in c.box(4) }),
            ("lightStorage", head, all, { c, _ in c.box(4) }),
            ("solidIndices", end, all, { c, _ in
                c.beginShape(.triangles)
                c.vertex(0, 0, 1)
                c.vertex(8, 0, 1)
                c.vertex(0, 8, 1)
                c.index(0)
                c.index(1)
                c.index(2)
                c.endShape()
            }),
            // 貼る絵の矩形は、読む面を替えた 1 つ目が列を閉じるので、2 つ目が畳む相手を待つ
            ("vertices", end, all, { c, f in
                c.texture(f.sheet)
                c.noStroke()
                c.rect(0, 0, 3, 3)
                c.rect(4, 0, 3, 3)
                f.pendingFlat = c.pendingFlat
                c.noTexture()
                c.stroke(.linear(red: 1, green: 1, blue: 1))
            }),
            ("flatInstances", end, all, { c, _ in c.flatInstances.append(.identity) }),
            ("recordedStrokeRanges", end, all, { c, _ in c.recordedStrokeRanges.append(StrokeRange(0..<0)) }),
            ("recordedSolidStrokes", end, all, { c, _ in
                c.recordedSolidStrokes.append(
                    SolidStrokePiece(kind: .disc(.zero), weight: 1, vertexStart: 0, vertexCount: 0))
            }),
            ("recordedGPUStrokes", end, all, { c, _ in
                c.recordedGPUStrokes.append(
                    RetainedGPUStroke(
                        source: .freeform, matrix: Transform.identity.matrix, weight: 1,
                        color: .transparent, uv: .zero, vertices: 0..<0))
            }),
            ("formInstances", end, all, { c, _ in c.rect(10, 10, 4, 4) }),
            ("batches", end, all, { c, _ in c.rect(10, 10, 4, 4) }),
            ("placedGraphics", end, all, { c, f in c.note(placing: f.other) }),
            ("outlinesAssembledThisFrame", end, all, { c, _ in c.outlinesAssembledThisFrame = 7 }),
            ("pointScansThisFrame", end, all, { c, _ in c.pointScansThisFrame = 7 }),
            // 組み立て中の形 (#1591)。閉じずに境目を越える
            ("isBuildingShape", both, all, { c, _ in c.beginShape(.triangles) }),
            ("shapeKind", both, all, { _, _ in }),
            ("currentNormal", both, all, { c, _ in c.normal(0, 0, 1) }),
            ("shapePoints", both, all, { c, _ in c.vertex(0, 0, 1) }),
            ("shapeHasDepth", both, all, { _, _ in }),
            ("shapeIndices", both, all, { c, _ in c.index(0) }),
            ("shapeHoles", both, all, { c, _ in
                c.beginContour()
                c.vertex(1, 1)
                c.vertex(2, 1)
                c.vertex(1, 2)
                c.beginContour()  // 1 つ目の穴を畳み、2 つ目を開いたままにする (#1528)
            }),
            ("holePoints", both, all, { c, _ in c.vertex(3, 3) }),
            ("curveGuides", both, all, { c, _ in
                c.curveVertex(0, 0)
                c.curveVertex(1, 1)
            }),
            // 開いたまま越える列 (1 本だけ)。**最後に開く** — 後から置いた図形が列を閉じる
            ("openSource", end, [.form, .solid], { c, f in Self.open(f.openBatch, on: c, f) }),
            ("openForm", end, [.form], { _, _ in }),
            ("openSolid", end, [.solid], { _, _ in }),
            ("openFlat", end, [.flatTemplate], { _, _ in }),
            ("currentTexture", end, [.flatTemplate], { _, _ in }),
            // 雛形を開く道は畳む相手を片付け、雛形の旗を立てて下ろすので、列を開いた後に
            // 汚す (列を閉じる道はどちらも読まない)
            ("pendingFlat", end, all, { c, f in c.pendingFlat = f.pendingFlat }),
            ("buildingFlatTemplate", end, all, { c, _ in c.buildingFlatTemplate = true }),
            // 捨てたフレームで積んだ力を落とすための控え (#1622)
            ("forcesThisFrame", end, all, { c, f in c.force(f.particles, [.gravity(0, 1)]) }),
            // 持ち越しの区間で置いた量の印。フレームの頭の検めが読んで下ろす (#1672)
            ("carriedOverAmount", head, all, { c, _ in c.carriedOverAmount = 7 }),
        ]
    }

    /// 開いたまま越える列を開く。
    private static func open(_ batch: OpenBatch, on canvas: Canvas, _ fixture: FrameFixture) {
        switch batch {
        case .form:
            canvas.rect(20, 20, 4, 4)
        case .solid:
            canvas.box(4)
        case .flatTemplate:
            // 読む面を替えた 1 つ目は列を閉じ、2 つ目が畳む相手を待ち、3 つ目で雛形が開く
            canvas.texture(fixture.sheet)
            canvas.noStroke()
            canvas.rect(0, 0, 4, 4)
            canvas.rect(8, 0, 4, 4)
            canvas.rect(16, 0, 4, 4)
            canvas.noTexture()
        }
    }

    /// **格納の中に降りて読む、フレームに属する状態の読み方** ([#1678])。名前は `.` で繋いだ道で、
    /// ``frameState`` の同じ名前が汚す手順を持つ。
    ///
    /// 持ち越しに分けた格納 (`target` は面と同じだけ生きる) の中にも、フレームに属する状態がある。
    /// 表と綴りが `Canvas` の格納で止まっていると、そこへ足した状態は境目を黙って越える — 写しの
    /// 書き込み待ちは、そうして描かずに捨てたフレームを越えていた。中の格納の分け方は
    /// ``everyTargetStoredPropertyIsClassified()`` が見る。
    ///
    /// [#1678]: https://github.com/mokume-metal/mokume/issues/1678
    private var nestedFrameState: [String: (Canvas) -> String] {
        [
            // 写しがまだ無いのは、書き込み待ちが無いのと同じ
            "target.pixelMirror.hasPendingWrites": {
                String(describing: $0.target.pixelMirror?.hasPendingWrites ?? false)
            }
        ]
    }

    /// 描く先 (``RenderTarget``) の格納のうち、持ち越すものと理由 ([#1678])。
    ///
    /// [#1678]: https://github.com/mokume-metal/mokume/issues/1678
    private var carriedTargetState: [String: String] {
        let construction = "面を作ったときに決まり、面と同じだけ生きる"
        let resource = "資源 (置き場・パイプライン)。頼まれてはじめて作り、使い回す"
        let count = "計数 (作ってから通算)。数で確かめる検査が読む"
        return [
            "width": construction, "height": construction, "texture": construction,
            "depthTexture": construction, "gpu": construction,
            "drawer": "この面を出す先に持つ描き場所 (弱く持つ)。組み立ての最後に 1 度だけ書く",
            "brightness": "明るさを画面へ写す段の設定。画面の性質なのでフレームを越える",
            "encodedStorage": resource, "outputPassStorage": resource,
            "lastEncodeSubmission": "最後に出力段を投入した番号。次の出力段の前に名指しで待つ (#927)",
            "pixelMirrorsMade": count, "pixelWriteBacksEncoded": count,
            "pixelReadbacksEncoded": count, "encodedImagesMade": count, "encodePassCount": count,
        ]
    }

    /// 画素の写し (``PixelMirror``) の格納のうち、持ち越すものと理由 ([#1678])。
    ///
    /// [#1678]: https://github.com/mokume-metal/mokume/issues/1678
    private var carriedMirrorState: [String: String] {
        let construction = "写しを作ったときに決まり、写しと同じだけ生きる"
        return [
            "storage": construction, "gpu": construction, "bytesPerRow": construction,
            "syncedThrough": "写しが映した投入の番号。読む口が進め、捨てる口が 0 に戻す。映した絵の印で、フレームに属さない",
        ]
    }

    /// **持ち越す状態と、その理由。** 境目で戻さないことが約束どおりのもの。
    ///
    /// 足すときは理由を 1 行で書く。「戻し忘れ」をここへ逃がすと、この検査は何も守らなく
    /// なる — 迷ったら ``frameState`` に載せ、赤くなったら境目の関数で戻す。
    private var carriedState: [String: String] {
        let construction = "面を作ったときに決まり、面と同じだけ生きる"
        let resource = "資源 (置き場・パイプライン)。作り直さないために持つ"
        let cache = "控え。同じ頼みで作り直さないために持つ (中身は入力で決まり、フレームに属さない)"
        let count = "計数 (作ってから通算・直前のフレーム)。数で確かめる検査が読む"
        let transient = "呼び出しの中でだけ立ち、抜ける前に戻る一時の値。境目では常に既定"
        let testing = "検査の差し込み・上限。製品の経路では既定のまま"
        return [
            "width": construction, "height": construction,
            "target": "\(construction)。中のフレームに属する状態は nestedFrameState が見る (#1678)",
            "output": construction, "upscaleStage": construction, "gpu": construction,
            "frameRing": construction, "pipeline": construction, "projection": construction,
            "atlas": construction, "timebase": "時刻と刻み。ランタイムが進め、描き場所は作った面と共有する (#1467)",
            "vertexStorage": resource, "flatInstanceStorage": resource,
            "formInstanceStorage": resource, "solidVertexStorage": resource,
            "solidIndexStorage": resource, "solidInstanceStorage": resource,
            "lightStorageBuffer": resource, "lightingStorage": resource, "materialStorage": resource,
            "surroundingsStorage": resource, "shadowMatrixStorage": resource,
            "blendModeBuffer": resource, "glyphPageBuffer": resource, "uniformsStorage": resource,
            "valuesStorage": resource, "matrixStorage": resource, "computeValuesStorage": resource,
            "uploadStorage": resource, "effectPipelineStorage": resource,
            "imageInputPass": resource, "imageInputUnavailable": "GPU入力の準備失敗を持ち越し、毎フレーム繰り返さない (#1753)",
            "computePipelineStorage": resource, "unbakedShadowTexture": resource,
            "emptyNumbers": resource, "blankPicture": resource,
            "shadowMap": "焼き付け先。同じ細かさなら作り直さない (ADR-0021 決定 4)。宣言は shadowDetailValue が戻る",
            "whiteUV": "焼き場の白い区画の位置。面を広げたときだけ変わる",
            "imageCache": cache, "modelCache": cache, "solidMeshes": cache, "solidEdges": cache,
            "typefaces": cache, "solidStrokeGeometry": cache, "modelFills": cache,
            "lastShadowBakeKey": "前に焼いた入力の指紋。焼かなかったフレームでは触らない (影の面は誰にも書き換えられない)",
            "discOffsets": "丸い継ぎ目の円板の周のずれ。直前の太さの 1 件だけで、点は 1024 個が上限 (#1785)。中身は太さで決まり、フレームに属さない",
            "atlasPageFrame": "焼き場の頁を作ったフレームの番号 (#1342)。番号どうしで比べる",
            "retainedSerial": "保持した形を置くたびの通し番号",
            "pendingDiscards": "溜め場を捨てた通し番号。形の組み立てが入口と出口で比べる (#1588)",
            "framesDrawn": "閉じたフレームの通し番号。境目の印そのもの",
            "shadowMapsBuilt": count,
            "shadowBarriersEncoded": count, "shadowBakesEncoded": count, "shadowBakesReused": count,
            "spheresFromUnit": count,
            "effectCarriesEncoded": count, "effectCarryRestoresEncoded": count,
            "effectChangesKeptEncoded": count, "effectCarryDrawsEncoded": count,
            "depthLoadsEncoded": count, "depthStoresEncoded": count,
            "effectBarriersEncoded": count, "effectPassesEncoded": count,
            "computeEncodersOpened": count, "computeEncodersClosed": count,
            "earlySubmissionsAttempted": count,
            "earlySubmissionFailedFrame": "面をまたぐ順のための早い投入に失敗したときのフレーム番号 (#1870)。番号どうしで比べるので、境目で戻す手は要らない (閉じ忘れを捨てる道も番号を進める)",
            "computeBarriersEncoded": count, "uploadBarriersEncoded": count,
            "glyphQuadsPlaced": count, "drawCallsInLastFrame": count,
            "flatVerticesInLastFrame": count, "flatOutlinesInLastFrame": count,
            "pointScansInLastFrame": count,
            "stagePassesUsed": "段の枠の採番。描き切りごとに 0 から数える (コマンドと同じ寿命)",
            "shaders": "この面が作った断片 (弱く持つ)。観測へ失敗を載せる",
            "effectShaders": "この面が作った効果 (弱く持つ)。観測へ失敗を載せる",
            "computations": "この面が作った計算 (弱く持つ)。観測へ失敗を載せる",
            "warnings": "言った注意の控え。初回だけ言うのは面の寿命で数える",
            "currentShader": "描き方。断片はフレームを越える (ADR-0021 決定 4)",
            "currentNumbers": "描き方。断片と一組でフレームを越える (#1470)",
            "currentCurveDetail": "描き方 (曲線の細かさ)。一度書けば残る",
            "currentCurveTightness": "描き方 (曲線の張り)。一度書けば残る",
            "noiseStore": "揺らぎの種と細かさの置き場。一度書けば残る (断片と共有する・#366)。描き場所は作った面と共有する (#1503)",
            "carriesPictureBeforeEffects": "効果を通す前の絵の控えがあるか。次のフレームの最初の描き切りが戻す (#1469)",
            "targetChangedSinceUpscale": "描く先が最後の拡大より後に変わったか。止まっている間の出力段が広げ直して下ろす。フレームの終わりの描き切りも下ろす (#1882)",
            "placers": "自分を置いた面。自分の絵が変わる直前 (描き切り) に相手を描き切らせて空にする。捨てるだけでは絵が変わらないので残す",
            "pixelLoadFailed": "直前の読む前の描き切りが失敗したか。描き切れたときに戻る (#1368・頭では戻さない)",
            "isDrawing": "フレームの内外の印そのもの。境目の関数だけが書く",
            "beginDrawFrame": "isDrawing と組のフレームの印 (beginDraw が開いた本体のフレームの番号)。境目の関数だけが書く",
            "droppedAtTheMainFrame": "本体の頭で閉じ忘れを捨てた後、次のフレームをまだ開いていないかの印 (遅れた endDraw() の注意を選ぶ・#1834)。境目の関数だけが書く",
            "paintSurfacesNoted": "断片の面を置いた記録に載せ終えた控え。記録が落ちる (フレームの終わりの描き切り) と placedGraphicsDrops と食い違って外れる (#1683)",
            "placedGraphicsDrops": count,
            "isFlushing": transient, "backdrop": transient, "replayedPaint": transient,
            "solidStrokeCapture": transient,
            "recordingShape": "形の組み立て (createShape) の入口と出口が対で戻す。閉包なので境目をまたがない",
            "carriesOver": "持ち越しの区間の印。ランタイムが setup() と止まっている間のコールバックの出入口で対で戻す (#1672)。境目をまたがない",
            "placementsFoundOutsideRegions": count,
            "stopsOnPlacementOutsideRegions": testing,
            "placesGlyphs": testing, "instanceCapacity": testing, "particleRoute": testing,
            "uploadByteLimit": testing, "failureForTesting": testing,
            "placesRetainedStrokesOnGPU": testing,
            "failEffectPassForTesting": testing, "failImageInputForTesting": testing,
            "failEarlySubmissionForTesting": testing,
        ]
    }

    /// ``Canvas/Style`` のうち、フレームに属するフィールドと汚す手順。**入れ子もフィールド
    /// ごとに同じ 2 つの表で扱う** — 切り抜き・材質・影は越えず、残りの描き方は越える
    /// (ADR-0021 決定 4 の表)。
    private var frameStyle: [String: (reset: FrameReset, dirty: (inout Canvas.Style) -> Void)] {
        [
            "clip": (.both, { $0.clip = MTLScissorRect(x: 1, y: 2, width: 3, height: 4) }),
            "material": (.end, { $0.material.shininess = 8 }),
            "castsShadow": (.end, { $0.castsShadow = false }),
            "receivesShadow": (.end, { $0.receivesShadow = false }),
        ]
    }

    /// 組み立て中の形の状態 (#1591・#1607)。フレームの外 (`setup()`) でも汚せ、頭で捨てる。
    /// 形の組み立て (`createShape`) の出入口が切り離す群でもある。
    static let shapeState: Set<String> = [
        "isBuildingShape", "shapeKind", "currentNormal", "shapePoints", "shapeHasDepth",
        "shapeIndices", "shapeHoles", "holePoints", "curveGuides",
    ]

    /// ``Canvas/Style`` のうち、越えるフィールド。どれも描き方である (ADR-0021 決定 4)。
    private let carriedStyle: Set<String> = [
        "fill", "stroke", "strokeWeight", "strokeCap", "strokeJoin", "hasFill", "hasStroke",
        "rectMode", "ellipseMode", "blendMode", "fontName", "textSize", "textStyle",
        "horizontalTextAlign", "verticalTextAlign", "textLeading", "textWrap", "imageMode",
        "tint", "picture",
    ]

    @Test("Canvas の格納は、フレームに属するか持ち越すかのどちらかに載っている")
    func everyStoredPropertyIsClassified() throws {
        // 境目で戻す状態は、境目の関数ごとに手で並べてあり、並べ落とした状態が越えていた
        // (#925・#1472・#1504・#1591・#1622)。**格納を 1 つ足したら、ここで止まる** —
        // どちらの表にも無い名前は、境目で戻すかを誰も決めていない
        let canvas = try makeCanvas()
        let labels = Mirror(reflecting: canvas).children.compactMap(\.label)
        let frame = Set(frameState.map(\.name))
        let carried = Set(carriedState.keys)
        #expect(frame.isDisjoint(with: carried), "両方の表に載っている: \(frame.intersection(carried))")
        for label in labels where label != "style" {
            #expect(
                frame.contains(label) || carried.contains(label),
                "\(label) がどちらの表にも無い。フレームに属するなら汚す手順を、持ち越すなら理由を書く")
        }
        for name in frame.union(carried) where !name.contains(".") {
            #expect(labels.contains(name), "\(name) は Canvas の格納に無い (表から消す)")
        }
        // 格納の中に降りる名前は、読み方が要る (綴りに載らないと、戻ったかを誰も見ない)
        #expect(
            Set(nestedFrameState.keys) == frame.filter { $0.contains(".") },
            "格納の中に降りる名前と、その読み方が食い違う")

        let fields = Mirror(reflecting: canvas.style).children.compactMap(\.label)
        let frameFields = Set(frameStyle.keys)
        #expect(frameFields.isDisjoint(with: carriedStyle))
        for field in fields {
            #expect(
                frameFields.contains(field) || carriedStyle.contains(field),
                "style.\(field) がどちらの表にも無い")
        }
        for name in frameFields.union(carriedStyle) {
            #expect(fields.contains(name), "style.\(name) は Style に無い (表から消す)")
        }
    }

    @Test("描く先と画素の写しの格納も、フレームに属するか持ち越すかのどちらかに載っている (#1678)")
    func everyTargetStoredPropertyIsClassified() throws {
        // 描く先は `Canvas` の表で「面と同じだけ生きる」に分けてあり、表も綴りもその中へ降りて
        // いなかった。写しの書き込み待ち (フレームに属する) が、描かずに捨てたフレームを黙って
        // 越えたのはそのためである ([#1678])。**中の格納を 1 つ足したら、ここで止まる**
        //
        // [#1678]: https://github.com/mokume-metal/mokume/issues/1678
        let canvas = try makeCanvas()
        _ = canvas.target.pixels  // 写しを作らせる
        let mirror = try #require(canvas.target.pixelMirror)
        let frame = Set(frameState.map(\.name))
        let layers: [(path: String, labels: [String], carried: [String: String], descended: Set<String>)] = [
            ("target", Mirror(reflecting: canvas.target).children.compactMap(\.label),
             carriedTargetState, ["pixelMirror"]),
            ("target.pixelMirror", Mirror(reflecting: mirror).children.compactMap(\.label),
             carriedMirrorState, []),
        ]
        for layer in layers {
            let framed = Set(
                frame.compactMap { name -> String? in
                    guard name.hasPrefix(layer.path + ".") else { return nil }
                    let rest = name.dropFirst(layer.path.count + 1)
                    return rest.contains(".") ? nil : String(rest)
                })
            let carried = Set(layer.carried.keys)
            #expect(framed.isDisjoint(with: carried), "\(layer.path): 両方の表に載っている")
            for label in layer.labels {
                #expect(
                    framed.contains(label) || carried.contains(label) || layer.descended.contains(label),
                    "\(layer.path).\(label) がどちらの表にも無い。フレームに属するなら汚す手順と読み方を、持ち越すなら理由を書く")
            }
            for name in framed.union(carried).union(layer.descended) {
                #expect(layer.labels.contains(name), "\(layer.path).\(name) は格納に無い (表から消す)")
            }
        }
    }

    @Test("控えに分けた格納は、どれも上限つきの型である")
    func everyCacheIsBounded() throws {
        // 控えの上限は 2 度書き落とされた (#1593・#1431)。上の表で「控え」に分けた格納は、
        // 上限を書き落とせない型 (BoundedCache) でしか作らない (ADR-0023 決定 5・#1602)。
        // 辞書で控えを足すと、表に理由を 1 行書いても、ここで止まる
        let canvas = try makeCanvas()
        let cacheReason = try #require(carriedState["imageCache"])
        let caches = Set(carriedState.filter { $0.value == cacheReason }.keys)
        #expect(caches.count >= 5)
        for child in Mirror(reflecting: canvas).children {
            guard let label = child.label, caches.contains(label) else { continue }
            let typeName = String(describing: type(of: child.value))
            #expect(
                typeName.hasPrefix("BoundedCache<"),
                "\(label) は控えに分けてあるのに \(typeName) で持っている。上限つきの型で作る")
        }
    }

    /// フレームに属する状態の綴り。**同じ面の上で比べる** — 面ごとに違う資源 (焼き場の面) を
    /// 指す値も、同じ面なら同じ綴りになる。
    private func frameFingerprint(of canvas: Canvas) -> [String: String] {
        let names = Set(frameState.map(\.name))
        var prints: [String: String] = [:]
        for child in Mirror(reflecting: canvas).children {
            guard let label = child.label, names.contains(label) else { continue }
            prints[label] = String(describing: child.value)
        }
        for (name, read) in nestedFrameState { prints[name] = read(canvas) }
        let styleNames = Set(frameStyle.keys)
        for child in Mirror(reflecting: canvas.style).children {
            guard let label = child.label, styleNames.contains(label) else { continue }
            prints["style.\(label)"] = String(describing: child.value)
        }
        return prints
    }

    @Test(
        "フレームに属する状態は、どの境目を越えても既定へ戻る (#1671)",
        arguments: FrameBoundary.allCases, OpenBatch.allCases)
    func frameStateResetsAtEveryBoundary(_ boundary: FrameBoundary, _ openBatch: OpenBatch) throws {
        // 戻す状態を境目の関数ごとに手で並べていたので、並べ落とした状態が 1 件ずつ見つかって
        // きた (#925・#1472・#1504・#1591・#1622)。**全部汚してから越え、全部が戻ったかを見る**
        // — 1 例ずつの検査では、次に足した状態の戻し落としが黙る
        let host = try makeCanvas()
        let canvas = boundary.usesLayer ? try host.createGraphics(Int(host.width), Int(host.height)) : host
        let other = try makeCanvas()
        var fixture = FrameFixture(
            sheet: try canvas.createImage(8, 8), other: other,
            computation: try canvas.makeComputation(
                "kernel void mark(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) { out[id] = 1; }",
                name: "mark"),
            numbers: try canvas.makeNumbers(count: 1),
            // 粒は別の面で作る。作る道は形を組み立てる (`particleQuad`) ので、開いた列の種類が
            // 汚す前から動いてしまう
            particles: try other.makeParticles(count: 8),
            openBatch: openBatch)
        fixture.sheet.fill(.linear(red: 1, green: 1, blue: 1))
        let resets = Dictionary(
            uniqueKeysWithValues: frameState.map { ($0.name, $0.reset) }
                + frameStyle.map { ("style.\($0.key)", $0.value.reset) })

        var baseline: [String: String] = [:]
        var dirtied: [String: String] = [:]
        var closed: [String: String]?
        var crossed: [String: String] = [:]
        try boundary.run(
            canvas, host: host,
            dirty: {
                baseline = frameFingerprint(of: canvas)
                for entry in frameState { entry.dirty(canvas, &fixture) }
                for (_, field) in frameStyle { field.dirty(&canvas.style) }
                dirtied = frameFingerprint(of: canvas)
            },
            closed: { closed = frameFingerprint(of: canvas) },
            inspect: { crossed = frameFingerprint(of: canvas) })

        if boundary.dirtiesOutside {
            // フレームの外で汚せるのは組み立て中の形くらいである。それが汚れていなければ、
            // この越え方は何も見ていない
            for name in Self.shapeState.subtracting(["shapeKind", "shapeHasDepth"]) {
                #expect(dirtied[name] != baseline[name], "\(name) を外で汚せていない")
            }
        } else {
            for entry in frameState where entry.openIn.contains(openBatch) {
                #expect(
                    dirtied[entry.name] != baseline[entry.name],
                    "\(entry.name) を汚す手順が汚していない (既定のままでは戻ったかを見分けられない)")
            }
            for field in frameStyle.keys {
                #expect(dirtied["style.\(field)"] != baseline["style.\(field)"], "style.\(field) が汚れていない")
            }
        }

        if boundary.closes {
            let closed = try #require(closed, "閉じた直後を見ていない")
            for (name, value) in baseline.sorted(by: { $0.key < $1.key }) where resets[name]?.atEnd == true {
                #expect(closed[name] == value, "\(name) が \(boundary) で閉じた直後に既定へ戻っていない")
            }
        }
        for (name, value) in baseline.sorted(by: { $0.key < $1.key }) {
            // 外で置いたものは最初のフレームへ持ち越すのが約束である (ADR-0021 決定 4 の追補
            // (2026-09-27))。頭で戻すものだけを見る
            guard !boundary.dirtiesOutside || resets[name]?.atHead == true else { continue }
            #expect(crossed[name] == value, "\(name) が \(boundary) の境目で既定へ戻らない")
        }
    }

    // MARK: - 形の組み立ての出入口で切り離す組み立て中の形 (#1607)

    /// 組み立て中の形の綴り (``shapeState`` の名前だけ)。
    private func shapeFingerprint(of canvas: Canvas) -> [String: String] {
        frameFingerprint(of: canvas).filter { Self.shapeState.contains($0.key) }
    }

    /// 組み立て中の形を、``shapeState`` の全部が既定と違う状態にする。
    private func openBusyShape(on canvas: Canvas) {
        canvas.beginShape(.triangles)
        canvas.normal(0, 0, 1)
        canvas.vertex(0, 0, 1)
        canvas.vertex(8, 0)
        canvas.vertex(0, 8)
        canvas.index(0)
        canvas.beginContour()
        canvas.vertex(1, 1)
        canvas.vertex(2, 1)
        canvas.vertex(1, 2)
        canvas.beginContour()  // 1 つ目の穴を畳み、2 つ目を開いたままにする
        canvas.vertex(3, 3)
        canvas.curveVertex(4, 4)
        canvas.curveVertex(5, 5)
    }

    @Test("外で開いた形は、形の組み立てを挟んでもそのまま残る (#1607)", arguments: [false, true])
    func createShapeKeepsTheOuterOpenShape(insideFrame: Bool) throws {
        // 形の組み立ても、積む・降ろすが釣り合う単位である (ADR-0021 決定 4 の追補
        // (2026-09-15))。直す前は組み立て中の形を切り離しておらず、記録の中の `beginShape()` が
        // 外で開いた形を黙って上書きした。**並びの全部を見る** — 退かせる並びは 3 か所に
        // 書いてあり (`Canvas.OpenShape`)、1 つ落としても型は通る
        let canvas = try makeCanvas()
        let fresh = shapeFingerprint(of: canvas)
        var before: [String: String] = [:]
        var after: [String: String] = [:]
        func run() {
            openBusyShape(on: canvas)
            before = shapeFingerprint(of: canvas)
            _ = canvas.createShape {
                canvas.beginShape()
                canvas.vertex(0, 0)
                canvas.vertex(16, 0)
                canvas.vertex(16, 16)
                canvas.endShape(.close)
            }
            after = shapeFingerprint(of: canvas)
            canvas.endShape()
        }
        // フレームの外は `setup()` を模す。形を開けるのは持ち越しの区間の中だけである (#1672)
        if insideFrame { try canvas.draw { run() } } else { carryingOver(canvas, run) }

        for name in Self.shapeState.sorted() {
            #expect(before[name] != fresh[name], "\(name) が既定のままなので、戻ったかを見分けられない")
            #expect(after[name] == before[name], "\(name) が形の組み立てを挟んで変わった")
        }
        #expect(!canvas.warnings.hasWarned(.shapeNotEnded), "閉じた形しか組み立てていないのに注意した")
    }

    @Test("形の組み立ての中で開いたまま抜けた形は、出口で捨てて外へ漏らさない (#1607)", arguments: [false, true])
    func createShapeDropsTheShapeLeftOpenInside(insideFrame: Bool) throws {
        // 直す前は記録の中で開いた形が外へ漏れ、外の `vertex()` が形自身の座標の点に積み足した
        let canvas = try makeCanvas()
        var building: Bool?
        var points: Int?
        func run() {
            _ = canvas.createShape {
                canvas.beginShape()
                canvas.vertex(0, 0)
                canvas.vertex(16, 0)
            }
            building = canvas.isBuildingShape
            canvas.vertex(16, 16)
            points = canvas.shapePoints.count
        }
        // フレームの外は `setup()` を模す。区間の外の `vertex()` は形の外より先に区間の外を
        // 言う (#1672) ので、形の外の注意を見るには区間の中で呼ぶ
        if insideFrame { try canvas.draw { run() } } else { carryingOver(canvas, run) }

        #expect(building == false, "記録の中で開いた形が外へ漏れた")
        #expect(points == 0, "外の vertex() が記録の中の形に積み足した")
        #expect(canvas.warnings.hasWarned(.shapeNotEnded))
        #expect(canvas.warnings.hasWarned(.vertexOutsideShape))
    }

    @Test("外で開いた形は、形の組み立ての中からは続けられない (#1607)")
    func createShapeCannotContinueTheOuterShape() throws {
        let canvas = try makeCanvas()
        var shape: Shape?
        try canvas.draw {
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(60, 0)
            shape = canvas.createShape {
                canvas.vertex(30, 60)  // 外の形の続きにはならない
                canvas.endShape(.close)
            }
            canvas.vertex(30, 60)
            canvas.endShape(.close)
        }
        #expect(canvas.warnings.hasWarned(.vertexOutsideShape), "記録の中から外の形を続けられた")
        #expect(canvas.warnings.hasWarned(.shapeNotBegun), "記録の中の endShape() が外の形を閉じた")
        let recorded = try #require(shape)
        #expect(recorded.runs.isEmpty, "記録の中に外の形が焼き付いた")
    }

    /// 戻すときに変わるフィールド。列を閉じるかどうかの違いを持つものを並べる。
    enum StyleChange: CaseIterable, CustomTestStringConvertible {
        case material, castsShadow, receivesShadow, blendMode, clip, picture, fill

        /// 戻す前に列を閉じるか。**置いた図形が、列の持つ設定を後から書き換えられない**
        /// ためのもので、列が読むのは材質・影・混ぜ方・切り抜きだけである。塗りに貼る絵は
        /// 塗りを置く手前で面を選び直すので、戻すときには閉じない
        var closesBatch: Bool {
            switch self {
            case .material, .castsShadow, .receivesShadow, .blendMode, .clip: true
            case .picture, .fill: false
            }
        }

        var testDescription: String { "\(self)" }

        func apply(from source: Canvas.Style, to style: inout Canvas.Style) {
            switch self {
            case .material: style.material = source.material
            case .castsShadow: style.castsShadow = source.castsShadow
            case .receivesShadow: style.receivesShadow = source.receivesShadow
            case .blendMode: style.blendMode = source.blendMode
            case .clip: style.clip = source.clip
            case .picture: style.picture = source.picture
            case .fill: style.fill = source.fill
            }
        }
    }

    @Test("スタイルを戻すとき、列を閉じるのは列が読む設定が変わったときだけ", arguments: StyleChange.allCases)
    func restoringStyleClosesTheBatchOnlyWhenItMatters(_ change: StyleChange) throws {
        let canvas = try makeCanvas()
        let distinct = distinctStyle(on: canvas)
        try canvas.draw {
            canvas.rect(0, 0, 8, 8)  // 閉じていない列を 1 本持つ
            var restored = canvas.currentStyle
            change.apply(from: distinct, to: &restored)
            let before = canvas.batches.count
            canvas.currentStyle = restored
            #expect(
                canvas.batches.count - before == (change.closesBatch ? 1 : 0),
                change.closesBatch ? "戻す前に列を閉じていない" : "閉じなくてよい列を閉じた")
        }
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

    // フレームの外で書いた変換・積み降ろし・切り抜きが口ごとに注意して無視されるかは、
    // シーンの記述の口をまとめて回す `SceneOutsideFrameTests` が見る (#941・#925・#1505 の
    // 検査をそこへ畳んだ・#1670)。ここに残すのは絵のほう

    @Test("初期化のときに変換を書いても、絵は変わらない")
    func transformsOutsideAFrameLeaveThePictureAlone() throws {
        // 警告を足したことで**絵まで変わっていない**ことを見る。フレームの外で書いた
        // 変換はもともと `beginFrame()` に捨てられていたので、変わるのは注意の有無だけ
        let plain = try makeCanvas()
        try plain.draw {
            plain.background(black)
            plain.noStroke()
            plain.fill(white)
            plain.rect(8, 8, 16, 16)
        }
        let expected = try pixels(of: plain)

        let written = try makeCanvas()
        written.translate(20, 20)  // フレームの外なので効かない
        written.pushMatrix()
        try written.draw {
            written.background(black)
            written.noStroke()
            written.fill(white)
            written.rect(8, 8, 16, 16)
        }
        #expect(try pixels(of: written).bytes == expected.bytes)
    }

    @Test("斜めに歪めると、まっすぐな辺が傾く")
    func shearTiltsStraightEdges() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.shearX(Float.pi / 4)  // 45 度なら y のぶんだけ x がずれる
            canvas.rect(8, 8, 8, 24)
        }
        let image = try pixels(of: canvas)
        // y=12 では x が 12 ぶんずれて 20…28 になる。傾いた縁 (20) は滑らかにする領域なので、
        // 1 画素内側を見る
        #expect(image[21, 12].red == 255)
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

    @Test("変換と切り抜きは、描き切った後のフレームの外へ残らない (#1472)")
    func transformAndClipDoNotOutliveTheFrame() throws {
        let canvas = try makeCanvas()
        // 描き場所 (`createGraphics`) の入口で描き切る。`draw { }` と同じ `endFrame()` を通る
        canvas.beginDraw()
        canvas.background(black)
        canvas.translate(20, 10)
        canvas.clip(0, 0, 8, 8)
        canvas.endDraw()

        #expect(canvas.screenX(5, 5) == 5)
        #expect(canvas.screenY(5, 5) == 5)
        #expect(canvas.style.clip == nil)
    }

    @Test("開いたままの形は、描き場所の endDraw() の後へ残らない (#1591)")
    func openShapeDoesNotOutliveTheFrame() throws {
        // 終わりの側で捨てることを見る。頭の側だけだと、`draw()` で開いた形が止まっている
        // 間のコールバック (ここではフレームの外の `vertex()`) へ漏れる
        let canvas = try makeCanvas()
        canvas.beginDraw()
        canvas.background(black)
        canvas.beginShape()
        canvas.vertex(0, 0)
        canvas.vertex(16, 0)
        canvas.vertex(16, 16)
        canvas.endDraw()

        #expect(!canvas.isBuildingShape)
        #expect(canvas.shapePoints.isEmpty)
        #expect(canvas.warnings.hasWarned(.shapeNotEnded))

        // 止まっている間のコールバックを模す (持ち越しの区間・#1672)
        carryingOver(canvas) { canvas.vertex(8, 8) }
        #expect(canvas.warnings.hasWarned(.vertexOutsideShape), "閉じた後の vertex() が黙っている")
        #expect(canvas.shapePoints.isEmpty, "閉じた後の vertex() が点を積んだ")
    }

    @Test("開いたままの穴と通過点の曲線も、形ごと捨てる (#1591)")
    func openHoleAndCurveGuidesDoNotOutliveTheFrame() throws {
        // 開いたままの穴 (#1528) は畳まずに形ごと捨てる。畳むのは `endShape()` が描くときの
        // 約束である
        let canvas = try makeCanvas()
        var holes = 0
        var guides = 0
        var holeOpen = false
        canvas.beginDraw()
        canvas.beginShape()
        canvas.vertex(0, 0)
        canvas.vertex(60, 0)
        canvas.vertex(60, 60)
        canvas.beginContour()
        canvas.vertex(4, 4)
        canvas.vertex(12, 4)
        canvas.vertex(4, 12)
        canvas.beginContour()  // 1 つ目の穴を畳み、2 つ目を開く
        for index in 0..<6 {
            canvas.curveVertex(Float(20 + index * 4), Float(20 + index % 2 * 8))
        }
        holes = canvas.shapeHoles.count
        guides = canvas.curveGuides.count
        holeOpen = canvas.holePoints != nil
        canvas.endDraw()

        try #require(holes > 0 && guides > 0 && holeOpen, "検査の前提: 穴と曲線を開いたまま抜けていない")
        #expect(canvas.curveGuides.isEmpty)
        #expect(canvas.shapeHoles.isEmpty)
        #expect(canvas.holePoints == nil)
    }

    @Test("endDraw() を忘れた描き場所は、次の beginDraw() が前のフレームを描かずに捨てる (#1622)")
    func beginDrawAgainDropsTheUnfinishedFrame() throws {
        // 描き場所の `beginDraw()` / `endDraw()` も対で開いて閉じる操作で、フレームの中で
        // 釣り合う (ADR-0021 決定 4 の追補 (2026-09-27))。直す前の `beginDraw()` は注意だけで
        // 帰り、閉じ忘れたフレームの変換がそのまま次の描き直しに積み上がった ([#1622])
        //
        // [#1622]: https://github.com/mokume-metal/mokume/issues/1622
        let canvas = try makeCanvas()
        try canvas.draw { canvas.background(black) }

        // 閉じ忘れる 1 枚。置いた図形も、書いた変換も、次へ持ち込まない
        canvas.beginDraw()
        canvas.noStroke()
        canvas.fill(white)
        canvas.rect(40, 40, 8, 8)
        canvas.translate(20, 0)

        canvas.beginDraw()
        canvas.noStroke()
        canvas.fill(white)
        canvas.rect(8, 8, 8, 8)
        canvas.endDraw()

        let image = try pixels(of: canvas)
        #expect(image[12, 12] == (255, 255, 255, 255), "前のフレームの変換が効いている")
        #expect(image[32, 12] == (0, 0, 0, 255), "前のフレームの変換が効いている")
        #expect(image[44, 44] == (0, 0, 0, 255), "閉じ忘れたフレームの図形が描かれた")
        // 捨てたフレームも 1 枚に数える。番号は粒の繰り越しと焼き場の頁が境目の印として読む
        #expect(canvas.framesDrawn == 3, "捨てたフレームと次のフレームが同じ番号になっている")
        #expect(canvas.warnings.message(for: .unfinishedFrameDropped) == unfinishedFrameNotice)
        #expect(!canvas.warnings.hasWarned(.alreadyDrawing), "境目を越えたのに、重ね呼びと言った")
    }

    private let unfinishedFrameNotice =
        "endDraw() was not called for a beginDraw() in an earlier frame, so that frame was "
        + "dropped without being drawn, and drawing starts over from here"

    @Test("endDraw() を忘れた描き場所は、次のフレームが draw { } から来ても捨てる (#1622)")
    func drawAfterForgottenEndDrawDropsTheUnfinishedFrame() throws {
        // 捨てるのは入口 (`beginDraw()`) ではなく、フレームの始まりである。入口にだけ置くと、
        // 閉じ忘れたフレームの図形が `draw { }` の新しいフレームへ黙って合流する
        let canvas = try makeCanvas()
        try canvas.draw { canvas.background(black) }

        canvas.beginDraw()
        canvas.noStroke()
        canvas.fill(white)
        canvas.rect(40, 40, 8, 8)
        canvas.translate(20, 0)

        try canvas.draw {
            canvas.noStroke()
            canvas.fill(white)
            canvas.rect(8, 8, 8, 8)
        }

        let image = try pixels(of: canvas)
        #expect(image[12, 12] == (255, 255, 255, 255), "前のフレームの変換が効いている")
        #expect(image[44, 44] == (0, 0, 0, 255), "閉じ忘れたフレームの図形が描かれた")
        #expect(canvas.warnings.message(for: .unfinishedFrameDropped) == unfinishedFrameNotice)
    }

    /// `draw { }` が開いたフレームの中で呼んだ、フレームを開く・閉じる口。
    enum FrameCallInsideDraw: CaseIterable, CustomTestStringConvertible {
        case beginDraw, endDraw, draw

        var testDescription: String { "\(self)" }

        var notice: String {
            switch self {
            case .beginDraw:
                "beginDraw(): this canvas is already inside a frame opened by draw { }, which "
                    + "closes it on its own. This call does nothing"
            case .endDraw:
                "endDraw(): this canvas is inside a frame opened by draw { }, which closes it on "
                    + "its own when the block returns. This call does nothing"
            case .draw:
                "draw(): this canvas is already inside a frame, so the block runs as part of that "
                    + "frame instead of opening a new one"
            }
        }
    }

    @Test(
        "draw { } の中で呼んだ beginDraw() / endDraw() / draw { } は、そのフレームを開き直さず閉じもしない",
        arguments: FrameCallInsideDraw.allCases)
    func frameCallsInsideDrawKeepTheFrame(_ call: FrameCallInsideDraw) throws {
        // `draw { }` が開いたフレームは、閉包を抜けるときに同じ呼び出しが閉じる。中で開き直すと
        // それまでに描いたものや変換が消え、中で閉じると閉包が戻った後にもう一度描き切って
        // 番号が 2 つ進む。本体の面は `Sketch.canvas` として公開されているので、`draw()` の中から
        // 呼べる (#1622 の反証役の指摘)
        let canvas = try makeCanvas()
        var passesAfterCall: Int?
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            canvas.rect(8, 8, 8, 8)
            canvas.translate(20, 0)
            switch call {
            case .beginDraw: canvas.beginDraw()
            case .endDraw: canvas.endDraw()
            case .draw: try? canvas.draw { canvas.rect(8, 30, 8, 8) }
            }
            passesAfterCall = canvas.framesDrawn
            canvas.rect(8, 8, 8, 8)
        }
        let image = try pixels(of: canvas)
        #expect(image[12, 12] == (255, 255, 255, 255), "\(call) がそれまでのフレームを捨てた")
        #expect(image[32, 12] == (255, 255, 255, 255), "\(call) がフレームの変換を戻した")
        if call == .draw {
            #expect(image[32, 34] == (255, 255, 255, 255), "入れ子の draw の中身が同じフレームに描かれない")
        }
        #expect(passesAfterCall == 0, "\(call) がフレームを閉じた")
        #expect(canvas.framesDrawn == 1, "フレームが 2 度閉じた")
        #expect(!canvas.isDrawing)
        #expect(canvas.warnings.message(for: .frameCallInsideDraw) == call.notice)
        #expect(!canvas.warnings.hasWarned(.unfinishedFrameDropped), "閉じ忘れではないのに、捨てたと言った")
    }

    @Test("描き場所で同じ本体のフレームの中に beginDraw() を重ねても、中身を捨てない (#1622)")
    func beginDrawTwiceInOneFrameKeepsTheLayer() throws {
        // 約束が捨てるのは、閉じ忘れたまま境目を越えたフレームである。補助の関数の入れ子などで
        // 同じ本体のフレームの中に重ねただけなら、境目は越えていない。描き場所は本体と時刻の
        // 置き場を共有する (#1467) ので、本体のフレームの番号で見分ける
        let main = try makeCanvas()
        let layer = try main.createGraphics(64, 64)
        try main.draw {
            layer.beginDraw()
            layer.background(black)
            layer.noStroke()
            layer.fill(white)
            layer.rect(8, 8, 8, 8)
            layer.beginDraw()  // 同じ本体のフレームで重ねる
            layer.rect(40, 40, 8, 8)
            layer.endDraw()
        }
        let image = try layer.target.encodeForDisplay()
        #expect(image[12, 12] == (255, 255, 255, 255), "重ねる前に描いたものが消えた")
        #expect(image[44, 44] == (255, 255, 255, 255))
        #expect(layer.framesDrawn == 1)
        #expect(
            layer.warnings.message(for: .alreadyDrawing)
                == "beginDraw(): endDraw() has not been called yet for the beginDraw() earlier in "
                + "this frame. This call does nothing, and drawing continues in the frame already open")
        #expect(!layer.warnings.hasWarned(.unfinishedFrameDropped))
    }

    /// 捨てるのは本体の次のフレームの頭である (#1834)。以前は次の `beginDraw()` が捨てていて、
    /// その間に読む口・描き切らせる口が捨てるはずの中身を描いた (口ごとの検査は
    /// `ForgottenLayerFrameTests`)。
    @Test("描き場所で閉じ忘れたまま本体のフレームが進めば、本体のフレームの頭で捨てる (#1622・#1834)")
    func theMainFrameDropsTheLayerLeftOpen() throws {
        let main = try makeCanvas()
        let layer = try main.createGraphics(64, 64)
        try main.draw {
            layer.beginDraw()
            layer.background(black)
            layer.endDraw()
        }
        try main.draw {
            layer.beginDraw()  // 閉じ忘れる
            layer.noStroke()
            layer.fill(white)
            layer.rect(40, 40, 8, 8)
            layer.translate(20, 0)
        }
        try main.draw {
            layer.beginDraw()
            layer.noStroke()
            layer.fill(white)
            layer.rect(8, 8, 8, 8)
            layer.endDraw()
        }
        let image = try layer.target.encodeForDisplay()
        #expect(image[12, 12] == (255, 255, 255, 255), "前のフレームの変換が効いている")
        #expect(image[44, 44] == (0, 0, 0, 255), "閉じ忘れたフレームの図形が描かれた")
        #expect(
            layer.warnings.message(for: .unfinishedFrameDropped)
                == ForgottenLayerFrameTests.droppedAtMainFrameNotice)
        #expect(!layer.warnings.hasWarned(.alreadyDrawing))
        #expect(layer.framesDrawn == 3, "捨てたフレームを 1 枚に数えていない、または捨て直した")
    }

    @Test("捨てたフレームで積んだ力だけを落とし、前のフレームで積んだ力は残す (#1622)")
    func droppedFrameDropsOnlyItsForces() throws {
        // 力は「次に進めるときにまとめて効く」ので、前のフレームで積んで進めていない力は
        // 捨てたフレームに属さない。捨てたフレームで積んだ力だけを落とす
        let canvas = try makeCanvas()
        let dust = try canvas.makeParticles(count: 8)
        try canvas.draw { canvas.force(dust, [.gravity(0, 1)]) }  // 進めずに終える
        #expect(dust.pendingForceCount == 1)

        canvas.beginDraw()
        canvas.force(dust, [.gravity(0, 2), .drag(0.5)])
        canvas.particles(dust)  // 取り出した後に積んだぶんも落ちる
        canvas.force(dust, [.gravity(0, 3)])
        canvas.beginDraw()  // 閉じ忘れたフレームを捨てる
        #expect(dust.pendingForceCount == 0, "捨てたフレームで積んだ力が残っている")
        canvas.endDraw()

        canvas.beginDraw()
        canvas.force(dust, [.gravity(0, 4)])
        #expect(dust.pendingForceCount == 1)
        canvas.beginDraw()
        #expect(dust.pendingForceCount == 0)
        canvas.force(dust, [.gravity(0, 5)])
        canvas.endDraw()
        try canvas.draw { canvas.force(dust, [.gravity(0, 6)]) }
        canvas.beginDraw()
        canvas.force(dust, [.gravity(0, 7)])
        canvas.beginDraw()
        #expect(dust.pendingForceCount == 2, "前のフレームで積んだ力まで落とした")
        canvas.endDraw()
    }

    @Test("光と周囲は、描き切った後のフレームの外へ残らない (#1504)")
    func lightsAndSurroundingsDoNotOutliveTheFrame() throws {
        let canvas = try makeCanvas()
        canvas.beginDraw()
        canvas.background(black)
        canvas.ambientLight(.linear(red: 0.2, green: 0.2, blue: 0.2))
        canvas.surroundings(.sky)
        canvas.box(10)
        canvas.endDraw()

        #expect(canvas.activeLights.isEmpty)
        #expect(canvas.activeSurroundings == nil)

        // フレームの外で置いて閉じた立体の列は、前のフレームの光も周囲も焼かない。
        // 線は既定で引くので、塗りの列は `box()` の中で稜線の列に閉じられる。
        //
        // **置くのは持ち越しの区間の中** (#1672)。フレームの外で置けるのは、ランタイムが次の
        // フレームを約束する区間 (本体の止まっている間のコールバック) だけで、#1504 の舞台も
        // そこである。区間の外では置かれない (下の検査)
        canvas.carriesOver = true
        canvas.box(10)
        canvas.blendMode(.add)
        canvas.carriesOver = false
        let solids = canvas.batches.filter { $0.source == .solid }
        try #require(!solids.isEmpty)
        for batch in solids {
            #expect(batch.lightRange.isEmpty)
            #expect(batch.surroundings.topAndPresence.w == 0)
        }
    }

    @Test("持ち越しの区間の外では、描き切った後に置いた立体は溜まらず、1 度注意する (#1672)")
    func solidsPlacedOutsideTheRegionsAreRefused() throws {
        let canvas = try makeCanvas()
        canvas.beginDraw()
        canvas.box(10)
        canvas.endDraw()

        canvas.box(10)
        canvas.blendMode(.add)
        #expect(canvas.batches.isEmpty)
        #expect(canvas.solidVertices.isEmpty)
        #expect(canvas.solidInstances.isEmpty)
        #expect(canvas.warnings.hasWarned(.placingOutsideFrame))
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
        // (55, 37) は中心 (50, 32) から 7.1 画素 — 半径 6 の円の 1 画素外、四角の 1 画素内。
        // 縁の上 (6.4 画素の (55, 36)) は滑らかにする領域なので見ない (ADR-0019 決定 4)
        #expect(try endOfThickLine(cap: .round, probe: (55, 37)) == 0)
        #expect(try endOfThickLine(cap: .project, probe: (55, 37)) == 255)
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
        #expect(try outerCornerOfBend(join: .miter) == 255)
    }

    @Test("削ぐ形は矩形の角を落とし、尖らせる形は残す")
    func bevelCutsTheCornerAndMiterKeepsIt() throws {
        // 矩形の角は 3 つの折れ目の形が区別される。距離関数の経路は式で削ぎ (#752)、
        // 三角形の経路も矩形の角だけは同じ線で削ぐ (#1506・下の
        // `triangleRectCornersFollowTheJoin`)。任意多角形の折れ目も、2 本の帯の向きから決まる
        // 同じ形で埋める (#1644・`PolylineJoinTests`)
        #expect(try outerCornerOfBend(join: .bevel) == 0)
        #expect(try outerCornerOfBend(join: .miter) == 255)
    }

    /// 矩形を三角形の経路へ乗せる手立て。
    nonisolated enum RectRoute: CaseIterable, CustomTestStringConvertible, Sendable {
        /// 断片を付ける (`shader()`)。1 つだけなので畳まない
        case shaded
        /// 同じ矩形を断片付きで 2 つ重ねる。2 つ目で畳みの雛形が開く
        case shadedFolded
        /// 絵を貼って塗る (`texture()`)。輪郭と同居するので畳まない
        case textured

        var testDescription: String {
            switch self {
            case .shaded: "断片を付けた"
            case .shadedFolded: "断片を付けて畳んだ"
            case .textured: "絵を貼って塗る"
            }
        }
    }

    /// 三角形の経路の矩形の角も、距離関数の経路と同じ線で削ぐ (#1506)。形と探針は
    /// `FormShapeTests.rectangleCornersFollowTheJoin` と同じで、削ぎ線は角から太さの半分だけ
    /// 離れた所を通る 45° の線。かつては `bevel` でも `miter` と同じ正方形で角を埋め、
    /// `shader()` / `texture()` を 1 行足しただけで矩形の角が尖っていた。
    @Test("三角形の経路で描く矩形も、削ぐ形は角を 45° で落とし、尖らせる形は残す", arguments: RectRoute.allCases)
    func triangleRectCornersFollowTheJoin(_ route: RectRoute) throws {
        func corner(_ join: StrokeJoin) throws -> DisplayImage {
            let canvas = try makeCanvas(width: 96, height: 96)
            var failure: (any Error)?
            try canvas.draw {
                canvas.background(black)
                canvas.stroke(white)
                canvas.strokeWeight(12)
                canvas.strokeJoin(join)
                do {
                    switch route {
                    case .shaded, .shadedFolded:
                        canvas.noFill()
                        canvas.shader(try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }"))
                    case .textured:
                        // 絵の中身は問わない。塗りに絵が付いていることだけが経路を決める
                        canvas.texture(try canvas.createImage(1, 1))
                        canvas.fill(black)
                    }
                } catch { failure = error }
                canvas.rect(20, 20, 40, 40)
                if route == .shadedFolded { canvas.rect(20, 20, 40, 40) }
            }
            if let failure { throw failure }
            return try pixels(of: canvas)
        }
        // 外縁は 14…66。角 (15, 15) は尖らせたときだけ塗られる
        #expect(try corner(.miter)[15, 15].red == 255)
        #expect(try corner(.bevel)[15, 15].red == 0, "削いだ角が尖っている")
        // 削いだ角は 45° の直線。(19, 19) は削ぎ線の内側
        #expect(try corner(.bevel)[19, 19].red == 255)
        // 内縁はどちらの形でも直角 (帯が重なる)
        for join in [StrokeJoin.miter, .bevel] {
            let image = try corner(join)
            #expect(image[27, 27].red == 0, "\(join): 内縁の角の内側が塗られている")
            #expect(image[25, 25].red == 255, "\(join): 内縁の角が欠けている")
        }
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
            canvas.arc(32, 32, 40, 40, Float.pi, 0)
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
        // 座標の約束のうち、線を半画素寄せているかを見る検査 (ADR-0039 決定 2)。
        // 寄せが無いと、縁が画素の中心に乗って隣の列が塗られるか 2 列にまたがる。
        // 経路ごとの寄せは `PixelGridTests.strokesSitOnPixelCenters` が見る
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
        // 太さ 4 の帯は 18.5…22.5 を覆う。偶数の太さは整数の座標では両端の画素に半分ずつ
        // 掛かる (線の中心は画素の中心に乗るので)。覆いの合計が 4 画素ぶんであることを見る
        let covered = (0..<64).map { Double(image[$0, 32].red) }
        let outside = (0..<64).filter { $0 < 18 || $0 > 22 }.map { Double(image[$0, 32].red) }
        #expect(outside.allSatisfy { $0 == 0 }, "帯の外が塗られている")
        #expect(image[20, 32].red == 255)
        #expect(image[19, 32].red == 255)
        #expect(image[21, 32].red == 255)
        #expect(image[18, 32].red == image[22, 32].red, "両端の覆いが対称でない")
        #expect(image[18, 32].red > 0 && image[18, 32].red < 255, "両端は半分だけ覆われる")
        // 線形の覆いの合計 (出力段の変換を戻す)
        let total = covered.map { TransferFunction.decode(Float($0 / 255)) }.reduce(0, +)
        #expect(abs(total - 4) < 0.05, "覆いの合計が太さと合わない: \(total)")
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

    @Test("見た目で指定した色は、sRGB から作業空間へ移した色として出る")
    func displayColorSurvivesTheRoundTrip() throws {
        // 入口は転送関数を外して原色を Display P3 へ移し、出口は転送関数だけを掛ける
        // (ADR-0011 決定 3)。だから書き出しのバイト列は、sRGB の色を Display P3 で書き直した
        // ものになる。期待値は CoreGraphics に同じ変換をさせて導く (ADR-0019 決定 4 の改訂)。
        //
        // **ぴたりとは戻らない。** 途中の作業空間は半精度浮動小数なので、線形へ
        // 落として戻す間に最下位の桁が動く。8 bit にした後の許容を 1 段に取るのは
        // そのため — ここを 0 段にすると、精度の話でしか落ちない検査になる。
        for (red, green, blue) in [(0.25, 0.5, 0.75), (204.0 / 255, 153.0 / 255, 0)] {
            let canvas = try makeCanvas(width: 4, height: 4)
            try canvas.draw {
                canvas.background(.display(red: Float(red), green: Float(green), blue: Float(blue)))
            }

            let pixel = try pixels(of: canvas)[0, 0]
            let expected = SRGBReference.writtenBytes(red: red, green: green, blue: blue)
            #expect(abs(Int(pixel.red) - Int(expected.0)) <= 1)
            #expect(abs(Int(pixel.green) - Int(expected.1)) <= 1)
            #expect(abs(Int(pixel.blue) - Int(expected.2)) <= 1)
            #expect(pixel.alpha == 255)
        }
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

    // MARK: - 描けなかったフレーム (#342)

    @Test("描けなかったフレームに置いたものは、次のフレームへ残らない")
    func nothingPlacedInAFailedFrameSurvivesIntoTheNext() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        // 描ける状態から始める。以降の絵はこの黒が下地になる
        try canvas.draw { canvas.background(black) }

        // 描けないフレームで、塗り直しの予定と図形を置く。`.timedOut` は製品でも
        // 通る経路 (GPU が混んだとき `commitAndWait` が諦める) で、そこを検査から作る
        canvas.failureForTesting = .timedOut(seconds: 5)
        #expect(throws: RenderFailure.self) {
            try canvas.draw {
                canvas.background(self.white)
                canvas.fill(self.white)
                canvas.rect(2, 2, 4, 4)
            }
        }

        // **次のフレームには何も置かない。** 持ち越しが無ければ描くものが 1 つも
        // 無く、下地の黒がそのまま残る
        canvas.failureForTesting = nil
        try canvas.draw {}

        let image = try pixels(of: canvas)
        for y in 0..<8 {
            for x in 0..<8 {
                #expect(image[x, y] == (0, 0, 0, 255))
            }
        }
    }

    @Test("描けないフレームが続いても、溜めたものは積み上がらない")
    func repeatedFailuresDoNotPileUp() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        canvas.failureForTesting = .encoderUnavailable
        for _ in 0..<20 {
            #expect(throws: RenderFailure.self) {
                try canvas.draw {
                    canvas.fill(self.white)
                    canvas.rect(0, 0, 8, 8)
                    // 番号で読む立体も置く。**番号の並びは頂点とは別の溜め場**なので、
                    // 片方だけ捨てても絵には出ない — フレーム数に比例して伸びるだけ
                    canvas.beginShape(.triangles)
                    canvas.normal(0, 0, 1)
                    canvas.vertex(0, 0, 1)
                    canvas.vertex(8, 0, 1)
                    canvas.vertex(8, 8, 1)
                    canvas.vertex(0, 8, 1)
                    for number in [0, 1, 2, 0, 2, 3] { canvas.index(number) }
                    canvas.endShape()
                }
            }
        }

        // **ここだけは絵ではなく溜め場を見る。** 「積み上がらない」は描かれなかった
        // ものの話なので、どのフレームの絵にも現れない
        #expect(canvas.vertices.isEmpty)
        #expect(canvas.solidVertices.isEmpty)
        #expect(canvas.solidIndices.isEmpty)
        #expect(canvas.batches.isEmpty)
    }
}
