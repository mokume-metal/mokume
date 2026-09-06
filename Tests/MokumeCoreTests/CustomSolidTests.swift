// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 頂点を並べて作った立体の検査。GPU を要する。
///
/// ここで守るのは「**書いた指定が絵に出ること**」である。面の向き・線の色・穴は
/// どれも、間違っていても例外を出さず、それらしい絵が出てしまう。だから画素で見る。
@Suite(
    "自由な立体",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CustomSolidTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)

    private func makeCanvas(width: Int = 96, height: Int = 96) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    // MARK: - 道具が 1 つであること

    @Test("同じ形なら、その場で描いても保持して描いても同じ絵になる")
    func retainedMatchesImmediate() throws {
        // 道具が 1 つに統一されていれば自明に満たされる性質だが、**統一されている
        // ことは絵からしか分からない** — 保持だけ別の経路を通っていれば、面の向きか
        // 頂点の色のどちらかが必ずずれる
        let immediate = try makeCanvas()
        try immediate.draw {
            immediate.background(black)
            immediate.lights()
            wedge(on: immediate)
        }

        let retained = try makeCanvas()
        try retained.draw {
            retained.background(black)
            retained.lights()
            let held = retained.createShape { wedge(on: retained) }
            retained.shape(held)
        }

        #expect(try differingPixels(pixels(of: immediate), pixels(of: retained)) == 0)
    }

    @Test("毎フレーム作り直しても、同じ形なら同じ絵になる")
    func rebuildingEveryFrameIsStable() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.lights()
            wedge(on: canvas)
        }
        let first = try pixels(of: canvas)

        try canvas.draw {
            canvas.background(black)
            canvas.lights()
            wedge(on: canvas)
        }
        #expect(try differingPixels(first, pixels(of: canvas)) == 0)
    }

    // MARK: - 面の向き

    @Test("法線を書かずに閉じた面が、真横から差す光で真っ黒にならない")
    func autoNormalsCatchTheLight() throws {
        // 面の向きを書かない形は、向きが既定値のまま残ると**その面だけ真っ黒**になる。
        // カメラの正面ではなく真横から照らすので、向きが求まっていなければ光は届かない
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            // 上から差す光 (縦軸は下向きなので、進む向きは +y)
            canvas.directionalLight(white, 0, 1, 0)
            canvas.fill(white)
            canvas.noStroke()
            canvas.push()
            canvas.translate(48, 48, 0)
            canvas.rotateX(1.15)  // ほぼ水平まで倒す = 光と正対し、カメラとは正対しない
            canvas.beginShape()
            canvas.vertex(-40, -40, 0)
            canvas.vertex(40, -40, 0)
            canvas.vertex(40, 40, 0)
            canvas.vertex(-40, 40, 0)
            canvas.endShape(.close)
            canvas.pop()
        }

        let image = try pixels(of: canvas)
        #expect(image[48, 48].red > 120)
    }

    @Test("面はどちらの側から見ても光を受ける")
    func bothSidesCatchTheLight() throws {
        // 並べる向き (巻き方) を逆にしただけで真っ黒になるなら、利用者は自分の
        // 座標を疑うことになる
        func brightness(reversed: Bool) throws -> Int {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.directionalLight(white, 0, 1, 0)
                canvas.fill(white)
                canvas.noStroke()
                canvas.push()
                canvas.translate(48, 48, 0)
                canvas.rotateX(1.15)
                canvas.beginShape()
                let corners: [(Float, Float)] = [(-40, -40), (40, -40), (40, 40), (-40, 40)]
                for corner in reversed ? corners.reversed() : corners {
                    canvas.vertex(corner.0, corner.1, 0)
                }
                canvas.endShape(.close)
                canvas.pop()
            }
            return Int(try pixels(of: canvas)[48, 48].red)
        }

        #expect(try brightness(reversed: false) == brightness(reversed: true))
    }

    @Test("書いた面の向きは、書き換えるまで続く")
    func writtenNormalsPersistUntilChanged() throws {
        // 2 つの三角形を、同じ形・同じ場所に置いて向きだけ変える。「次の 1 頂点まで」
        // なら 2 枚目の 2・3 番目の頂点に効かず、絵は混ざる
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.directionalLight(white, 0, 1, 0)
            canvas.fill(white)
            canvas.noStroke()
            canvas.push()
            canvas.translate(48, 48, 0)
            canvas.beginShape(.triangles)
            canvas.normal(0, -1, 0)  // 光へ真っ直ぐ向く = 明るい
            canvas.vertex(-40, -30, 0)
            canvas.vertex(0, -30, 0)
            canvas.vertex(-40, 30, 0)
            canvas.normal(0, 1, 0)  // 光に背を向ける = 暗い
            canvas.vertex(40, -30, 0)
            canvas.vertex(40, 30, 0)
            canvas.vertex(0, 30, 0)
            canvas.endShape()
            canvas.pop()
        }

        let image = try pixels(of: canvas)
        // 2 枚目は 3 頂点とも同じ向きなので、隅まで一様に暗い
        #expect(image[20, 30].red > 200)
        #expect(image[76, 70].red < 40)
        #expect(image[70, 30].red < 40)
    }

    @Test("面の向きは、形を始めるところで未指定へ戻る")
    func normalsResetAtTheStartOfAShape() throws {
        func draw(writingNormalBefore: Bool) throws -> DisplayImage {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.directionalLight(white, 0, 1, 0)
                canvas.fill(white)
                canvas.noStroke()
                if writingNormalBefore { canvas.normal(0, 1, 0) }
                canvas.push()
                canvas.translate(48, 48, 0)
                canvas.rotateX(1.15)
                canvas.beginShape()
                canvas.vertex(-40, -40, 0)
                canvas.vertex(40, -40, 0)
                canvas.vertex(40, 40, 0)
                canvas.vertex(-40, 40, 0)
                canvas.endShape(.close)
                canvas.pop()
            }
            return try pixels(of: canvas)
        }

        // 形の前に書いた向きが残っていれば、形から求めた向きと違う明るさになる
        #expect(try differingPixels(draw(writingNormalBefore: true), draw(writingNormalBefore: false)) == 0)
    }

    @Test("帯の内側の頂点にも、面の向きが付く")
    func triangleStripDerivesNormalsAtSharedVertices() throws {
        // 屋根の形に折った帯。**巻きが 1 枚おきに反転していると**、2 枚に挟まれた頂点で
        // 外積が打ち消し合い、向きの定まらない面が残る (`placedVertices`)。打ち消しが
        // 起きるのは左右の裾の頂点なので、そこが暗く落ちれば読み取れる
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.directionalLight(white, 0, 0, -1)  // 画面の手前を向く面が明るい
            canvas.fill(white)
            canvas.noStroke()
            canvas.push()
            canvas.translate(48, 48, 0)
            canvas.beginShape(.triangleStrip)
            canvas.vertex(-30, -30, 0)
            canvas.vertex(-30, 30, 0)
            canvas.vertex(0, -30, 30)
            canvas.vertex(0, 30, 30)
            canvas.vertex(30, -30, 0)
            canvas.vertex(30, 30, 0)
            canvas.endShape()
            canvas.pop()
        }

        let image = try pixels(of: canvas)
        #expect(image[24, 70].red > 100, "左の裾が暗い")
        #expect(image[72, 26].red > 100, "右の裾が暗い")
        #expect(image[48, 48].red > 100, "折り目が暗い")
    }

    // MARK: - 線と点

    @Test("線と点のモードは、塗りではなく線の色で描かれる")
    func linesAndPointsUseTheStrokeColour() throws {
        for kind in [VertexKind.lines, .points] {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.fill(red)
                canvas.stroke(blue)
                canvas.strokeWeight(9)
                canvas.beginShape(kind)
                canvas.vertex(24, 48, 0)
                canvas.vertex(72, 48, 0)
                canvas.endShape()
            }

            let image = try pixels(of: canvas)
            let sample = image[24, 48]
            #expect(sample.blue > 200, "\(kind) の色が線の色ではない")
            #expect(sample.red < 40, "\(kind) が塗りの色で描かれている")
        }
    }

    @Test("立体の線は、面と同じように奥行きで前後する")
    func solidStrokeRespectsDepth() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(red)
            // 手前に赤い面
            canvas.beginShape()
            canvas.vertex(16, 16, 30)
            canvas.vertex(80, 16, 30)
            canvas.vertex(80, 80, 30)
            canvas.vertex(16, 80, 30)
            canvas.endShape(.close)
            // 奥に青い線
            canvas.stroke(blue)
            canvas.strokeWeight(9)
            canvas.beginShape(.lines)
            canvas.vertex(24, 48, -30)
            canvas.vertex(72, 48, -30)
            canvas.endShape()
        }

        // 面のほうが手前なので、線は隠れる
        #expect(try pixels(of: canvas)[48, 48].red > 200)
    }

    // MARK: - 穴

    @Test("穴は、平面でも立体でも穴として出る", arguments: [false, true])
    func contoursWorkInBothPlaneAndSolid(_ hasDepth: Bool) throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.noStroke()
            canvas.beginShape()
            for corner in [(12, 12), (84, 12), (84, 84), (12, 84)] {
                place(canvas, Float(corner.0), Float(corner.1), depth: hasDepth)
            }
            canvas.beginContour()
            // 穴は外周と逆に回る
            for corner in [(32, 32), (32, 64), (64, 64), (64, 32)] {
                place(canvas, Float(corner.0), Float(corner.1), depth: hasDepth)
            }
            canvas.endContour()
            canvas.endShape(.close)
        }

        let image = try pixels(of: canvas)
        #expect(image[48, 48] == (0, 0, 0, 255), "穴が開いていない")
        #expect(image[20, 48].red > 200, "外周まで抜けている")
    }

    // MARK: - 頂点ごとの色

    @Test("頂点ごとに塗りを変えると、色が頂点の間で移る", arguments: [false, true])
    func fillVariesPerVertex(_ hasDepth: Bool) throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.beginShape()
            canvas.fill(red)
            place(canvas, 12, 12, depth: hasDepth)
            place(canvas, 12, 84, depth: hasDepth)
            canvas.fill(blue)
            place(canvas, 84, 84, depth: hasDepth)
            place(canvas, 84, 12, depth: hasDepth)
            canvas.endShape(.close)
        }

        let image = try pixels(of: canvas)
        #expect(image[20, 48].red > image[20, 48].blue)
        #expect(image[76, 48].blue > image[76, 48].red)
    }

    // MARK: - 壊れた入力

    @Test("壊れた入力でも落ちない")
    func brokenInputDoesNotCrash() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)

            // 頂点が 1 つだけ
            canvas.beginShape()
            canvas.vertex(20, 20, 0)
            canvas.endShape(.close)

            // 同じ点を 3 つ = 面積を持たない三角形
            canvas.beginShape()
            for _ in 0..<3 { canvas.vertex(40, 40, 5) }
            canvas.endShape(.close)

            // 一直線に並んだ点 = 平面が決まらない
            canvas.beginShape()
            for step in 0..<4 { canvas.vertex(Float(step) * 10, Float(step) * 10, Float(step)) }
            canvas.endShape(.close)

            // 数でない座標
            canvas.beginShape()
            canvas.vertex(Float.nan, 10, 0)
            canvas.vertex(10, Float.infinity, 0)
            canvas.vertex(20, 20, Float.nan)
            canvas.vertex(30, 30, 10)
            canvas.endShape(.close)

            // 始めていないのに閉じる
            canvas.endShape(.close)
        }

        #expect(try pixels(of: canvas).width == 96)
    }

    // MARK: - 番号で読む

    @Test(
        "同じ形を、点を書き出しても番号で指しても 1 画素も違わない",
        arguments: [false, true], [false, true])
    func indexedMatchesExpanded(stroked: Bool, textured: Bool) throws {
        // **絵で見るしかない性質である。** 番号の経路は頂点の積み方も描く口も違うので
        // (`drawIndexedPrimitives`)、どこか 1 つずれても「それらしい絵」が出てしまう。
        //
        // 4 通りとも別の経路を踏む:
        // - 輪郭なし・貼る絵なし … 共有そのもの
        // - **輪郭あり・貼る絵なし** … 帯と端点が**番号の列に同居する** (共有できないので
        //   自分の番号を名乗る)。名乗らないと、輪郭だけが黙って消える
        // - 貼る絵あり … 読み取り位置が共有した点に付く
        // - 輪郭あり・貼る絵あり … 塗りと輪郭で面が変わるので、**列が原始形ごとに閉じる**
        func render(indexed: Bool) throws -> DisplayImage {
            let canvas = try makeCanvas()
            let picture = try canvas.createImage(4, 4)
            picture.fill(.display(red: 0.2, green: 0.9, blue: 0.4))
            try canvas.draw {
                canvas.background(black)
                canvas.lights()
                if textured { canvas.texture(picture) }
                grid(on: canvas, indexed: indexed, stroked: stroked)
            }
            return try pixels(of: canvas)
        }

        #expect(try differingPixels(render(indexed: false), render(indexed: true)) == 0)
    }

    @Test(
        "番号を書く形と書かない形が続いても、どちらも消えない",
        arguments: [false, true], [false, true])
    func mixedShapesKeepBoth(leftIndexed: Bool, rightIndexed: Bool) throws {
        // **列は形をまたいで開いたままである。** 読み方が列ごと切り替わると、先に置いた
        // 形が誰からも参照されずに消える (番号を積み始めた列では、番号の無い頂点は
        // 描かれない)。どちらの順でも起きる
        func render(_ left: Bool, _ right: Bool) throws -> DisplayImage {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.lights()
                patch(on: canvas, x: 10, indexed: left)
                patch(on: canvas, x: 56, indexed: right)
            }
            return try pixels(of: canvas)
        }

        #expect(
            try differingPixels(render(false, false), render(leftIndexed, rightIndexed)) == 0)
    }

    @Test("番号は、自分の列の頂点だけを指す")
    func indicesStayInsideTheirRun() throws {
        // **絵からは分からない不変条件である。** 番号は並び全体の位置なので、その場で
        // 描く間は列をまたいで届いてしまい、絵は正しく出る。破れが現れるのは
        // 保持した形を切り出すときで (区間しか写さない)、そこまで行かないと気づけない
        let canvas = try makeCanvas()
        var outside = 0
        let picture = try canvas.createImage(4, 4)
        picture.fill(.display(red: 0.2, green: 0.9, blue: 0.4))
        try canvas.draw {
            canvas.lights()
            canvas.texture(picture)
            grid(on: canvas, indexed: true, stroked: true)
            canvas.closeBatch()
            for run in canvas.batches.map(\.run) where run.isIndexed {
                let own = run.start..<(run.start + run.count)
                outside += canvas.solidIndices[run.indexStart..<(run.indexStart + run.indexCount)]
                    .filter { !own.contains(Int($0)) }.count
            }
        }
        #expect(outside == 0)
    }

    @Test("番号で指した点は、面の数だけ書き出されない (54 個が 16 個になる)")
    func indexedSharesVertices() throws {
        // #938 の実害を数で写したもの。あちらは 46,356 個が 14,556 個になる形で、
        // 比 (3.18 倍) はこの検査の 3.375 倍と同じ桁にある
        var expandedCount = 0
        var indexedCount = 0

        let canvas = try makeCanvas()
        try canvas.draw {
            grid(on: canvas, indexed: false)
            expandedCount = canvas.solidVertices.count
        }
        try canvas.draw {
            grid(on: canvas, indexed: true)
            indexedCount = canvas.solidVertices.count
        }

        // 書き出す側は「三角形の枚数 × 3」、番号で指す側は「置いた点の数」に一致する
        #expect(expandedCount == Self.gridTriangles.count * 3)
        #expect(indexedCount == Self.gridPoints.count)
    }

    @Test("置いていない番号を含む面だけが落ちる")
    func outOfRangeIndicesDropTheirFaceOnly() throws {
        // **面ごと落とす。** 1 つずつ落とすと 3 つ組の区切りがずれて、それ以降の面が
        // 全部別の点を指す — 絵は出るので、崩れるまで誰も気づけない。だから壊れた番号を
        // **先の面**に置き、後の面が無傷で残ることを見る (1 つずつ落とす作りでは、
        // 後の面が (0,1,0) のような潰れた三角形になって消える)
        func render(_ order: [Int]) throws -> DisplayImage {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.lights()
                canvas.noStroke()
                canvas.fill(red)
                canvas.beginShape(.triangles)
                quadPoints(on: canvas)
                for number in order { canvas.index(number) }
                canvas.endShape()
            }
            return try pixels(of: canvas)
        }

        #expect(try differingPixels(render([0, 1, 99, 0, 2, 3]), render([0, 2, 3])) == 0)
    }

    @Test(
        "番号で指した形は、保持して置いても同じ絵になる",
        arguments: [false, true])
    func indexedRetainedMatchesImmediate(stroked: Bool) throws {
        // 保持は頂点も番号も**区間で切り出して**積み直す経路 (`openRetainedSolid`)。
        // 番号を積み忘れると非添字へ落ちて、頂点を 3 つずつ束ねただけの並びが描かれる。
        //
        // **輪郭つきの側が、共有の表が列の寿命を持つことを見る。** 貼る絵と輪郭が
        // 両方効くと列が原始形ごとに閉じるので、表を持ち越すと番号が**自分の列の外**を
        // 指す。その場で描く間は絵が出てしまう (番号は並び全体の位置なので届く) が、
        // 切り出す側は区間しか写さないので、そこで初めて崩れる
        let immediate = try makeCanvas()
        let immediatePicture = try immediate.createImage(4, 4)
        immediatePicture.fill(.display(red: 0.2, green: 0.9, blue: 0.4))
        try immediate.draw {
            immediate.background(black)
            immediate.lights()
            immediate.texture(immediatePicture)
            grid(on: immediate, indexed: true, stroked: stroked)
        }

        let retained = try makeCanvas()
        let retainedPicture = try retained.createImage(4, 4)
        retainedPicture.fill(.display(red: 0.2, green: 0.9, blue: 0.4))
        try retained.draw {
            retained.background(black)
            retained.lights()
            retained.texture(retainedPicture)
            let held = retained.createShape { grid(on: retained, indexed: true, stroked: stroked) }
            retained.shape(held)
        }

        #expect(try differingPixels(pixels(of: immediate), pixels(of: retained)) == 0)
    }

    // MARK: - 道具

    /// 番号で指す検査に使う立体 — 4x4 の格子。
    ///
    /// **角を共有する形**である。16 点で 18 枚の三角形を張るので、書き出せば 54 点に
    /// なる。面の向きは点ごとに書く — 書かない向きは面から求まり、共有すると隣の面の
    /// ぶんまで足し込まれるので、**書き出した形と揃わなくなる** (それは仕様どおりの
    /// 違いで、この検査が見たいものではない)。
    private static let gridSide = 4
    private static let gridPoints: [SIMD3<Float>] = {
        (0..<(gridSide * gridSide)).map { number in
            let column = Float(number % gridSide)
            let row = Float(number / gridSide)
            let step = 64 / Float(gridSide - 1)
            return SIMD3(16 + column * step, 16 + row * step, (column - row) * 6)
        }
    }()
    private static let gridTriangles: [(Int, Int, Int)] = {
        var triangles: [(Int, Int, Int)] = []
        for row in 0..<(gridSide - 1) {
            for column in 0..<(gridSide - 1) {
                let corner = row * gridSide + column
                triangles.append((corner, corner + 1, corner + gridSide + 1))
                triangles.append((corner, corner + gridSide + 1, corner + gridSide))
            }
        }
        return triangles
    }()

    private func gridNormal(_ point: SIMD3<Float>) -> SIMD3<Float> {
        simd_normalize(SIMD3(point.x - 48, point.y - 48, 40))
    }

    private func grid(on canvas: Canvas, indexed: Bool, stroked: Bool = false) {
        if stroked {
            canvas.stroke(blue)
            canvas.strokeWeight(2)
        } else {
            canvas.noStroke()
        }
        canvas.fill(red)
        canvas.beginShape(.triangles)
        if indexed {
            for point in Self.gridPoints {
                let normal = gridNormal(point)
                canvas.normal(normal.x, normal.y, normal.z)
                canvas.vertex(point.x, point.y, point.z)
            }
            for triangle in Self.gridTriangles {
                canvas.index(triangle.0)
                canvas.index(triangle.1)
                canvas.index(triangle.2)
            }
        } else {
            for triangle in Self.gridTriangles {
                for number in [triangle.0, triangle.1, triangle.2] {
                    let point = Self.gridPoints[number]
                    let normal = gridNormal(point)
                    canvas.normal(normal.x, normal.y, normal.z)
                    canvas.vertex(point.x, point.y, point.z)
                }
            }
        }
        canvas.endShape()
    }

    /// 4 隅を 2 枚の三角形で張った小さな面。番号で指すかを選べる。
    private func patch(on canvas: Canvas, x: Float, indexed: Bool) {
        let corners: [SIMD2<Float>] = [
            SIMD2(x, 20), SIMD2(x + 30, 20), SIMD2(x + 30, 70), SIMD2(x, 70),
        ]
        let order = [0, 1, 2, 0, 2, 3]
        canvas.noStroke()
        canvas.fill(red)
        canvas.beginShape(.triangles)
        canvas.normal(0, 0, 1)
        if indexed {
            for corner in corners { canvas.vertex(corner.x, corner.y, 0) }
            for number in order { canvas.index(number) }
        } else {
            for number in order {
                canvas.vertex(corners[number].x, corners[number].y, 0)
            }
        }
        canvas.endShape()
    }

    /// 番号で指す最小の形の点 (四角の 4 隅)。
    private func quadPoints(on canvas: Canvas) {
        canvas.normal(0, 0, 1)
        canvas.vertex(20, 20, 0)
        canvas.vertex(76, 20, 0)
        canvas.vertex(76, 76, 0)
        canvas.vertex(20, 76, 0)
    }

    /// 検査に使う立体。面の向きを書かず、頂点ごとに色を変える。
    private func wedge(on canvas: Canvas) {
        canvas.stroke(blue)
        canvas.strokeWeight(3)
        canvas.beginShape()
        canvas.fill(red)
        canvas.vertex(20, 24, 0)
        canvas.vertex(76, 20, 26)
        canvas.fill(white)
        canvas.vertex(70, 74, -18)
        canvas.vertex(26, 78, 8)
        canvas.endShape(.close)
    }

    /// 頂点を、平面としても立体としても置けるようにする。
    private func place(_ canvas: Canvas, _ x: Float, _ y: Float, depth: Bool) {
        if depth { canvas.vertex(x, y, 0) } else { canvas.vertex(x, y) }
    }

    private func differingPixels(_ a: DisplayImage, _ b: DisplayImage) -> Int {
        guard a.width == b.width, a.height == b.height else { return .max }
        var differing = 0
        for y in 0..<a.height {
            for x in 0..<a.width where a[x, y] != b[x, y] { differing += 1 }
        }
        return differing
    }
}
