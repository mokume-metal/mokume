// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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

    /// - Parameters:
    ///   - persists: このフレームの絵が次のフレームに描き直されずに残るか (`draw()` の後ろでランタイムが書く)。
    ///   - midFlush: 字を置いた後、フレームの途中で描き切る (`loadPixels()`)。
    private func drawSix(
        _ canvas: Canvas, scale: Float, persists: Bool = false, midFlush: Bool = false,
        shaped: Bool = false
    ) throws -> Int {
        let before = canvas.glyphQuadsPlaced
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(16)
            canvas.translate(4, 60)
            canvas.scale(scale, scale)
            if shaped { canvas.shapedText("abcdef", 0, 0) } else { canvas.text("abcdef", 0, 0) }
            if midFlush { canvas.loadPixels() }
            canvas.framePersists = persists
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

    // MARK: - 絵が残るフレームは、先送りした字を払う

    /// 6 字を 4 倍で描く参照の絵 (先送りせず、全部を要る段で焼く)。
    private func referenceImage(shaped: Bool = false) throws -> DisplayImage {
        let canvas = try makeCanvas(width: 400, height: 128)
        #expect(try drawSix(canvas, scale: 4, shaped: shaped) == 6)
        return try canvas.target.encodeForDisplay()
    }

    /// 反証 1〜4 の根: 先送りは、そのフレームの絵が次のフレームに描き直されるときだけ許す。**絵が残る
    /// フレーム (`framePersists`) は、先送りして近い段で置いた四角を、描き切る直前に焼いて置き直す** —
    /// 先送りしなかった絵と 1 画素も違わない。
    @Test("絵が残るフレームは、先送りした字をフレームの終わりに払い、先送りしなかった絵と同じになる")
    func aFrameThatPersistsPaysTheDeferredGlyphs() throws {
        let reference = try referenceImage()

        // 検査の前提: 払わないと、近い段で置いたぼけた字が絵に残る
        let soft = try makeCanvas(width: 400, height: 128)
        soft.atlas.scaledBakesPerFrame = 2
        soft.atlas.mayDeferScaledBakes = true
        #expect(try drawSix(soft, scale: 4, persists: false) == 6)
        #expect(scaledBakedCount(soft) == 2)
        #expect(try soft.target.encodeForDisplay() != reference, "検査の前提: 先送りした絵がぼけていない")

        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 2
        canvas.atlas.mayDeferScaledBakes = true
        #expect(try drawSix(canvas, scale: 4, persists: true) == 6, "字が欠けた")
        #expect(scaledBakedCount(canvas) == 6, "払っていない: \(scaledBakedCount(canvas))")
        #expect(canvas.atlas.owedGlyphCount == 0, "払った字が先送りの履歴に残っている")
        #expect(canvas.deferredRuns.isEmpty)
        #expect(try canvas.target.encodeForDisplay() == reference, "払った絵が、先送りしなかった絵と違う")
        #expect(canvas.warnings.message(for: .softEnlargedText) == nil)
    }

    /// 境界: 途中の描き切り (`loadPixels()`) の前は、そのフレームが残るか分からないので払う。
    /// 描き切った頂点は GPU へ渡り、後からは置き直せない。
    @Test("フレームの途中で描き切るときは、その前に先送りした字を払う")
    func aMidFramePassPaysTheDeferredGlyphs() throws {
        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 2
        canvas.atlas.mayDeferScaledBakes = true
        #expect(try drawSix(canvas, scale: 4, persists: false, midFlush: true) == 6)
        #expect(scaledBakedCount(canvas) == 6, "途中の描き切りの前に払っていない")
        #expect(canvas.atlas.owedGlyphCount == 0)
        #expect(try canvas.target.encodeForDisplay() == (try referenceImage()))
    }

    /// 反証 1: 形の記録 (`createShape`) の中は先送りしない。記録した四角は形に焼き付いて残り、次のフレームでも
    /// 近い段のままになる。上限を越えても、記録の中の字は要る段で焼く。
    @Test("形の記録の中で、上限を越える字を先送りしない")
    func aShapeRecordingDoesNotDefer() throws {
        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 2
        canvas.atlas.mayDeferScaledBakes = true
        try canvas.draw {
            canvas.textSize(16)
            let shape = canvas.createShape {
                canvas.scale(4, 4)
                canvas.text("abcdef", 0, 0)
            }
            #expect(canvas.deferredRuns.isEmpty)
            canvas.fill(white)
            canvas.shape(shape, 4, 60)
        }
        #expect(scaledBakedCount(canvas) == 6, "記録の中の字を先送りした: \(scaledBakedCount(canvas))")
        #expect(canvas.atlas.owedGlyphCount == 0)
    }

    /// 境界: 先送りした四角を置いた後に、同じフレームで頁が広がる (焼いた字形が全部消える) 場合。**静的な 1 枚の
    /// 絵 (`noLoop()` のポスター) の最初のフレームは、これが普通に起きる** — 頁は小さく始まり、字を焼くたびに
    /// 広がる。先送りした四角は列に分けてあるので、広げた頁へ焼き直して列の読む面を差し替えれば、先送りしな
    /// かった絵と同じになる。
    @Test("先送りした後に頁が広がっても、絵が残るなら先送りしなかった絵と同じになる")
    func aPageGrowingAfterTheDeferralIsStillPaid() throws {
        func frame(_ canvas: Canvas, persists: Bool) throws -> Int {
            let before = canvas.glyphQuadsPlaced
            var pages = 0
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textSize(16)
                canvas.pushMatrix()
                canvas.translate(4, 60)
                canvas.scale(4, 4)
                canvas.text("abcdef", 0, 0)
                canvas.popMatrix()
                // 先送りした後に、拡大しない字を大量に焼いて頁を広げさせる
                let serial = canvas.atlas.pageSerial
                canvas.textSize(90)
                canvas.text("ABCDEFGHIJKLMNOPQRSTUVWXYZ", 4, 100)
                canvas.text("abcdefghijklmnopqrstuvwxyz0123456789", 4, 124)
                if canvas.atlas.pageSerial != serial { pages += 1 }
                canvas.framePersists = persists
            }
            #expect(canvas.glyphQuadsPlaced - before == 6 + 26 + 36, "字が欠けた")
            return pages
        }
        let reference = try makeCanvas(width: 400, height: 128)
        _ = try frame(reference, persists: false)
        let expected = try reference.target.encodeForDisplay()

        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 2
        canvas.atlas.mayDeferScaledBakes = true
        #expect(try frame(canvas, persists: true) >= 1, "検査の前提: 先送りの後に頁が広がらなかった")
        #expect(canvas.atlas.owedGlyphCount == 0, "先送りの履歴が残っている")
        #expect(try canvas.target.encodeForDisplay() == expected, "頁が広がった後の絵が、先送りしなかった絵と違う")
        #expect(canvas.warnings.message(for: .softEnlargedText) == nil)
    }

    /// 境界: **払うときに頁が広がる** 場合 (先送りした字を要る段で焼くと、頁に入りきらない)。広げると焼いた字形は
    /// 全部消えるので、列の字を広げた頁へ焼き直す。焼き直さないと、列の字が別々の頁の位置を読む。
    @Test("払うときに頁が広がっても、列の字は同じ頁へ揃い、先送りしなかった絵と同じになる")
    func aPageGrowingWhilePayingIsStillPaid() throws {
        func frame(_ canvas: Canvas, persists: Bool) throws {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textSize(16)
                canvas.translate(4, 100)
                canvas.scale(8, 8)
                canvas.text("abcdef", 0, 0)
                canvas.framePersists = persists
            }
        }
        let reference = try makeCanvas(width: 400, height: 128)
        try frame(reference, persists: false)
        let expected = try reference.target.encodeForDisplay()

        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 1
        canvas.atlas.mayDeferScaledBakes = true
        var serialBeforePaying = canvas.atlas.pageSerial
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(16)
            canvas.translate(4, 100)
            canvas.scale(8, 8)
            canvas.text("abcdef", 0, 0)
            #expect(canvas.deferredRuns.map(\.glyphs.count) == [5], "検査の前提: 5 字を先送りしていない")
            serialBeforePaying = canvas.atlas.pageSerial
            canvas.framePersists = true
        }
        #expect(canvas.atlas.pageSerial != serialBeforePaying, "検査の前提: 払うときに頁が広がらなかった")
        #expect(canvas.atlas.owedGlyphCount == 0)
        #expect(try canvas.target.encodeForDisplay() == expected, "払う途中で頁が広がった絵が、先送りしなかった絵と違う")
        #expect(canvas.warnings.message(for: .softEnlargedText) == nil)
    }

    /// 境界: 列が控えたとおりでなければ (頂点が動いた・列に数えていない頂点がある)、読む面を差し替えない。差し替えると、
    /// 数えていない頂点が別の頁の位置を読む。置き直さず、近い段のまま、拡大が原因だと知らせる。
    @Test("控えと食い違う列は置き直さず、近い段のまま残して知らせる")
    func aRunThatDoesNotMatchItsRecordIsLeftSoftAndReported() throws {
        func frame(_ tamper: (Canvas) -> Void) throws -> Canvas {
            let canvas = try makeCanvas(width: 400, height: 128)
            canvas.atlas.scaledBakesPerFrame = 2
            canvas.atlas.mayDeferScaledBakes = true
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textSize(16)
                canvas.translate(4, 60)
                canvas.scale(4, 4)
                canvas.text("abcdef", 0, 0)
                tamper(canvas)
                canvas.framePersists = true
            }
            return canvas
        }
        // 控えに無い四角が列にある (控えを 1 字減らす)
        let extra = try frame { $0.deferredRuns[0].glyphs.removeLast() }
        #expect(extra.warnings.message(for: .softEnlargedText) != nil, "列の頂点の数が控えと違うのに置き直した")
        // 頂点が動いている (控えた位置が違う)
        let moved = try frame { $0.deferredRuns[0].glyphs[1].topLeft.x += 1 }
        #expect(moved.warnings.message(for: .softEnlargedText) != nil, "頂点が控えと違うのに置き直した")
        // 崩れていない列は、知らせない
        let intact = try frame { _ in }
        #expect(intact.warnings.message(for: .softEnlargedText) == nil)
    }

    /// 反証 1〜4 の根の 2: 先送りした四角の列は、**ほかの頂点を混ぜない**。先送りした字と焼いてある字が
    /// 入れ替わる所で列を閉じ、列は先送りした字の数だけの頂点でできている。
    @Test("先送りした四角は、ほかの頂点と別の列に並ぶ")
    func deferredQuadsFormTheirOwnRuns() throws {
        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 2
        canvas.atlas.mayDeferScaledBakes = true
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(16)
            canvas.translate(4, 60)
            canvas.scale(4, 4)
            canvas.text("abcdef", 0, 0)
            // 続けて先送りした 4 字が 1 つの列 (開いたまま)。ほかの図形を置く前に閉じる
            #expect(canvas.deferredRuns.count == 1)
            #expect(canvas.deferredRuns[0].glyphs.count == 4)
            canvas.rect(0, 0, 3, 3)
            #expect(!canvas.deferredRunOpen, "ほかの図形を置いたのに、列が開いたまま")
            let run = canvas.deferredRuns[0]
            #expect(canvas.batches[run.batch].run.count == 4 * 6)
            canvas.framePersists = false
        }
    }

    /// 反証 5: 描き場所 (`createGraphics`) は自分の焼き場を持ち、旗を立てるのは本体の面だけ。**描き場所の絵は
    /// 次のフレームへ残る**ので先送りせず、上限を越えても常に焼き切る。
    @Test("描き場所は先送りせず、上限を越えても焼き切る")
    func aGraphicsSurfaceBakesEverything() throws {
        let canvas = try makeCanvas(width: 400, height: 128)
        let layer = try canvas.createGraphics(400, 128)
        layer.textFont("Helvetica")
        layer.atlas.scaledBakesPerFrame = 2
        layer.beginDraw()
        layer.background(black)
        layer.fill(white)
        layer.textSize(16)
        layer.translate(4, 60)
        layer.scale(4, 4)
        layer.text("abcdef", 0, 0)
        layer.endDraw()
        #expect(scaledBakedCount(layer) == 6, "描き場所で先送りした: \(scaledBakedCount(layer))")
        #expect(layer.atlas.owedGlyphCount == 0)
        #expect(try layer.target.encodeForDisplay() == (try referenceImage()))
    }

    /// 反証 6: 先送りした字が、別の道で焼けていた (焼いてある段で早く返る) とき、先送りの履歴から外す。
    /// 外さないと、次のフレームで新しい字の枠をその分だけ押さえる。
    @Test("焼いてある段で早く返る字は、先送りの履歴から外れる")
    func aGlyphThatIsAlreadyBakedLeavesTheDeferredHistory() throws {
        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 1
        // 2 倍 (8 段) を先に全部焼いておく
        #expect(try drawSix(canvas, scale: 2) == 6)
        canvas.atlas.mayDeferScaledBakes = true
        // 4 倍 (16 段) は 1 字だけ焼き、残りは 8 段の字で描いて先送りする
        #expect(try drawSix(canvas, scale: 4) == 6)
        #expect(canvas.atlas.owedGlyphCount == 5)
        // 2 倍へ戻す。書体の控えを空にして、焼き場の引きを通す (控えから引くと、引かずに置く)
        canvas.typeface.placedScaled.removeAll()
        #expect(try drawSix(canvas, scale: 2) == 6)
        #expect(canvas.atlas.owedGlyphCount == 0, "焼いてある字が先送りの履歴に残っている")
    }

    // MARK: - 走らせる側が立てる旗

    final class Zoom: Sketch {
        var settings = SketchSettings(width: 400, height: 128)
        /// `draw()` の最後に `noLoop()` を呼ぶか。
        var stopsAfterDrawing = false
        /// `draw()` の最後に `save()` を頼む先。
        var savesTo: String?
        /// 字を `shapedText()` で描くか (偽なら `text()`)。
        var shaped = false
        /// 描き始めたときに先送りが許されていたかを読む口。
        var readsDeferral: (() -> Bool)?
        var seen: [Bool] = []
        init() {}
        func draw() {
            seen.append(readsDeferral?() ?? false)
            background(0)
            fill(255)
            textFont("Helvetica")
            textSize(16)
            translate(4, 60)
            scale(4, 4)
            if shaped { shapedText("abcdef", 0, 0) } else { text("abcdef", 0, 0) }
            if let savesTo { save(savesTo) }
            if stopsAfterDrawing { noLoop() }
        }
    }

    /// 窓に出しながら回すランタイム (`defersEnlargedGlyphBakes`) を組む。
    private func makeZoom(
        _ sketch: Zoom, onScreen: Bool = true, observer: URL? = nil, scaledBakesPerFrame: Int = 2
    ) throws -> SketchRuntime {
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: observer.map { FrameObserver(directory: $0) })
        runtime.defersEnlargedGlyphBakes = onScreen
        runtime.canvas.atlas.scaledBakesPerFrame = scaledBakesPerFrame
        sketch.readsDeferral = { [unowned runtime] in runtime.canvas.atlas.mayDeferScaledBakes }
        return runtime
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-glyph-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func scaledBakedCount(_ runtime: SketchRuntime) -> Int { scaledBakedCount(runtime.canvas) }

    /// ランタイムが先送りを許すのは、窓に出しながら回していて、そのフレームの絵を次のフレームが描き直す
    /// ときだけ。直に回す側 (窓の経路でない)・1 枚の書き出し・撮る係が居る (`mokume render`・`save()`・
    /// `beginRecord()`)・観測が撮るフレームは、許さない。
    @Test("ランタイムは、次のフレームが描き直すフレームだけで先送りを許す")
    func theRuntimeAllowsDeferringOnlyForAFrameThatIsRedrawn() throws {
        // 窓に出しながら回している間は許す
        let live = Zoom()
        let runtime = try makeZoom(live)
        try runtime.advance()
        try runtime.advance()
        #expect(live.seen == [true, true])

        // 窓の経路でない (直に回す・`mokume render`) ランタイムは許さない
        let direct = Zoom()
        let plain = try makeZoom(direct, onScreen: false)
        try plain.advance()
        #expect(direct.seen == [false])

        // 1 枚の書き出し
        let exported = Zoom()
        let exporter = try makeZoom(exported)
        let directory = try temporaryDirectory()
        try exporter.renderFrame(to: directory.appendingPathComponent("a.png"))
        #expect(exported.seen == [false], "1 枚の書き出しで先送りを許した")
        try exporter.advance()
        #expect(exported.seen == [false, true], "書き出しの後の通常のフレームで許さない")

        // 連番を撮っている (`mokume render` は撮る係を先に頼む)
        let recorded = Zoom()
        let recorder = try makeZoom(recorded)
        recorder.beginRecord(directory.appendingPathComponent("r-###.png").path, rendering: 2)
        try recorder.advance()
        #expect(recorded.seen == [false], "撮る係が居るフレームで先送りを許した")

        // 止めたフレームは、描き始めは許す。描き切る前に払う (下の検査)
        let stopping = Zoom()
        stopping.stopsAfterDrawing = true
        let stopped = try makeZoom(stopping)
        try stopped.advance()
        #expect(stopping.seen == [true])
        try stopped.advance()
        #expect(stopping.seen == [true], "止めたスケッチが描いた")
    }

    /// 反証 4: 観測が撮るフレームは、先送りを許さない。撮った絵は残る。
    @Test("観測が撮るフレームでは、先送りを許さない")
    func anObservedFrameDoesNotDefer() throws {
        let facet = try temporaryDirectory()
        let sketch = Zoom()
        let runtime = try makeZoom(sketch, observer: facet)
        try runtime.advance()
        #expect(sketch.seen == [true])
        try AtomicFile.write(
            Data(#"{"id":"snap"}"#.utf8), to: facet.appendingPathComponent("request.json"))
        try runtime.advance()
        #expect(sketch.seen == [true, false], "撮るフレームで先送りを許した")
        try runtime.advance()
        #expect(sketch.seen == [true, false, true], "撮り終えた後のフレームで許さない")
    }

    /// 反証 2: `draw()` の後ろで `noLoop()` を呼ぶ形 (Processing の定番)。先に描いた字は先送りされて
    /// いたが、止まるフレームの描き切りで払うので、窓・出口に残る絵は先送りしなかった絵と同じ。
    @Test("draw() の後ろで noLoop() を呼ぶと、止めた絵は先送りしなかった絵と同じになる")
    func noLoopAfterTheTextPaysTheDeferredGlyphs() throws {
        // 参照: 先送りしない (窓の経路でない)
        let plain = try makeZoom(Zoom(), onScreen: false)
        try plain.advance()
        let reference = try plain.target.encodeForDisplay()

        let sketch = Zoom()
        sketch.stopsAfterDrawing = true
        let runtime = try makeZoom(sketch)
        try runtime.advance()
        #expect(sketch.seen == [true], "検査の前提: 描き始めは先送りが許されている")
        #expect(scaledBakedCount(runtime) == 6, "止めたフレームの字が、近い段のまま残った")
        #expect(runtime.canvas.atlas.owedGlyphCount == 0)
        #expect(try runtime.target.encodeForDisplay() == reference)

        // 止めずに回し続ける絵は、次のフレームが焼き直すまでぼけている (払わない)
        let looping = Zoom()
        let running = try makeZoom(looping)
        try running.advance()
        #expect(scaledBakedCount(running) == 2)
        #expect(try running.target.encodeForDisplay() != reference, "検査の前提: 回している間は先送りが効く")
    }

    /// 反証 4: `draw()` の後ろで `save()` を頼む形。撮る絵は先送りしなかった絵と同じ。
    @Test("draw() の後ろで save() を頼むと、撮る絵は先送りしなかった絵と同じになる")
    func saveAfterTheTextPaysTheDeferredGlyphs() throws {
        let plain = try makeZoom(Zoom(), onScreen: false)
        try plain.advance()
        let reference = try plain.target.encodeForDisplay()

        let directory = try temporaryDirectory()
        let sketch = Zoom()
        sketch.savesTo = directory.appendingPathComponent("shot.png").path
        let runtime = try makeZoom(sketch)
        try runtime.advance()
        #expect(sketch.seen == [true])
        #expect(scaledBakedCount(runtime) == 6)
        #expect(try runtime.target.encodeForDisplay() == reference)
    }

    /// 反証 3: 公開の `renderFrame(to:)` は 1 枚だけ描いて書き出す。先送りせず、全部の字を要る段で焼く。
    @Test("renderFrame(to:) は先送りせず、書き出す絵は先送りしなかった絵と同じ")
    func renderFrameDoesNotDefer() throws {
        let plain = try makeZoom(Zoom(), onScreen: false)
        try plain.advance()
        let reference = try plain.target.encodeForDisplay()

        let runtime = try makeZoom(Zoom())
        let file = try temporaryDirectory().appendingPathComponent("frame.png")
        try runtime.renderFrame(to: file)
        #expect(scaledBakedCount(runtime) == 6)
        #expect(runtime.canvas.atlas.owedGlyphCount == 0)
        #expect(try runtime.target.encodeForDisplay() == reference)
    }

    // MARK: - 組版した文字列 (shapedText) も同じ段で焼く (#3251)

    /// `shapedText()` の 1 字を、`scale(8)` で描いた行の真ん中の縁 (`scaledGlyphEdgesAreSharp` の組版版)。
    @Test("拡大した shapedText の縁は鮮明で、伸ばしてぼけない")
    func shapedTextEdgesAreSharp() throws {
        let canvas = try makeCanvas(width: 160, height: 160)
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(12)
            canvas.translate(60, 140)
            canvas.scale(8, 8)
            canvas.shapedText("I", 0, 0)
        }
        let image = try canvas.target.encodeForDisplay()
        let row = 100
        let inked = (0..<image.width).filter { image[$0, row].red > 200 }.count
        #expect(inked >= 6, "検査の前提: 棒に墨が乗っていない (\(inked))")
        let soft = edgePixels(image, row: row)
        #expect(soft <= 4, "縁の中間の画素が \(soft) ある — 伸ばしてぼけている")
    }

    /// 完了条件 3: `scale(5, 5)` で同じ文字列を `text()` と `shapedText()` で描くと、どちらも段 > 0 の鍵で焼かれ、
    /// 段 0 では焼かれない。
    @Test("scale(5) の shapedText は text() と同じく、段 > 0 の鍵で焼く")
    func shapedTextBakesUnderTheStep() throws {
        for shaped in [false, true] {
            let canvas = try makeCanvas(width: 200, height: 200)
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textSize(14)
                canvas.translate(4, 150)
                canvas.scale(5, 5)
                if shaped { canvas.shapedText("Ag", 0, 0) } else { canvas.text("Ag", 0, 0) }
            }
            for scalar: Unicode.Scalar in ["A", "g"] {
                let baked = bakedSteps(canvas, scalar, size: 14)
                #expect(
                    baked.count == 1 && baked[0] > 0,
                    "shaped=\(shaped) \(scalar): 段 > 0 の鍵だけで焼くはず: \(baked)")
            }
        }
    }

    /// 単純な ASCII 1 字は、組版の位置も `text()` と同じなので、絵が 1 画素も違わない。
    @Test("拡大した ASCII 1 字は、shapedText と text() で同じ絵になる")
    func shapedTextMatchesTextForOneGlyph() throws {
        func picture(shaped: Bool) throws -> DisplayImage {
            let canvas = try makeCanvas(width: 200, height: 200)
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textSize(14)
                canvas.translate(10, 150)
                canvas.scale(5, 5)
                if shaped { canvas.shapedText("M", 0, 0) } else { canvas.text("M", 0, 0) }
            }
            return try canvas.target.encodeForDisplay()
        }
        #expect(try picture(shaped: true) == (try picture(shaped: false)))
    }

    /// 完了条件 2: 等倍で描いた行 (段 0 の控えを持つ) を拡大して描き直すと拡大段の字形で描かれ、段を替えて戻っても
    /// 取り違えない。同じ段へ戻れば焼き直さない。
    @Test("等倍で描いた shapedText の行を拡大して描き直すと、拡大段の字形で描かれる")
    func aShapedLineDrawnAtOneToOneIsRebakedWhenEnlarged() throws {
        let canvas = try makeCanvas(width: 200, height: 200)
        func frame(scale: Float) throws -> DisplayImage {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textSize(14)
                canvas.translate(10, 150)
                canvas.scale(scale, scale)
                canvas.shapedText("M", 0, 0)
            }
            return try canvas.target.encodeForDisplay()
        }
        let small = try frame(scale: 1)
        #expect(bakedSteps(canvas, "M", size: 14) == [0])
        let large = try frame(scale: 5)
        let steps = bakedSteps(canvas, "M", size: 14)
        #expect(steps.count == 2 && steps[0] == 0 && steps[1] > 0, "拡大した段で焼いていない: \(steps)")
        let baked = canvas.atlas.bakedCount
        // 戻っても、段ごとの控えが取り違えない (等倍の絵は最初と同じ、拡大の絵は 1 回目と同じ)
        #expect(try frame(scale: 1) == small)
        #expect(try frame(scale: 5) == large)
        #expect(canvas.atlas.bakedCount == baked, "同じ段へ戻って焼き直した")
        // 検査の前提: 拡大の絵は、段 0 を伸ばした絵と違う
        #expect(large != small)
    }

    /// 完了条件 1: 上限を越えた分は、焼いてある近い段 (無ければ段 0) で描いて欠けず、次のフレームで先に焼く
    /// (`text()` の `bakesPerFrameAreCappedWithoutDroppingGlyphs` の組版版)。控えは、決まった答えのときだけ入る。
    @Test("shapedText も、1 フレームに新しく焼く数の上限を越えた分は、欠けずに描いて次のフレームへ送る")
    func shapedTextBakesPerFrameAreCappedWithoutDroppingGlyphs() throws {
        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 2
        canvas.atlas.mayDeferScaledBakes = true
        #expect(try drawSix(canvas, scale: 2, shaped: true) == 6, "上限を越えた字が欠けた")
        #expect(scaledBakedCount(canvas) == 2, "上限を越えて焼いた: \(scaledBakedCount(canvas))")
        #expect(try drawSix(canvas, scale: 2, shaped: true) == 6)
        #expect(scaledBakedCount(canvas) == 4)
        #expect(try drawSix(canvas, scale: 2, shaped: true) == 6)
        #expect(scaledBakedCount(canvas) == 6)
        let settled = canvas.atlas.bakedCount
        #expect(try drawSix(canvas, scale: 2, shaped: true) == 6)
        #expect(canvas.atlas.bakedCount == settled, "揃った後は焼き直さない")
        #expect(canvas.atlas.owedGlyphCount == 0)
    }

    /// 完了条件 1: 絵が残るフレームは、先送りして近い段で置いた四角をフレームの終わりに払い、先送りしなかった絵と
    /// 1 画素も違わない。
    @Test("shapedText も、絵が残るフレームは先送りした字を払い、先送りしなかった絵と同じになる")
    func aFrameThatPersistsPaysTheDeferredShapedGlyphs() throws {
        let reference = try referenceImage(shaped: true)

        let soft = try makeCanvas(width: 400, height: 128)
        soft.atlas.scaledBakesPerFrame = 2
        soft.atlas.mayDeferScaledBakes = true
        #expect(try drawSix(soft, scale: 4, persists: false, shaped: true) == 6)
        #expect(scaledBakedCount(soft) == 2)
        #expect(try soft.target.encodeForDisplay() != reference, "検査の前提: 先送りした絵がぼけていない")

        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 2
        canvas.atlas.mayDeferScaledBakes = true
        #expect(try drawSix(canvas, scale: 4, persists: true, shaped: true) == 6, "字が欠けた")
        #expect(scaledBakedCount(canvas) == 6, "払っていない: \(scaledBakedCount(canvas))")
        #expect(canvas.atlas.owedGlyphCount == 0)
        #expect(canvas.deferredRuns.isEmpty)
        #expect(try canvas.target.encodeForDisplay() == reference, "払った絵が、先送りしなかった絵と違う")
        #expect(canvas.warnings.message(for: .softEnlargedText) == nil)
    }

    @Test("shapedText も、フレームの途中で描き切るときは、その前に先送りした字を払う")
    func aMidFramePassPaysTheDeferredShapedGlyphs() throws {
        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 2
        canvas.atlas.mayDeferScaledBakes = true
        #expect(try drawSix(canvas, scale: 4, persists: false, midFlush: true, shaped: true) == 6)
        #expect(scaledBakedCount(canvas) == 6, "途中の描き切りの前に払っていない")
        #expect(canvas.atlas.owedGlyphCount == 0)
        #expect(try canvas.target.encodeForDisplay() == (try referenceImage(shaped: true)))
    }

    /// 完了条件 3 の確かめ方: `noLoop()` と書き出しで、繰り越した字が解決される。
    @Test("shapedText も、noLoop() で止めた絵と renderFrame(to:) の絵は、先送りしなかった絵と同じになる")
    func shapedTextIsSettledByNoLoopAndRenderFrame() throws {
        let plainSketch = Zoom()
        plainSketch.shaped = true
        let plain = try makeZoom(plainSketch, onScreen: false)
        try plain.advance()
        let reference = try plain.target.encodeForDisplay()

        let stopping = Zoom()
        stopping.shaped = true
        stopping.stopsAfterDrawing = true
        let stopped = try makeZoom(stopping)
        try stopped.advance()
        #expect(stopping.seen == [true], "検査の前提: 描き始めは先送りが許されている")
        #expect(scaledBakedCount(stopped) == 6, "止めたフレームの字が、近い段のまま残った")
        #expect(stopped.canvas.atlas.owedGlyphCount == 0)
        #expect(try stopped.target.encodeForDisplay() == reference)

        let rendering = Zoom()
        rendering.shaped = true
        let runtime = try makeZoom(rendering)
        let file = try temporaryDirectory().appendingPathComponent("frame.png")
        try runtime.renderFrame(to: file)
        #expect(scaledBakedCount(runtime) == 6)
        #expect(runtime.canvas.atlas.owedGlyphCount == 0)
        #expect(try runtime.target.encodeForDisplay() == reference)
    }

    // MARK: - 組版した文字列の反証の直し (#3251)

    /// 拡大して `shapedText()` を描くとき、`shapedTextBounds` が段 0 の画素を預けても引き取られない。預けない
    /// (`textBounds` と同じ・#2560・#2446)。
    @Test("拡大した字の shapedTextBounds は、段 0 の画素を預けない")
    func shapedTextBoundsDoesNotKeepPixelsForAnEnlargedText() throws {
        let canvas = try makeCanvas(width: 200, height: 200)
        try canvas.draw {
            canvas.textSize(24)
            canvas.scale(4, 4)
            _ = canvas.shapedTextBounds("🌲", 0, 0)
        }
        #expect(canvas.atlas.keptCount == 0, "引き取られない画素を預けた")
        let plain = try makeCanvas(width: 200, height: 200)
        try plain.draw {
            plain.textSize(24)
            _ = plain.shapedTextBounds("🌲", 0, 0)
        }
        #expect(plain.atlas.keptCount == 1, "拡大しないときは、これまでどおり預ける")
    }

    /// 拡大を動かし続けても、1 行が抱える拡大した段の控えは上限で止まる。上限の中の段を行き来するなら焼き直さない。
    @Test("shapedText の行が抱える拡大した段の控えは、段の数の上限で止まる")
    func aShapedLineKeepsAtMostAFewScaledSteps() throws {
        let canvas = try makeCanvas(width: 200, height: 200)
        func frame(scale: Float) throws {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textSize(12)
                canvas.translate(4, 190)
                canvas.scale(scale, scale)
                canvas.shapedText("M", 0, 0)
            }
        }
        for scale: Float in [2, 3, 4, 5, 6, 7, 8] { try frame(scale: scale) }
        let line = canvas.typeface.shape("M")
        #expect(line.placedScaled.count == ShapedLine.scaledStepLimit, "段の控えが上限で止まっていない: \(line.placedScaled.keys.sorted())")
        // 直近の段は残っていて、行き来しても焼き直さない
        let baked = canvas.atlas.bakedCount
        try frame(scale: 8)
        try frame(scale: 7)
        try frame(scale: 8)
        #expect(canvas.atlas.bakedCount == baked, "直近の段を焼き直した")
        #expect(line.placedScaled.count == ShapedLine.scaledStepLimit)
    }

    /// 拡大しすぎの知らせは、呼んだ口の名前で名乗る。
    @Test("拡大しすぎの知らせは、text() と shapedText() のどちらで描いたかを名乗る")
    func theSoftEnlargedWarningNamesTheCaller() throws {
        for shaped in [false, true] {
            let canvas = try makeCanvas(width: 200, height: 200)
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textSize(24)
                canvas.scale(60, 60)
                if shaped { canvas.shapedText("M", 0, 0) } else { canvas.text("M", 0, 0) }
            }
            let message = try #require(canvas.warnings.message(for: .softEnlargedText), "shaped=\(shaped)")
            #expect(message.hasPrefix(shaped ? "shapedText():" : "text():"), "shaped=\(shaped): \(message)")
        }
    }

    /// 先送りした字を払えなかったときの知らせも、その字を置いた口の名前で名乗る。
    @Test("先送りした字を払えなかった知らせは、shapedText() と名乗る")
    func anUnpaidShapedRunNamesShapedText() throws {
        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 2
        canvas.atlas.mayDeferScaledBakes = true
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(16)
            canvas.translate(4, 60)
            canvas.scale(4, 4)
            canvas.shapedText("abcdef", 0, 0)
            // 控えと食い違わせる (払えない列にする)
            canvas.vertices[canvas.deferredRuns[0].glyphs[0].start].position.x += 1
            canvas.framePersists = true
        }
        let message = try #require(canvas.warnings.message(for: .softEnlargedText), "払えなかった知らせが出ていない")
        #expect(message.hasPrefix("shapedText():"), "\(message)")
    }

    /// 色字 (絵文字)・別の書体へ切り替わる字・合字や結合記号を含む行でも、拡大した段で焼き、先送りした字を払い、
    /// 等倍と拡大を交互に描いても焼き直さず、絵が取り違えない。
    @Test("色字・別書体の字・合字を含む shapedText の行も、払った絵が先送りしなかった絵と同じで、段を行き来しても焼き直さない",
        arguments: ["a🌲b", "漢a字", "office ﬁ", "e\u{0301}xe\u{0301}"])
    func richShapedLinesAreSettledAndKeptPerStep(line: String) throws {
        func picture(_ canvas: Canvas, scale: Float, persists: Bool) throws -> DisplayImage {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textSize(16)
                canvas.translate(4, 70)
                canvas.scale(scale, scale)
                canvas.shapedText(line, 0, 0)
                canvas.framePersists = persists
            }
            return try canvas.target.encodeForDisplay()
        }
        // 参照: 先送りしない
        let plain = try makeCanvas(width: 400, height: 128)
        let reference = try picture(plain, scale: 4, persists: false)
        let referenceSmall = try picture(plain, scale: 1, persists: false)
        #expect(reference != referenceSmall, "検査の前提: 拡大の絵が等倍の絵と違う")

        // 先送りして払う
        let canvas = try makeCanvas(width: 400, height: 128)
        canvas.atlas.scaledBakesPerFrame = 1
        canvas.atlas.mayDeferScaledBakes = true
        let settled = try picture(canvas, scale: 4, persists: true)
        #expect(canvas.atlas.owedGlyphCount == 0, "払っていない")
        #expect(canvas.deferredRuns.isEmpty)
        #expect(settled == reference, "払った絵が、先送りしなかった絵と違う")

        // 等倍 → 拡大 → 等倍 → 拡大: 段ごとの控えが取り違えず、焼き直さない
        let small = try picture(canvas, scale: 1, persists: true)
        #expect(small == referenceSmall)
        let baked = canvas.atlas.bakedCount
        #expect(try picture(canvas, scale: 4, persists: true) == reference)
        #expect(try picture(canvas, scale: 1, persists: true) == small)
        #expect(try picture(canvas, scale: 4, persists: true) == reference)
        #expect(canvas.atlas.bakedCount == baked, "段を行き来して焼き直した")
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
