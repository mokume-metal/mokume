// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import Testing

@testable import MokumeCore

/// `filter(_:)` は呼んだ時点の絵に効果をその場で掛け、`Image.filtered(_:)` は同じ並びを掛けた新しい絵を返す
/// ([#2455])。`.threshold(level:)` は明るさ (`brightness(_:)` と同じ物差し) で 2 値にする。
///
/// 期待は絵ぜんぶへ掛ける `effects(_:)` の絵と、手で数えた画素から作り、検査の対象と同じ口から作らない。
///
/// [#2455]: https://github.com/mokume-metal/mokume/issues/2455
@Suite(
    "filter()・Image.filtered()・threshold",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FilterImmediateTests {
    private func makeCanvas(width: Int = 100, height: Int = 100) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    private func read(_ canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    // MARK: - 呼んだ時点で掛かる (完了条件 1)

    /// 左に白い矩形、右に赤い矩形。間で `apply` を呼ぶ。
    private func scene(on canvas: Canvas, between apply: () -> Void) {
        canvas.background(0)
        canvas.noStroke()
        canvas.fill(255)
        canvas.rect(0, 0, 50, 100)
        apply()
        canvas.fill(255, 0, 0)
        canvas.rect(60, 0, 40, 100)
    }

    @Test("filter() の後に描いたものには掛からず、前に描いたものには掛かる。effects() は後のものにも掛かる")
    func laterDrawingIsLeftAlone() throws {
        let blur = [Effect.blur(radius: 8)]
        let immediate = try makeCanvas()
        try immediate.draw { scene(on: immediate) { immediate.filter(blur) } }
        let deferred = try makeCanvas()
        try deferred.draw { scene(on: deferred) { deferred.effects(blur) } }
        let plain = try makeCanvas()
        try plain.draw { scene(on: plain) {} }
        let after = try read(immediate)
        let all = try read(deferred)
        let untouched = try read(plain)

        // 白い矩形の縁 (x = 50 付近) は、どちらもぼける
        #expect(after[49, 50].red < 255 && after[49, 50].red > 0, "filter の前に描いた縁がぼけていない")
        // 赤い矩形の内側は、filter の後に描いたので、ぼけない
        #expect(after[61, 50] == untouched[61, 50], "filter の後に描いた赤が、ぼけた")
        #expect(after[80, 50] == untouched[80, 50])
        // effects() で書くと、同じ赤の縁 (x = 61) もぼける — 比べる相手が「何もしない口」でない
        #expect(all[61, 50] != untouched[61, 50], "effects() が後に描いたものにも掛かるはずが、掛かっていない")
    }

    // MARK: - 持ち越す (完了条件 2)

    /// 1 枚目だけ背景を塗り、中央に点を置く。以後は毎フレーム `apply` だけを呼ぶ。広がった画素の数を返す。
    private func spread(over frames: Int, _ apply: (Canvas) -> Void) throws -> [Int] {
        let canvas = try makeCanvas(width: 64, height: 64)
        var counts: [Int] = []
        for frame in 0..<frames {
            try canvas.draw {
                if frame == 0 {
                    canvas.background(0)
                    canvas.noStroke()
                    canvas.fill(255)
                    canvas.rect(31, 31, 2, 2)
                }
                apply(canvas)
            }
            let image = try read(canvas)
            var lit = 0
            for y in 0..<64 {
                for x in 0..<64 where image[x, y].red > 0 { lit += 1 }
            }
            counts.append(lit)
        }
        return counts
    }

    @Test("filter() で掛けた絵は次のフレームへ持ち越し、広がりが回ごとに増える。effects() は増えない")
    func filteredPictureCarriesOver() throws {
        let filtered = try spread(over: 3) { $0.filter([.blur(radius: 2)]) }
        #expect(filtered[1] > filtered[0] && filtered[2] > filtered[1], "広がりが増えない: \(filtered)")
        let deferred = try spread(over: 3) { $0.effects([.blur(radius: 2)]) }
        #expect(deferred[1] == deferred[0] && deferred[2] == deferred[0], "effects() の広がりが回ごとに増えた: \(deferred)")
    }

    // MARK: - Image.filtered (完了条件 3)

    @Test("filtered() は掛けた新しい絵を返し、元の絵を変えない。返った絵は元が書き換わっても動かない")
    func filteredReturnsANewPicture() throws {
        let canvas = try makeCanvas(width: 4, height: 4)
        let source = try canvas.createImage(2, 1)
        let dark = LinearRGBA.display(red: 0.4, green: 0.4, blue: 0.4)
        let light = LinearRGBA.display(red: 0.6, green: 0.6, blue: 0.6)
        source.set(0, 0, dark)
        source.set(1, 0, light)
        // 面は半精度で持つので、置いた色を読み直した値を「元の絵」とする
        let (darkBefore, lightBefore) = (source.get(0, 0), source.get(1, 0))

        let result = source.filtered([.threshold(level: 0.5)])
        #expect(result !== source)
        #expect((result.width, result.height) == (2, 1))
        #expect(result.get(0, 0) == LinearRGBA.linear(red: 0, green: 0, blue: 0), "暗い側が黒でない")
        #expect(result.get(1, 0) == LinearRGBA.linear(red: 1, green: 1, blue: 1), "明るい側が白でない")
        #expect(source.get(0, 0) == darkBefore && source.get(1, 0) == lightBefore, "元の絵が変わった")

        // 元が書き換わっても (カメラの次の 1 枚のように)、返った絵は動かない
        source.set(0, 0, LinearRGBA.display(red: 1, green: 0, blue: 0))
        #expect(result.get(0, 0) == LinearRGBA.linear(red: 0, green: 0, blue: 0))
    }

    @Test("filtered([]) は掛けずに写しを返す")
    func emptyListIsACopy() throws {
        let canvas = try makeCanvas(width: 4, height: 4)
        let source = try canvas.createImage(2, 1)
        source.set(0, 0, LinearRGBA.display(red: 0.2, green: 0.5, blue: 0.9))
        let result = source.filtered([])
        #expect(result !== source)
        #expect(result.get(0, 0) == source.get(0, 0))
    }

    // MARK: - threshold の物差し (完了条件 4)

    /// 1 画素ずつ別の色を置いて 2 値化し、画素を読む。
    private func thresholded(
        _ colors: [LinearRGBA], level: Float, background: Bool = false
    ) throws -> DisplayImage {
        let canvas = try makeCanvas(width: colors.count, height: 1)
        try canvas.draw {
            if background { canvas.background(0) }
            canvas.noStroke()
            for (index, color) in colors.enumerated() {
                canvas.fill(color)
                canvas.rect(Float(index), 0, 1, 1)
            }
            canvas.filter([.threshold(level: level)])
        }
        return try read(canvas)
    }

    @Test("明るさが level 以上の画素は白、未満は黒。物差しは brightness() と同じで、境目は 127 と 128")
    func thresholdFollowsTheBrightnessRuler() throws {
        let gray = { (value: Float) in LinearRGBA.display(red: value / 255, green: value / 255, blue: value / 255) }
        let image = try thresholded([gray(127), gray(128), gray(0), gray(255)], level: 0.5, background: true)
        #expect(image[0, 0] == (0, 0, 0, 255), "127/255 は 0.5 に届かない")
        #expect(image[1, 0] == (255, 255, 255, 255), "128/255 は 0.5 を越える")
        #expect(image[2, 0] == (0, 0, 0, 255))
        #expect(image[3, 0] == (255, 255, 255, 255))
    }

    @Test("明るさは R・G・B の最大で比べる。青だけの暗い色も、成分が level に届けば白")
    func thresholdUsesTheBrightestChannel() throws {
        let blueOnly = LinearRGBA.display(red: 0, green: 0, blue: 200 / 255)
        let dimBlue = LinearRGBA.display(red: 0, green: 0, blue: 100 / 255)
        let image = try thresholded([blueOnly, dimBlue], level: 0.5, background: true)
        #expect(image[0, 0] == (255, 255, 255, 255), "最大の成分が 0.78 なので白")
        #expect(image[1, 0] == (0, 0, 0, 255), "最大の成分が 0.39 なので黒")
    }

    @Test("アルファは動かさない。透明は透明のまま、半透明は半透明の白になる")
    func thresholdKeepsTheAlpha() throws {
        let half = LinearRGBA.display(red: 0.9, green: 0.9, blue: 0.9, alpha: 0.5)
        let image = try thresholded([half], level: 0.5)
        let kept = try #require(image[0, 0].alpha as UInt8?)
        #expect(abs(Int(kept) - 128) <= 1, "半透明のアルファが動いた: \(kept)")
        #expect(image[0, 0].red == 255 && image[0, 0].green == 255 && image[0, 0].blue == 255, "半透明の明るい画素が白でない")
        // 何も描かなかった所 (透明) はそのまま
        let canvas = try makeCanvas(width: 2, height: 1)
        try canvas.draw { canvas.filter([.threshold(level: 0)]) }
        #expect(try read(canvas)[0, 0] == (0, 0, 0, 0), "透明が塗られた")
    }

    @Test("level は 0…1 に締まり、数でない値は並びから外す")
    func thresholdClampsTheLevel() throws {
        let gray = { (value: Float) in LinearRGBA.display(red: value / 255, green: value / 255, blue: value / 255) }
        // 2 は 1 に締まる: 254/255 は届かず、255 だけが白
        let over = try thresholded([gray(254), gray(255)], level: 2, background: true)
        #expect(over[0, 0] == (0, 0, 0, 255) && over[1, 0] == (255, 255, 255, 255))
        // -1 は 0 に締まる: 黒い画素も 0 以上なので白
        let under = try thresholded([gray(0)], level: -1, background: true)
        #expect(under[0, 0] == (255, 255, 255, 255))
        // 数でない値は外す: 絵は変わらない
        let dropped = try thresholded([gray(100)], level: .nan, background: true)
        #expect(dropped[0, 0].red == 100 || abs(Int(dropped[0, 0].red) - 100) <= 1, "数でない level の効果が掛かった")
    }

    // MARK: - 寿命は置いたものの側 (反証 1)

    /// `setup()` で絵を置いて `filter()` を掛け、`noLoop()` で止める Processing の定番。
    final class FilterInSetup: Sketch {
        var settings: SketchSettings { SketchSettings(width: 64, height: 64) }
        var filters = true
        func setup() {
            background(0)
            noStroke()
            fill(255)
            rect(0, 0, 32, 64)
            if filters { filter([.invert()]) }
            noLoop()
        }
        func draw() {}
    }

    @Test("setup() で置いた絵に filter() を掛け、noLoop() で止めても、掛けた絵が出る")
    func filterWorksInSetup() throws {
        func picture(filters: Bool) throws -> DisplayImage {
            let sketch = FilterInSetup()
            sketch.filters = filters
            let runtime = try SketchRuntime(
                sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 })
            try runtime.advance()
            return try runtime.target.encodeToImage().read()
        }
        let plain = try picture(filters: false)
        let filtered = try picture(filters: true)
        #expect(plain[10, 10] == (255, 255, 255, 255) && plain[50, 10] == (0, 0, 0, 255), "検査が成り立たない: \(plain[10, 10]) \(plain[50, 10])")
        #expect(filtered[10, 10] == (0, 0, 0, 255), "setup() の filter が左の白に掛かっていない")
        #expect(filtered[50, 10] == (255, 255, 255, 255), "setup() の filter が右の黒に掛かっていない")
    }

    /// 止まっている間のコールバックを模す (持ち越しの区間の印を立てる・``EffectStoppedChangeTests`` と同じ)。
    private static func whileStopped(_ canvas: Canvas, _ body: () -> Void) {
        canvas.carriesOver = true
        defer { canvas.carriesOver = false }
        body()
    }

    @Test("止まっている間の filter() は、画面の絵と、次のフレームの入り (効果を通す前の絵) の両方に掛かる")
    func filterWhileStoppedReachesBothSurfaces() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        // 1 枚目: 暗い下地 (77) に反転を通す。反転は線形の値で 1 から引くので、画面は明るく (247)、控えは暗い (77) まま
        try canvas.draw {
            canvas.background(77)
            canvas.effects([.invert()])
        }
        let shown = try read(canvas)
        #expect(shown[8, 8].red > 200, "検査が成り立たない: 画面は反転した明るい灰のはず")
        Self.whileStopped(canvas) { canvas.filter([.threshold(level: 0.5)]) }
        // 画面の絵: 明るい灰は 2 値化で白になる
        #expect(try read(canvas)[8, 8] == (255, 255, 255, 255), "画面の絵に掛かっていない")
        // 2 枚目: 何も頼まない。入りは控え。暗い灰が 2 値化されて黒になっていれば、控えにも掛かっている
        try canvas.draw {}
        #expect(try read(canvas)[8, 8] == (0, 0, 0, 255), "次のフレームの入り (控え) に掛かっていない")
    }

    @Test("前のフレームが effects() で、塗り直さずに filter() だけを掛けても、効果は焼き込まれない")
    func filterAfterAFrameWithEffectsDoesNotBakeThem() throws {
        let canvas = try makeCanvas(width: 64, height: 64)
        try canvas.draw {
            canvas.background(235)
            canvas.effects([.vignette(amount: 0.8)])
        }
        let vignetted = try read(canvas)
        #expect(vignetted[2, 2].red < vignetted[32, 32].red, "検査が成り立たない: 周辺減光が効いていない")
        // 2 枚目: 塗り直さず、反転だけを掛ける。入りは効果を通す前の絵 (一様な 235) なので、隅も中央も同じ
        try canvas.draw { canvas.filter([.invert()]) }
        let image = try read(canvas)
        // 期待は、周辺減光を通さずに同じ下地を反転した別の面から取る
        let reference = try makeCanvas(width: 64, height: 64)
        try reference.draw {
            reference.background(235)
            reference.filter([.invert()])
        }
        let expected = try read(reference)
        #expect(image[32, 32] == expected[32, 32], "入りの絵 (235) の反転と違う: \(image[32, 32]) 対 \(expected[32, 32])")
        #expect(image[2, 2] == expected[2, 2], "前のフレームの周辺減光が焼き込まれた: \(image[2, 2])")
    }

    @Test("同じフレームで filter() と effects() を併用すると、filter の分を含めた絵にフレームの終わりの効果が掛かる")
    func filterAndEffectsInTheSameFrame() throws {
        let both = try makeCanvas(width: 64, height: 64)
        try both.draw {
            both.background(255)
            both.filter([.invert()])  // 黒になる
            both.fill(255)
            both.noStroke()
            both.rect(16, 16, 32, 32)  // filter の後に描いた白
            both.effects([.vignette(amount: 0.8)])
        }
        // 手で書いた期待: 黒い下地に白い矩形を描いてから周辺減光だけを掛ける
        let expected = try makeCanvas(width: 64, height: 64)
        try expected.draw {
            expected.background(0)
            expected.fill(255)
            expected.noStroke()
            expected.rect(16, 16, 32, 32)
            expected.effects([.vignette(amount: 0.8)])
        }
        let (a, b) = (try read(both), try read(expected))
        for (x, y) in [(2, 2), (30, 30), (60, 60), (20, 40)] {
            #expect(a[x, y] == b[x, y], "(\(x), \(y)) が期待と違う: \(a[x, y]) 対 \(b[x, y])")
        }
    }

    @Test("set() の後の書き込み待ちが残っていても、filter() は書いた画素を含めて掛ける")
    func filterIncludesPendingPixelWrites() throws {
        func picture(viaSet: Bool) throws -> DisplayImage {
            let canvas = try makeCanvas(width: 8, height: 8)
            try canvas.draw {
                canvas.background(0)
                if viaSet {
                    canvas.set(3, 3, LinearRGBA.linear(red: 1, green: 0, blue: 0))
                } else {
                    canvas.noStroke()
                    canvas.fill(LinearRGBA.linear(red: 1, green: 0, blue: 0))
                    canvas.rect(3, 3, 1, 1)
                }
                canvas.filter([.invert()])
            }
            return try read(canvas)
        }
        let viaSet = try picture(viaSet: true)
        let viaRect = try picture(viaSet: false)
        #expect(viaSet[3, 3] == viaRect[3, 3] && viaSet[3, 3].red < 10, "set した画素が反転に含まれていない: \(viaSet[3, 3])")
        #expect(viaSet[0, 0] == (255, 255, 255, 255))
    }

    @Test("描く細かさを下げた面でも、filter() の絵が出す先に届く")
    func filterOnAHalfDensitySurface() throws {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 64, height: 64)
        let canvas = try Canvas(output: output, gpu: gpu, pixelDensity: 0.5, upscale: .spatial)
        try canvas.draw {
            canvas.background(255)
            canvas.filter([.invert()])
        }
        #expect(try canvas.output.encodeForDisplay()[32, 32] == (0, 0, 0, 255), "出す先に反転が届いていない")
    }

    // MARK: - 断り方 (反証 1)

    @Test("持ち越しの区間の外の filter() は、effects() とは別の鍵と、置ける場面を名乗る文で 1 度だけ断る")
    func filterOutsideTheRegionsSaysItsOwnThing() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        canvas.effects([.invert()])
        canvas.filter([.invert()])
        canvas.filter([.invert()])
        let said = try #require(canvas.warnings.message(for: .filterOutsideFrame))
        #expect(said.contains("beginDraw()"), "置ける場面を名乗っていない: \(said)")
        #expect(!said.contains("from draw()"), "当てはまらない案内: \(said)")
        #expect(canvas.warnings.hasWarned(.effectsOutsideFrame), "effects() の注意が filter() に黙らされた")
        #expect(try read(canvas)[4, 4] == (0, 0, 0, 0), "区間の外で絵が変わった")
    }

    @Test("形の組み立ての中の filter() は、組み立ての区間を壊さず、注意して何もしない")
    func filterInsideAShapeIsRefused() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        var shape = Shape.empty
        try canvas.draw {
            canvas.background(0)
            shape = canvas.createShape {
                canvas.fill(255)
                canvas.rect(0, 0, 4, 4)
                canvas.filter([.invert()])
            }
        }
        #expect(canvas.warnings.hasWarned(.filterInsideShape))
        #expect(!canvas.warnings.hasWarned(.shapeDrawnOutWhileBuilding), "組み立ての区間が描き切られた")
        #expect(!shape.isEmpty, "形が空になった")
    }

    // MARK: - 失敗の鍵

    @Test("filter() の失敗は、フレームの終わりの効果の失敗とは別の鍵と文で言い、絵はそのまま残る")
    func filterFailureHasItsOwnKey() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        canvas.failEffectPassForTesting = 0
        try canvas.draw {
            canvas.background(255)
            canvas.filter([.invert()])
        }
        let said = try #require(canvas.warnings.message(for: .filterFailed))
        #expect(said.hasPrefix("Could not run filter()"), "\(said)")
        #expect(!canvas.warnings.hasWarned(.effectFailed))
        #expect(try read(canvas)[4, 4] == (255, 255, 255, 255), "失敗したのに絵が変わった")
    }

    // MARK: - threshold の端 (反証 7・8・9)

    @Test("不透明度 0 の画素 (加算した光) は、level によらずそのまま通る。何も無い画素も透明のまま (ADR-0011 決定 1)")
    func thresholdPassesZeroOpacityPixelsThrough() throws {
        func after(level: Float) throws -> [LinearRGBA] {
            let canvas = try makeCanvas(width: 4, height: 1)
            try canvas.draw {
                canvas.set(0, 0, LinearRGBA(premultipliedRed: 0.5, green: 0.2, blue: 0, alpha: 0))
                canvas.set(1, 0, LinearRGBA(premultipliedRed: 0.02, green: 0.01, blue: 0, alpha: 0))
                canvas.filter([.threshold(level: level)])
            }
            return (0..<4).map { canvas.get($0, 0) }
        }
        let original = try after(level: 0)
        // level 0 (全部が届く) でも、level 1 (どれも届かない) でも、不透明度 0 の光は同じ値のまま
        for level: Float in [0, 0.3, 1] {
            let result = try after(level: level)
            for index in 0..<2 {
                #expect(result[index] == original[index], "level \(level) で不透明度 0 の光 \(index) が動いた: \(result[index])")
            }
            #expect(result[2] == LinearRGBA.transparent, "何も無い画素が塗られた")
        }
        // 光は本当に持っている (検査が空振りしていない): 0.02 の弱い光が 1 の光にならない
        #expect(original[1].red < 0.1 && original[1].red > 0, "前提が崩れている: \(original[1])")
        #expect(original[1].alpha == 0)
    }

    @Test("明るさが負の画素 (引いて負にした分) は、level が 0 でも黒になる。0 の画素は白")
    func thresholdTurnsNegativeBrightnessBlack() throws {
        let canvas = try makeCanvas(width: 2, height: 1)
        try canvas.draw {
            canvas.set(0, 0, LinearRGBA(premultipliedRed: -0.2, green: -0.2, blue: -0.2, alpha: 1))
            canvas.set(1, 0, LinearRGBA.linear(red: 0, green: 0, blue: 0))
            canvas.filter([.threshold(level: 0)])
        }
        let image = try read(canvas)
        #expect(image[0, 0] == (0, 0, 0, 255), "負の明るさが黒でない: \(image[0, 0])")
        #expect(image[1, 0] == (255, 255, 255, 255), "0 の画素が白でない: \(image[1, 0])")
    }

    @Test("半透明の画素でも、ちょうどの値は白で 1 つ上の level は黒。不透明度を割り戻さずに比べる")
    func thresholdTreatsTheExactValueAsWhiteWhenSemiTransparent() throws {
        for alpha: Float in [0.1, 0.25, 0.4, 0.5, 0.75, 0.9] {
            let colors = (0...255).map { value -> LinearRGBA in
                let level = Float(value) / 255
                return LinearRGBA.display(red: level, green: level, blue: level, alpha: alpha)
            }
            for k in [1, 2, 64, 127, 128, 200, 254, 255] {
                let image = try thresholded(colors, level: Float(k) / 255)
                var wrong: [Int] = []
                for v in 0...255 where image[v, 0].alpha > 0 {
                    if (image[v, 0].red == 255) != (v >= k) { wrong.append(v) }
                }
                #expect(wrong.isEmpty, "不透明度 \(alpha)・level \(k)/255 で白黒が違う灰: \(wrong.prefix(8))")
            }
        }
    }

    @Test("ちょうどの値 (v / 255 の灰に level: v / 255) は白で、1 つ上の level は黒。0…255 の全部で")
    func thresholdTreatsTheExactValueAsWhite() throws {
        let gray = { (value: Float) in LinearRGBA.display(red: value / 255, green: value / 255, blue: value / 255) }
        let colors = (0...255).map { gray(Float($0)) }
        for k in [0, 1, 2, 64, 127, 128, 129, 200, 254, 255] {
            let image = try thresholded(colors, level: Float(k) / 255, background: true)
            var wrong: [Int] = []
            for v in 0...255 {
                let white = image[v, 0].red == 255
                if white != (v >= k) { wrong.append(v) }
            }
            #expect(wrong.isEmpty, "level \(k)/255 で白黒が違う灰: \(wrong.prefix(8))")
        }
    }

    @Test("シェーダに写した P3 → sRGB の係数は、Swift の正本 (ColorPrimaries) と同じ")
    func shaderMatrixMatchesTheSwiftOriginal() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MokumeCore/Drawing/Shaders/Effects/Builtin.metal")
        let text = try String(contentsOf: source, encoding: .utf8)
        let pattern = try NSRegularExpression(
            pattern: #"dot\(premultiplied, float3\(([-0-9.]+), ([-0-9.]+), ([-0-9.]+)\)\)"#)
        let range = NSRange(text.startIndex..., in: text)
        let rows = pattern.matches(in: text, range: range).map { match in
            (1...3).map { Double(text[Range(match.range(at: $0), in: text)!])! }
        }
        try #require(rows.count == 3, "シェーダの係数の行が 3 本見つからない (\(rows.count))")
        // 正本の行は、基底ベクトルを移した列から組み直す
        let columns = (0..<3).map { j -> SIMD3<Float> in
            var unit = SIMD3<Float>(0, 0, 0)
            unit[j] = 1
            return ColorPrimaries.sRGB(fromWorking: unit)
        }
        for i in 0..<3 {
            for j in 0..<3 {
                #expect(
                    abs(rows[i][j] - Double(columns[j][i])) < 1e-6,
                    "行 \(i) の \(j) 番目: シェーダ \(rows[i][j]) 対 正本 \(columns[j][i])")
            }
        }
    }

    @Test("彩度の高い色の 2 値化は、CPU の brightness() の答えと一致する (境目の少し下は白、少し上は黒)")
    func thresholdAgreesWithTheCPUBrightnessOnSaturatedColors() throws {
        let colors: [LinearRGBA] = [
            .display(red: 0.7, green: 0.1, blue: 0.0), .display(red: 0.0, green: 0.7, blue: 0.1),
            .display(red: 0.1, green: 0.0, blue: 0.7), .display(red: 0.6, green: 0.6, blue: 0.0),
        ]
        for color in colors {
            let boundary = brightness(color) / 100
            let below = try thresholded([color], level: boundary - 0.02, background: true)
            let above = try thresholded([color], level: boundary + 0.02, background: true)
            #expect(below[0, 0].red == 255, "境目 \(boundary) の少し下で白でない: \(color)")
            #expect(above[0, 0].red == 0, "境目 \(boundary) の少し上で黒でない: \(color)")
        }
    }

    // MARK: - 名前の衝突 (反証 11)

    /// 音の例が定番にする `var filter: …` を持つスケッチ。**組めること自体が検査である。**
    final class SketchWithAFilterProperty: Sketch {
        struct LowPass { var cutoff: Float }
        var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
        var filter: LowPass? = LowPass(cutoff: 500)
        func draw() {
            background(255)
            filter([.invert()])
            _ = filter?.cutoff
        }
    }

    @Test("スケッチの property `filter` があっても、修飾なしの filter([...]) は口へ解決され、property は読める")
    func aPropertyNamedFilterDoesNotShadowTheMouth() throws {
        let sketch = SketchWithAFilterProperty()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 })
        try runtime.advance()
        #expect(try runtime.target.encodeToImage().read()[4, 4] == (0, 0, 0, 255))
        #expect(sketch.filter?.cutoff == 500)
    }

    // MARK: - Image.filtered の作業の面 (反証 2・3)

    private func grayImage(on canvas: Canvas, level: Float, alpha: Float = 1) throws -> Image {
        let image = try canvas.createImage(2, 1)
        image.set(0, 0, LinearRGBA.display(red: level, green: level, blue: level, alpha: alpha))
        image.set(1, 0, LinearRGBA.display(red: level, green: level, blue: level, alpha: alpha))
        return image
    }

    @Test("同じ絵に filtered() を続けて呼んでも、作業の面は使い回し、前の呼び出しの絵が残らない")
    func filteredReusesItsWorkspaceWithoutLeaking() throws {
        let canvas = try makeCanvas(width: 4, height: 4)
        let source = try grayImage(on: canvas, level: 0.9)
        #expect(source.filterWorkspace == nil, "掛ける前から作業の面がある")
        let first = source.filtered([.threshold(level: 0.5)])
        let workspace = try #require(source.filterWorkspace)
        #expect(first.get(0, 0) == LinearRGBA.linear(red: 1, green: 1, blue: 1))
        // 同じ絵を透明に書き換えて、もう一度。前の呼び出しの白い絵が作業の面に残っていれば、透明にならない
        source.set(0, 0, .transparent)
        source.set(1, 0, .transparent)
        let second = source.filtered([.invert()])
        #expect(source.filterWorkspace === workspace, "2 回目で作業の面を作り直した")
        #expect(second.get(0, 0) == LinearRGBA.transparent, "前の呼び出しの絵が作業の面に残った: \(second.get(0, 0))")
        // 最初の呼び出しの返り値は、作業の面を使い回しても書き換わらない
        #expect(first.get(0, 0) == LinearRGBA.linear(red: 1, green: 1, blue: 1), "返した絵が後の呼び出しで書き換わった")
    }

    @Test("filtered() の注意 (数でない値・範囲の外) は、呼ぶたびにではなく 1 度だけ言う")
    func filteredWarnsOnce() throws {
        let canvas = try makeCanvas(width: 4, height: 4)
        let source = try grayImage(on: canvas, level: 0.5)
        _ = source.filtered([.threshold(level: 2), .blur(radius: .nan)])
        let workspace = try #require(source.filterWorkspace)
        let rounded = try #require(workspace.warnings.message(for: .filterSide(.roundedThresholdLevel)))
        let bad = try #require(workspace.warnings.message(for: .filterSide(.badEffect)))
        #expect(rounded.hasPrefix("filtered()"), Comment(rawValue: rounded))
        #expect(bad.hasPrefix("filtered()"), Comment(rawValue: bad))
        // 2 回目は同じ控えを見るので、文面は変わらず (言い直さず) 同じ鍵のまま
        _ = source.filtered([.threshold(level: 2), .blur(radius: .nan)])
        #expect(source.filterWorkspace === workspace)
        #expect(workspace.warnings.message(for: .filterSide(.roundedThresholdLevel)) == rounded)
    }

    @Test("面の中で効果が失敗したら、効果の掛かっていない絵を成功として返さず、filtered() の文で 1 度だけ言う")
    func filteredFailureIsNotSwallowed() throws {
        let canvas = try makeCanvas(width: 4, height: 4)
        let source = try grayImage(on: canvas, level: 0.9)
        _ = source.filtered([.invert()])
        let workspace = try #require(source.filterWorkspace)
        workspace.failEffectPassForTesting = 0
        let result = source.filtered([.invert()])
        let said = try #require(workspace.warnings.message(for: .filterFailed))
        #expect(said.hasPrefix("filtered(): could not run the effects"), Comment(rawValue: said))
        #expect(!workspace.warnings.hasWarned(.effectFailed), "フレームの終わりの文が使われた")
        #expect(result !== source)
        #expect(result.get(0, 0) == source.get(0, 0), "失敗したときは掛けない写しを返す")
    }

    // MARK: - 時刻・共有・打ち切り・鍵・画面の一致 (2 回目の反証)

    /// 時刻を色に出す効果で絵を作り、`filtered()` の結果を毎フレーム控えるスケッチ。
    final class FilteredTimeSketch: Sketch {
        var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
        var source: Image?
        var effect: EffectShader?
        var seen: [Float] = []
        func setup() {
            source = try? createImage(2, 2)
            source?.set(0, 0, LinearRGBA.display(red: 0.5, green: 0.5, blue: 0.5))
            effect = try? makeEffect(
                "float4 effect(Pixel in, Values values) { return float4(float3(in.time * 10.0), 1.0); }")
        }
        func draw() {
            background(0)
            guard let source, let effect else { return }
            seen.append(source.filtered([.custom(effect)]).get(0, 0).red)
        }
    }

    @Test("filtered() の .custom が読む秒は、走っているスケッチの時刻で進む (作業の面が自分の時刻を持たない)")
    func filteredCustomEffectReadsTheSketchTime() throws {
        let sketch = FilteredTimeSketch()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60))
        for _ in 0..<4 { try runtime.advance() }
        #expect(sketch.seen.count == 4)
        // フレーム 0 の秒は 0 なので黒。以後は 1/60 秒ずつ進み、10 倍した値が赤に出る
        #expect(sketch.seen[0] == 0, "最初のフレームの秒が 0 でない: \(sketch.seen)")
        for index in 1..<4 {
            #expect(sketch.seen[index] > sketch.seen[index - 1], "秒が進んでいない: \(sketch.seen)")
        }
        let expected = Float(3) / 60 * 10
        #expect(abs(sketch.seen[3] - expected) < 0.02, "秒がスケッチの時刻と合わない: \(sketch.seen[3]) 対 \(expected)")
    }

    @Test("スケッチの外から呼んだ .custom の秒は 0 になる (説明に書いた約束)")
    func filteredOutsideASketchReadsTimeZero() throws {
        let canvas = try makeCanvas(width: 4, height: 4)
        let source = try grayImage(on: canvas, level: 0.5)
        let timed = try canvas.makeEffect(
            "float4 effect(Pixel in, Values values) { return float4(float3(in.time * 10.0 + 0.25), 1.0); }")
        let result = source.filtered([.custom(timed)])
        #expect(abs(result.get(0, 0).red - 0.25) < 0.01, "\(result.get(0, 0))")
    }

    @Test("同じ大きさの別の絵・写しは作業の面を使い回し、大きさが違えば別の面になる。ライブラリは組み直さない")
    func filteredSharesTheWorkspaceBySize() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 8, height: 8)
        let a = try grayImage(on: canvas, level: 0.9)
        let b = try grayImage(on: canvas, level: 0.2)
        let first = a.filtered([.threshold(level: 0.5)])
        #expect(gpu.filterWorkspaces.made == 1)
        // 返った絵・別の絵・写しに掛けても、同じ面を使う (面一式も効果の組み立ても払わない)
        _ = first.filtered([.invert()])
        _ = b.filtered([.invert()])
        _ = a.copy().filtered([.invert()])
        #expect(gpu.filterWorkspaces.made == 1, "同じ大きさで面を作り直した: \(gpu.filterWorkspaces.made)")
        #expect(first.filterWorkspace === b.filterWorkspace)
        // 大きさが違えば別の面
        let wide = try canvas.createImage(3, 1)
        _ = wide.filtered([.invert()])
        #expect(gpu.filterWorkspaces.made == 2)
        #expect(wide.filterWorkspace !== a.filterWorkspace)
        // 組み込みの効果のライブラリは、面が増えても 1 度だけ組む (本体の面の分も含めて)
        try canvas.draw { canvas.effects([.invert()]) }
        #expect(gpu.shaders.librariesBuilt["builtin"] == 1, "ライブラリを組み直した: \(gpu.shaders.librariesBuilt)")
    }

    @Test("走っているスケッチの面が作業の面を持つので、掛け終えた絵が手放されても面は残る。持つのは最近の 2 つまで")
    func theRunningSketchKeepsTheWorkspaces() throws {
        final class Chained: Sketch {
            var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
            func draw() {
                background(0)
                // 毎フレーム新しい写しに掛ける (写しは手放される)
                if let image = try? createImage(2, 2) { _ = image.copy().filtered([.invert()]) }
                if let image = try? createImage(3, 1) { _ = image.copy().filtered([.invert()]) }
            }
        }
        let gpu = try RenderDevice()
        let runtime = try SketchRuntime(sketch: Chained(), gpu: gpu, clock: nil, now: { 0 })
        try runtime.advance()
        let made = gpu.filterWorkspaces.made
        #expect(made == 2, "前提が崩れている (大きさ 2 つに掛けて 2 面)")
        // 手放された写しに掛け続けても、スケッチの面が面を持つので作り直さない
        try runtime.advance()
        try runtime.advance()
        #expect(gpu.filterWorkspaces.made == made, "毎フレーム面を作り直している: \(made) → \(gpu.filterWorkspaces.made)")
        #expect(runtime.canvas.filterWorkspaces.count == 2)
    }

    @Test("スケッチの面が持つ作業の面は、最近使った 2 つまで。古いものから手放す")
    func theSketchKeepsOnlyTheRecentWorkspaces() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 8, height: 8)
        let first = try Canvas(target: RenderTarget(gpu: gpu, width: 1, height: 1), gpu: gpu)
        let second = try Canvas(target: RenderTarget(gpu: gpu, width: 2, height: 1), gpu: gpu)
        let third = try Canvas(target: RenderTarget(gpu: gpu, width: 3, height: 1), gpu: gpu)
        for workspace in [first, second, third] { canvas.holdFilterWorkspace(workspace) }
        #expect(canvas.filterWorkspaces.count == Canvas.filterWorkspaceLimit)
        #expect(canvas.filterWorkspaces.first === third && canvas.filterWorkspaces.last === second, "最近使った順でない")
        // 持っているものを使い直すと、先頭へ上がる
        canvas.holdFilterWorkspace(second)
        #expect(canvas.filterWorkspaces.first === second && canvas.filterWorkspaces.count == 2)
    }

    @Test("作業の面を作れない大きさは覚え、作り直しを試さず、警告も大きさごとに 1 度だけ。効果を掛けない写しを返す")
    func unavailableWorkspaceIsRememberedAndWarnedOnce() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 8, height: 8)
        let source = try grayImage(on: canvas, level: 0.9)
        gpu.filterWorkspaces.failsNextMakeForTesting = .invalidSize(width: 2, height: 1)
        let digest = WarningDigest()
        let results = Diagnostics.$digest.withValue(digest) {
            (0..<3).map { _ in source.filtered([.invert()]) }
        }
        for result in results {
            #expect(result.get(0, 0) == source.get(0, 0), "作れなかったときは、掛けない写しを返す")
        }
        #expect(gpu.filterWorkspaces.made == 0, "覚えたはずの大きさで作り直しを試した")
        let lines = digest.takeUnreported().filter { $0.contains("filtered()") }
        #expect(lines.count == 1, "警告が 1 度にならない: \(lines)")
        // 別の大きさは別に試す
        let other = try canvas.createImage(3, 1)
        _ = other.filtered([.invert()])
        #expect(gpu.filterWorkspaces.made == 1)
    }

    @Test("別の面への投入が打ち切られても filtered() は掛かる。この呼び出しの投入が打ち切られたら、掛けない写しを返して言う")
    func filteredJudgesOnlyItsOwnSubmissions() throws {
        let gpu = try RenderDevice()
        let host = try CanvasFixture.make(gpu: gpu, width: 8, height: 8)
        let other = try CanvasFixture.make(gpu: gpu, width: 8, height: 8)
        let source = try grayImage(on: host, level: 0.9)
        // 別の面の描画が打ち切られた後
        gpu.dropsNextSubmissionForTesting = DroppedWorkReadersTests.victim
        try other.draw { other.background(255) }
        let applied = source.filtered([.threshold(level: 0.5)])
        #expect(applied.get(0, 0) == LinearRGBA.linear(red: 1, green: 1, blue: 1), "別の面の打ち切りで、効果が掛からなかった")
        // この呼び出しが積む最初の投入が打ち切られたとき
        gpu.dropsNextSubmissionForTesting = DroppedWorkReadersTests.victim
        let refused = source.filtered([.threshold(level: 0.5)])
        #expect(refused.get(0, 0) == source.get(0, 0), "自分の投入が打ち切られたのに、掛かった絵を返した")
        let workspace = try #require(source.filterWorkspace)
        #expect(workspace.warnings.hasWarned(.filterFailed), "打ち切りを言っていない")
    }

    @Test("受け口の注意の鍵は filter() と effects() で別で、片方で出しても、もう片方の注意が黙らない")
    func warningKeysAreSeparatePerMouth() throws {
        for effectsFirst in [true, false] {
            let canvas = try makeCanvas(width: 8, height: 8)
            try canvas.draw {
                if effectsFirst {
                    canvas.effects([.threshold(level: 2), .blur(radius: .nan)])
                    canvas.filter([.threshold(level: 2), .blur(radius: .nan)])
                } else {
                    canvas.filter([.threshold(level: 2), .blur(radius: .nan)])
                    canvas.effects([.threshold(level: 2), .blur(radius: .nan)])
                }
            }
            for key in [Canvas.Warning.roundedThresholdLevel, .badEffect] {
                #expect(canvas.warnings.hasWarned(key), "effects() の注意が出ていない (\(effectsFirst))")
                #expect(canvas.warnings.hasWarned(.filterSide(key)), "filter() の注意が出ていない (\(effectsFirst))")
            }
            let said = try #require(canvas.warnings.message(for: .filterSide(.badEffect)))
            #expect(said.hasPrefix("filter()"), "呼んだ口の名前を名乗らない: \(said)")
            #expect(try #require(canvas.warnings.message(for: .badEffect)).hasPrefix("effects()"))
        }
    }

    @Test("止まっている間に filter() を掛けた画面は、redraw() の後の画面と一致する。可換でない組み合わせ (threshold と blur) でも")
    func stoppedScreenMatchesTheRedrawnScreen() throws {
        let canvas = try makeCanvas(width: 48, height: 48)
        let effects: [Effect] = [.threshold(level: 0.5)]
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.circle(24, 24, 28)
            canvas.effects(effects)
        }
        Self.whileStopped(canvas) { canvas.filter([.blur(radius: 5)]) }
        let shown = try read(canvas)
        // 前提: ぼかしは 2 値化の前に効いている — 画面は 2 値のまま (G(E(x)) なら縁が中間の灰になる)
        var grey = 0
        for y in 0..<48 { for x in 0..<48 where ![0, 255].contains(shown[x, y].red) { grey += 1 } }
        #expect(grey == 0, "画面に 2 値でない画素がある (ぼかしが 2 値化の後に効いた): \(grey)")
        // redraw(): 塗り直さず、同じ効果だけを頼む
        try canvas.draw { canvas.effects(effects) }
        let redrawn = try read(canvas)
        var different = 0
        for y in 0..<48 { for x in 0..<48 where shown[x, y] != redrawn[x, y] { different += 1 } }
        #expect(different == 0, "止まっている間の画面と redraw() 後の画面が \(different) 画素違う")
    }

    @Test("止まっている間の filter() の投入が打ち切られたら 1 度知らせる。打ち切りが無ければ知らせず、覚えも残さない")
    func aDroppedFilterInTheStoppedPeriodIsAnnounced() throws {
        for dropped in [true, false] {
            let gpu = try RenderDevice()
            let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
            try canvas.draw {
                canvas.background(77)
                canvas.effects([.invert()])
            }
            // 途中の描き切りも投入を 1 本積むので、filter() 自身の投入の直前に仕掛ける
            if dropped {
                canvas.beforeFilterCommitForTesting = {
                    gpu.dropsNextSubmissionForTesting = DroppedWorkReadersTests.victim
                }
            }
            Self.whileStopped(canvas) { canvas.filter([.threshold(level: 0.5)]) }
            _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
            gpu.revokeDroppedDeliveries()
            #expect(canvas.warnings.hasWarned(.filterDropped) == dropped, "打ち切りの知らせが合わない (打ち切り \(dropped))")
            #expect(canvas.filterSubmissions.isEmpty, "結末が届いたのに覚えが残っている")
        }
    }
}
