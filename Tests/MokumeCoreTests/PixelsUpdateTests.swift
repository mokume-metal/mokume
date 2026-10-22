// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 全画素を 1 つの関数で書き換える口 (`Pixels.update`) と `Image.pixels` ([#2450])。
///
/// 意味は添字 (`pixels[x, y]`) と同じで、違いは費用である — 書いてよいかの判定と GPU の決着を
/// 入口で 1 回にする。期待値は、添字の 2 重ループで同じ式を書いた結果から取る。
///
/// [#2450]: https://github.com/mokume-metal/mokume/issues/2450
@Suite(
    "画素の一括の書き換え",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PixelsUpdateTests {
    private let black = Color.linear(red: 0, green: 0, blue: 0)
    private let red = Color.linear(red: 1, green: 0, blue: 0)

    private func makeCanvas(width: Int = 32, height: Int = 32) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// 半精度の面へ書いて読み直した値。期待値は、面が表せる丸めを通してから比べる。
    private func quantized(_ color: Color, on canvas: Canvas) throws -> Color {
        let scratch = try canvas.createImage(1, 1)
        scratch.set(0, 0, color)
        return scratch.get(0, 0)
    }

    // MARK: - Image.pixels (条件 1)

    @Test("2×1 の絵を明るさで 2 値にすると、暗い方は黒・明るい方は白になる")
    func thresholdingATwoPixelImage() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 1)
        image.set(0, 0, color(64))
        image.set(1, 0, color(200))
        try #require(brightness(image.get(0, 0)) < 50 && brightness(image.get(1, 0)) > 50)

        image.pixels.update { _, _, c in brightness(c) > 50 ? color(255) : color(0) }

        #expect(image.get(0, 0) == color(0))
        #expect(image.get(1, 0) == color(255))
    }

    @Test("3×2 の絵へ位置から決めた色を書くと、各画素が渡した座標の値になる")
    func coordinatesAreTheSameAsTheSubscript() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(3, 2)
        image.pixels.update { x, y, _ in color(Float(x * 10 + y)) }

        for y in 0..<2 {
            for x in 0..<3 {
                let expected = try quantized(color(Float(x * 10 + y)), on: canvas)
                #expect(image.get(x, y) == expected, "(\(x), \(y))")
                #expect(image.pixels[x, y] == expected, "窓の添字が get と違う (\(x), \(y))")
            }
        }
    }

    @Test("閉包が受ける色は、その画素のいまの色である")
    func theClosureReceivesTheCurrentColor() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(3, 3)
        for y in 0..<3 { for x in 0..<3 { image.set(x, y, color(Float(x * 40 + y * 3))) } }
        var seen: [Color] = []
        var visited: [[Int]] = []
        image.pixels.update { x, y, c in
            visited.append([x, y])
            seen.append(c)
            return c
        }

        #expect(visited == (0..<3).flatMap { y in (0..<3).map { [$0, y] } }, "上の行から左から右へ回っていない")
        #expect(seen == (0..<3).flatMap { y in (0..<3).map { image.get($0, y) } })
    }

    @Test("絵の窓の fill と添字は、絵の fill・set と同じ画素を書く")
    func theImageWindowAgreesWithTheImage() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(4, 4)
        image.pixels.fill(red)
        #expect(image.get(2, 2) == red)
        image.pixels[1, 1] = black
        #expect(image.get(1, 1) == black)
        #expect(image.pixels.count == 16)
        #expect(image.pixels.width == 4 && image.pixels.height == 4)
    }

    @Test("書き換えは送り直す印を立て、描くと書き換えた絵が出る")
    func anUpdatedImageIsSentToTheSurface() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        let image = try canvas.createImage(8, 8)
        image.fill(black)
        // 一度描いて、送り直しの印を下ろす。印が立っていたままでは、書き換えが印を立てたか見えない
        try canvas.draw { canvas.image(image, 0, 0, 8, 8) }
        try #require(!image.needsUpload, "送り直しの印が下りていない — この検査は何も見ていない")

        image.pixels.update { _, _, _ in Color.linear(red: 0, green: 1, blue: 0) }
        #expect(image.needsUpload)

        try canvas.draw {
            canvas.background(black)
            canvas.image(image, 0, 0, 8, 8)
        }
        #expect(canvas.get(4, 4) == Color.linear(red: 0, green: 1, blue: 0))
    }

    @Test("大きな入力 (復号を遅らせた絵) でも、書き換えは入力を読んだ値から始まる")
    func updatingALargeDisplayInput() throws {
        let canvas = try makeCanvas()
        let width = 1100
        let height = 1000
        let image = try canvas.createImage(width, height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) { bytes[index * 4 + 3] = 255 }
        bytes[(3 * width + 5) * 4] = 255
        image.write(DisplayImage(width: width, height: height, bytes: bytes))
        try #require(image.displayInput != nil, "大きな入力が値で保たれていない — この検査は何も見ていない")

        var marked = 0
        image.pixels.update { x, y, c in
            if c.premultipliedRed > 0.5 {
                marked += 1
                #expect(x == 5 && y == 3)
            }
            return c
        }
        #expect(marked == 1)
        #expect(image.displayInput == nil)
        #expect(image.get(5, 3).premultipliedRed > 0.5)
    }

    @Test("閉包の中で同じ絵を読んでも落ちない")
    func readingTheSameImageInsideTheClosureDoesNotTrap() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(4, 4)
        image.fill(red)
        image.pixels.update { x, y, c in
            _ = image.get(x + 1, y)
            image.set(0, 0, black)
            return c
        }
        #expect(image.get(2, 2) == red)
    }

    // MARK: - 費用 (条件 2)

    @Test("1280×720 の本体を 1 つの関数で書き換えても、GPU の決着は画素の数に比例しない")
    func updateSettlesOnceAtTheEntrance() throws {
        let canvas = try makeCanvas(width: 1280, height: 720)
        var calls = 0
        var settles = 0
        try canvas.draw {
            canvas.background(red)
            let before = canvas.gpu.settleCalls
            canvas.pixels.update { _, _, c in
                calls += 1
                return c
            }
            settles = canvas.gpu.settleCalls - before
        }
        try #require(calls == 1280 * 720, "全画素を回っていない — この検査は何も見ていない")
        #expect(settles <= 1, "画素ごとに決着を頼んでいる: \(settles) 回 / \(calls) 画素")
    }

    /// 書いてよいかの尋ねは、全画素を回る前に **1 度だけ** — 画素ごとに尋ねると、添字の 2 重ループと
    /// 同じ費用になる。尋ねる先を数える窓 (面を通さない・GPU を要さない) で見る。
    @Test("書いてよいかの尋ねは、画素の数にかかわらず入口で 1 回で、断られれば閉包を呼ばない")
    func theGateIsAskedOncePerCall() {
        let width = 7
        let height = 5
        let memory = UnsafeMutablePointer<SIMD4<Float16>>.allocate(capacity: width * height)
        memory.initialize(repeating: .zero, count: width * height)
        defer { memory.deallocate() }
        var asked = 0
        var admit = true
        let window = Pixels(
            base: UnsafeMutableRawPointer(memory), width: width, height: height,
            bytesPerRow: width * MemoryLayout<SIMD4<Float16>>.stride, mirror: nil,
            admitsWrite: {
                asked += 1
                return admit
            })

        var calls = 0
        window.update { _, _, _ in
            calls += 1
            return red
        }
        #expect(asked == 1, "画素ごとに尋ねている: \(asked) 回")
        #expect(calls == width * height)
        #expect(window[3, 2] == red)

        let askedBefore = asked
        admit = false
        window.update { _, _, _ in
            calls += 1
            return black
        }
        #expect(asked == askedBefore + 1)
        #expect(calls == width * height, "断られたのに閉包を呼んだ")
        #expect(window[3, 2] == red, "断られたのに書いた")
    }

    // MARK: - 意味は添字と同じ (条件 3・4)

    /// 本体の形 (`Sketches/PixelsAndPaint.swift` の右半分を赤と青で入れ替える書き方)。
    @Test("一括の書き換えは、同じ式を添字の 2 重ループで書いた結果と画素まで一致する")
    func updateMatchesTheDoubleLoop() throws {
        func draw(_ canvas: Canvas, _ rewrite: () -> Void) throws {
            try canvas.draw {
                canvas.background(.display(red: 0.1, green: 0.1, blue: 0.2))
                canvas.noStroke()
                canvas.fill(Color(straightRed: 1, green: 0.4, blue: 0.2, alpha: 0.5))
                canvas.circle(24, 20, 30)
                rewrite()
            }
        }
        let width = 64
        let height = 48
        let looped = try makeCanvas(width: width, height: height)
        let bulk = try makeCanvas(width: width, height: height)

        try draw(looped) {
            for y in 0..<height {
                for x in 32..<width {
                    let mix = Float(x - 32) / 32
                    let c = looped.pixels[x, y]
                    looped.pixels[x, y] = Color(
                        premultipliedRed: c.premultipliedRed * (1 - mix) + c.premultipliedBlue * mix, green: c.premultipliedGreen,
                        blue: c.premultipliedBlue * (1 - mix) + c.premultipliedRed * mix, alpha: c.alpha)
                }
            }
        }
        try draw(bulk) {
            bulk.pixels.update { x, _, c in
                guard x >= 32 else { return c }
                let mix = Float(x - 32) / 32
                return Color(
                    premultipliedRed: c.premultipliedRed * (1 - mix) + c.premultipliedBlue * mix, green: c.premultipliedGreen,
                    blue: c.premultipliedBlue * (1 - mix) + c.premultipliedRed * mix, alpha: c.alpha)
            }
        }
        // 左半分が元のままで、右半分が書き換わっていること (何も書いていなければ一致は自明)
        try #require(bulk.get(10, 20) == looped.get(10, 20))
        try #require(bulk.get(60, 20) != black)

        #expect(try bulk.target.readPixels() == looped.target.readPixels())
    }

    @Test("区間の外では、閉包を 1 度も呼ばずに 1 度だけ注意して何もしない")
    func outsideTheRegionNothingIsCalled() throws {
        let canvas = try makeCanvas()
        var calls = 0
        let before = canvas.get(2, 2)
        canvas.pixels.update { _, _, _ in
            calls += 1
            return red
        }
        canvas.pixels.update { _, _, _ in
            calls += 1
            return red
        }

        #expect(calls == 0, "区間の外で閉包を呼んだ")
        #expect(
            canvas.warnings.message(for: .pixelWriteOutsideFrame)
                == Canvas.OutsideFrame.pixelWrite.drawingTargetNotice)
        #expect(canvas.get(2, 2) == before)
    }

    @Test("形の組み立ての中では、閉包を 1 度も呼ばずに注意して何もしない")
    func insideAShapeNothingIsCalled() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        var calls = 0
        try canvas.draw {
            canvas.background(black)
            _ = canvas.createShape {
                canvas.circle(8, 8, 8)
                canvas.pixels.update { _, _, _ in
                    calls += 1
                    return red
                }
            }
        }
        #expect(calls == 0, "組み立ての中で閉包を呼んだ")
        #expect(canvas.warnings.hasWarned(.pixelsInsideShape))
        #expect(canvas.get(2, 2) == black)
    }

    @Test("前のフレームで取った窓でも、許可は呼んだ時点で見る")
    func aKeptWindowAsksAtCallTime() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        var window: Pixels?
        try canvas.draw {
            canvas.background(black)
            window = canvas.pixels
        }
        var calls = 0
        window?.update { _, _, _ in
            calls += 1
            return red
        }
        #expect(calls == 0, "区間の外で、取っておいた窓が閉包を呼んだ")

        try canvas.draw {
            canvas.background(black)
            window?.update { _, _, _ in
                calls += 1
                return red
            }
        }
        #expect(calls == 16 * 16, "区間の中では書ける")
        #expect(canvas.get(3, 3) == red)
    }

    @Test("前のフレームで取った窓で書き換えても、効果は 1 回だけ掛かる")
    func effectsAreAppliedOnceWhenAKeptWindowUpdates() throws {
        func secondFrame(updates: Bool) throws -> Color {
            let canvas = try makeCanvas(width: 16, height: 16)
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.fill(.linear(red: 1, green: 1, blue: 1))
                canvas.rect(0, 0, 8, 16)
                canvas.effects([.invert()])
            }
            let window = canvas.pixels
            try canvas.draw {
                if updates { window.update { _, _, c in c } }
                canvas.effects([.invert()])
            }
            return canvas.get(4, 8)
        }
        #expect(try secondFrame(updates: true) == secondFrame(updates: false))
    }

    @Test("大きさ 0 の窓では、閉包を呼ばずに何も起きない")
    func anUnavailableWindowCallsNothing() {
        var calls = 0
        Pixels.unavailable.update { _, _, c in
            calls += 1
            return c
        }
        #expect(calls == 0)
    }

    @Test("1×1 の面でも、1 度だけ呼ばれる")
    func aSinglePixelIsVisitedOnce() throws {
        let canvas = try makeCanvas(width: 1, height: 1)
        var calls = 0
        try canvas.draw {
            canvas.background(black)
            canvas.pixels.update { x, y, _ in
                calls += 1
                #expect(x == 0 && y == 0)
                return red
            }
        }
        #expect(calls == 1)
        #expect(canvas.get(0, 0) == red)
    }
}
