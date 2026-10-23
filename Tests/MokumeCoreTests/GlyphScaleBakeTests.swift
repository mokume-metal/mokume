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
/// 見るのは、変換から決まる段 (細かさを掛ける)・焼き場の鍵・描いた縁の鮮明さ・送り幅が拡大で変わらないこと・
/// 1 字の大きさと 1 フレームの量と面の割合の上限 (越えた分は欠けずに低い段か近い段で描く・先送りした字は
/// 次のフレームで先に焼く・次のフレームが来ない面は上限を外す)。
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

    // MARK: - 細かさ・桁あふれ

    private func makeDensityCanvas(width: Int = 128, height: Int = 128, density: Float) throws -> Canvas {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: width, height: height)
        let canvas = try Canvas(output: output, gpu: gpu, pixelDensity: density, upscale: .spatial)
        canvas.textFont("Helvetica")
        return canvas
    }

    /// 反証 2: 段は出す画素での伸びではなく、**描く画素での伸び**で決まる。細かさ 0.5 の `scale(2)` は、
    /// 描く画素では 1 対 1 で、段 0 (以前と同じ)。2 倍で焼いて 1/2 に縮めて読まない。
    @Test("細かさを下げた面では、描く画素での伸びで段を決める")
    func theStepFollowsTheDrawnPixels() throws {
        let canvas = try makeDensityCanvas(density: 0.5)
        #expect(try step(canvas) { $0.scale(2, 2) } == 0, "細かさ 0.5 の scale(2) は描く画素で 1 対 1 のはず")
        #expect(try step(canvas) { $0.scale(1, 1) } == 0)
        // 描く画素で 2 倍 = 出す画素で 4 倍 → 8 段
        #expect(try step(canvas) { $0.scale(4, 4) } == 8)
        #expect(try step(makeCanvas()) { $0.scale(2, 2) } == 8, "検査の前提: 細かさ 1 の scale(2) は 8 段")
    }

    @Test("細かさ 0.5 の scale(2) の字は、段 0 の画素で焼く (2 倍で焼いて縮めない)")
    func halfDensityDoesNotBakeLargerThanItDraws() throws {
        let canvas = try makeDensityCanvas(width: 200, height: 200, density: 0.5)
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(24)
            canvas.scale(2, 2)
            canvas.text("M", 10, 60)
        }
        #expect(bakedSteps(canvas, "M") == [0], "描く画素と 1 対 1 のはずが、段 \(bakedSteps(canvas, "M")) で焼いた")
    }

    /// 反証 11: 変換の成分が桁違いに大きくても、拡大は 1 に化けず、頭打ちの段になる (`splitScale(of:)` は倍精度)。
    @Test("巨大な拡大でも、段は 0 に化けずに頭打ちの段になる")
    func hugeStretchDoesNotWrapToStepZero() throws {
        let canvas = try makeCanvas()
        let limit = try step(canvas) { $0.scale(100, 100) }
        #expect(limit > 0)
        #expect(try step(canvas) { $0.scale(1e20, 1e20) } == limit, "巨大な拡大が頭打ちの段にならない")
        #expect(try step(canvas) { $0.scale(1e30, 1e30) } == limit)
    }

    // MARK: - 1 字の大きさ・頁の割合

    /// その字が焼いてある段。**鍵は `textSize` を含む**ので、焼いたときの大きさに合わせて引く。
    private func bakedSteps(_ canvas: Canvas, _ scalar: Unicode.Scalar, size: Float? = nil) -> [Int] {
        if let size { canvas.textSize(size) }
        return (0...200).filter { entryExists(canvas, scalar, size: 0, step: $0) }
    }

    /// 反証 3・4・8: 1 字の画素が上限 (`pendingByteLimit`) を越える段は焼かず、収まる段まで下げる。
    /// 字は欠けず、下げたことは拡大が原因だと名乗って知らせ、頼んだ段の控えへ決まった答えとして入れる
    /// (次のフレームで外接矩形と大きさの判定をやり直さない)。
    @Test("1 字の画素が上限を越える段は、収まる段まで下げて描き、拡大を名乗って知らせる")
    func oversizedStepsAreLoweredToFit() throws {
        let canvas = try makeCanvas(width: 200, height: 200)
        let wanted = try step(canvas) { $0.scale(60, 60) }
        func drawOne() throws {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textSize(24)
                canvas.scale(60, 60)
                canvas.text("M", 0, 0)
            }
        }
        try drawOne()
        let steps = bakedSteps(canvas, "M")
        #expect(steps.count == 1, "1 つの段だけを焼くはず: \(steps)")
        let baked = try #require(steps.first)
        #expect(baked > 0 && baked < wanted, "頼んだ段 \(wanted) より低く、段 0 より上の段で焼くはず: \(baked)")
        let resolved = try #require(canvas.typeface.glyph(for: "M"))
        let plan = canvas.atlas.plan(for: canvas.glyphKey(for: resolved, step: wanted), font: resolved.font)
        #expect(plan.step == baked)
        #expect(plan.bytes <= canvas.atlas.scaledBakeByteLimit, "1 字が上限のバイト数を越えた (\(plan.bytes))")
        let above = canvas.atlas.plan(for: canvas.glyphKey(for: resolved, step: baked + 1), font: resolved.font)
        #expect(above.step == baked, "収まる中で最も高い段のはず")
        let message = try #require(canvas.warnings.message(for: .softEnlargedText), "拡大が原因だと知らせていない")
        #expect(message.contains("textSize() times scale()"), "原因を名乗っていない: \(message)")
        #expect(canvas.warnings.message(for: .atlasFullInOneFrame) == nil)

        // 次のフレームは書体の控えから引く: 外接矩形の判定 (CPU の描き直し・焼き場の引き直し) をやり直さない
        let renders = canvas.atlas.cpuRenders
        let quads = canvas.glyphQuadsPlaced
        try drawOne()
        #expect(canvas.glyphQuadsPlaced == quads + 1, "字が欠けた")
        #expect(canvas.atlas.cpuRenders == renders)
        #expect(
            canvas.typeface.placedScaled[ScaledGlyphKey(scalar: "M", step: wanted)] != nil,
            "段を下げた字を、頼んだ段の控えへ入れていない")
    }

    /// 反証 3: 拡大した字で頁が溢れても、そのフレームの後の字 (拡大しない小さなラベルも) は欠けない。
    /// 以前は伸ばして全部描けたので、それを下回らない。
    @Test("拡大した字で頁が溢れても、後の字は欠けない")
    func overflowingEnlargedGlyphsDoNotDropLaterText() throws {
        let canvas = try makeCanvas(width: 200, height: 200)
        let all = (33...126).compactMap { Unicode.Scalar($0).map(String.init) }.joined()
        let before = canvas.glyphQuadsPlaced
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(60)
            canvas.pushMatrix()
            canvas.scale(20, 20)
            canvas.text(all, 0, 0)
            canvas.popMatrix()
            canvas.textSize(12)
            canvas.text("LABELSok", 4, 190)
        }
        #expect(canvas.glyphQuadsPlaced - before == all.count + 8, "字が欠けた: \(canvas.glyphQuadsPlaced - before)")
        // 検査の前提: 拡大した段で焼けた字もあれば、頁が足りず低い段に下がった字もある (頁が溢れた)
        let enlarged = all.unicodeScalars.filter { bakedSteps(canvas, $0, size: 60).contains { $0 > 0 } }.count
        #expect(enlarged > 0 && enlarged < all.count, "頁が溢れず、検査が場面に当たっていない (拡大した段の字: \(enlarged))")
        #expect(
            canvas.warnings.message(for: .atlasFullInOneFrame) == nil,
            "字は欠けていないのに、欠けると名乗る知らせが出た")
        #expect(canvas.warnings.message(for: .softEnlargedText) != nil, "拡大が原因だと名乗る知らせが出ていない")
    }

    // MARK: - 1 フレームに新しく焼く量の上限

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

    private func scaledBakedCount(_ canvas: Canvas, _ text: String = "abcdef") -> Int {
        text.unicodeScalars.filter { scalar in bakedSteps(canvas, scalar).contains { $0 > 0 } }.count
    }

    /// 完了条件 5: 次のフレームが来る面は、上限を越えた分を焼いてある近い段 (無ければ段 0) で描いて欠けず、
    /// 次のフレームで先に焼く。3 フレームで全部が新しい段に揃う。
    @Test("1 フレームに新しく焼く数の上限を越えた分は、欠けずに描いて次のフレームへ送る")
    func bakesPerFrameAreCappedWithoutDroppingGlyphs() throws {
        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 2
        canvas.atlas.mayDeferScaledBakes = true
        // 初めて出る 6 字: 拡大した段で焼くのは上限の 2 字で、残り 4 字は段 0 で焼いて描く。6 字とも置かれる
        #expect(try drawSix(canvas, scale: 2) == 6, "上限を越えた字が欠けた")
        #expect(scaledBakedCount(canvas) == 2, "上限を越えて焼いた: \(scaledBakedCount(canvas))")
        // 次のフレームは、先送りした字を先に焼く (新しい字に先を越させない)
        #expect(try drawSix(canvas, scale: 2) == 6)
        #expect(scaledBakedCount(canvas) == 4)
        #expect(try drawSix(canvas, scale: 2) == 6)
        #expect(scaledBakedCount(canvas) == 6)
        let settled = canvas.atlas.bakedCount
        #expect(try drawSix(canvas, scale: 2) == 6)
        #expect(canvas.atlas.bakedCount == settled, "揃った後は焼き直さない")
        #expect(canvas.atlas.owedGlyphCount == 0)
    }

    /// 反証 5: 速くズームしても、描く順で後ろの字がいつまでも焼かれないことは無い。先送りした字が枠を先に
    /// 使うので、後ろの字も数フレームのうちに拡大した段で焼かれる。
    @Test("拡大を動かし続けても、描く順で後ろの字が焼かれない (飢餓) ことは無い")
    func laterGlyphsAreNotStarvedWhileZooming() throws {
        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 2
        canvas.atlas.mayDeferScaledBakes = true
        // 毎フレーム段が変わる速さで拡大する
        var scale: Float = 2
        var firstBaked: [Unicode.Scalar: Int] = [:]
        for frame in 1...6 {
            #expect(try drawSix(canvas, scale: scale) == 6)
            for scalar in "abcdef".unicodeScalars where firstBaked[scalar] == nil {
                if bakedSteps(canvas, scalar).contains(where: { $0 > 0 }) { firstBaked[scalar] = frame }
            }
            scale *= 1.2
        }
        // 6 字を 1 フレーム 2 字ずつ焼くので、3 フレームで一巡する
        #expect((firstBaked["f"] ?? 99) <= 3, "後ろの字が一巡のうちに焼かれていない: \(firstBaked)")
        #expect((firstBaked["e"] ?? 99) <= 3, "後ろの字が一巡のうちに焼かれていない: \(firstBaked)")
    }

    /// 反証 6: 頁を替えた直後 (焼いた字形が全部消える) も上限が効く。全部が「初めて出る字」になって
    /// 上限が外れ、1 フレームに全部を拡大した段で焼くことはしない。
    @Test("頁を替えた直後も上限が効き、字は欠けない")
    func rebakeStillObeysTheCap() throws {
        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 2
        canvas.atlas.mayDeferScaledBakes = true
        for _ in 0..<3 { _ = try drawSix(canvas, scale: 4) }
        #expect(scaledBakedCount(canvas) == 6, "検査の前提: 3 フレームで揃うはず")

        try canvas.atlas.rebake(gpu: canvas.gpu)
        #expect(canvas.atlas.bakedCount == 0, "検査の前提")
        #expect(try drawSix(canvas, scale: 4) == 6, "頁を替えた直後に字が欠けた")
        #expect(scaledBakedCount(canvas) == 2, "頁を替えた直後に上限を越えて焼いた: \(scaledBakedCount(canvas))")
        for _ in 0..<2 { #expect(try drawSix(canvas, scale: 4) == 6) }
        #expect(scaledBakedCount(canvas) == 6, "3 フレームで揃うはず")
    }

    /// 反証 7: 次のフレームが来ない面 (1 枚だけの書き出し・止めたフレーム) は上限を外し、先送りせずに
    /// 要る段で焼き切る — 段 0 が焼いてあっても、ぼけたまま残らない。
    @Test("次のフレームが来ない面は、上限を外して要る段で焼き切る")
    func theLastFrameBakesEverythingAtTheNeededStep() throws {
        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 2
        // 段 0 を焼いておく
        #expect(try drawSix(canvas, scale: 1) == 6)
        #expect(scaledBakedCount(canvas) == 0)
        // 次が来る面なら、上限の 2 字だけ
        canvas.atlas.mayDeferScaledBakes = true
        #expect(try drawSix(canvas, scale: 2) == 6)
        #expect(scaledBakedCount(canvas) == 2)
        // 次が来ない面 (止めた・最後の 1 枚): 新しい拡大でも、残りを全部その段で焼く
        canvas.atlas.mayDeferScaledBakes = false
        #expect(try drawSix(canvas, scale: 4) == 6)
        for scalar in "abcdef".unicodeScalars {
            #expect(entryExists(canvas, scalar, size: 16, step: 16), "\(scalar) を 4 倍の段で焼いていない")
        }
    }

    /// 境界: 上限が 0 でも、次のフレームが来ない面は焼く。欠けず、ぼけたまま残らない。
    @Test("次のフレームが来ない面は、上限が 0 でも拡大した段で焼く")
    func theCapDoesNotApplyWithoutAFollowingFrame() throws {
        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 0
        #expect(try drawSix(canvas, scale: 4) == 6)
        #expect(entryExists(canvas, "a", size: 16, step: 16))
        #expect(canvas.atlas.bakedCount == 6)
    }

    // MARK: - 走らせる側が立てる旗

    final class Idle: Sketch {
        var settings: SketchSettings { SketchSettings(width: 32, height: 32) }
        var stopAtFrame: Int?
        init() {}
        func draw() {
            if frameCount == stopAtFrame { noLoop() }
        }
    }

    /// 反証 7 の口: 走らせる側 (`SketchRuntime`) が、次のフレームが来るときだけ旗を立てる。
    @Test("ランタイムは、次のフレームが来る間だけ拡大した字の先送りを許す")
    func theRuntimeAllowsDeferringOnlyBeforeAnotherFrame() throws {
        let runtime = try SketchRuntime(sketch: Idle(), gpu: try RenderDevice())
        runtime.framesToRender = 3
        try runtime.advance()
        #expect(runtime.canvas.atlas.mayDeferScaledBakes, "走っている間は先送りを許すはず")
        try runtime.advance()
        #expect(runtime.canvas.atlas.mayDeferScaledBakes)
        try runtime.advance()
        #expect(!runtime.canvas.atlas.mayDeferScaledBakes, "書き出しの最後の 1 枚で先送りを許した")

        let stopping = Idle()
        stopping.stopAtFrame = 2
        let stopped = try SketchRuntime(sketch: stopping, gpu: try RenderDevice())
        try stopped.advance()
        #expect(stopped.canvas.atlas.mayDeferScaledBakes)
        try stopped.advance()
        #expect(!stopped.canvas.atlas.mayDeferScaledBakes, "noLoop() を呼んだフレームで先送りを許した")
    }

    // MARK: - 測る側が預ける画素

    /// 反証 9: 拡大して `text()` を描くとき、`textBounds` が段 0 の画素を預けても引き取られない。預けない。
    @Test("拡大した字の textBounds は、段 0 の画素を預けない")
    func textBoundsDoesNotKeepPixelsForAnEnlargedText() throws {
        let canvas = try makeCanvas(width: 200, height: 200)
        try canvas.draw {
            canvas.textSize(24)
            canvas.scale(4, 4)
            _ = canvas.textBounds("🌲", 0, 0)
        }
        #expect(canvas.atlas.keptCount == 0, "引き取られない画素を預けた")
        let plain = try makeCanvas(width: 200, height: 200)
        try plain.draw {
            plain.textSize(24)
            _ = plain.textBounds("🌲", 0, 0)
        }
        #expect(plain.atlas.keptCount == 1, "拡大しないときは、これまでどおり預ける")
    }

    // MARK: - 保持した形

    /// 反証 1 の記録: 保持した形の中の字は、**記録した時点の変換**で焼く (形の記録は `transform = .identity`
    /// で始まる)。`shape()` で拡大して置いても、字は焼き直さない — 説明文はこの限りを名乗る。
    /// 記録の中で `scale()` した字は、その拡大で焼く。
    @Test("保持した形の中の字は、記録した時点の変換の段で焼く")
    func glyphsInARetainedShapeAreBakedAtTheRecordedStep() throws {
        let canvas = try makeCanvas(width: 200, height: 200)
        try canvas.draw {
            canvas.textSize(24)
            let plain = canvas.createShape { canvas.text("p", 0, 0) }
            let enlarged = canvas.createShape {
                canvas.scale(4, 4)
                canvas.text("e", 0, 0)
            }
            canvas.fill(white)
            canvas.scale(8, 8)
            canvas.shape(plain, 4, 12)
            canvas.shape(enlarged, 4, 12)
        }
        #expect(bakedSteps(canvas, "p") == [0], "置くときの拡大で字を焼き直した: \(bakedSteps(canvas, "p"))")
        #expect(bakedSteps(canvas, "e") == [16], "記録の中の拡大で焼いていない: \(bakedSteps(canvas, "e"))")
    }
}
