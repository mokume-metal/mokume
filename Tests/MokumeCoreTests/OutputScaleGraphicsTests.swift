// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 書き出しの倍率 (`mokume render --scale N`) の下での `createGraphics` ([#3453])。GPU を要する。
///
/// 描き場所も本体の面と同じ組み立て (`Canvas(output:…outputScale:)`) で、**座標の大きさは頼んだ
/// まま、画素だけが倍率を掛けた数**になる。置く側 (`image`) は描き場所の座標の大きさで読むので、
/// 倍率 1 で書いた作品は、倍率を上げても同じ構図で出る。
///
/// [#3453]: https://github.com/mokume-metal/mokume/issues/3453
@Suite(
    "書き出しの倍率の下の描き場所",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct OutputScaleGraphicsTests {
    /// 座標の大きさが `size`×`size` で、出す先を `scale` 倍の画素で作った本体の面。
    private static func makeCanvas(size: Int = 128, scale: Int) throws -> Canvas {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: size * scale, height: size * scale)
        return try Canvas(
            output: output, gpu: gpu, pixelDensity: 1, upscale: .spatial, outputScale: scale)
    }

    /// 1 フレーム描く。
    @MainActor
    private static func draw(on canvas: Canvas, _ body: () throws -> Void) throws {
        var failure: (any Error)?
        try canvas.draw {
            do { try body() } catch { failure = error }
        }
        if let failure { throw failure }
    }

    /// 赤い画素 (`red > 0.5`) の外接矩形と数。無ければ `nil`。
    private static func litBounds(
        _ buffer: PixelBuffer
    ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int, count: Int)? {
        var bounds = (minX: Int.max, minY: Int.max, maxX: -1, maxY: -1, count: 0)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width where buffer[x, y].red > 0.5 {
                bounds.minX = min(bounds.minX, x)
                bounds.maxX = max(bounds.maxX, x)
                bounds.minY = min(bounds.minY, y)
                bounds.maxY = max(bounds.maxY, y)
                bounds.count += 1
            }
        }
        return bounds.count == 0 ? nil : bounds
    }

    // MARK: - 座標と画素 (完了条件 1・3・4)

    @Test(
        "倍率 N の下の createGraphics は、座標のまま (width / height) で、画素は N 倍。倍率 1 は今までどおり",
        arguments: [1, 2, 3])
    func graphicsKeepCoordinatesAndScalePixels(_ factor: Int) throws {
        let canvas = try Self.makeCanvas(scale: factor)
        let graphics = try canvas.createGraphics(192, 108)
        #expect(graphics.width == 192 && graphics.height == 108)
        #expect(graphics.pixelWidth == 192 * factor && graphics.pixelHeight == 108 * factor)
        #expect(graphics.output.width == 192 * factor && graphics.output.height == 108 * factor)
        #expect(graphics.unitsPerDrawnPixel == SIMD2<Float>(repeating: 1 / Float(factor)))
        // 描き場所から作った描き場所も、同じ倍率を引き継ぐ (完了条件 3)
        let inner = try graphics.createGraphics(40, 30)
        #expect(inner.width == 40 && inner.height == 30)
        #expect(inner.pixelWidth == 40 * factor && inner.pixelHeight == 30 * factor)
        #expect(inner.outputScale == factor)
    }

    /// 完了条件 1・4: 線は倍率を掛けた画素で刻まれ (座標の太さ 2 は N 倍の画素)、`get` は実際の画素で読む。
    @Test("描き場所の strokeWeight(2) の線は、倍率 N で 2N 画素の太さになり、get / set は実際の画素で数える", arguments: [2, 3])
    func strokeIsDrawnAtTheScaledPixelSize(_ factor: Int) throws {
        func crossing(scale: Int) throws -> (sum: Float, graphics: Canvas) {
            let canvas = try Self.makeCanvas(scale: scale)
            let graphics = try canvas.createGraphics(128, 128)
            try Self.draw(on: graphics) {
                graphics.background(0)
                graphics.stroke(255)
                graphics.strokeWeight(2)
                graphics.line(8, 64, 120, 64)
            }
            let pixels = try graphics.output.readPixels()
            var sum: Float = 0
            for y in 0..<pixels.height { sum += pixels[30 * scale, y].red }
            return (sum, graphics)
        }
        let one = try crossing(scale: 1)
        let scaled = try crossing(scale: factor)
        #expect(abs(one.sum - 2) < 0.2, "倍率 1 の線の太さ: \(one.sum)")
        #expect(abs(scaled.sum - Float(2 * factor)) < 0.2, "倍率 \(factor) の線の太さ: \(scaled.sum)")
        // get / set は実際の画素 (倍率 N の線の中心 y = 64N は、線の上)
        #expect(scaled.graphics.get(30 * factor, 64 * factor).red > 0.5)
        #expect(scaled.graphics.get(30 * factor, 20 * factor).red < 0.01)
        let last = factor * 128 - 1
        try Self.draw(on: scaled.graphics) {
            scaled.graphics.set(last, last, .linear(red: 1, green: 0, blue: 0))
        }
        #expect(scaled.graphics.get(last, last).red == 1)
        #expect(scaled.graphics.get(last - 1, last).red < 0.01)
    }

    // MARK: - 置く (完了条件 2)

    /// 描き場所 (`size`×`size` の座標) に、座標 (50, 50)〜(100, 100) だけを赤く塗って、本体へ `place` で置く。
    /// 返すのは本体の出力の赤い画素の外接矩形。
    private static func placed(
        scale: Int, graphicsSize: Int = 128,
        _ place: (Canvas, Canvas) -> Void
    ) throws -> (minX: Int, minY: Int, maxX: Int, maxY: Int, count: Int)? {
        let canvas = try makeCanvas(scale: scale)
        let graphics = try canvas.createGraphics(graphicsSize, graphicsSize)
        try draw(on: graphics) {
            graphics.noStroke()
            graphics.fill(255, 0, 0)
            graphics.rect(50, 50, 50, 50)
        }
        try draw(on: canvas) {
            canvas.background(0)
            place(canvas, graphics)
        }
        return litBounds(try canvas.output.readPixels())
    }

    /// 置いた赤い四角は、座標 (50, 50)〜(100, 100) が `(x, y)` の分ずれて、倍率 N 倍の画素の範囲に出る。
    private static func expectedBounds(
        offsetX: Int, offsetY: Int, scale: Int
    ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int, count: Int) {
        let (x0, y0) = ((50 + offsetX) * scale, (50 + offsetY) * scale)
        let side = 50 * scale
        return (x0, y0, x0 + side - 1, y0 + side - 1, side * side)
    }

    @Test("image(graphics, x, y) は、倍率 N でも描き場所の座標の大きさ (128) で置く", arguments: [1, 2, 3])
    func placingAtItsSizeUsesCoordinates(_ factor: Int) throws {
        let bounds = try #require(try Self.placed(scale: factor) { canvas, graphics in
            canvas.image(graphics, 0, 0)
        })
        let expected = Self.expectedBounds(offsetX: 0, offsetY: 0, scale: factor)
        #expect(bounds == expected, "\(bounds) <> \(expected)")
    }

    @Test("image(graphics, x, y, w, h) は、置き先を座標で読み、倍率 N でも同じ構図で置く", arguments: [1, 2, 3])
    func placingToARectangleUsesCoordinates(_ factor: Int) throws {
        // 128×128 の描き場所を (10, 20) から 64×64 へ置く → 赤い四角は半分の大きさ
        let bounds = try #require(try Self.placed(scale: factor) { canvas, graphics in
            canvas.image(graphics, 10, 20, 64, 64)
        })
        // 座標 (50..100) → 置き先の (10 + 25 .. 10 + 50) = 35..60, y は 20 + 25 .. 20 + 50 = 45..70
        #expect(bounds.minX == 35 * factor && bounds.maxX == 60 * factor - 1, "\(bounds)")
        #expect(bounds.minY == 45 * factor && bounds.maxY == 70 * factor - 1, "\(bounds)")
        #expect(bounds.count == 25 * 25 * factor * factor, "\(bounds)")
    }

    @Test("image(graphics, a, b, c, d, sx, sy, sw, sh) は、切り出しを描き場所の座標で読む", arguments: [1, 2, 3])
    func croppingUsesCoordinates(_ factor: Int) throws {
        // 描き場所の座標 (50, 50) から 50×50 だけを (0, 0)〜(100, 100) へ 2 倍で置く → 赤は置き先をいっぱいに覆う
        let full = try #require(try Self.placed(scale: factor) { canvas, graphics in
            canvas.image(graphics, 0, 0, 100, 100, 50, 50, 50, 50)
        })
        #expect(full.minX == 0 && full.minY == 0, "\(full)")
        #expect(full.maxX == 100 * factor - 1 && full.maxY == 100 * factor - 1, "\(full)")
        // 四隅の 4 画素は、置き先の縁で薄くなるので数えない
        #expect(full.count >= 100 * 100 * factor * factor - 4, "\(full)")
        // 四角の左上の隅 (座標 (50, 50)〜(75, 75)) だけを切ると、置き先 (10, 10)〜(60, 60) の中の
        // 25×25 だけが赤で、残りは透明のまま
        let part = try #require(try Self.placed(scale: factor) { canvas, graphics in
            canvas.image(graphics, 10, 10, 50, 50, 25, 25, 50, 50)
        })
        // 切り出し (25..75) のうち赤は (50..75) = 切り出しの後ろ半分 → 置き先の (35..60)
        #expect(part.minX == 35 * factor && part.minY == 35 * factor, "\(part)")
        #expect(part.maxX == 60 * factor - 1 && part.maxY == 60 * factor - 1, "\(part)")
    }

    // MARK: - 上限 (完了条件 5)

    @Test("倍率を掛けた描き場所が 16384 を越えると、倍率を名指す失敗で断る。上限ちょうどは通る")
    func oversizedGraphicsNamesTheScale() throws {
        let canvas = try Self.makeCanvas(size: 16, scale: 3)
        #expect(throws: RenderFailure.sizeBeyondOutputScale(width: 8192, height: 100, scale: 3)) {
            _ = try canvas.createGraphics(8192, 100)
        }
        let failure = RenderFailure.sizeBeyondOutputScale(width: 8192, height: 100, scale: 3)
        #expect(failure.description.contains("--scale 3"), "\(failure.description)")
        #expect(failure.description.contains("24576"), "\(failure.description)")
        #expect(failure.description.contains("5461"), "\(failure.description)")
        // 上限ちょうど (5461 × 3 = 16383) は通る
        let edge = try canvas.createGraphics(5461, 4)
        #expect(edge.pixelWidth == 16383 && edge.width == 5461)
        // 桁あふれする値も、落ちずに断る
        #expect(throws: RenderFailure.self) {
            _ = try canvas.createGraphics(.max, 4)
        }
        // 頼んだ大きさ自体が範囲の外なら、倍率のせいにせず今までの失敗
        #expect(throws: RenderFailure.invalidSize(width: 0, height: 10)) {
            _ = try canvas.createGraphics(0, 10)
        }
        #expect(throws: RenderFailure.invalidSize(width: 20000, height: 10)) {
            _ = try canvas.createGraphics(20000, 10)
        }
        // 倍率 1 は、これまでと同じ失敗
        let plain = try Self.makeCanvas(size: 16, scale: 1)
        #expect(throws: RenderFailure.invalidSize(width: 20000, height: 10)) {
            _ = try plain.createGraphics(20000, 10)
        }
    }

    // MARK: - 決定論・倍率 1 (完了条件 6)

    @Test("同じ倍率・同じ引数で描き場所を 2 度描くと、同じ画素になる")
    func sameScaleGivesTheSameGraphicsPixels() throws {
        func render() throws -> PixelBuffer {
            let canvas = try Self.makeCanvas(scale: 2)
            let graphics = try canvas.createGraphics(128, 128)
            try Self.draw(on: graphics) {
                graphics.background(20)
                graphics.fill(255, 120, 40)
                graphics.circle(50, 60, 70)
                graphics.stroke(255)
                graphics.strokeWeight(3)
                graphics.line(10, 10, 118, 100)
            }
            try Self.draw(on: canvas) { canvas.image(graphics, 0, 0) }
            return try canvas.output.readPixels()
        }
        #expect(try render() == render())
    }

    @Test("倍率 1 の描き場所は、これまでの Canvas(target:gpu:) の描き場所と同じ画素になる")
    func scaleOneIsUnchanged() throws {
        func scene(_ graphics: Canvas) throws {
            try Self.draw(on: graphics) {
                graphics.background(20)
                graphics.fill(255, 120, 40)
                graphics.circle(50, 60, 70)
                graphics.stroke(255)
                graphics.strokeWeight(1)
                graphics.line(10, 10, 118, 100)
            }
        }
        let canvas = try Self.makeCanvas(scale: 1)
        let made = try canvas.createGraphics(128, 128)
        try scene(made)
        // 倍率の仕組みを通らない作り方 (今までの作り方) で作った面
        let gpu = try RenderDevice()
        let direct = try Canvas(target: RenderTarget(gpu: gpu, width: 128, height: 128), gpu: gpu)
        try scene(direct)
        #expect(try made.output.readPixels() == direct.output.readPixels())
    }
}
