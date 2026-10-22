// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing

@testable import MokumeCore

/// 拡大した字を、拡大に合わせた画素で焼く ([#2446])。GPU を要する。
///
/// 焼く大きさは「`textSize` × いまの変換の拡大」を段 (1 オクターブを 8 段) に丸めたもので、字形の形と並びは
/// `textSize` のまま変わらない。拡大が 1 以下の絵は、これまでと同じ焼き方 (段 0) を通る。
///
/// 見るのは、変換から決まる段・焼き場の鍵・描いた縁の鮮明さ・送り幅が拡大で変わらないこと・
/// 1 フレームに新しく焼く数の上限 (越えた分は近い段で描く・初めて出る字は上限に関わらず焼く)。
///
/// [#2446]: https://github.com/mokume-metal/mokume/issues/2446
@Suite(
    "拡大した字の焼き",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct GlyphScaleBakeTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    private func makeCanvas(width: Int = 128, height: Int = 128) throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        canvas.textFont("Helvetica")
        return canvas
    }

    /// 変換を掛けて 1 フレームを描き、その中で段を読む。
    private func step(
        _ canvas: Canvas, textSize: Float = 24, _ transform: (Canvas) -> Void
    ) throws -> Int {
        var read = -1
        try canvas.draw {
            canvas.textSize(textSize)
            transform(canvas)
            read = canvas.glyphStep
        }
        return read
    }

    // MARK: - 変換から決まる段

    /// 完了条件 1: `textSize(24)` の字は、`scale(4)` で 96 の段 (1 オクターブ 8 段の 16 段目)、`scale(4.01)` で
    /// 同じ段、`scale(1)` で段 0 (24 のまま)。
    @Test("段は拡大を対数で丸めたもの: 4 倍は 16 段目で、4.01 倍も同じ段、1 倍は 0")
    func stepRoundsTheStretchOnALogScale() throws {
        let canvas = try makeCanvas()
        #expect(try step(canvas) { $0.scale(4, 4) } == 16)
        #expect(try step(canvas) { $0.scale(4.01, 4.01) } == 16)
        #expect(try step(canvas) { $0.scale(9, 9) } == 25)
        #expect(GlyphAtlas.ratio(ofStep: 16) == 4)
        #expect(GlyphAtlas.ratio(ofStep: 0) == 1)
        #expect(try step(canvas) { $0.scale(1, 1) } == 0)
    }

    /// 境界: 1 以下の拡大・回転だけ・1 の外の丸め (1.04 倍は 0 段に丸まる) は段 0 で、焼き直さない。
    @Test("拡大が 1 以下の変換と、回転だけの変換は段 0")
    func noStretchStaysAtStepZero() throws {
        let canvas = try makeCanvas()
        #expect(try step(canvas) { $0.scale(0.5, 0.5) } == 0)
        #expect(try step(canvas) { $0.rotate(Float.pi / 3) } == 0)
        #expect(try step(canvas) { $0.scale(1.04, 1.04) } == 0)
        #expect(try step(canvas) { $0.translate(30, 40) } == 0)
    }

    /// 拡大は 2×2 の最大の伸び: 軸ごとに違う倍率なら大きいほう、拡大して回しても伸びの大きさ。
    @Test("拡大は変換の最大の伸びで取る")
    func theStretchIsTheLargestSingularValue() throws {
        let canvas = try makeCanvas()
        // 3 倍と 1 倍 → 3 倍 (8 × log2(3) ≈ 12.7 → 13)
        #expect(try step(canvas) { $0.scale(3, 1) } == 13)
        // 回しても伸びは変わらない
        #expect(try step(canvas) { c in c.rotate(0.7); c.scale(4, 4) } == 16)
        #expect(try step(canvas) { c in c.scale(4, 4); c.rotate(0.7) } == 16)
    }

    /// 焼く大きさの上限: 1 字の em は 2048 画素まで。`textSize(1000)` は 2 倍強 (8 段 × log2(2.048)) まで。
    @Test("段は、1 字の em が 2048 画素を超えないところで頭打ちになる")
    func theStepIsCapped() throws {
        let canvas = try makeCanvas()
        #expect(try step(canvas, textSize: 1000) { $0.scale(100, 100) } == 8)
        #expect(try step(canvas, textSize: 4000) { $0.scale(100, 100) } == 0)
    }

    // MARK: - 焼き場の鍵

    private func entryExists(_ canvas: Canvas, _ scalar: Unicode.Scalar, size: Float, step: Int) -> Bool {
        guard let resolved = canvas.typeface.glyph(for: scalar) else { return false }
        return canvas.atlas.cachedEntry(for: canvas.glyphKey(for: resolved, step: step)) != nil
    }

    /// 完了条件 1: 拡大した字は段の鍵で焼かれ、同じ段の拡大は焼き直さない。拡大しない字は段 0。
    @Test("拡大した字は段の鍵で焼かれ、同じ段なら焼き直さない")
    func scaledGlyphsAreBakedUnderTheirStep() throws {
        let canvas = try makeCanvas(width: 200, height: 200)
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(24)
            canvas.translate(10, 150)
            canvas.scale(4, 4)
            canvas.text("M", 0, 0)
        }
        #expect(entryExists(canvas, "M", size: 24, step: 16), "96 画素の段で焼いていない")
        #expect(!entryExists(canvas, "M", size: 24, step: 0), "24 画素でも焼いている")
        let baked = canvas.atlas.bakedCount

        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(24)
            canvas.translate(10, 150)
            canvas.scale(4.01, 4.01)
            canvas.text("M", 0, 0)
        }
        #expect(canvas.atlas.bakedCount == baked, "同じ段の拡大で焼き直した")

        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(24)
            canvas.text("M", 10, 100)
        }
        #expect(entryExists(canvas, "M", size: 24, step: 0), "拡大しない字を段 0 で焼いていない")
        #expect(canvas.atlas.bakedCount == baked + 1)
    }

    // MARK: - 絵

    /// 縦の棒 (`I`) の真ん中の行で、墨と地の間にある画素 (縁のなだらかさ) を数える。
    private func edgePixels(_ image: DisplayImage, row: Int) -> Int {
        var count = 0
        for x in 0..<image.width {
            let value = Int(image[x, row].red)
            if value > 20 && value < 235 { count += 1 }
        }
        return count
    }

    /// 完了条件 1・3 の絵: 8 倍に拡大した `I` の縁が鮮明 (棒の左右の縁で、中間の明るさの画素が数画素に収まる)。
    /// 以前は 12 画素で焼いた字を 8 倍に伸ばしたので、縁が 8 画素ほどにぼけた。
    @Test("拡大した字の縁は鮮明で、伸ばしてぼけない")
    func scaledGlyphEdgesAreSharp() throws {
        let canvas = try makeCanvas(width: 160, height: 160)
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(12)
            canvas.translate(60, 140)
            canvas.scale(8, 8)
            canvas.text("I", 0, 0)
        }
        let image = try canvas.target.encodeForDisplay()
        let row = 100
        let inked = (0..<image.width).filter { image[$0, row].red > 200 }.count
        #expect(inked >= 6, "検査の前提: 棒に墨が乗っていない (\(inked))")
        let soft = edgePixels(image, row: row)
        #expect(soft <= 4, "縁の中間の画素が \(soft) ある — 伸ばしてぼけている")
    }

    /// 完了条件 2: 送り幅・整列は拡大で変わらない (`textSize` のまま)。
    @Test("textWidth は拡大の下でも変わらない")
    func textWidthIsIndependentOfTheStretch() throws {
        let canvas = try makeCanvas()
        var plain: Float = 0
        var scaled: Float = 0
        try canvas.draw {
            canvas.textSize(24)
            plain = canvas.textWidth("ZOOM")
            canvas.scale(9, 9)
            scaled = canvas.textWidth("ZOOM")
        }
        #expect(plain > 0)
        #expect(plain == scaled)
    }

    // MARK: - 1 フレームに新しく焼く数の上限

    private func drawSix(_ canvas: Canvas, scale: Float) throws -> Int {
        let before = canvas.glyphQuadsPlaced
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(16)
            canvas.translate(4, 60)
            canvas.scale(scale, scale)
            canvas.text("abcdef", 0, 0)
        }
        return canvas.glyphQuadsPlaced - before
    }

    /// 完了条件 5: 上限を越えた分は、焼いてある近い段で描く (欠けない)。次のフレームでまた上限まで焼く。
    @Test("1 フレームに新しく焼く数の上限を越えた分は、近い段で描いて欠けない")
    func bakesPerFrameAreCappedWithoutDroppingGlyphs() throws {
        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 2
        // 初めて出る 6 字は、上限に関わらず 2 倍の段で焼く
        #expect(try drawSix(canvas, scale: 2) == 6)
        #expect(canvas.atlas.bakedCount == 6)
        // 拡大を動かす: 段が変わる。新しく焼くのは上限の 2 字で、残り 4 字は焼いてある段で描く。6 字とも置かれる
        let baked = canvas.atlas.bakedCount
        #expect(try drawSix(canvas, scale: 2.5) == 6, "上限を越えた字が欠けた")
        #expect(canvas.atlas.bakedCount == baked + 2, "上限を越えて焼いた: \(canvas.atlas.bakedCount - baked)")
        // 続けるとまた 2 字ずつ焼き、3 フレームで全部が新しい段に揃う
        #expect(try drawSix(canvas, scale: 2.5) == 6)
        #expect(try drawSix(canvas, scale: 2.5) == 6)
        #expect(canvas.atlas.bakedCount == baked + 6)
        let settled = canvas.atlas.bakedCount
        #expect(try drawSix(canvas, scale: 2.5) == 6)
        #expect(canvas.atlas.bakedCount == settled, "揃った後は焼き直さない")
    }

    /// 境界: 上限が 0 でも、焼いてある近い段が無い (初めて出る) 字は焼く。欠けず、ぼけたまま残らない。
    @Test("初めて出る字は、上限が 0 でも拡大した段で焼く")
    func firstAppearancesIgnoreTheCap() throws {
        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 0
        #expect(try drawSix(canvas, scale: 4) == 6)
        #expect(entryExists(canvas, "a", size: 16, step: 16))
        #expect(canvas.atlas.bakedCount == 6)
    }
}
