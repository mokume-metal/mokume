// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 描いた画面と描き場所を新しい `Image` にして返す `get()`・`get(_:_:_:_:)`・`get(in:)` ([#3714])。
///
/// 領域も返す絵の大きさも座標の単位で数える (1 画素の `get(_:_:)` は実際の画素で数える)。範囲の外は
/// 透明、1 を割る領域は `createImage` と同じく投げる。
///
/// [#3714]: https://github.com/mokume-metal/mokume/issues/3714
@Suite(
    "画面を絵にして返す get",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ScreenGetTests {
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)

    /// 400 x 300 の画面。`outputScale` は書き出しの倍率 (`mokume render --scale`)、`density` は細かさ。
    private func makeCanvas(outputScale: Int = 1, density: Float = 1) throws -> Canvas {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 400 * outputScale, height: 300 * outputScale)
        return try Canvas(
            output: output, gpu: gpu, pixelDensity: density, upscale: .spatial,
            outputScale: outputScale)
    }

    private func same(_ a: LinearRGBA, _ b: LinearRGBA, within tolerance: Float = 0) -> Bool {
        abs(a.red - b.red) <= tolerance && abs(a.green - b.green) <= tolerance
            && abs(a.blue - b.blue) <= tolerance && abs(a.alpha - b.alpha) <= tolerance
    }

    /// 黒い下地の左上 100 x 100 に赤い四角 (完了条件 1・2 の絵)。
    private func paintRedSquare(_ canvas: Canvas) {
        canvas.background(black)
        canvas.fill(red)
        canvas.noStroke()
        canvas.rect(0, 0, 100, 100)
    }

    /// 絵の全画素が `color` か。
    private func everyPixel(of image: Image, is color: LinearRGBA, within tolerance: Float = 0) -> Bool {
        (0..<image.height).allSatisfy { y in
            (0..<image.width).allSatisfy { x in same(image.get(x, y), color, within: tolerance) }
        }
    }

    @Test("取った画面を、消した後に置き直すと赤い四角が戻る (完了条件 1)")
    func theWholeScreenComesBackWhenPlacedAgain() throws {
        let canvas = try makeCanvas()
        var size = (0, 0)
        try canvas.draw {
            paintRedSquare(canvas)
            guard let shot = try? canvas.get() else { return }
            size = (shot.width, shot.height)
            canvas.background(black)
            canvas.image(shot, 0, 0)
        }
        #expect(size == (400, 300))
        #expect(same(canvas.get(50, 50), red))
        #expect(same(canvas.get(99, 99), red))
        #expect(same(canvas.get(100, 100), black))
        #expect(same(canvas.get(300, 200), black))
    }

    @Test("領域は w x h の絵で、画面をはみ出す部分は透明 (完了条件 2)")
    func aRegionIsItsOwnSizeAndTransparentBeyondTheScreen() throws {
        let canvas = try makeCanvas()
        var inside: Image?
        var edge: Image?
        try canvas.draw {
            paintRedSquare(canvas)
            inside = try? canvas.get(0, 0, 100, 100)
            edge = try? canvas.get(350, 250, 100, 100)
        }
        let square = try #require(inside)
        #expect(square.width == 100 && square.height == 100)
        #expect(everyPixel(of: square, is: red))

        let corner = try #require(edge)
        #expect(corner.width == 100 && corner.height == 100)
        for y in 0..<100 {
            for x in 0..<100 {
                let expected = x < 50 && y < 50 ? black : .transparent
                #expect(same(corner.get(x, y), expected), "(\(x), \(y))")
            }
        }
    }

    @Test("画面と重ならない領域も投げず、全体が透明の絵を返す")
    func aRegionAwayFromTheScreenIsTransparent() throws {
        let canvas = try makeCanvas()
        var far: Image?
        try canvas.draw {
            paintRedSquare(canvas)
            far = try? canvas.get(-500, 10, 20, 20)
        }
        #expect(everyPixel(of: try #require(far), is: .transparent))
    }

    @Test("幅か高さが 1 を割る領域は、createImage と同じ unplaceable を投げる")
    func aRegionNarrowerThanOneThrows() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            paintRedSquare(canvas)
            #expect(throws: ImageFailure.unplaceable(width: 0, height: 10)) { try canvas.get(0, 0, 0, 10) }
            #expect(throws: ImageFailure.unplaceable(width: 10, height: -1)) { try canvas.get(0, 0, 10, -1) }
            #expect(throws: ImageFailure.unplaceable(width: 0, height: 10)) {
                try canvas.get(in: Rect(left: 0, top: 0, width: Float.nan, height: 10))
            }
        }
    }

    @Test("取った絵は、後の描き足しでも次のフレームでも変わらない (完了条件 3)")
    func theShotKeepsThePictureItTook() throws {
        let canvas = try makeCanvas()
        var taken: Image?
        var before = LinearRGBA.transparent
        var after = LinearRGBA.transparent
        try canvas.draw {
            paintRedSquare(canvas)
            guard let shot = try? canvas.get() else { return }
            before = shot.get(10, 10)
            canvas.fill(LinearRGBA.linear(red: 0, green: 0, blue: 1))
            canvas.rect(0, 0, 50, 50)
            _ = canvas.get(10, 10)  // 描き足しを描き切らせる
            after = shot.get(10, 10)
            taken = shot
        }
        try canvas.draw { canvas.background(LinearRGBA.linear(red: 0, green: 1, blue: 0)) }
        _ = canvas.get(0, 0)
        #expect(same(before, red))
        #expect(same(after, red))
        #expect(same(try #require(taken).get(10, 10), red))
    }

    @Test("描き場所は描き終えた後でも読める (完了条件 4)")
    func aGraphicsCanBeReadAfterItsDrawingEnded() throws {
        let canvas = try makeCanvas()
        let graphics = try canvas.createGraphics(120, 80)
        try graphics.draw {
            graphics.background(black)
            graphics.fill(red)
            graphics.noStroke()
            graphics.rect(0, 0, 40, 40)
        }
        let whole = try graphics.get()
        #expect(whole.width == 120 && whole.height == 80)
        #expect(same(whole.get(20, 20), red))
        #expect(same(whole.get(60, 60), black))
        #expect(everyPixel(of: try graphics.get(0, 0, 40, 40), is: red))
    }

    @Test("書き出しの倍率 2 でも、領域は座標の大きさで返り、置き直すと元の大きさに重なる (完了条件 5)")
    func underAnOutputScaleTheShotHasTheCoordinateSize() throws {
        let canvas = try makeCanvas(outputScale: 2)
        #expect(canvas.pixelWidth == 800, "検査の前提: 倍率の下で画素が座標の 2 倍で刻まれていない")
        var whole: Image?
        var square: Image?
        try canvas.draw {
            paintRedSquare(canvas)
            whole = try? canvas.get()
            square = try? canvas.get(0, 0, 100, 100)
            canvas.background(black)
            if let whole { canvas.image(whole, 0, 0) }
        }
        let shot = try #require(whole)
        #expect(shot.width == 400 && shot.height == 300)
        let part = try #require(square)
        #expect(part.width == 100 && part.height == 100)
        #expect(everyPixel(of: part, is: red, within: 1e-3))
        // 置き直した四角の縁は、刻んだ画素の 200 (座標の 100)。縁の補いが及ばない所で見る
        #expect(same(canvas.get(190, 190), red, within: 1e-3))
        #expect(same(canvas.get(210, 210), black, within: 1e-3))
        #expect(same(canvas.get(190, 210), black, within: 1e-3))
    }

    @Test("細かさを下げても、返す絵は座標の大きさ")
    func underALowerDensityTheShotHasTheCoordinateSize() throws {
        let canvas = try makeCanvas(density: 0.5)
        #expect(canvas.pixelWidth == 200, "検査の前提: 細かさ 0.5 で画素が座標の半分で刻まれていない")
        var whole: Image?
        var square: Image?
        try canvas.draw {
            paintRedSquare(canvas)
            whole = try? canvas.get()
            square = try? canvas.get(20, 20, 60, 60)
        }
        let shot = try #require(whole)
        #expect(shot.width == 400 && shot.height == 300)
        #expect(same(shot.get(50, 50), red, within: 1e-3))
        #expect(same(shot.get(150, 150), black, within: 1e-3))
        let part = try #require(square)
        #expect(part.width == 60 && part.height == 60)
        #expect(everyPixel(of: part, is: red, within: 1e-3))
    }

    @Test("画面の領域を画面の別の所へ写せる (対応表の copy() の行・完了条件 7)")
    func aRegionOfTheScreenCopiesToAnotherPlace() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            paintRedSquare(canvas)
            // Processing の copy(0, 0, 100, 100, 200, 100, 50, 50) に当たる書き方
            if let part = try? canvas.get(0, 0, 100, 100) { canvas.image(part, 200, 100, 50, 50) }
        }
        #expect(same(canvas.get(225, 125), red, within: 1e-3))
        #expect(same(canvas.get(260, 125), black))
        #expect(same(canvas.get(225, 160), black))
    }

    @Test("画面を絵にしてマスクを掛け、置き直せる (対応表の mask() の行)")
    func theScreenCanBeMaskedThroughAnImage() throws {
        let canvas = try makeCanvas()
        let mask = try canvas.createImage(100, 100)
        mask.pixels.update { x, _, _ in x < 50 ? .linear(red: 1, green: 1, blue: 1) : .linear(red: 0, green: 0, blue: 0) }
        try canvas.draw {
            paintRedSquare(canvas)
            guard let part = try? canvas.get(0, 0, 100, 100) else { return }
            part.mask(mask)
            canvas.background(black)
            canvas.image(part, 0, 0)
        }
        #expect(same(canvas.get(25, 50), red, within: 1e-3))
        #expect(same(canvas.get(75, 50), black, within: 1e-3))
    }

    @Test("get(in:) は同じ値の get(x, y, w, h) と同じ絵で、rectMode・imageMode に従わない")
    func aRectReadsLikeTheFourNumbers() throws {
        let canvas = try makeCanvas()
        var numbers: Image?
        var rect: Image?
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            for x in stride(from: 0, to: 400, by: 20) {
                canvas.fill(LinearRGBA.linear(red: Float(x) / 400, green: 0.3, blue: 0.6))
                canvas.rect(Float(x), 0, 20, 300)
            }
            canvas.rectMode(.center)
            canvas.imageMode(.center)
            numbers = try? canvas.get(130, 40, 70, 50)
            rect = try? canvas.get(in: Rect(left: 130, top: 40, width: 70, height: 50))
        }
        let a = try #require(numbers)
        let b = try #require(rect)
        #expect(a.width == b.width && a.height == b.height)
        #expect(a.workingPixels == b.workingPixels)
        // 左上で読んでいる: 左端は x = 130 の帯 (120〜140 の帯の色)
        #expect(same(a.get(0, 0), LinearRGBA.linear(red: 120.0 / 400, green: 0.3, blue: 0.6), within: 1e-3))
    }
}

