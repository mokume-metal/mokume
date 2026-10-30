// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// **`clip(_:_:_:_:)` の矩形は、呼んだ時点の変換で面へ写して読む** ([#2721])。GPU を要する。
///
/// 手本 (Processing 4.5.7) の既定の描き手で `translate(100, 0); clip(0, 0, 50, 50); background(255)` を走らせると、
/// 白いのは x = 100…150 (変換が効く)・`scale(2); clip(10, 10, 20, 20)` は (20, 20)〜(60, 60)・切り抜いた後の
/// `translate` は切り抜きを動かさない・`clip(100, 100, -50, -50)` は (50, 50)〜(100, 100) を通す。ここはそれと
/// 同じ値を画素で固定する。読み方 (`rectMode` で読む・`imageMode` は読まない) もここで固定する。
///
/// [#2721]: https://github.com/mokume-metal/mokume/issues/2721
@Suite(
    "clip は呼んだ時点の変換で矩形を読み、rectMode で数を読む",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ClipTransformTests {
    /// 面 100×100 で、黒の下地に `body` が白く塗ったもの。`body` の後に面全体を白で塗る。
    private func drawn(_ body: (Canvas) -> Void) throws -> (pixels: PixelBuffer, canvas: Canvas) {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 100, height: 100)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            body(canvas)
            // 変換と読み方を戻してから面全体を塗る。切り抜きは残る
            canvas.resetMatrix()
            canvas.rectMode(.corner)
            canvas.rect(0, 0, 100, 100)
        }
        return (try canvas.target.readPixels(), canvas)
    }

    /// 白い画素の外接矩形 (`x`・`y` は両端を含む範囲)。白い画素が矩形になっていることも確かめる。
    private func whiteBox(_ pixels: PixelBuffer) -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
        var xs: [Int] = []
        var ys: [Int] = []
        var count = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].red > 0.5 {
                xs.append(x)
                ys.append(y)
                count += 1
            }
        }
        guard let left = xs.min(), let right = xs.max(), let top = ys.min(), let bottom = ys.max() else {
            return nil
        }
        #expect(count == (right - left + 1) * (bottom - top + 1), "白い画素が矩形になっていない")
        return (left...right, top...bottom)
    }

    // MARK: - 数の読み方 (rectMode)

    @Test("rectMode(.center) の clip(50, 40, 40, 20) は (30, 30)〜(70, 50) を通し、imageMode(.center) だけでは左上から読む")
    func theNumbersAreReadByRectMode() throws {
        let center = try drawn { canvas in
            canvas.rectMode(.center)
            canvas.clip(50, 40, 40, 20)
        }
        let centerBox = try #require(whiteBox(center.pixels))
        #expect(centerBox.x == 30...69 && centerBox.y == 30...49)

        let imageOnly = try drawn { canvas in
            canvas.imageMode(.center)
            canvas.clip(50, 40, 40, 20)
        }
        let imageBox = try #require(whiteBox(imageOnly.pixels))
        #expect(imageBox.x == 50...89 && imageBox.y == 40...59, "imageMode は clip の読み方に効かない")
    }

    // MARK: - 今の変換

    @Test("translate の後の clip(0, 0, 20, 20) は、動かした先 (30, 10)〜(50, 30) を通す")
    func translationMovesTheClip() throws {
        let result = try drawn { canvas in
            canvas.translate(30, 10)
            canvas.clip(0, 0, 20, 20)
        }
        let box = try #require(whiteBox(result.pixels))
        #expect(box.x == 30...49 && box.y == 10...29)
        #expect(result.pixels[10, 10].red < 0.5, "変換を無視した位置 (0, 0)〜(20, 20) は切り抜かない")
        #expect(!result.canvas.warnings.hasWarned(.clipUnderRotation))
    }

    @Test("scale(2) の clip(10, 10, 20, 20) は (20, 20)〜(60, 60) を通す")
    func scalingGrowsTheClip() throws {
        let result = try drawn { canvas in
            canvas.scale(2, 2)
            canvas.clip(10, 10, 20, 20)
        }
        let box = try #require(whiteBox(result.pixels))
        #expect(box.x == 20...59 && box.y == 20...59)
    }

    @Test("切り抜いた後の translate は、切り抜きを動かさない (呼んだ時点の変換で決まる)")
    func laterTransformsDoNotMoveTheClip() throws {
        let result = try drawn { canvas in
            canvas.translate(10, 10)
            canvas.clip(0, 0, 20, 20)
            canvas.translate(40, 40)
        }
        let box = try #require(whiteBox(result.pixels))
        #expect(box.x == 10...29 && box.y == 10...29)
    }

    @Test("鏡映しの変換 (scale(-1, 1)) と 90 度・180 度の回転は、面に沿った矩形に写るので警告しない")
    func axisAlignedTransformsAreExact() throws {
        let mirrored = try drawn { canvas in
            canvas.translate(80, 0)
            canvas.scale(-1, 1)
            canvas.clip(10, 10, 30, 30)  // x = 80 - 40 …80 - 10
        }
        let mirroredBox = try #require(whiteBox(mirrored.pixels))
        #expect(mirroredBox.x == 40...69 && mirroredBox.y == 10...39)
        #expect(!mirrored.canvas.warnings.hasWarned(.clipUnderRotation))

        let quarter = try drawn { canvas in
            canvas.translate(50, 0)
            canvas.rotate(Float.pi / 2)  // (x, y) → (-y, x)
            canvas.clip(10, 5, 20, 30)  // x = 50 - 35 …50 - 5, y = 10 …30
        }
        let quarterBox = try #require(whiteBox(quarter.pixels))
        #expect(quarterBox.x == 15...44 && quarterBox.y == 10...29)
        #expect(!quarter.canvas.warnings.hasWarned(.clipUnderRotation))

        let half = try drawn { canvas in
            canvas.translate(60, 60)
            canvas.rotate(Float.pi)
            canvas.clip(10, 10, 20, 20)  // (60 - 30, 60 - 30)〜(60 - 10, 60 - 10)
        }
        let halfBox = try #require(whiteBox(half.pixels))
        #expect(halfBox.x == 30...49 && halfBox.y == 30...49)
        #expect(!half.canvas.warnings.hasWarned(.clipUnderRotation))
    }

    @Test("回転 (45 度) の下の clip は、写した 4 つの角を囲む矩形で切り抜き、clip() の名前で 1 度だけ知らせる")
    func rotationClipsToTheEnclosingRectangle() throws {
        let result = try drawn { canvas in
            canvas.translate(50, 10)
            canvas.rotate(Float.pi / 4)
            canvas.clip(0, 0, 20, 20)  // 写した角: (50, 10)・(64.1, 24.1)・(50, 38.3)・(35.9, 24.1)
            canvas.clip(0, 0, 20, 20)  // 同じ呼び出しを繰り返しても、知らせるのは 1 度
        }
        let box = try #require(whiteBox(result.pixels))
        #expect(box.x == 36...63 && box.y == 10...37, "囲む矩形 (35.86…64.14, 10…38.28) の画素の中心の規則")
        #expect(result.canvas.warnings.hasWarned(.clipUnderRotation))
        #expect(result.canvas.warnings.message(for: .clipUnderRotation)?.hasPrefix("clip()") == true)
        #expect(!result.canvas.warnings.hasWarned(.badClip))
    }

    // MARK: - 負の幅・高さ

    @Test("clip(60, 60, -30, -30) は、手本と同じに裏返して (30, 30)〜(60, 60) を通す")
    func negativeSizesAreReadFlipped() throws {
        let result = try drawn { canvas in
            canvas.clip(60, 60, -30, -30)
        }
        let box = try #require(whiteBox(result.pixels))
        #expect(box.x == 30...59 && box.y == 30...59)
    }

    // MARK: - 溢れ

    @Test("変換の下でも、面より桁違いに大きい矩形は面へ収まり、数でない値を作らない")
    func hugeRectanglesStillClampUnderATransform() throws {
        let result = try drawn { canvas in
            canvas.translate(20, 20)
            canvas.scale(3, 3)
            canvas.rectMode(.radius)
            canvas.clip(0, 0, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        }
        let box = try #require(whiteBox(result.pixels))
        #expect(box.x == 0...99 && box.y == 0...99)
        #expect(!result.canvas.warnings.hasWarned(.badClip))
        #expect(!result.canvas.warnings.hasWarned(.clipUnderRotation))
    }
    // MARK: - 反証 r1 の取りこぼし

    @Test("pushMatrix / popMatrix は切り抜きを動かさず、push / pop と pushStyle / popStyle は切り抜きも戻す")
    func stacksRestoreWhatTheyOwn() throws {
        let matrixOnly = try drawn { canvas in
            canvas.pushMatrix()
            canvas.translate(30, 0)
            canvas.clip(0, 0, 20, 20)
            canvas.popMatrix()
        }
        let matrixBox = try #require(whiteBox(matrixOnly.pixels))
        #expect(matrixBox.x == 30...49 && matrixBox.y == 0...19, "popMatrix は切り抜きを戻さない")

        let whole = try drawn { canvas in
            canvas.push()
            canvas.translate(30, 0)
            canvas.clip(0, 0, 20, 20)
            canvas.pop()
        }
        let wholeBox = try #require(whiteBox(whole.pixels))
        #expect(wholeBox.x == 0...99 && wholeBox.y == 0...99, "pop は切り抜きも戻す")

        let styleOnly = try drawn { canvas in
            canvas.pushStyle()
            canvas.translate(30, 0)
            canvas.clip(0, 0, 20, 20)
            canvas.popStyle()
        }
        let styleBox = try #require(whiteBox(styleOnly.pixels))
        #expect(styleBox.x == 0...99 && styleBox.y == 0...99, "popStyle は切り抜きを戻す")
    }

    @Test("90 度回転で縁が画素の中心 (x.5) に乗る矩形も、縁の画素を落とさない")
    func quarterTurnKeepsEdgesOnPixelCenters() throws {
        let result = try drawn { canvas in
            canvas.translate(50, 0)
            canvas.rotate(Float.pi / 2)  // (x, y) → (50 - y, x)
            canvas.clip(10.5, 5, 20, 30)  // 行 = 10.5 …30.5 (両端の画素の中心が縁の上)
        }
        let box = try #require(whiteBox(result.pixels))
        #expect(box.x == 15...44 && box.y == 10...30)
        #expect(!result.canvas.warnings.hasWarned(.clipUnderRotation))

        // 面から遠い所で回すと、`cos(π / 2)` の誤差 (-4.4e-8) が座標の大きさを掛けて縁を越える
        let far = try drawn { canvas in
            canvas.translate(-2000, 0)
            canvas.rotate(Float.pi / 2)  // (x, y) → (-2000 - y, x)
            canvas.clip(10.5, -2100, 20, 100)  // 列 0…100・行 10.5 …30.5
        }
        let farBox = try #require(whiteBox(far.pixels))
        #expect(farBox.x == 0...99 && farBox.y == 10...30, "誤差で縁の行が落ちた")
        #expect(!far.canvas.warnings.hasWarned(.clipUnderRotation))
    }

    @Test("数でない値になる読み方 (rectMode(.radius) の -∞ + ∞) は、回転の警告ではなく bad clip で断り、切り抜きを触らない")
    func overflowingResolutionIsRefusedAsABadClip() throws {
        let result = try drawn { canvas in
            canvas.clip(10, 10, 30, 30)
            canvas.rectMode(.radius)
            canvas.clip(-Float.greatestFiniteMagnitude, 50, Float.greatestFiniteMagnitude, 10)
        }
        #expect(result.canvas.warnings.hasWarned(.badClip))
        #expect(result.canvas.warnings.message(for: .badClip)?.contains("transform") == false, "変換のせいではない")
        #expect(!result.canvas.warnings.hasWarned(.clipUnderRotation))
        let box = try #require(whiteBox(result.pixels))
        #expect(box.x == 10...39 && box.y == 10...39, "前の切り抜きのまま")
    }

    @Test("変換が溢れて有限でなくなるときは、変換のせいだと言う (渡された数のせいにしない)")
    func transformOverflowIsNamed() throws {
        let result = try drawn { canvas in
            canvas.scale(1e30, 1e30)
            canvas.clip(1e10, 1e10, 1e10, 1e10)
        }
        #expect(result.canvas.warnings.hasWarned(.badClip))
        #expect(result.canvas.warnings.message(for: .badClip)?.contains("transform") == true)
    }

    @Test("大きな矩形 (辺が 4 万画素) の 90 度回転も、誤差で警告もずれもしない")
    func hugeQuarterTurnIsExact() throws {
        let result = try drawn { canvas in
            canvas.rotate(Float.pi / 2)  // (x, y) → (-y, x)
            canvas.clip(0, -40_000, 50, 80_000)  // 行 0…50・列 -40000…40000
        }
        let box = try #require(whiteBox(result.pixels))
        #expect(box.x == 0...99 && box.y == 0...49)
        #expect(!result.canvas.warnings.hasWarned(.clipUnderRotation))
    }

    @Test("幅か高さが 0 の矩形は、回転の下でも空のまま (対角線を囲む矩形にならない)")
    func emptyRectanglesStayEmptyUnderRotation() throws {
        for width: Float in [0, 30] {
            let result = try drawn { canvas in
                canvas.translate(50, 50)
                canvas.rotate(Float.pi / 4)
                canvas.clip(0, 0, width, width == 0 ? 30 : 0)
            }
            #expect(whiteBox(result.pixels) == nil, "幅 \(width) の矩形が空でなくなった")
        }
    }

    // MARK: - 面の大きさと画素の対応 (細かさ・出力の倍率・描き場所)

    /// 座標の大きさ 100×100 の面を、細かさ `density`・出力の倍率 `scale` で作り、`body` を描く。
    /// 返すのは本体の出力の絵。`body` は 2 度目の呼び出しで描き場所も使えるよう `Canvas` を渡す。
    private func drawnScaled(
        density: Float = 1, scale: Int = 1, _ body: (Canvas) throws -> Void
    ) throws -> PixelBuffer {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 100 * scale, height: 100 * scale)
        let canvas = try Canvas(
            output: output, gpu: gpu, pixelDensity: density, upscale: .spatial, outputScale: scale)
        var failure: (any Error)?
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            do { try body(canvas) } catch { failure = error }
        }
        if let failure { throw failure }
        return try canvas.output.readPixels()
    }

    @Test("細かさ 0.5 でも、translate の下の clip は、変換を通した同じ矩形と同じ画素を通す")
    func transformedClipMatchesUntransformedUnderHalfDensity() throws {
        let moved = try drawnScaled(density: 0.5) { canvas in
            canvas.translate(41.5, 0)
            canvas.clip(10, 0, 20, 100)
            canvas.resetMatrix()
            canvas.rect(0, 0, 100, 100)
        }
        let direct = try drawnScaled(density: 0.5) { canvas in
            canvas.clip(51.5, 0, 20, 100)
            canvas.rect(0, 0, 100, 100)
        }
        #expect(moved == direct)
        #expect(whiteBox(moved) != nil)
    }

    @Test("出力の倍率 2 でも、translate の下の clip は座標で読まれ、倍率を掛けた画素 (60…99・20…59) を通す")
    func transformedClipFollowsTheOutputScale() throws {
        let pixels = try drawnScaled(scale: 2) { canvas in
            canvas.translate(30, 10)
            canvas.clip(0, 0, 20, 20)
            canvas.resetMatrix()
            canvas.rect(0, 0, 100, 100)
        }
        let box = try #require(whiteBox(pixels))
        #expect(box.x == 60...99 && box.y == 20...59)
    }

    @Test("出力の倍率 2 の下の createGraphics の描き場所でも、translate の下の clip は同じ位置を通す")
    func transformedClipInsideAGraphicsFollowsTheScale() throws {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 200, height: 200)
        let canvas = try Canvas(
            output: output, gpu: gpu, pixelDensity: 1, upscale: .spatial, outputScale: 2)
        let graphics = try canvas.createGraphics(100, 100)
        try graphics.draw {
            graphics.background(0)
            graphics.noStroke()
            graphics.fill(255)
            graphics.translate(30, 10)
            graphics.clip(0, 0, 20, 20)
            graphics.resetMatrix()
            graphics.rect(0, 0, 100, 100)
        }
        let box = try #require(whiteBox(try graphics.output.readPixels()))
        #expect(box.x == 60...99 && box.y == 20...59)
    }
}
