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
        let gpu = try RenderDevice()
        return try Canvas(target: try RenderTarget(gpu: gpu, width: width, height: height), gpu: gpu)
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
            canvas.vertex(.nan, 10, 0)
            canvas.vertex(10, .infinity, 0)
            canvas.vertex(20, 20, .nan)
            canvas.vertex(30, 30, 10)
            canvas.endShape(.close)

            // 始めていないのに閉じる
            canvas.endShape(.close)
        }

        #expect(try pixels(of: canvas).width == 96)
    }

    // MARK: - 道具

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
