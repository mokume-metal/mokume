// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 2D 描画の検査。GPU を要する。
///
/// 見るのは**書き出した絵の画素**で、内部の頂点ではない。頂点を数えても
/// 「指定した場所に指定した色で出たか」は分からない。
///
/// **機能ごとの入れ子 `@Suite` に分けてある** ([#2262])。1 つの型に 3,000 行超を置くと、
/// 読む前に踏んだ検査の置き場を探すだけで時間が掛かる。
///
/// | 入れ子の型 | ファイル | 見るもの |
/// | --- | --- | --- |
/// | ``ShapeDrawing`` | `CanvasTests.swift` | 背景・基本図形・頂点の列・四角の列・切り抜き |
/// | ``Blending`` | `CanvasBlendTests.swift` | 混ぜ方 |
/// | ``StackAndFrame`` | `CanvasStackTests.swift` | 積み降ろしと、フレームの外・境目での変換や立体 |
/// | ``FrameState`` | `CanvasFrameStateTests.swift` | **格納の台帳**・境目で戻す状態・形の組み立ての出入口 |
/// | ``StrokeAndPlacement`` | `CanvasStrokeTests.swift` | 輪郭・位置の基準・変換・色 |
///
/// **格納の台帳 (`FrameState` の `everyStoredPropertyIsClassified` と表) は 1 つの型に置く。**
/// 複数の検査から読む表なので、型を分けると読み手が表をまたぐ。
///
/// 条件 (`.enabled(if:)`) は入れ子の `@Suite` へ継がれるが、`GPUGateTests` は 1 ファイルの
/// 原文だけを読むので、別ファイルの入れ子の `@Suite` には同じ条件を掛け直してある。
///
/// 補助 (`makeCanvas` ほか) は、`CanvasFixture` の方針どおり**入れ子の型ごとに持つ**。
///
/// [#2262]: https://github.com/mokume-metal/mokume/issues/2262
@Suite(
    "2D 描画",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CanvasTests {
    /// 背景・基本図形・頂点を並べて描く形・四角の列・切り抜き。
    @Suite("背景・図形・頂点・切り抜き")
    struct ShapeDrawing {
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
    }
}
