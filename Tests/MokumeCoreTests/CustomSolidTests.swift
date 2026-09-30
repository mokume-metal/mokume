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

    @Test("全指定の法線は、未使用の未指定頂点を含む形と頂点値・陰影が一致する",
        arguments: [VertexKind.triangles, .triangleStrip], [false, true])
    func writtenNormalsMatchAccumulatingPath(kind: VertexKind, mirrored: Bool) throws {
        let canvas = try makeCanvas()
        let paint = try canvas.makeShader("""
            float4 paint(Fragment in, Values values) {
                return float4(in.shapeNormal * 0.25 + in.worldNormal * 0.25 + 0.5, 1.0);
            }
            """)
        // 最後の三角形は縮退。互いに異なる指定法線を、非一様拡大・鏡映で移す。
        let points: [SIMD3<Float>] = [
            SIMD3(-25, -20, 0), SIMD3(25, -20, 3), SIMD3(-25, 20, 5),
            SIMD3(25, 20, -2), SIMD3(25, 20, -2), SIMD3(25, 20, -2),
        ]
        func render(accumulating: Bool, lit: Bool) throws -> ([SolidVertex], DisplayImage) {
            var vertices: [SolidVertex] = []
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                if lit {
                    canvas.resetShader()
                    canvas.lights()
                } else {
                    canvas.shader(paint)
                }
                canvas.translate(48, 48, 0)
                canvas.rotateX(0.31)
                canvas.rotateY(-0.27)
                canvas.scale(mirrored ? -1.2 : 1.2, 0.7, 1.5)
                canvas.beginShape(kind)
                // 添字から参照しない未指定頂点だけを足すと、必ず既存の累積経路に入る。
                // 塗りの入力は同じなので、早期returnの判定・変換・isDerivedを比較できる。
                if accumulating { canvas.vertex(0, 0, 0) }
                for (index, point) in points.enumerated() {
                    canvas.normal(Float(index + 1), -2, 3)
                    canvas.fill(.linear(red: Float(index + 1) / 8, green: 0.4, blue: 0.7))
                    canvas.vertex(point.x, point.y, point.z, Float(index) / 8, 0.25)
                    canvas.index(index + (accumulating ? 1 : 0))
                }
                canvas.endShape()
                vertices = canvas.solidVertices
            }
            return (vertices, try pixels(of: canvas))
        }
        for lit in [false, true] {
            let (actual, image) = try render(accumulating: false, lit: lit)
            let (reference, referenceImage) = try render(accumulating: true, lit: lit)
            #expect(!actual.isEmpty)
            #expect(actual.count == reference.count)
            for (a, b) in zip(actual, reference) {
                // padding は読まず、shaderへ届く全成分をbit単位で比べる。
                let aValues = [a.position.x, a.position.y, a.position.z,
                    a.shapePosition.x, a.shapePosition.y, a.shapePosition.z,
                    a.normal.x, a.normal.y, a.normal.z, a.normal.w,
                    a.shapeNormal.x, a.shapeNormal.y, a.shapeNormal.z,
                    a.uv.x, a.uv.y, a.stroke, a.color.x, a.color.y, a.color.z, a.color.w]
                let bValues = [b.position.x, b.position.y, b.position.z,
                    b.shapePosition.x, b.shapePosition.y, b.shapePosition.z,
                    b.normal.x, b.normal.y, b.normal.z, b.normal.w,
                    b.shapeNormal.x, b.shapeNormal.y, b.shapeNormal.z,
                    b.uv.x, b.uv.y, b.stroke, b.color.x, b.color.y, b.color.z, b.color.w]
                #expect(aValues.map(\.bitPattern) == bValues.map(\.bitPattern))
                #expect(a.normal.w == 0)
            }
            #expect(image.bytes == referenceImage.bytes)
            #expect(image.bytes.contains { $0 != 0 && $0 != 255 }, "空の画像だけを比較しない")
        }
    }

    @Test("帯の未指定法線は、指定済みの隣の頂点があっても形から求める")
    func mixedStripNormalsKeepTheDerivedVertices() throws {
        let canvas = try makeCanvas()
        var normals: [SIMD4<Float>] = []
        var shapeNormals: [SIMD3<Float>] = []
        try canvas.draw {
            canvas.noStroke()
            canvas.beginShape(.triangleStrip)
            canvas.vertex(10, 10, 0)
            canvas.vertex(50, 10, 0)
            canvas.normal(0, 1, 0)
            canvas.vertex(10, 50, 0)
            canvas.vertex(50, 50, 0)
            canvas.endShape()
            normals = canvas.solidVertices.map(\.normal)
            shapeNormals = canvas.solidVertices.map(\.shapeNormal)
        }
        #expect(normals.count == 6)
        #expect(normals.filter { $0.w == 1 }.allSatisfy { $0 == SIMD4(0, 0, 1, 1) })
        #expect(normals.filter { $0.w == 0 }.allSatisfy { $0 == SIMD4(0, 1, 0, 0) })
        #expect(normals.contains { $0.w == 1 })
        #expect(normals.contains { $0.w == 0 })
        #expect(shapeNormals == normals.map { SIMD3($0.x, $0.y, $0.z) })
    }

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

    @Test("上下を裏返した平行投影でも、形から求めた向きの面は見る側から光を受ける")
    func derivedNormalsCatchTheLightUnderAFlippedProjection() throws {
        // 上の検査と同じ場面を、上下を裏返した ortho で描く。投影が画面の巻き方を裏返すと
        // 「裏を向いている」の判定も裏返るので、表の巻き方を裏返さないと、どちらの巻き方で
        // 並べても視線と逆の向きで光を受けて暗くなる — **2 つが同じ明るさのまま暗くなる**
        // ので、上の検査の比べ方 (2 つが等しい) では見分けられない (#1446)
        func brightness(flipped: Bool, reversed: Bool) throws -> Int {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                if flipped { canvas.ortho(-48, 48, -48, 48, 5, 600) } else { canvas.ortho() }
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
            // 裏返した絵では、真ん中の画素は縦に 1 つずれた位置へ移る (96 画素の面の 48 ↔ 47)
            return Int(try pixels(of: canvas)[48, flipped ? 47 : 48].red)
        }

        for reversed in [false, true] {
            let upright = try brightness(flipped: false, reversed: reversed)
            let flipped = try brightness(flipped: true, reversed: reversed)
            #expect(upright > 120, "裏返さない投影で面が光を受けていない (\(upright))")
            #expect(
                abs(flipped - upright) <= 2,
                "裏返した投影で明るさが変わった (\(upright) → \(flipped)・並べる向きの逆転 \(reversed))")
        }
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

    // MARK: - 1 度に渡す量

    @Test("同じ総量なら、1 度に渡す塊の大きさを変えても組み立ての費用が動かない")
    func foldingCostFollowsTheTotalOnly() throws {
        // #915 の本体。**時間ではなく数で見る** — 時間は release でしか測れず、機械の
        // 都合で揺れるので `ci-check` に載せられない。舐めた点の延べ回数なら、
        // 二乗が戻った瞬間に塊の大きさに比例して動く
        //
        // 直す前はこの 3 通りが 1,536 / 49,152 / 196,608 に開いていた
        // (塊 1 枚 → 512 枚で 128 倍)
        func scans(chunk: Int) throws -> Int {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.noStroke()
                canvas.fill(red)
                stripes(on: canvas, triangles: 512, chunk: chunk)
            }
            return canvas.pointScansInLastFrame
        }

        let one = try scans(chunk: 1)
        #expect(try scans(chunk: 64) == one)
        #expect(try scans(chunk: 512) == one)
    }

    @Test("塊の大きさを変えても、絵は 1 画素も違わない")
    func chunkingDoesNotChangeThePicture() throws {
        // 費用の話が絵を動かしていないこと。**塊を変えると列の切れ目は動く**が、
        // 描かれる三角形は同じである
        func render(chunk: Int) throws -> DisplayImage {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.lights()
                canvas.noStroke()
                canvas.fill(red)
                stripes(on: canvas, triangles: 512, chunk: chunk)
            }
            return try pixels(of: canvas)
        }
        #expect(try differingPixels(render(chunk: 1), render(chunk: 512)) == 0)
    }

    @Test("番号と穴を同時に使っても、番号を使わない同じ形と同じ絵になる")
    func indicesAndContoursWorkTogether() throws {
        // **穴があるときだけ全点を平らへ落とす**経路。番号を渡すと環の番号が飛び飛びに
        // なるので、穴の番号 (置いた点の数から数える) と混ざったまま引ける並びが
        // 要る。この組み合わせはこれまでどこにも検査が無かった
        func render(indexed: Bool) throws -> DisplayImage {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.lights()
                canvas.noStroke()
                canvas.fill(red)
                canvas.beginShape()
                canvas.normal(0, 0, 1)
                // 外周は 5 点置くが、読むのは 4 点だけ (番号を使う側)
                for corner in [(14, 14), (48, 8), (82, 14), (82, 82), (14, 82)]
                    as [(Float, Float)]
                {
                    canvas.vertex(corner.0, corner.1, 0)
                }
                canvas.beginContour()
                for corner in [(38, 38), (38, 58), (58, 58), (58, 38)] as [(Float, Float)] {
                    canvas.vertex(corner.0, corner.1, 0)
                }
                canvas.endContour()
                if indexed {
                    for number in [0, 2, 3, 4] { canvas.index(number) }
                }
                canvas.endShape(.close)
            }
            return try pixels(of: canvas)
        }

        // 番号で 1 番を飛ばした形は、その点を置かなかった形と同じ絵になる
        let indexed = try render(indexed: true)
        let plain = try makeCanvas()
        try plain.draw {
            plain.background(black)
            plain.lights()
            plain.noStroke()
            plain.fill(red)
            plain.beginShape()
            plain.normal(0, 0, 1)
            for corner in [(14, 14), (82, 14), (82, 82), (14, 82)] as [(Float, Float)] {
                plain.vertex(corner.0, corner.1, 0)
            }
            plain.beginContour()
            for corner in [(38, 38), (38, 58), (58, 58), (58, 38)] as [(Float, Float)] {
                plain.vertex(corner.0, corner.1, 0)
            }
            plain.endContour()
            plain.endShape(.close)
        }
        #expect(try differingPixels(indexed, pixels(of: plain)) == 0)
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

    // MARK: - 四角の列

    /// 1 隅だけ奥行きをずらした、平らでない四角の 4 隅。
    private static let warpedCorners: [SIMD3<Float>] = [
        SIMD3(-30, -30, 0), SIMD3(30, -30, 0), SIMD3(30, 30, 0), SIMD3(-30, 30, 24),
    ]

    @Test("面の向きを書いた立体の四角は、平らでなくても `.triangles` で 2 枚に割った絵と一致する")
    func solidQuadsMatchTheHandSplitTriangles() throws {
        // 4 隅の色は 0 と 2 が白、1 と 3 が赤。面の向きは隅ごとに違う値を書く。
        // 平らでない四角では、対角線の選び方が色にも光にも出る
        func render(_ kind: VertexKind, _ order: [Int]) throws -> DisplayImage {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.lights()
                canvas.noStroke()
                canvas.translate(48, 48, 0)
                canvas.beginShape(kind)
                for index in order {
                    canvas.normal(Float(index) * 0.3 - 0.4, 0.2 - Float(index) * 0.1, 1)
                    canvas.fill(index.isMultiple(of: 2) ? white : red)
                    let corner = Self.warpedCorners[index]
                    canvas.vertex(corner.x, corner.y, corner.z)
                }
                canvas.endShape()
            }
            return try pixels(of: canvas)
        }
        let byQuads = try render(.quads, [0, 1, 2, 3])
        #expect(try differingPixels(byQuads, render(.triangles, [0, 1, 2, 0, 2, 3])) == 0)
        #expect(
            try differingPixels(byQuads, render(.triangles, [1, 2, 3, 1, 3, 0])) > 0,
            "対角線を変えても絵が動かない")
    }

    @Test("面の向きを書かない立体の四角は、番号で指して 2 枚に割った同じ形と 1 画素も違わない")
    func solidQuadsMatchTheIndexedHandSplit() throws {
        // 書かない向きは面から求まり、頂点を共有すれば隣の面のぶんまで足し込まれる。
        // 四角の 0 番と 2 番は 2 枚に共有されるので、番号で共有した手割りと揃う
        func render(quads: Bool) throws -> DisplayImage {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.lights()
                canvas.noStroke()
                canvas.fill(white)
                canvas.translate(48, 48, 0)
                canvas.beginShape(quads ? .quads : .triangles)
                for corner in Self.warpedCorners { canvas.vertex(corner.x, corner.y, corner.z) }
                if !quads { for number in [0, 1, 2, 0, 2, 3] { canvas.index(number) } }
                canvas.endShape()
            }
            return try pixels(of: canvas)
        }
        #expect(try differingPixels(render(quads: true), render(quads: false)) == 0)
    }

    @Test("四角の 4 隅すべてに、面の向きが付く")
    func quadsDeriveNormalsAtAllFourCorners() throws {
        // 手前を向く平らな四角を、面の向きを書かずに描く。2 枚が共有する 0 番と 2 番の隅は、
        // 2 枚目の巻きが逆だと外積が打ち消し合って向きが 0 になる (`placedVertices`)。
        // 向きの無い頂点は光を受けず色そのままで出る (立体の線と点と同じ) ので、暗くは落ちない —
        // 光を面の向きから傾けておけば、対角線 (0 番と 2 番の間) だけが周りと違う明るさで出る
        let canvas = try makeCanvas()
        var normals: [SIMD4<Float>] = []
        try canvas.draw {
            canvas.background(black)
            canvas.directionalLight(white, 0, 0.8, -0.6)
            canvas.fill(white)
            canvas.noStroke()
            canvas.push()
            canvas.translate(48, 48, 0)
            canvas.beginShape(.quads)
            canvas.vertex(-30, -30, 0)
            canvas.vertex(30, -30, 0)
            canvas.vertex(30, 30, 0)
            canvas.vertex(-30, 30, 0)
            canvas.endShape()
            canvas.pop()
            normals = canvas.solidVertices.map(\.normal)
        }

        // 2 枚ぶんの 6 頂点のすべてに、形から求めた向きが付いている
        #expect(normals.count == 6)
        for normal in normals {
            #expect(normal.w == 1 && abs(normal.z - 1) < 1e-5, "向きが付いていない: \(normal)")
        }
        let image = try pixels(of: canvas)
        let onDiagonal = Int(image[48, 48].red)
        let beside = Int(image[60, 36].red)
        #expect(onDiagonal < 250, "傾けた光を受けていない (\(onDiagonal))")
        #expect(abs(onDiagonal - beside) <= 6, "対角線の上だけ明るさが違う (\(onDiagonal) と \(beside))")
    }

    @Test("立体の凹んだ四角と交差した四角は、同じ 4 点を周として塗った形と同じ絵になる")
    func solidConcaveAndCrossedQuadsMatchThePolygon() throws {
        // 平面の検査 (`QuadFillTests`) と同じ約束を、外周の平面へ落とす立体の経路で見る。
        // 1 隅だけ奥行きをずらして、平らでない 4 点にする
        let arrowhead: [SIMD3<Float>] = [
            SIMD3(-30, -30, 0), SIMD3(30, 0, 6), SIMD3(-30, 30, 0), SIMD3(-8, 0, 3),
        ]
        let hourglass: [SIMD3<Float>] = [
            SIMD3(-30, -30, 0), SIMD3(30, -30, 6), SIMD3(-30, 30, 0), SIMD3(30, 30, 6),
        ]
        func render(_ points: [SIMD3<Float>], _ kind: VertexKind) throws -> DisplayImage {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.lights()
                canvas.noStroke()
                canvas.translate(48, 48, 0)
                canvas.beginShape(kind)
                for (index, point) in points.enumerated() {
                    canvas.fill(index.isMultiple(of: 2) ? white : red)
                    canvas.vertex(point.x, point.y, point.z)
                }
                canvas.endShape(.close)
            }
            return try pixels(of: canvas)
        }
        for points in [arrowhead, hourglass] {
            let byQuads = try render(points, .quads)
            #expect(try differingPixels(byQuads, render(points, .polygon)) == 0)
            #expect(byQuads.bytes.contains { $0 != 0 && $0 != 255 }, "空の画像だけを比較しない")
        }
    }

    @Test("立体の四角の線は 4 辺だけで、面と同じように奥行きで前後する")
    func solidQuadsOutlineFollowsDepthAndHasNoDiagonal() throws {
        func render(hidden: Bool) throws -> DisplayImage {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                if hidden {
                    // 手前に赤い面。線は奥に回る
                    canvas.noStroke()
                    canvas.fill(red)
                    canvas.beginShape()
                    canvas.vertex(8, 8, 30)
                    canvas.vertex(88, 8, 30)
                    canvas.vertex(88, 88, 30)
                    canvas.vertex(8, 88, 30)
                    canvas.endShape(.close)
                }
                canvas.fill(white)
                canvas.stroke(blue)
                canvas.strokeWeight(6)
                canvas.beginShape(.quads)
                canvas.vertex(24, 24, 0)
                canvas.vertex(72, 24, 0)
                canvas.vertex(72, 72, 0)
                canvas.vertex(24, 72, 0)
                canvas.endShape()
            }
            return try pixels(of: canvas)
        }
        let visible = try render(hidden: false)
        #expect(visible[48, 24].blue > 200 && visible[48, 24].red < 60, "辺の上が線の色でない")
        #expect(visible[36, 36].red > 200, "対角線の上に線が引かれている")
        #expect(visible[48, 48].red > 200, "対角線の上に線が引かれている")
        let hidden = try render(hidden: true)
        #expect(hidden[48, 24].red > 200 && hidden[48, 24].blue < 60, "手前の面に隠れない")
    }

    @Test("番号で指した四角の列は、同じ格子を三角形の列で張った絵と一致し、点も共有される")
    func indexedQuadsMatchTheTriangleGrid() throws {
        // 格子の 9 枚の四角は、`gridTriangles` の 18 枚 (どれも対角線 0–2) と同じ張り方
        func render(quads: Bool) throws -> (DisplayImage, Int) {
            let canvas = try makeCanvas()
            var count = 0
            try canvas.draw {
                canvas.background(black)
                canvas.lights()
                if quads { quadGrid(on: canvas) } else { grid(on: canvas, indexed: true) }
                count = canvas.solidVertices.count
            }
            return (try pixels(of: canvas), count)
        }
        let (quadPicture, quadCount) = try render(quads: true)
        let (trianglePicture, triangleCount) = try render(quads: false)
        #expect(differingPixels(quadPicture, trianglePicture) == 0)
        #expect(quadCount == triangleCount)
        #expect(quadCount == Self.gridPoints.count)
    }

    @Test("番号で指した四角の列は、保持して置いても同じ絵になる")
    func indexedQuadsRetainedMatchImmediate() throws {
        let immediate = try makeCanvas()
        try immediate.draw {
            immediate.background(black)
            immediate.lights()
            quadGrid(on: immediate)
        }
        let retained = try makeCanvas()
        try retained.draw {
            retained.background(black)
            retained.lights()
            let held = retained.createShape { quadGrid(on: retained) }
            retained.shape(held)
        }
        let picture = try pixels(of: immediate)
        #expect(try differingPixels(picture, pixels(of: retained)) == 0)
        #expect(picture.bytes.contains { $0 != 0 && $0 != 255 }, "空の画像だけを比較しない")
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

    /// `grid(on:indexed:)` と同じ点を、四角の列として番号で指して張る。
    private func quadGrid(on canvas: Canvas) {
        canvas.noStroke()
        canvas.fill(red)
        canvas.beginShape(.quads)
        for point in Self.gridPoints {
            let normal = gridNormal(point)
            canvas.normal(normal.x, normal.y, normal.z)
            canvas.vertex(point.x, point.y, point.z)
        }
        for row in 0..<(Self.gridSide - 1) {
            for column in 0..<(Self.gridSide - 1) {
                let corner = row * Self.gridSide + column
                for number in [corner, corner + 1, corner + Self.gridSide + 1, corner + Self.gridSide] {
                    canvas.index(number)
                }
            }
        }
        canvas.endShape()
    }

    /// 細い三角形を `triangles` 枚並べる。
    ///
    /// **`chunk` 枚ごとに `beginShape` を切り直す** — 描かれる三角形は塊の大きさに
    /// よらず同じで、変わるのは「1 度に渡す量」だけである。連続した `endShape` は
    /// 同じ列へ積まれるので、絵も描く回数も動かない。
    private func stripes(on canvas: Canvas, triangles: Int, chunk: Int) {
        var placed = 0
        while placed < triangles {
            let count = min(chunk, triangles - placed)
            canvas.beginShape(.triangles)
            canvas.normal(0, 0, 1)
            for step in placed..<(placed + count) {
                let x = 8 + Float(step % 40) * 2
                let y = 8 + Float(step / 40) * 6
                canvas.vertex(x, y, 0)
                canvas.vertex(x + 1.6, y, 0)
                canvas.vertex(x + 0.8, y + 5, 0)
            }
            canvas.endShape()
            placed += count
        }
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
