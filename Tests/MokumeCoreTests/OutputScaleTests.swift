// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 書き出しの倍率 (`mokume render --scale N`) は、座標を変えずに出す画素だけを増やす ([#2441])。GPU を要する。
///
/// 倍率 N の面は、出す先と描く先を座標の N 倍の画素で刻み、``Canvas/width`` / ``Canvas/height`` は
/// 座標のまま。線の太さ・効果の半径・切り抜き・断片が受ける位置と大きさ・字の焼き場の鍵は、
/// 描く画素 1 つが座標でいくらか (``Canvas/unitsPerDrawnPixel``) を通して倍率を掛けて読まれる。
///
/// [#2441]: https://github.com/mokume-metal/mokume/issues/2441
@Suite(
    "書き出しの倍率",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct OutputScaleTests {
    /// 座標の大きさ (正方形) は ``DensityInvarianceTests/size``。
    private static let size = DensityInvarianceTests.size

    /// 座標の大きさが `width`×`height` で、出す先を `scale` 倍の画素で作った面。
    private static func makeCanvas(
        width: Int = size, height: Int = size, scale: Int, density: Float = 1
    ) throws -> Canvas {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: width * scale, height: height * scale)
        return try Canvas(
            output: output, gpu: gpu, pixelDensity: density, upscale: .spatial, outputScale: scale)
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

    /// `factor` × `factor` の画素を平均して、`factor` 分の 1 の大きさにした絵。
    private static func averaged(_ buffer: PixelBuffer, by factor: Int) -> PixelBuffer {
        let (width, height) = (buffer.width / factor, buffer.height / factor)
        var components = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var sum = SIMD4<Float>(repeating: 0)
                for dy in 0..<factor {
                    for dx in 0..<factor {
                        let value = buffer[x * factor + dx, y * factor + dy]
                        sum += SIMD4(value.red, value.green, value.blue, value.alpha)
                    }
                }
                sum /= Float(factor * factor)
                for channel in 0..<4 { components[(y * width + x) * 4 + channel] = Float16(sum[channel]) }
            }
        }
        return PixelBuffer(width: width, height: height, components: components)
    }

    // MARK: - 座標と画素

    /// 完了条件 2: 倍率の下でも座標は変わらず、画素の口は実際の画素で数える。
    @Test("倍率 2 の面は、width / height が座標のままで、画素は倍の大きさ。描く画素 1 つは座標の半分")
    func coordinatesStayAndPixelsDouble() throws {
        let canvas = try Self.makeCanvas(width: 192, height: 108, scale: 2)
        #expect(canvas.width == 192 && canvas.height == 108)
        #expect(canvas.pixelWidth == 384 && canvas.pixelHeight == 216)
        #expect(canvas.output.width == 384 && canvas.output.height == 216)
        #expect(canvas.unitsPerDrawnPixel == SIMD2<Float>(0.5, 0.5))
        // 倍率を掛けない面は、これまでどおり
        let plain = try Self.makeCanvas(width: 192, height: 108, scale: 1)
        #expect(plain.width == 192 && plain.pixelWidth == 192)
        #expect(plain.unitsPerDrawnPixel == SIMD2<Float>(1, 1))
    }

    /// 倍率と細かさは掛け合わさる: 描く画素は「出す大きさ × 倍率 × 細かさ」。
    @Test("倍率 2・細かさ 0.5 は、座標と同じ数の画素で描いて、倍の画素へ拡大する")
    func scaleAndDensityMultiply() throws {
        let canvas = try Self.makeCanvas(scale: 2, density: 0.5)
        #expect(canvas.width == Float(Self.size))
        #expect(canvas.pixelWidth == Self.size)
        #expect(canvas.output.width == Self.size * 2)
        #expect(canvas.unitsPerDrawnPixel == SIMD2<Float>(1, 1))
    }

    /// 完了条件 1: 円は (中心を座標のまま) 倍の直径、線の太さは倍の画素で描かれる。
    @Test(
        "倍率 N では、円の面積が N² 倍の画素になり、線は座標の太さの N 倍の画素で刻まれる (2 のべきでない 3 も)",
        arguments: [2, 3])
    func shapesAreDrawnAtTheScaledPixelSize(_ factor: Int) throws {
        func draw(on canvas: Canvas) throws {
            try Self.draw(on: canvas) {
                canvas.background(0)
                canvas.noStroke()
                canvas.fill(255)
                canvas.circle(64, 64, 80)
                canvas.stroke(255)
                canvas.strokeWeight(2)
                canvas.line(8, 12, 120, 12)
            }
        }
        let base = try Self.makeCanvas(scale: 1)
        try draw(on: base)
        let scaled = try Self.makeCanvas(scale: factor)
        try draw(on: scaled)
        let one = try base.output.readPixels()
        let two = try scaled.output.readPixels()
        #expect(two.width == 128 * factor && two.height == 128 * factor)

        func lightness(_ buffer: PixelBuffer, rows: Range<Int>) -> Float {
            var sum: Float = 0
            for y in rows { for x in 0..<buffer.width { sum += buffer[x, y].red } }
            return sum
        }
        // 円 (線より下の行): 面積は π·40² ≈ 5027 画素 (倍率 1)、倍率 2 では 4 倍
        let circle1 = lightness(one, rows: 20..<128)
        let circle2 = lightness(two, rows: 20 * factor..<128 * factor)
        #expect(abs(circle1 - 5027) < 5027 * 0.02, "倍率 1 の円の面積: \(circle1)")
        #expect(
            abs(circle2 / circle1 - Float(factor * factor)) < 0.04 * Float(factor * factor),
            "倍率 \(factor) の円の面積は \(factor * factor) 倍のはず: \(circle2 / circle1)")
        // 線: 中ほどの 1 列を横切る和が、太さ 2 → 倍率 1 で 2 画素・倍率 2 で 4 画素
        func crossing(_ buffer: PixelBuffer, column: Int, rows: Range<Int>) -> Float {
            rows.reduce(0) { $0 + buffer[column, $1].red }
        }
        #expect(abs(crossing(one, column: 30, rows: 0..<20) - 2) < 0.2)
        #expect(abs(crossing(two, column: 30 * factor, rows: 0..<20 * factor) - Float(2 * factor)) < 0.2)
    }

    // MARK: - 形の口

    /// 完了条件 3: 位置・半径・矩形・断片の口は、倍率を掛けて読む。**倍率 2 の絵を 2×2 で平均すると、
    /// 倍率 1 の絵と同じ形** (縁は倍率 1 の画素の半分までずれてよい)。
    @Test(
        "位置・矩形・効果・断片の口は、倍率 2・3 の絵を縮めると倍率 1 の絵と同じ形に出る",
        arguments: DensityInvarianceTests.Outline.allCases, [2, 3])
    func outlineStaysInPlaceUnderScale(_ mouth: DensityInvarianceTests.Outline, _ factor: Int) throws {
        var broken: [String] = []
        for offset in mouth.offsets {
            let base = try Self.makeCanvas(scale: 1)
            try Self.draw(on: base) { try mouth.draw(on: base, offset: offset, reference: false) }
            let full = try base.output.readPixels()
            let scaled = try Self.makeCanvas(scale: factor)
            try Self.draw(on: scaled) { try mouth.draw(on: scaled, offset: offset, reference: false) }
            let shrunk = Self.averaged(try scaled.output.readPixels(), by: factor)
            // 何も描かれない絵どうしを比べて緑にしない
            let whites = full.components.enumerated().filter { $0.offset % 4 == 0 && $0.element > 0.5 }.count
            try #require(
                whites > 0 && whites < Self.size * Self.size,
                "\(mouth.rawValue): 倍率 1 の絵が白黒に分かれない (白 \(whites) 画素)")
            let reference =
                mouth.hasReference
                ? try {
                    let canvas = try Self.makeCanvas(scale: 1)
                    try Self.draw(on: canvas) {
                        try mouth.draw(on: canvas, offset: offset, reference: true)
                    }
                    return try canvas.output.readPixels()
                }() : full
            for threshold in mouth.thresholds {
                let (count, examples) = DensityInvarianceTests.displaced(
                    shrunk, from: reference, threshold: threshold, reach: 1)
                if count > 0 {
                    broken.append(
                        "ずらし \(offset)・濃さ \(threshold): \(count) 画素 (\(examples.joined(separator: " ")))")
                }
            }
        }
        #expect(broken.isEmpty, "\(mouth.rawValue): \(broken.joined(separator: " / "))")
    }

    /// 例 (完了条件 3): `clip(100, 100, 200, 200)` は倍率 2 の面で (200, 200) から 400×400 を切る。
    @Test("clip(100, 100, 200, 200) は、倍率 2 の面で (200, 200) から 400×400 を切る")
    func clipRectangleIsScaled() throws {
        let canvas = try Self.makeCanvas(width: 400, height: 400, scale: 2)
        try Self.draw(on: canvas) {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.clip(100, 100, 200, 200)
            canvas.rect(0, 0, 400, 400)
            canvas.noClip()
        }
        let pixels = try canvas.output.readPixels()
        #expect(pixels.width == 800)
        var lit = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].red > 0.5 {
                lit += 1
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        #expect((minX, minY, maxX, maxY) == (200, 200, 599, 599), "\((minX, minY, maxX, maxY))")
        #expect(lit == 400 * 400)
    }

    /// 例 (完了条件 3): ぼけの幅は、倍率 1 の絵を 2 倍に拡大した絵と揃う (半径 10 → 20 画素ぶん)。
    @Test("blur(radius: 10) の幅は、倍率 2 で 20 画素ぶんになり、倍率 1 の絵を縮めたものと揃う")
    func blurRadiusIsScaled() throws {
        func blurred(scale: Int) throws -> PixelBuffer {
            let canvas = try Self.makeCanvas(scale: scale)
            try Self.draw(on: canvas) {
                canvas.background(0)
                canvas.noStroke()
                canvas.fill(255)
                canvas.rect(40, 40, 48, 48)
                canvas.effects([.blur(radius: 10)])
            }
            return try canvas.output.readPixels()
        }
        let one = try blurred(scale: 1)
        let shrunk = Self.averaged(try blurred(scale: 2), by: 2)
        var worst: Float = 0
        for y in 0..<one.height {
            for x in 0..<one.width {
                worst = max(worst, abs(one[x, y].red - shrunk[x, y].red))
            }
        }
        #expect(worst < 0.03, "ぼけの形が倍率 1 と揃わない: 最大の差 \(worst)")
        // 比べる相手が空でない (ぼけの裾が実際に広がっている)
        #expect(one[64, 64].red > 0.5 && one[36, 64].red > 0.02 && one[36, 64].red < 0.5)
    }

    // MARK: - 字

    /// 完了条件 3: 字は倍率を掛けた画素で焼く。`textSize(24)` は倍率 2 で 48 の大きさ (1 オクターブ上の
    /// 8 段目) で焼き、倍率 1 は段 0。送り幅 (`textWidth`) は座標の単位のまま。
    @Test("textSize(24) の字は、倍率 2 では 48 画素の段 (8) で焼き、textWidth は倍率によらない")
    func glyphsAreBakedAtTheScaledSize() throws {
        func measure(scale: Int) throws -> (step: Int, width: Float) {
            let canvas = try Self.makeCanvas(width: 200, height: 100, scale: scale)
            canvas.textFont("Helvetica")
            var read = (step: -1, width: Float(0))
            try canvas.draw {
                canvas.textSize(24)
                read = (canvas.glyphStep, canvas.textWidth("ZOOM"))
            }
            return read
        }
        let one = try measure(scale: 1)
        let two = try measure(scale: 2)
        let three = try measure(scale: 3)
        // 3 倍 (2 のべきでない) は 8 × log2(3) ≈ 12.7 → 13 段目
        #expect(three.step == 13, "倍率 3 の textSize(24) は 13 段目のはず: \(three.step)")
        #expect(three.width == one.width)
        #expect(one.step == 0)
        #expect(two.step == 8, "倍率 2 の textSize(24) は 48 画素の段 (8) のはず: \(two.step)")
        #expect(one.width > 0 && one.width == two.width, "textWidth は座標の単位のまま: \(one.width) / \(two.width)")
    }

    /// 倍率 2 と細かさ 0.5 は打ち消し合い、字は座標と同じ画素 (段 0) で焼く。
    @Test("倍率 2 と細かさ 0.5 は、字の焼きでは打ち消し合って段 0")
    func scaleAndDensityCancelForGlyphs() throws {
        let canvas = try Self.makeCanvas(width: 200, height: 100, scale: 2, density: 0.5)
        canvas.textFont("Helvetica")
        var step = -1
        try canvas.draw {
            canvas.textSize(24)
            step = canvas.glyphStep
        }
        #expect(step == 0)
    }

    // MARK: - 決定論・上限

    /// 完了条件 5: 同じ引数で 2 度描くと同じ画素になる。
    @Test("倍率 2 で同じ場面を 2 度描くと、同じ画素になる")
    func sameScaleGivesTheSamePixels() throws {
        func render() throws -> PixelBuffer {
            let canvas = try Self.makeCanvas(scale: 2)
            try Self.draw(on: canvas) {
                canvas.background(20)
                canvas.fill(255, 120, 40)
                canvas.circle(50, 60, 70)
                canvas.stroke(255)
                canvas.strokeWeight(3)
                canvas.line(10, 10, 118, 100)
                canvas.effects([.blur(radius: 3)])
            }
            return try canvas.output.readPixels()
        }
        #expect(try render() == render())
    }

    /// 完了条件 4: 倍率を掛けた大きさが面の一辺の上限 (16384) を越える組は、描く前に、掛けた大きさを名乗って断る。
    @Test("倍率を掛けた大きさが 16384 を越えると、掛けた大きさで invalidSize")
    func oversizedOutputIsRefused() throws {
        let gpu = try RenderDevice()
        #expect(throws: RenderFailure.invalidSize(width: 20000, height: 10000)) {
            _ = try SketchRuntime.outputTarget(gpu: gpu, width: 10000, height: 5000, scale: 2)
        }
        // 上限ちょうどは通る (幅だけ上限・高さは小さく)
        let edge = try SketchRuntime.outputTarget(gpu: gpu, width: 8192, height: 4, scale: 2)
        #expect(edge.width == 16384 && edge.height == 8)
        // 桁あふれする値も、落ちずに断る
        #expect(throws: RenderFailure.self) {
            _ = try SketchRuntime.outputTarget(gpu: gpu, width: .max, height: 4, scale: 2)
        }
    }
}
