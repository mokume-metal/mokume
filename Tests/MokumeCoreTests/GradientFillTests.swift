// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 描く状態の塗りに勾配を渡す口 (`fill(_: Gradient)`・#2433)。GPU を要する。
///
/// 見るのは、完了条件の画素の例 (混ぜる空間・区切りの規則・放射)、描く状態との 3 つの関係
/// (`pushStyle()` の積み降ろし・`createShape { }` への焼き付き・`shader()` が勝つ)、効くのは塗りだけで
/// 線と値型の色は変わらないこと、`Placement.fill` が勾配に掛かること。画素は描く面の**線形の値**で読む。
@Suite(
    "勾配で塗る (fill(_: Gradient))",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct GradientFillTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)

    private func makeCanvas(width: Int = 100, height: Int = 20) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// 黒地に `body` を描き、描く面の線形の値を読む。
    private func pixels(
        _ canvas: Canvas, _ body: (Canvas) throws -> Void
    ) throws -> PixelBuffer {
        var failure: (any Error)?
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            do { try body(canvas) } catch { failure = error }
        }
        if let failure { throw failure }
        return try canvas.target.readPixels()
    }

    /// 勾配の位置 `t` の画素 (横に 100 の勾配の x 番目) が持つ線形の赤。画素の中心は x + 0.5。
    private func position(of x: Int) -> Float { (Float(x) + 0.5) / 100 }

    /// **完了条件 1: 黒から白への勾配は、線形の光の量で混ざる** (`lerpColor` と同じ空間)。
    ///
    /// x = 50 の画素の位置は 0.505 で、線形の赤はそのまま 0.505、符号化した表示は約 188 (符号化した値で
    /// 混ぜる手本は 128 付近)。混ぜる空間を符号化した値に差し替えると赤になる。
    @Test("黒から白への線形の勾配は、線形の光の量で混ざる")
    func linearGradientMixesLinearLight() throws {
        let canvas = try makeCanvas()
        let pixels = try pixels(canvas) { c in
            c.fill(.linearGradient((black, 0), (white, 1), from: [0, 0], to: [100, 0]))
            c.rect(0, 0, 100, 10)
        }
        #expect(abs(pixels[0, 5].red - position(of: 0)) < 0.01)
        #expect(abs(pixels[99, 5].red - position(of: 99)) < 0.01)
        #expect(abs(pixels[50, 5].red - 0.505) < 0.01, "x = 50: \(pixels[50, 5].red)")
        for x in [10, 30, 70, 90] {
            #expect(abs(pixels[x, 5].red - position(of: x)) < 0.01, "x = \(x): \(pixels[x, 5].red)")
        }
        // 勾配は縦には変わらない。矩形の外は黒のまま
        #expect(abs(pixels[50, 0].red - pixels[50, 9].red) < 0.002)
        #expect(pixels[50, 15].red == 0)
        let display = try canvas.target.encodeForDisplay()
        let shown = Float(display[50, 5].red)
        #expect(abs(shown - 188) <= 3, "表示の赤: \(shown)")
    }

    /// 完了条件 2: 区切りが 3 つ (黒・白・黒) なら、位置 0.5 の所だけが白い。
    @Test("3 つの区切りの勾配は、区切りの位置で折れる")
    func threeStopsBendAtTheStop() throws {
        let canvas = try makeCanvas()
        let pixels = try pixels(canvas) { c in
            c.fill(.linearGradient((black, 0), (white, 0.5), (black, 1), from: [0, 0], to: [100, 0]))
            c.rect(0, 0, 100, 10)
        }
        for x in [0, 10, 25, 49, 50, 75, 90, 99] {
            let t = position(of: x)
            let expected = 1 - abs(2 * t - 1)
            #expect(abs(pixels[x, 5].red - expected) < 0.02, "x = \(x): \(pixels[x, 5].red) (期待 \(expected))")
        }
    }

    /// 区切りの規則: 並べ直す・端の外は端の色・同じ位置は書いた順 (後の色へ折れる)。
    @Test("区切りは位置の小さい順に使い、端の外は端の色のまま伸びる")
    func stopsAreSortedAndClamped() throws {
        let canvas = try makeCanvas()
        // 並びを逆に書き、位置は 0.25…0.75 だけに置く
        let pixels = try pixels(canvas) { c in
            c.fill(.linearGradient((white, 0.75), (black, 0.25), from: [0, 0], to: [100, 0]))
            c.rect(0, 0, 100, 10)
        }
        #expect(pixels[5, 5].red < 0.002, "0.25 より手前は最初の色 (黒)")
        #expect(pixels[95, 5].red > 0.998, "0.75 より先は最後の色 (白)")
        #expect(abs(pixels[50, 5].red - 0.51) < 0.02, "中ほどは混ざる: \(pixels[50, 5].red)")
        // 同じ位置の 2 つは書いた順に並び、その位置で色が切り替わる
        let stepped = try self.pixels(canvas) { c in
            c.fill(.linearGradient((black, 0.5), (white, 0.5), from: [0, 0], to: [100, 0]))
            c.rect(0, 0, 100, 10)
        }
        #expect(stepped[40, 5].red < 0.002)
        #expect(stepped[60, 5].red > 0.998)
    }

    /// 完了条件 3: 放射の勾配で塗った円は、中心が 1 つ目の色、縁の内側が最後の色になる。
    @Test("放射の勾配で塗った円は、中心が最初の色・縁の内側が最後の色")
    func radialGradientRunsFromCenterToEdge() throws {
        let canvas = try makeCanvas(width: 100, height: 100)
        let pixels = try pixels(canvas) { c in
            c.fill(.radialGradient((red, 0), (blue, 1), center: [50, 50], radius: 40))
            c.circle(50, 50, 80)
        }
        let center = pixels[50, 50]
        #expect(center.red > 0.95 && center.blue < 0.05, "中心 \(center)")
        let edge = pixels[50 + 38, 50]
        #expect(edge.blue > 0.9 && edge.red < 0.1, "縁の内側 \(edge)")
        // 途中は距離に比例して混ざる (x = 70 は中心から 20.5 = 位置 0.5125)
        let middle = pixels[70, 50]
        #expect(abs(middle.blue - 0.5125) < 0.03, "中ほど \(middle)")
        // 円の外は黒のまま
        #expect(pixels[2, 2].red == 0 && pixels[2, 2].blue == 0)
    }

    /// 区切りを配列で組み立てて渡す形は、`(色, 位置)` を並べる形と同じ勾配になる。並べる形は
    /// Swift 6.3 でも整数の位置を受けて組める (配列を括弧の中へ直に書く形は 6.3 が断る)。
    @Test("区切りを配列で渡す形は、並べて渡す形と同じ勾配になる")
    func arrayFormMatchesTheListedForm() throws {
        let stops: [(LinearRGBA, Float)] = [(black, 0), (white, 0.25), (red, 1)]
        let listed = try pixels(try makeCanvas()) { c in
            c.fill(.linearGradient((black, 0), (white, 0.25), (red, 1), from: [0, 0], to: [100, 0]))
            c.rect(0, 0, 100, 10)
        }
        let array = try pixels(try makeCanvas()) { c in
            c.fill(.linearGradient(stops, from: [0, 0], to: [100, 0]))
            c.rect(0, 0, 100, 10)
        }
        for x in [0, 10, 25, 60, 99] {
            #expect(listed[x, 5] == array[x, 5], "x = \(x): \(listed[x, 5]) と \(array[x, 5])")
        }
        #expect(listed[10, 5] != listed[60, 5], "勾配が掛かっている")
        let radialListed = try pixels(try makeCanvas(width: 100, height: 100)) { c in
            c.fill(.radialGradient((red, 0), (blue, 1), center: [50, 50], radius: 40))
            c.circle(50, 50, 80)
        }
        let radialArray = try pixels(try makeCanvas(width: 100, height: 100)) { c in
            c.fill(.radialGradient([(red, 0), (blue, 1)] as [(LinearRGBA, Float)], center: [50, 50], radius: 40))
            c.circle(50, 50, 80)
        }
        for x in [50, 60, 70, 88] {
            #expect(radialListed[x, 50] == radialArray[x, 50], "x = \(x)")
        }
    }

    /// 完了条件 3: 字も同じ勾配で塗れる。左の字と右の字は、勾配の色が違う。
    @Test("字にも勾配が効き、勾配の座標で色が変わる")
    func textTakesTheGradient() throws {
        let canvas = try makeCanvas(width: 200, height: 60)
        let pixels = try pixels(canvas) { c in
            c.fill(.linearGradient((red, 0), (blue, 1), from: [0, 0], to: [200, 0]))
            c.textSize(48)
            c.text("MMMM", 8, 48)
        }
        func tint(_ columns: Range<Int>) -> (red: Float, blue: Float) {
            var total: (Float, Float) = (0, 0)
            for y in 0..<60 {
                for x in columns {
                    total.0 += pixels[x, y].red
                    total.1 += pixels[x, y].blue
                }
            }
            return total
        }
        let left = tint(0..<70)
        let right = tint(130..<200)
        #expect(left.red > 3 * left.blue, "左の字は赤が強い: \(left)")
        #expect(right.blue > 2 * right.red, "右の字は青が強い: \(right)")
    }

    /// 完了条件 3: `textOutline` の周を `beginShape` で塗っても、同じ勾配が形を描く座標で効く。
    @Test("textOutline の周を塗っても、勾配が形を描く座標で効く")
    func textOutlineContoursTakeTheGradient() throws {
        let canvas = try makeCanvas(width: 200, height: 60)
        let pixels = try pixels(canvas) { c in
            c.fill(.linearGradient((red, 0), (blue, 1), from: [0, 0], to: [200, 0]))
            c.textSize(48)
            for contour in c.textOutline("MMMM", 8, 48) where !contour.isHole {
                c.beginShape()
                for point in contour.points { c.vertex(point.x, point.y) }
                c.endShape(.close)
            }
        }
        var left: (Float, Float) = (0, 0)
        var right: (Float, Float) = (0, 0)
        for y in 0..<60 {
            for x in 0..<70 { left.0 += pixels[x, y].red; left.1 += pixels[x, y].blue }
            for x in 130..<200 { right.0 += pixels[x, y].red; right.1 += pixels[x, y].blue }
        }
        #expect(left.0 > 3 * left.1, "左の字は赤が強い: \(left)")
        #expect(right.1 > 2 * right.0, "右の字は青が強い: \(right)")
    }

    /// 完了条件 4: `pushStyle()` / `popStyle()` で勾配が積み降ろされる。
    @Test("pushStyle と popStyle で勾配が積み降ろされる")
    func gradientFollowsPushAndPopStyle() throws {
        let canvas = try makeCanvas()
        let pixels = try pixels(canvas) { c in
            c.fill(red)
            c.pushStyle()
            c.fill(.linearGradient((black, 0), (white, 1), from: [0, 0], to: [100, 0]))
            c.rect(0, 0, 100, 5)
            c.popStyle()
            c.rect(0, 10, 100, 5)
        }
        #expect(pixels[10, 2].green > 0.05, "積んだ中は勾配: \(pixels[10, 2])")
        #expect(pixels[10, 12] == red.sameLinear, "戻した後は前の色: \(pixels[10, 12])")
        #expect(pixels[90, 12] == red.sameLinear)
        // 勾配を持ったまま積み、その中で色に替えて戻すと、勾配へ戻る
        let canvas2 = try makeCanvas()
        let pixels2 = try self.pixels(canvas2) { c in
            c.fill(.linearGradient((black, 0), (white, 1), from: [0, 0], to: [100, 0]))
            c.pushStyle()
            c.fill(blue)
            c.rect(0, 0, 100, 5)
            c.popStyle()
            c.rect(0, 10, 100, 5)
        }
        #expect(pixels2[10, 2] == blue.sameLinear, "積んだ中は色: \(pixels2[10, 2])")
        #expect(abs(pixels2[90, 12].red - position(of: 90)) < 0.01, "戻すと勾配: \(pixels2[90, 12])")
    }

    /// 完了条件 4: `createShape { }` の中で塗った勾配は形に焼き付き、置き場所で回すと勾配も一緒に回る。
    @Test("createShape の中の勾配は形に焼き付き、置き場所で回すと一緒に回る")
    func gradientBakesIntoShapesAndRotatesWithThem() throws {
        let canvas = try makeCanvas(width: 100, height: 100)
        let pixels = try pixels(canvas) { c in
            // 形自身の座標で、横に黒から白へ変わる帯 (幅 60・高さ 20)
            let strip = c.createShape {
                c.fill(.linearGradient((black, 0), (white, 1), from: [0, 0], to: [60, 0]))
                c.rect(0, 0, 60, 20)
            }
            // 左は回さずに置く。右は 90° 回して置くので、勾配は縦に変わる
            c.shape(strip, at: [Placement(x: 5, y: 5)])
            c.shape(strip, at: [Placement(x: 90, y: 20, rotation: Vector3(0, 0, Float.pi / 2))])
        }
        // 回さない帯: 左から右へ明るくなる (x = 5…65・y = 5…25)
        #expect(pixels[10, 15].red < pixels[60, 15].red - 0.5, "回さない帯: \(pixels[10, 15].red) → \(pixels[60, 15].red)")
        // 回した帯: 上から下へ明るくなる。90° 回すので、形の x が下向きになる (x = 70…90・y = 20…80)
        #expect(pixels[80, 25].red < pixels[80, 75].red - 0.5, "回した帯: \(pixels[80, 25].red) → \(pixels[80, 75].red)")
        // 横には変わらない
        #expect(abs(pixels[72, 50].red - pixels[88, 50].red) < 0.02, "回した帯の横: \(pixels[72, 50].red), \(pixels[88, 50].red)")
    }

    /// 形の組み立ての外で決めた勾配は、組み立ての中では形自身の座標で読み直す。
    @Test("組み立ての外で決めた勾配は、形自身の座標で読み直す")
    func gradientSetOutsideIsReadInTheShapesOwnCoordinates() throws {
        let canvas = try makeCanvas(width: 100, height: 20)
        let pixels = try pixels(canvas) { c in
            // 外で平行移動してから勾配を決める。形の組み立ての中は変換が単位から始まるので、
            // 勾配の座標 (0…50) は形自身の座標 (0…50) として読む
            c.translate(50, 0)
            c.fill(.linearGradient((black, 0), (white, 1), from: [0, 0], to: [50, 0]))
            let strip = c.createShape { c.rect(0, 0, 50, 10) }
            c.resetMatrix()
            c.shape(strip)
        }
        #expect(abs(pixels[45, 5].red - 0.905) < 0.02, "形自身の座標で読む: \(pixels[45, 5].red)")
        #expect(pixels[5, 5].red < 0.15)
    }

    /// 同じ形を続けて置くと畳まれる (雛形 + 置き場所)。畳まれた置き場所も勾配で塗る。
    @Test("畳まれる同じ形も、勾配で塗る")
    func foldedShapesTakeTheGradient() throws {
        let canvas = try makeCanvas(width: 100, height: 20)
        let pixels = try pixels(canvas) { c in
            c.fill(.linearGradient((black, 0), (white, 1), from: [0, 0], to: [100, 0]))
            // 同じ大きさの矩形を 3 つ。2 つ目から畳まれる
            c.rect(0, 0, 30, 10)
            c.rect(35, 0, 30, 10)
            c.rect(70, 0, 30, 10)
        }
        for x in [10, 50, 90] {
            #expect(abs(pixels[x, 5].red - position(of: x)) < 0.01, "x = \(x): \(pixels[x, 5].red)")
        }
    }

    /// 焼き付いた勾配は、置く側の状態に左右されない: 置く側が別の勾配や色を持っていても、形の勾配で塗る。
    @Test("焼き付いた勾配は、置く側の塗りに左右されない")
    func bakedGradientIgnoresTheLiveFill() throws {
        let canvas = try makeCanvas(width: 100, height: 20)
        let pixels = try pixels(canvas) { c in
            let strip = c.createShape {
                c.fill(.linearGradient((black, 0), (white, 1), from: [0, 0], to: [100, 0]))
                c.rect(0, 0, 100, 10)
            }
            c.fill(blue)
            c.shape(strip)
        }
        #expect(abs(pixels[90, 5].red - position(of: 90)) < 0.01)
        #expect(pixels[90, 5].blue < 0.95 * pixels[90, 5].red + 0.05, "置く側の青は混ざらない: \(pixels[90, 5])")
    }

    /// 置く前の勾配は、組み込みの塗りで記録した形 (読んだ SVG と、色を塗って組み立てた形) に効かず、
    /// 記録した色で出る (#3008・#788)。`ShapeTests.anAmbientFragmentDoesNotReachARetainedShape` の勾配版。
    ///
    /// 読んだ SVG は矩形・円 (距離関数の区間) と三角形の path (三角形の区間) の両方を含む。勾配は
    /// 赤から青へ x に沿って変わるので、勾配が効く実装なら白にならない (矩形の中ほどは紫がかった赤)。
    /// 置いた後の同じ状態の `rect` は勾配で塗る (形を置いても状態は使い切られない)。
    @Test("置く前の勾配は、読んだ SVG と色を塗って記録した形に効かず、記録した色で出る")
    func ambientGradientDoesNotReachARetainedShape() throws {
        let canvas = try makeCanvas(width: 100, height: 140)
        // 白の矩形 (0…50 × 0…50)・円 (中心 (65, 15)・半径 15)・三角形 ((0, 60)・(80, 60)・(40, 100))
        let source = """
            <svg xmlns="http://www.w3.org/2000/svg" width="80" height="100">
              <rect x="0" y="0" width="50" height="50" fill="white"/>
              <circle cx="65" cy="15" r="15" fill="white"/>
              <path d="M0 60 L80 60 L40 100 Z" fill="white"/>
            </svg>
            """
        let drawing = try SVGFile.parse(source, path: "mark.svg")
        let mark = canvas.shape(of: drawing, readFrom: "mark.svg")
        let square = canvas.createShape {
            canvas.noStroke()
            canvas.fill(red)
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(30, 0)
            canvas.vertex(30, 30)
            canvas.vertex(0, 30)
            canvas.endShape(.close)
        }
        let pixels = try pixels(canvas) { c in
            c.fill(.linearGradient((red, 0), (blue, 1), from: [0, 0], to: [80, 0]))
            c.shape(mark)
            c.shape(square, at: [Placement(x: 5, y: 105)])
            c.rect(60, 105, 30, 30)
        }
        func isWhite(_ pixel: LinearRGBA, _ what: String) {
            #expect(
                pixel.red > 0.98 && pixel.green > 0.98 && pixel.blue > 0.98,
                "\(what) は記録した白のまま: \(pixel)")
        }
        isWhite(pixels[25, 25], "矩形の中ほど")
        isWhite(pixels[65, 15], "円の中心")
        isWhite(pixels[40, 70], "三角形の中")
        let recorded = pixels[20, 120]
        #expect(
            recorded.red > 0.98 && recorded.green < 0.02 && recorded.blue < 0.02,
            "色を塗って記録した四角は赤のまま: \(recorded)")
        let live = pixels[75, 120]
        #expect(live.blue > 0.8 && live.red < 0.2, "置いた後の rect は勾配で塗る: \(live)")
    }

    /// 完了条件 4: `shader()` を付けたら利用者の断片が勝ち、勾配は効かない。外すと勾配で塗る。
    @Test("shader() を付けると利用者の断片が勝ち、外すと勾配で塗る")
    func userShaderBeatsTheGradient() throws {
        let canvas = try makeCanvas()
        let flat = try canvas.makeShader("float4 paint(Fragment in, Values values) { return float4(0, 0, 1, 1); }")
        let pixels = try pixels(canvas) { c in
            c.fill(.linearGradient((black, 0), (white, 1), from: [0, 0], to: [100, 0]))
            c.shader(flat)
            c.rect(0, 0, 100, 5)
            c.resetShader()
            c.rect(0, 10, 100, 5)
        }
        #expect(pixels[50, 2] == blue.sameLinear, "断片が勝つ: \(pixels[50, 2])")
        #expect(abs(pixels[90, 12].red - position(of: 90)) < 0.01, "外すと勾配: \(pixels[90, 12])")
        // 断片を付けた後で勾配を渡しても、断片が勝つ
        let canvas2 = try makeCanvas()
        let flat2 = try canvas2.makeShader("float4 paint(Fragment in, Values values) { return float4(0, 0, 1, 1); }")
        let pixels2 = try self.pixels(canvas2) { c in
            c.shader(flat2)
            c.fill(.linearGradient((black, 0), (white, 1), from: [0, 0], to: [100, 0]))
            c.rect(0, 0, 100, 5)
        }
        #expect(pixels2[50, 2] == blue.sameLinear, "後から渡しても断片が勝つ: \(pixels2[50, 2])")
    }

    /// 完了条件 5: 勾配が受け持つのは塗りだけ。線の色は変わらない。
    @Test("線 (stroke) は勾配にならず、色のまま")
    func strokeKeepsItsColour() throws {
        let canvas = try makeCanvas(width: 100, height: 100)
        let pixels = try pixels(canvas) { c in
            c.fill(.linearGradient((black, 0), (white, 1), from: [0, 0], to: [100, 0]))
            c.stroke(red)
            c.strokeWeight(6)
            c.rect(20, 20, 60, 60)
        }
        // 輪郭の帯の中 (左辺の x = 20 の中心・右辺の x = 80 の中心) は赤
        let left = pixels[20, 50]
        let right = pixels[80, 50]
        #expect(left.red > 0.95 && left.green < 0.02, "左の辺: \(left)")
        #expect(right.red > 0.95 && right.green < 0.02, "右の辺: \(right)")
        // 内側は勾配 (x = 50 は 0.505)
        #expect(abs(pixels[50, 50].green - 0.505) < 0.02, "内側: \(pixels[50, 50])")
    }

    /// `body` を `draw()` として 1 フレーム描くスケッチ (値型の `draw()` は走っているスケッチの面へ描く)。
    final class Scene: Sketch {
        var settings = SketchSettings(width: 160, height: 90)
        var body: (Scene) -> Void = { _ in }

        init() {}

        convenience init(_ body: @escaping (Scene) -> Void) {
            self.init()
            self.body = body
        }

        func draw() {
            background(0)
            noStroke()
            body(self)
        }
    }

    /// 完了条件 5: 値型の `fill` が `nil` なら、いまの状態の勾配で塗る。色を持てば、その色が勝つ。
    @Test("値型の fill が nil なら状態の勾配で塗り、色を持てばその色で塗る")
    func valueTypesFollowTheStateGradient() throws {
        let runtime = try SketchRuntime(
            sketch: Scene { s in
                s.fill(
                    .linearGradient(
                        (LinearRGBA.linear(red: 0, green: 0, blue: 0), 0), (LinearRGBA.linear(red: 1, green: 1, blue: 1), 1),
                        from: [0, 0], to: [160, 0]))
                Rect(left: 0, top: 0, width: 160, height: 20).draw()
                var colored = Rect(left: 0, top: 30, width: 160, height: 20)
                colored.fill = LinearRGBA.linear(red: 0, green: 0, blue: 1)
                colored.draw()
                // 値を描いた後も、状態の勾配は残る
                s.rect(0, 60, 160, 20)
            },
            gpu: try RenderDevice())
        try runtime.advance()
        let image = try runtime.canvas.target.encodeForDisplay()
        // 勾配: 左は暗く、右は明るい。値を描いた前 (上の帯) も後 (下の帯) も同じ
        for y in [10, 70] {
            #expect(image[5, y].red < 70 && image[155, y].red > 230, "y = \(y): \(image[5, y].red) → \(image[155, y].red)")
            #expect(abs(Int(image[100, y].green) - Int(image[100, y].red)) <= 1)
        }
        // 色を持つ値は、その色 (青) で塗る
        #expect(image[100, 40].blue == 255 && image[100, 40].red == 0 && image[100, 40].green == 0)
    }

    /// 完了条件 6: `Placement.fill` は勾配に掛かる (範囲の外を名乗る条件。掛けると決めた)。
    @Test("Placement.fill は勾配に掛かる")
    func placementFillMultipliesTheGradient() throws {
        let canvas = try makeCanvas(width: 100, height: 20)
        let pixels = try pixels(canvas) { c in
            let strip = c.createShape {
                c.fill(.linearGradient((white, 0), (white, 1), from: [0, 0], to: [100, 0]))
                c.rect(0, 0, 100, 10)
            }
            c.shape(strip, at: [Placement(fill: red)])
        }
        let sample = pixels[50, 5]
        #expect(sample.red > 0.95 && sample.green < 0.02 && sample.blue < 0.02, "赤を掛ける: \(sample)")
    }

    /// 勾配の区切りが 1 つなら単色。受けられない勾配は、塗りを前のまま残す。
    @Test("受けられない勾配は塗りを前のまま残す")
    func refusedGradientsLeaveTheFill() throws {
        let canvas = try makeCanvas()
        let pixels = try pixels(canvas) { c in
            c.fill(red)
            // 区切りが無い・2 点が同じ・半径が 0・数でない位置
            c.fill(.linearGradient(from: [0, 0], to: [100, 0]))
            c.fill(Gradient.linearGradient([], from: [0, 0], to: [100, 0]))
            c.fill(.linearGradient((black, 0), (white, 1), from: [5, 5], to: [5, 5]))
            c.fill(.radialGradient((black, 0), (white, 1), center: [5, 5], radius: 0))
            c.fill(.linearGradient((black, .nan), (white, 1), from: [0, 0], to: [100, 0]))
            c.rect(0, 0, 100, 5)
            // 区切りが 1 つなら、その色の単色
            c.fill(.linearGradient((blue, 0.5), from: [0, 0], to: [100, 0]))
            c.rect(0, 10, 100, 5)
        }
        #expect(pixels[50, 2] == red.sameLinear, "前のまま: \(pixels[50, 2])")
        #expect(pixels[5, 12] == blue.sameLinear && pixels[95, 12] == blue.sameLinear, "区切り 1 つは単色")
    }

    /// 区切りが上限を越えたら、位置の小さい順に上限まで使う。
    @Test("区切りが 10 を越えたら、位置の小さい順に 10 個を使う")
    func extraStopsAreDropped() throws {
        let canvas = try makeCanvas()
        // 位置 0…0.9 は黒、1.0 だけ白 (11 個目)
        var stops: [(LinearRGBA, Float)] = (0..<10).map { (black, Float($0) / 10) }
        stops.append((white, 1))
        let pixels = try pixels(canvas) { c in
            c.fill(.linearGradient(stops, from: [0, 0], to: [100, 0]))
            c.rect(0, 0, 100, 5)
        }
        #expect(pixels[95, 2].red < 0.002, "11 個目 (白) は使わない: \(pixels[95, 2].red)")
    }

    /// 勾配は `fill(_:)` を呼んだときの変換で読む: 呼んだ後に変換を変えても動かない。
    @Test("勾配は fill を呼んだときの座標系で読み、呼んだ後の変換では動かない")
    func gradientReadsTheCoordinatesAtTheCall() throws {
        let canvas = try makeCanvas(width: 100, height: 40)
        let pixels = try pixels(canvas) { c in
            // 平行移動の後で呼ぶと、勾配の座標にも掛かる (0…50 が画面の 50…100 になる)
            c.pushMatrix()
            c.translate(50, 0)
            c.fill(.linearGradient((black, 0), (white, 1), from: [0, 0], to: [50, 0]))
            c.rect(0, 0, 50, 10)
            c.popMatrix()
            // 呼んだ後で平行移動しても、勾配は動かない (画面の 0…100)
            c.fill(.linearGradient((black, 0), (white, 1), from: [0, 0], to: [100, 0]))
            c.translate(50, 0)
            c.rect(0, 20, 50, 10)
        }
        #expect(abs(pixels[50, 5].red - 0.01) < 0.02, "平行移動の後で呼ぶ: \(pixels[50, 5].red)")
        #expect(abs(pixels[99, 5].red - 0.99) < 0.02)
        #expect(abs(pixels[50, 25].red - 0.505) < 0.02, "呼んだ後の平行移動では動かない: \(pixels[50, 25].red)")
        #expect(abs(pixels[99, 25].red - 0.995) < 0.02)
    }

    /// 勾配は塗らない設定を覚えている: `noFill()` で塗らなくなり、`fill(_:)` で戻る。
    @Test("noFill は勾配を外さず、塗らなくするだけ")
    func noFillKeepsTheGradient() throws {
        let canvas = try makeCanvas()
        let pixels = try pixels(canvas) { c in
            c.fill(.linearGradient((black, 0), (white, 1), from: [0, 0], to: [100, 0]))
            c.noFill()
            c.rect(0, 0, 100, 5)
            c.fill(.linearGradient((black, 0), (white, 1), from: [0, 0], to: [100, 0]))
            c.rect(0, 10, 100, 5)
        }
        #expect(pixels[90, 2].red == 0, "塗らない")
        #expect(abs(pixels[90, 12].red - position(of: 90)) < 0.01)
    }
}

extension LinearRGBA {
    /// 描いた画素と比べるための、半精度の丸めを通した値。
    fileprivate var sameLinear: LinearRGBA {
        LinearRGBA(
            premultipliedRed: Float(Float16(red)), green: Float(Float16(green)),
            blue: Float(Float16(blue)), alpha: Float(Float16(alpha)))
    }
}