/// スケッチから呼ぶ `get()` (走っている画面と、走っていない所)。
@Suite(
    "スケッチの画面を絵にして返す get",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct SketchScreenGetTests {
    /// 1 枚目に赤い四角を描いて画面を取り、消してから置き直す。2 枚目は緑で塗る。
    final class Snapper: Sketch {
        var shot: Image?
        var region: Image?
        var settings: SketchSettings { SketchSettings(width: 400, height: 300) }
        func draw() {
            if frameCount == 1 {
                background(LinearRGBA.linear(red: 0, green: 0, blue: 0))
                noStroke()
                fill(LinearRGBA.linear(red: 1, green: 0, blue: 0))
                rect(0, 0, 100, 100)
                shot = try? get()
                region = try? get(0, 0, 100, 100)
                background(LinearRGBA.linear(red: 0, green: 0, blue: 0))
                if let shot { image(shot, 0, 0) }
            } else {
                background(LinearRGBA.linear(red: 0, green: 1, blue: 0))
            }
        }
    }

    @Test("draw() の中で取った画面は、置き直すと戻り、次のフレームでも変わらない")
    func aShotTakenInDrawSurvivesTheNextFrame() throws {
        let sketch = Snapper()
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 })
        try runtime.advance()
        let shot = try #require(sketch.shot)
        #expect(shot.width == 400 && shot.height == 300)
        #expect(try #require(sketch.region).width == 100)
        #expect(runtime.canvas.get(50, 50).red > 0.99)
        #expect(runtime.canvas.get(150, 150).red < 0.01)

        try runtime.advance()
        #expect(runtime.canvas.get(50, 50).green > 0.99, "検査の前提: 2 枚目が描かれていない")
        #expect(shot.get(50, 50).red > 0.99 && shot.get(50, 50).green < 0.01)
    }
}

/// 走っている実行の外から呼ぶと、落ちずに `notRunning(call:)` を投げる (GPU は要らない)。
@MainActor
@Suite("走っている実行の外から呼んだ画面の get")
struct ScreenGetOutsideRunTests {
    struct Reader: SketchPart {}

    @Test("走らせずに呼ぶと、口の名前の notRunning を投げる")
    func outsideARunItThrowsNotRunning() {
        let part = Reader()
        #expect(throws: ImageFailure.notRunning(call: "get()")) { try part.get() }
        #expect(throws: ImageFailure.notRunning(call: "get(_:_:_:_:)")) { try part.get(0, 0, 4, 4) }
        #expect(throws: ImageFailure.notRunning(call: "get(in:)")) {
            try part.get(in: Rect(left: 0, top: 0, width: 4, height: 4))
        }
    }
}
