// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 利用者が自分で持つ描き場所。GPU を要する。
@Suite(
    "描き場所",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct GraphicsTests {
    private static let size = 64

    // 目印の色は作業空間の原色 (`.linear`) で書く。この検査の主題は色の入口ではなく、
    // 純色のまま 255 / 0 に出るので期待値をそのまま書ける (入口は ColorSurfaceTests が見る — #911)
    private let black = LinearRGBA.display(red: 0, green: 0, blue: 0)
    private let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)
    private let white = LinearRGBA.display(red: 1, green: 1, blue: 1)

    private func makeCanvas(width: Int = size, height: Int = size) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.output.encodeForDisplay()
    }

    /// 描き場所を 1 色で塗る。
    private func paint(_ graphics: Canvas, _ color: LinearRGBA) {
        graphics.beginDraw()
        graphics.background(color)
        graphics.endDraw()
    }

    // MARK: - 焼いて置ける (完了条件 1)

    @Test("描き場所へ焼いた絵が、置いた場所に出る")
    func whatIsBakedShowsUpWhereItIsPlaced() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(24, 24)
        paint(layer, red)

        try canvas.draw {
            canvas.background(black)
            canvas.image(layer, 20, 20)
        }

        let image = try pixels(of: canvas)
        // 置いた区画の中は描き場所の色
        #expect(image[32, 32] == (255, 0, 0, 255))
        // 外は画面の背景のまま
        #expect(image[8, 8] == (0, 0, 0, 255))
        #expect(image[56, 56] == (0, 0, 0, 255))
    }

    @Test("描き場所は画面と別の大きさを持てる")
    func theGraphicsHasItsOwnSize() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(24, 12)
        #expect(layer.width == 24)
        #expect(layer.height == 12)
        #expect(canvas.width == Float(Self.size))
    }

    // MARK: - 既定で透けている (完了条件 2)

    @Test("何も描いていない描き場所を置いても、下の絵が消えない")
    func anUntouchedGraphicsIsTransparent() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(32, 32)

        try canvas.draw {
            canvas.background(green)
            canvas.image(layer, 0, 0)
        }

        // **既定が不透明だと、ここが黒で埋まる。** 重ねる用途で毎回消す作法が要る形に
        // なっていないことを、置いた区画のど真ん中で見る
        let image = try pixels(of: canvas)
        #expect(image[16, 16] == (0, 255, 0, 255))
    }

    @Test("描いた区画だけが出て、描いていない区画は透ける")
    func onlyTheDrawnPartCoversWhatIsBelow() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(32, 32)
        layer.beginDraw()
        layer.noStroke()
        layer.fill(red)
        layer.rect(0, 0, 16, 16)
        layer.endDraw()

        try canvas.draw {
            canvas.background(green)
            canvas.image(layer, 0, 0)
        }

        let image = try pixels(of: canvas)
        #expect(image[8, 8] == (255, 0, 0, 255))
        #expect(image[24, 24] == (0, 255, 0, 255))
    }

    // MARK: - 置いた時点の絵が残る (完了条件 3)

    @Test("同じフレームで描き換えて 2 度置くと、置いた時点の絵が 2 つ出る")
    func eachPlacementKeepsThePictureItWasGiven() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(16, 16)

        try canvas.draw {
            canvas.background(black)
            paint(layer, red)
            canvas.image(layer, 0, 0)
            // **置いたあとに描き換える。** 素直に組むと、先に置いた場所まで青くなる
            paint(layer, blue)
            canvas.image(layer, 32, 0)
        }

        let image = try pixels(of: canvas)
        #expect(image[8, 8] == (255, 0, 0, 255))
        #expect(image[40, 8] == (0, 0, 255, 255))
    }

    @Test("3 度描き換えて 3 度置いても、それぞれの時点の絵が出る")
    func threePlacementsKeepThreePictures() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(16, 16)

        try canvas.draw {
            canvas.background(black)
            for (index, color) in [red, green, blue].enumerated() {
                paint(layer, color)
                canvas.image(layer, Float(index) * 20, 0)
            }
        }

        let image = try pixels(of: canvas)
        #expect(image[8, 8] == (255, 0, 0, 255))
        #expect(image[28, 8] == (0, 255, 0, 255))
        #expect(image[48, 8] == (0, 0, 255, 255))
    }

    /// 効果を通した描き場所を置いてから、その描き場所へ塗り直さずに描き足す ([#1469])。
    ///
    /// 描き場所は次のフレームの頭で効果を通す前の絵へ戻るが、**戻すのは自分を置いている面を
    /// 描き切らせた後**である。先に戻すと、先に置いた側が効果を通す前の絵 (赤) を拾う —
    /// 置いた時点の絵は、前のフレームの出口 (反転した絵) である。後に置いた側は、効果を
    /// 通す前の絵に描き足して反転した絵になる。
    ///
    /// [#1469]: https://github.com/mokume-metal/mokume/issues/1469
    @Test("効果を通した描き場所を置いてから描き足しても、置いた時点の絵が残る")
    func placedGraphicsKeepTheirEffectedPictureWhenDrawnOver() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(16, 16)
        layer.beginDraw()
        layer.background(red)
        layer.effects([.invert()])
        layer.endDraw()

        try canvas.draw {
            canvas.background(black)
            canvas.image(layer, 0, 0)
            // **塗り直さずに**右半分だけ描き足し、もう一度反転する
            layer.beginDraw()
            layer.noStroke()
            layer.fill(blue)
            layer.rect(8, 0, 8, 16)
            layer.effects([.invert()])
            layer.endDraw()
            canvas.image(layer, 32, 0)
        }

        let image = try pixels(of: canvas)
        // 先に置いた絵は、前のフレームの出口 (赤の反転) のまま
        #expect(image[4, 8] == (0, 255, 255, 255), "先に置いた絵が、効果を通す前の絵に変わった")
        #expect(image[12, 8] == (0, 255, 255, 255))
        // 後に置いた絵は、効果を通す前の赤に青を描き足して反転したもの
        #expect(image[36, 8] == (0, 255, 255, 255), "描き場所の入りに前のフレームの効果が残った")
        #expect(image[44, 8] == (255, 255, 0, 255))
    }

    @Test("描き場所を貼った立体も、貼った時点の絵で焼かれる")
    func aPastedGraphicsKeepsThePictureItWasGiven() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(16, 16)

        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            paint(layer, red)
            canvas.texture(layer)
            canvas.rect(0, 0, 24, 24)
            paint(layer, blue)
            canvas.texture(layer)
            canvas.rect(32, 0, 24, 24)
        }

        let image = try pixels(of: canvas)
        #expect(image[12, 12] == (255, 0, 0, 255))
        #expect(image[44, 12] == (0, 0, 255, 255))
    }

    // MARK: - 貼り直さずに塗り続けても、置いた時点の絵が残る (#1543)

    @Test("描き場所を 1 度だけ貼って塗り続けても、置くたびにその時点の絵が出る")
    func aPastedGraphicsKeepsItsPictureWithoutPastingAgain() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(16, 16)

        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            paint(layer, red)
            canvas.texture(layer)
            canvas.rect(0, 0, 24, 24)
            // **貼り直さずに**描き換えて、もう 1 つ置く
            paint(layer, blue)
            canvas.rect(32, 0, 24, 24)
            paint(layer, green)
        }

        let image = try pixels(of: canvas)
        #expect(image[12, 12] == (255, 0, 0, 255))
        #expect(image[44, 12] == (0, 0, 255, 255), "置いた後に描き換えた絵が出た")
    }

    @Test("立体に 1 度だけ貼って塗り続けても、置くたびにその時点の絵が出る")
    func aSolidKeepsThePictureWithoutPastingAgain() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(16, 16)

        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            paint(layer, red)
            canvas.texture(layer)
            canvas.push()
            canvas.translate(16, 32, 0)
            canvas.plane(24, 24)
            canvas.pop()
            paint(layer, blue)
            canvas.push()
            canvas.translate(48, 32, 0)
            canvas.plane(24, 24)
            canvas.pop()
            paint(layer, green)
        }

        let image = try pixels(of: canvas)
        #expect(image[16, 32] == (255, 0, 0, 255))
        #expect(image[48, 32] == (0, 0, 255, 255), "置いた後に描き換えた絵が出た")
    }

    /// `placedFirst` は、塗り直す前に 1 度置いておくか。置いておくと、塗り直した後も読む面が
    /// 描き場所のまま続くので、**面が変わらなくても記録し直す**ことを見られる。
    @Test("貼った後に背景で塗り直しても、置いた時点の絵が出る", arguments: [false, true])
    func aPastedGraphicsSurvivesABackgroundBeforeItIsPlaced(placedFirst: Bool) throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(16, 16)

        try canvas.draw {
            canvas.noStroke()
            paint(layer, red)
            canvas.texture(layer)
            if placedFirst { canvas.rect(32, 32, 24, 24) }
            // 塗り直しは溜めたものと一緒に「置いた記録」も落とす
            canvas.background(black)
            canvas.rect(0, 0, 24, 24)
            paint(layer, green)
        }

        #expect(try pixels(of: canvas)[12, 12] == (255, 0, 0, 255), "置いた後に描き換えた絵が出た")
    }

    @Test("最初のフレームで 1 度だけ貼れば、後のフレームでも置いた時点の絵が出る")
    func aPastedGraphicsKeepsItsPictureAcrossFrames() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(16, 16)

        for frame in 0..<3 {
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                paint(layer, blue)
                if frame == 0 { canvas.texture(layer) }
                canvas.rect(0, 0, 24, 24)
                paint(layer, green)
            }
            #expect(
                try pixels(of: canvas)[12, 12] == (0, 0, 255, 255),
                "\(frame + 1) フレーム目で、置いた後に描き換えた絵が出た")
        }
    }

    @Test("描き場所を貼って保持した形も、置くたびにその時点の絵が出る")
    func aHeldShapeKeepsThePictureOfEachPlacement() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(16, 16)
        let tile = canvas.createShape {
            canvas.noStroke()
            canvas.texture(layer)
            canvas.rect(0, 0, 24, 24)
        }

        try canvas.draw {
            canvas.background(black)
            paint(layer, red)
            canvas.shape(tile, 0, 0)
            paint(layer, blue)
            canvas.shape(tile, 32, 0)
            paint(layer, green)
        }

        let image = try pixels(of: canvas)
        #expect(image[12, 12] == (255, 0, 0, 255), "置いた後に描き換えた絵が出た")
        #expect(image[44, 12] == (0, 0, 255, 255), "置いた後に描き換えた絵が出た")
    }

    // MARK: - 背景が独立している (完了条件 4)

    @Test("描き場所の背景は、画面の背景と独立に決められる")
    func theGraphicsHasItsOwnBackground() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(24, 24)
        paint(layer, white)

        try canvas.draw {
            canvas.background(black)
            canvas.image(layer, 20, 20)
        }

        let image = try pixels(of: canvas)
        #expect(image[32, 32] == (255, 255, 255, 255))
        #expect(image[4, 4] == (0, 0, 0, 255))
    }

    // MARK: - 積み上がる (完了条件 5)

    @Test("消さずに描き続けると、前のフレームの上に積み上がる")
    func whatWasDrawnBeforeStaysUntilItIsCleared() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(64, 64)

        for step in 0..<3 {
            layer.beginDraw()
            layer.noStroke()
            layer.fill(red)
            layer.rect(Float(step) * 16, 0, 8, 8)
            layer.endDraw()
        }

        try canvas.draw {
            canvas.background(black)
            canvas.image(layer, 0, 0)
        }

        // **3 つとも残っている。** 自動で消す形だと最後の 1 つしか出ない
        let image = try pixels(of: canvas)
        #expect(image[4, 4] == (255, 0, 0, 255))
        #expect(image[20, 4] == (255, 0, 0, 255))
        #expect(image[36, 4] == (255, 0, 0, 255))
    }

    @Test("塗り直しを頼めば、前のフレームは消える")
    func clearingTheGraphicsRemovesWhatCameBefore() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(64, 64)

        for step in 0..<3 {
            layer.beginDraw()
            layer.background(.transparent)
            layer.noStroke()
            layer.fill(red)
            layer.rect(Float(step) * 16, 0, 8, 8)
            layer.endDraw()
        }

        try canvas.draw {
            canvas.background(black)
            canvas.image(layer, 0, 0)
        }

        let image = try pixels(of: canvas)
        #expect(image[4, 4] == (0, 0, 0, 255))
        #expect(image[36, 4] == (255, 0, 0, 255))
    }

    // MARK: - 立体も焼ける (完了条件 6)

    @Test("描き場所にも立体が焼ける — 手前が奥を隠す")
    func solidsAreBakedWithTheirOwnDepth() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(Self.size, Self.size)

        layer.beginDraw()
        layer.background(black)
        // 先に手前 (奥行きが正) の赤、あとから奥の緑。**描いた順ではなく奥行きで決まる**
        layer.fill(red)
        layer.push()
        layer.translate(32, 32, 20)
        layer.plane(30, 30)
        layer.pop()
        layer.fill(green)
        layer.push()
        layer.translate(32, 32, -20)
        layer.plane(30, 30)
        layer.pop()
        layer.endDraw()

        try canvas.draw {
            canvas.background(blue)
            canvas.image(layer, 0, 0)
        }

        let image = try pixels(of: canvas)
        #expect(image[32, 32] == (255, 0, 0, 255))
    }

    @Test("描き場所を描き換えても、画面側の立体の前後関係が崩れない")
    func redrawingTheGraphicsKeepsTheScreenDepth() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(16, 16)
        paint(layer, white)

        try canvas.draw {
            canvas.background(black)
            // 手前の赤を先に置く
            canvas.fill(red)
            canvas.push()
            canvas.translate(32, 32, 20)
            canvas.plane(20, 20)
            canvas.pop()

            // 置いてから描き換える = このフレームの途中で描き切ることになる
            canvas.image(layer, 0, 0)
            paint(layer, blue)
            canvas.image(layer, 48, 48)

            // 奥の緑をあとから置く。**描いた順ではなく奥行きで決まる**ので、
            // 途中の描き切りで奥行きが落ちていると、ここで赤が塗り潰される
            canvas.fill(green)
            canvas.push()
            canvas.translate(32, 32, -20)
            canvas.plane(60, 60)
            canvas.pop()
        }

        let image = try pixels(of: canvas)
        #expect(image[32, 32] == (255, 0, 0, 255))
    }

    // MARK: - 段が読み書きする絵と同じもの (ADR-0023 決定 1)

    @Test("描き場所は立体に貼れる")
    func theGraphicsCanBePastedOnASolid() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(16, 16)
        paint(layer, red)

        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.texture(layer)
            canvas.push()
            canvas.translate(32, 32, 0)
            canvas.plane(40, 40)
            canvas.pop()
        }

        let image = try pixels(of: canvas)
        #expect(image[32, 32] == (255, 0, 0, 255))
        #expect(image[4, 4] == (0, 0, 0, 255))
    }

    @Test("描き場所にも効果が通る")
    func stagesRunOnTheGraphicsToo() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(32, 32)

        layer.beginDraw()
        layer.background(red)
        layer.effects([.invert()])
        layer.endDraw()

        try canvas.draw {
            canvas.background(black)
            canvas.image(layer, 0, 0)
        }

        // 反転した赤は水色
        let image = try pixels(of: canvas)
        #expect(image[16, 16] == (0, 255, 255, 255))
    }

    @Test("描き場所の画素を読める")
    func theGraphicsPixelsCanBeRead() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(16, 16)
        paint(layer, red)
        let color = layer.get(8, 8)
        #expect(color.red > 0.9)
        #expect(color.green < 0.01)
        #expect(color.alpha > 0.99)
    }

    // MARK: - 時刻と刻みは作った面と同じ (#1467)

    /// 時刻で脈打つ色。赤は `0.5 + 0.5·sin(πt)` で、0 秒で 0.5、0.5 秒 (30 fps の 16 枚目)
    /// で 1.0 になる。時刻が 0 のまま止まると、16 枚目も 0.5 のまま残る。
    private static let pulse = "float k = 0.5 + 0.5 * sin(in.time * 3.14159265);"
        + " return float4(k, 0.3 * k, 0.9 * (1.0 - k), 1.0);"

    /// 左の半分に描き場所、右の半分に本体の面へ、同じ断片で同じ矩形を塗る
    /// ([#1467] の再現スケッチを縮めたもの)。
    ///
    /// [#1467]: https://github.com/mokume-metal/mokume/issues/1467
    final class PulseSideBySide: Sketch {
        /// 描き場所を描き場所から作るか (完了条件 4)。間の描き場所は描かない。
        var nested = false
        var pulse: Shader?
        var outer: Canvas?
        var graphics: Canvas?
        init() {}
        var settings: SketchSettings { SketchSettings(width: 32, height: 16, frameRate: 30) }
        func setup() {
            pulse = try? makeShader(
                "float4 paint(Fragment in, Values values) { \(GraphicsTests.pulse) }")
            outer = try? createGraphics(16, 16)
            graphics = outer
            if nested { graphics = try? outer?.createGraphics(16, 16) }
        }
        func draw() {
            guard let pulse, let graphics else { return }
            background(.display(red: 0, green: 0, blue: 0))
            graphics.beginDraw()
            graphics.noStroke()
            graphics.shader(pulse)
            graphics.rect(0, 0, 16, 16)
            graphics.endDraw()
            image(graphics, 0, 0)
            noStroke()
            shader(pulse)
            rect(16, 0, 16, 16)
            resetShader()
        }
    }

    /// 1 枚目と 16 枚目の、描き場所を置いた画素と本体の面の画素の赤を返す。
    private func sideBySideReds(nested: Bool) throws -> [(graphics: Float, screen: Float)] {
        let sketch = PulseSideBySide()
        sketch.nested = nested
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
        var reds: [(graphics: Float, screen: Float)] = []
        for frame in 1...16 {
            try runtime.advance()
            guard frame == 1 || frame == 16 else { continue }
            try #require(sketch.graphics != nil && sketch.pulse != nil, "描き場所か断片を作れなかった")
            let pixels = try runtime.target.readPixels()
            reds.append((pixels[8, 8].red, pixels[24, 8].red))
        }
        return reds
    }

    /// 完了条件 1 ([#1467])。直す前は描き場所の時刻が 0 のまま止まり、16 枚目の描き場所が
    /// 0.5 (= `sin(0)`) で残る。1 枚目は本体も 0 秒なので、直す前でも揃う。
    ///
    /// [#1467]: https://github.com/mokume-metal/mokume/issues/1467
    @Test("描き場所で塗った断片も、本体の面と同じ時刻を読む")
    func graphicsFragmentReadsTheSketchTime() throws {
        let reds = try sideBySideReds(nested: false)
        let (first, sixteenth) = (reds[0], reds[1])
        #expect(abs(first.graphics - 0.5) < 0.02, "1 枚目: \(first)")
        #expect(abs(first.graphics - first.screen) < 0.02, "1 枚目: \(first)")
        #expect(abs(sixteenth.screen - 1) < 0.02, "16 枚目: \(sixteenth)")
        #expect(abs(sixteenth.graphics - sixteenth.screen) < 0.02, "16 枚目: \(sixteenth)")
    }

    /// 完了条件 4 ([#1467])。描き場所から作った描き場所も、作った面 (その先の本体の面) と
    /// 同じ時刻を読む。**間の描き場所は 1 度も描かない** — 描いた時点で作った面から写す
    /// 作りなら、ここで古い値が残る。
    ///
    /// [#1467]: https://github.com/mokume-metal/mokume/issues/1467
    @Test("描き場所から作った描き場所も、間を描かなくても本体の面と同じ時刻を読む")
    func nestedGraphicsReadsTheSketchTime() throws {
        let reds = try sideBySideReds(nested: true)
        let (first, sixteenth) = (reds[0], reds[1])
        #expect(abs(first.graphics - first.screen) < 0.02, "1 枚目: \(first)")
        #expect(abs(sixteenth.screen - 1) < 0.02, "16 枚目: \(sixteenth)")
        #expect(abs(sixteenth.graphics - sixteenth.screen) < 0.02, "16 枚目: \(sixteenth)")
    }

    /// 時刻で脈打つ色を返す利用者の効果を、描き場所か本体の面のどちらかに掛ける。
    ///
    /// **本体に掛けた効果は画面全体を上書きする**ので、1 回の走らせ方で両方は比べられない。
    /// 掛け先を変えて 2 回走らせ、同じ画素を比べる。描き場所は毎フレーム塗り直す
    /// (#1469 の焼き込みを混ぜないため)。
    final class PulsingEffect: Sketch {
        var onGraphics = false
        var effect: EffectShader?
        var graphics: Canvas?
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 30) }
        func setup() {
            effect = try? makeEffect(
                "float4 effect(Pixel in, Values values) { \(GraphicsTests.pulse) }")
            graphics = try? createGraphics(16, 16)
        }
        func draw() {
            guard let effect, let graphics else { return }
            let gray = LinearRGBA.display(red: 0.5, green: 0.5, blue: 0.5)
            if onGraphics {
                background(.display(red: 0, green: 0, blue: 0))
                graphics.beginDraw()
                graphics.background(gray)
                graphics.effects([.custom(effect)])
                graphics.endDraw()
                image(graphics, 0, 0)
            } else {
                background(gray)
                effects([.custom(effect)])
            }
        }
    }

    /// 16 枚目の中央の赤。
    private func pulsingEffectRed(onGraphics: Bool) throws -> Float {
        let sketch = PulsingEffect()
        sketch.onGraphics = onGraphics
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
        for _ in 0..<16 { try runtime.advance() }
        try #require(sketch.effect != nil && sketch.graphics != nil, "描き場所か効果を作れなかった")
        return try runtime.target.readPixels()[8, 8].red
    }

    /// 完了条件 2 ([#1467])。直す前は描き場所の効果が時刻 0 の色 (赤 0.5) を返す。
    ///
    /// [#1467]: https://github.com/mokume-metal/mokume/issues/1467
    @Test("描き場所に掛けた効果も、本体の面に掛けた効果と同じ時刻を読む")
    func graphicsEffectReadsTheSketchTime() throws {
        let screen = try pulsingEffectRed(onGraphics: false)
        let graphics = try pulsingEffectRed(onGraphics: true)
        #expect(abs(screen - 1) < 0.02, "本体: \(screen)")
        #expect(abs(graphics - screen) < 0.02, "描き場所: \(graphics) / 本体: \(screen)")
    }

    /// 1 枚目にだけ本体から粒を 1 つずつ出し、片方は本体で、もう片方は描き場所で進める。
    /// **力は掛けない** (#1471 の `drag` の不安定を混ぜないため)。
    final class DriftingDust: Sketch {
        static let start: Float = 4
        var onScreen: Particles?
        var onGraphics: Particles?
        var graphics: Canvas?
        private var emitted = false
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 30) }
        func setup() {
            onScreen = try? makeParticles(count: 1)
            onGraphics = try? makeParticles(count: 1)
            graphics = try? createGraphics(16, 16)
        }
        func draw() {
            guard let onScreen, let onGraphics, let graphics else { return }
            if !emitted {
                emitted = true
                // 毎秒 30 個を 1/30 秒ぶん = 1 個。速さ 60 px/秒で右へ
                for dust in [onScreen, onGraphics] {
                    emit(
                        dust, from: .point(Self.start, 8), rate: 30, speed: 60...60,
                        angle: 0...0, life: 100...100, size: 1...1)
                }
            }
            particles(onScreen)
            graphics.beginDraw()
            graphics.particles(onGraphics)
            graphics.endDraw()
        }
    }

    /// 完了条件 3 ([#1467])。30 fps で 30 枚 (1 秒) 進めると、どちらも出た位置から約 60 px
    /// に居る。直す前は描き場所の刻みが 1/60 のままなので、描き場所で進めた粒は約 30 px
    /// しか進まず、寿命も半分しか減らない。
    ///
    /// [#1467]: https://github.com/mokume-metal/mokume/issues/1467
    @Test("描き場所で進める粒も、本体の面と同じ刻みで進む")
    func graphicsParticlesStepWithTheSketch() throws {
        let sketch = DriftingDust()
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
        for _ in 0..<30 { try runtime.advance() }
        let onScreen = try #require(sketch.onScreen, "粒を作れなかった")
        let onGraphics = try #require(sketch.onGraphics, "粒を作れなかった")

        func particle(_ dust: Particles) -> Particle {
            runtime.canvas.read(dust.state).withUnsafeBytes { raw in
                raw.bindMemory(to: Particle.self)[0]
            }
        }
        let screen = particle(onScreen)
        let graphics = particle(onGraphics)
        try #require(screen.life > 0 && graphics.life > 0, "粒が出ていない")
        #expect(abs(screen.x - DriftingDust.start - 60) < 0.5, "本体: \(screen.x)")
        #expect(abs(graphics.x - screen.x) < 1e-3, "描き場所: \(graphics.x) / 本体: \(screen.x)")
        #expect(
            abs(graphics.life - screen.life) < 1e-3,
            "描き場所: \(graphics.life) / 本体: \(screen.life)")
    }

    /// 完了条件 5 のうち描き場所の側 ([#1467])。時計を差さない経路 (`Canvas` を直に回す
    /// 検査・台帳のシーン) では、描き場所の時刻と刻みは作った面と同じ値のまま。作った面の
    /// 値を変えれば、描き場所も入れ子の描き場所も同じ値を読む。
    ///
    /// [#1467]: https://github.com/mokume-metal/mokume/issues/1467
    @Test("時計を差さない面でも、描き場所は作った面と同じ時刻と刻みを読む")
    func graphicsWithoutAClockFollowsItsMaker() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(16, 16)
        let inner = try layer.createGraphics(8, 8)
        // 既定は作った面と同じ 0 と 1/60
        #expect(layer.time == 0)
        #expect(layer.deltaTime == 1.0 / 60)

        canvas.time = 0.5
        canvas.deltaTime = 1.0 / 30
        for graphics in [layer, inner] {
            #expect(graphics.time == 0.5)
            #expect(graphics.deltaTime == 1.0 / 30)
        }
    }

    // MARK: - 揺らぎの種と細かさは作った面と同じ (#1503)

    /// 本体で決める種と細かさ。**既定 (種 0・4 枚・0.5) と模様が大きく離れる**ものを選ぶ —
    /// 離れていないと、描き場所が既定の設定を読む作りでも差の検査が通ってしまう
    /// (``noisePlaces`` の前提として `#require` する)。
    private static let noiseSeed = 20_260_929
    private static let noiseDetail = (octaves: 6, falloff: Float(0.8))

    /// 突き合わせる座標。格子の間・負の側・遠くを並べる。どれも ``noiseSeed`` と ``noiseDetail``
    /// の下で、既定の設定での値と 0.1 ほど離れる (`requireNoiseFarFromTheDefault()`)。
    private static let noisePlaces: [SIMD3<Float>] = [
        SIMD3(0.5, 0.5, 0.5),
        SIMD3(1234.5, -6789.25, 42.0625),
        SIMD3(-0.5, -0.25, -0.125),
        SIMD3(-12.58, 45.33, -78.42),
    ]

    /// 断片が返すのは、CPU で引いた値との**差そのもの** (``NoiseParityTests`` と同じ形)。
    private static let noiseComparison = """
        float4 paint(Fragment in, Values values) {
            float mine = mokume_noise(in, float3(values.place, values.depth));
            return float4(abs(mine - values.expected), 0.0, 0.0, 1.0);
        }
        """

    /// 断片が返す揺らぎの傾きの大きさ (符号は落とす)。
    private static let noiseSlope = """
        float4 paint(Fragment in, Values values) {
            return float4(abs(mokume_noiseGradient(in, float3(values.place, values.depth))), 1.0);
        }
        """

    /// 本体の面に種と細かさを決める。
    private func decideNoise(on canvas: Canvas) {
        canvas.noiseSeed(Self.noiseSeed)
        canvas.noiseDetail(Self.noiseDetail.octaves, Self.noiseDetail.falloff)
    }

    /// 選んだ種と細かさが、どの座標でも既定の設定と十分に離れていることを確かめる。
    private func requireNoiseFarFromTheDefault() throws {
        let decided = ValueNoise(
            seed: UInt32(Self.noiseSeed), octaves: Self.noiseDetail.octaves,
            falloff: Self.noiseDetail.falloff)
        for place in Self.noisePlaces {
            let apart = abs(
                decided.value(place.x, place.y, place.z)
                    - ValueNoise().value(place.x, place.y, place.z))
            try #require(apart > 0.05, "\(place) では既定の設定と \(apart) しか離れていない")
        }
    }

    /// 面に同じ断片で 8×8 を塗り、真ん中の画素を読む。描き場所は `beginDraw()` / `endDraw()`
    /// で、直に作った面は ``Canvas/draw(_:)`` で描く。
    private func paintAndRead(_ surface: Canvas, with shader: Shader, graphics: Bool) throws -> LinearRGBA {
        func paint() {
            surface.background(.linear(red: 0, green: 0, blue: 0))
            surface.blendMode(.replace)
            surface.noStroke()
            surface.shader(shader)
            surface.rect(0, 0, 8, 8)
            surface.resetShader()
        }
        if graphics {
            surface.beginDraw()
            paint()
            surface.endDraw()
        } else {
            try surface.draw { paint() }
        }
        return surface.get(4, 4)
    }

    /// その面の断片で引いた揺らぎと、`expected` (CPU で引いた値) との差を座標ごとに返す。
    private func noiseGaps(
        on surface: Canvas, graphics: Bool, expected: (SIMD3<Float>) -> Float
    ) throws -> [Float] {
        let shader = try surface.makeShader(
            Self.noiseComparison,
            values: ["place": .pair(0, 0), "depth": .number(0), "expected": .number(0)])
        return try Self.noisePlaces.map { place in
            shader.set("place", .pair(place.x, place.y))
            shader.set("depth", .number(place.z))
            shader.set("expected", .number(expected(place)))
            return try paintAndRead(surface, with: shader, graphics: graphics).red
        }
    }

    /// 完了条件 1 ([#1503])。本体で種と細かさを決める**前**に作った描き場所と**後**に作った
    /// 描き場所の断片が、本体の `noise()` と同じ値を返す。直す前はどちらも既定の設定を読む。
    ///
    /// [#1503]: https://github.com/mokume-metal/mokume/issues/1503
    @Test("本体で決めた種と細かさが、決める前後に作った描き場所の断片にも届く")
    func graphicsFragmentsReadTheSketchNoise() throws {
        try requireNoiseFarFromTheDefault()
        let canvas = try makeCanvas(width: 8, height: 8)
        let before = try canvas.createGraphics(8, 8)
        decideNoise(on: canvas)
        let after = try canvas.createGraphics(8, 8)

        for (name, graphics) in [("決める前", before), ("決めた後", after)] {
            let gaps = try noiseGaps(on: graphics, graphics: true) { canvas.noise($0.x, $0.y, $0.z) }
            for (place, gap) in zip(Self.noisePlaces, gaps) {
                #expect(
                    gap < NoiseParityTests.tolerance,
                    "\(name)に作った描き場所の \(place) で \(gap) ずれている")
            }
        }
    }

    /// 完了条件 2 ([#1503])。描き場所から作った描き場所も、本体で決めた種と細かさを読む。
    /// **間の描き場所は 1 度も描かない** — 描いた時点で作った面から写す作りなら、ここで
    /// 既定の設定が残る。
    ///
    /// [#1503]: https://github.com/mokume-metal/mokume/issues/1503
    @Test("描き場所から作った描き場所も、間を描かなくても本体の種と細かさを読む")
    func nestedGraphicsReadsTheSketchNoise() throws {
        try requireNoiseFarFromTheDefault()
        let canvas = try makeCanvas(width: 8, height: 8)
        let layer = try canvas.createGraphics(8, 8)
        let inner = try layer.createGraphics(8, 8)
        decideNoise(on: canvas)

        let gaps = try noiseGaps(on: inner, graphics: true) { canvas.noise($0.x, $0.y, $0.z) }
        for (place, gap) in zip(Self.noisePlaces, gaps) {
            #expect(gap < NoiseParityTests.tolerance, "入れ子の描き場所の \(place) で \(gap) ずれている")
        }
    }

    /// 完了条件 2 のうち傾きの口 ([#1503])。同じ `mokume_noiseGradient` の断片を本体の面と
    /// 描き場所 (入れ子も) に塗ると、同じ値が出る。**同じ式を同じ設定で引くので、半精度に
    /// 丸めても同じ値になる** — 直す前は描き場所が既定の設定で引くので、模様ごと違う。
    ///
    /// [#1503]: https://github.com/mokume-metal/mokume/issues/1503
    @Test("描き場所の断片の揺らぎの傾きも、本体の断片と同じ値を返す")
    func graphicsGradientMatchesTheSketch() throws {
        try requireNoiseFarFromTheDefault()
        let canvas = try makeCanvas(width: 8, height: 8)
        let layer = try canvas.createGraphics(8, 8)
        decideNoise(on: canvas)
        let inner = try layer.createGraphics(8, 8)
        let shader = try canvas.makeShader(
            Self.noiseSlope, values: ["place": .pair(0, 0), "depth": .number(0)])

        func slope(on surface: Canvas, graphics: Bool) throws -> SIMD3<Float> {
            let pixel = try paintAndRead(surface, with: shader, graphics: graphics)
            return SIMD3(pixel.red, pixel.green, pixel.blue)
        }
        for place in Self.noisePlaces {
            shader.set("place", .pair(place.x, place.y))
            shader.set("depth", .number(place.z))
            let screen = try slope(on: canvas, graphics: false)
            try #require(screen.max() > 0, "\(place) で本体の傾きが 0 (比べる意味が無い)")
            for (name, graphics) in [("描き場所", layer), ("入れ子の描き場所", inner)] {
                let mine = try slope(on: graphics, graphics: true)
                let gap = (0..<3).map { abs(mine[$0] - screen[$0]) }.max() ?? .infinity
                #expect(
                    gap <= 1e-3 * max(1, screen.max()),
                    "\(name)の \(place) で \(mine)、本体は \(screen)")
            }
        }
    }

    /// 完了条件 3 ([#1503])。描き場所の上で種と細かさを決めても、**同じ 1 つ**を書き換える —
    /// 本体の `noise()` も本体の断片も、ほかの描き場所もその値を読む。直す前は描き場所だけに効く。
    ///
    /// [#1503]: https://github.com/mokume-metal/mokume/issues/1503
    @Test("描き場所で決めた種と細かさを、本体の noise() と本体の断片も読む")
    func noiseDecidedOnGraphicsReachesTheSketch() throws {
        try requireNoiseFarFromTheDefault()
        let canvas = try makeCanvas(width: 8, height: 8)
        let layer = try canvas.createGraphics(8, 8)
        let sibling = try canvas.createGraphics(8, 8)
        decideNoise(on: layer)

        let decided = ValueNoise(
            seed: UInt32(Self.noiseSeed), octaves: Self.noiseDetail.octaves,
            falloff: Self.noiseDetail.falloff)
        #expect(canvas.noiseSettings == decided)
        for place in Self.noisePlaces {
            #expect(
                canvas.noise(place.x, place.y, place.z) == decided.value(place.x, place.y, place.z),
                "本体の noise() が \(place) で描き場所の設定を読まない")
        }
        let expected = { (place: SIMD3<Float>) in decided.value(place.x, place.y, place.z) }
        for (name, surface, graphics) in [("本体", canvas, false), ("別の描き場所", sibling, true)] {
            let gaps = try noiseGaps(on: surface, graphics: graphics, expected: expected)
            for (place, gap) in zip(Self.noisePlaces, gaps) {
                #expect(gap < NoiseParityTests.tolerance, "\(name)の断片の \(place) で \(gap) ずれている")
            }
        }
    }

    /// 置いてから種を決め直したときの 3 通り。どれも、置いた時点の種で CPU が引いた値と、
    /// 断片が引いた値を比べる。
    enum LateChange: CaseIterable, CustomTestStringConvertible {
        /// 本体に置いたあと、描き場所で種を決め直す (本体の描き切りはフレームの終わり)
        case onGraphicsAfterPlacingOnTheSketch
        /// 描き場所に置いたあと、`endDraw()` の前に本体で種を決め直す
        case onTheSketchAfterPlacingOnGraphics
        /// 同じ面に置いたあと、その面で種を決め直す
        case onTheSameSurface

        var testDescription: String {
            switch self {
            case .onGraphicsAfterPlacingOnTheSketch: "本体に置いてから描き場所で"
            case .onTheSketchAfterPlacingOnGraphics: "描き場所に置いてから本体で"
            case .onTheSameSurface: "同じ面に置いてから同じ面で"
            }
        }
    }

    /// 反証の指摘 1 ([#1503])。**断片は、置いた時点の種で引く** — CPU の `noise()` は呼んだ
    /// 時点の種を読むので、置いた後に種を決め直しても (どの面で決めても) 置いたものは
    /// 置いた時点の種のまま出る。直す前は、描き切りの時点の種 (決め直した後の種) で引いていた。
    /// 置き場を共有したので、この時差が面をまたいで起きる。
    ///
    /// [#1503]: https://github.com/mokume-metal/mokume/issues/1503
    @Test("置いた後に種を決め直しても、置いたものは置いた時点の種で引く", arguments: LateChange.allCases)
    func placedFragmentsKeepTheSeedOfTheirPlacement(_ change: LateChange) throws {
        try requireNoiseFarFromTheDefault()
        let canvas = try makeCanvas(width: 8, height: 8)
        let layer = try canvas.createGraphics(8, 8)
        decideNoise(on: canvas)
        let place = Self.noisePlaces[0]
        let expected = canvas.noise(place.x, place.y, place.z)
        let shader = try canvas.makeShader(
            Self.noiseComparison,
            values: [
                "place": .pair(place.x, place.y), "depth": .number(place.z),
                "expected": .number(expected),
            ])
        // 決め直す種は既定の設定 (種 0・4 枚・0.5)。既定から離れていることは上で確かめた
        func reset(_ surface: Canvas) {
            surface.noiseSeed(0)
            surface.noiseDetail(4, 0.5)
        }
        func placeRect(on surface: Canvas) {
            surface.background(.linear(red: 0, green: 0, blue: 0))
            surface.blendMode(.replace)
            surface.noStroke()
            surface.shader(shader)
            surface.rect(0, 0, 8, 8)
            surface.resetShader()
        }

        let read: Canvas
        switch change {
        case .onGraphicsAfterPlacingOnTheSketch:
            try canvas.draw {
                placeRect(on: canvas)
                layer.beginDraw()
                reset(layer)
                layer.endDraw()
            }
            read = canvas
        case .onTheSketchAfterPlacingOnGraphics:
            try canvas.draw {
                layer.beginDraw()
                placeRect(on: layer)
                reset(canvas)
                layer.endDraw()
            }
            read = layer
        case .onTheSameSurface:
            try canvas.draw {
                placeRect(on: canvas)
                reset(canvas)
            }
            read = canvas
        }
        let gap = read.get(4, 4).red
        #expect(gap < NoiseParityTests.tolerance, "\(change.testDescription): \(gap) ずれている")
    }

    /// 同じ種を書き直しても描き切らない — 毎フレーム `noiseSeed` を呼ぶ書き方
    /// (`Sketches/KnobsAndValues.swift`) で、フレームの途中の描き切りを増やさない。
    ///
    /// [#1503]: https://github.com/mokume-metal/mokume/issues/1503
    @Test("同じ種と細かさを書き直しても、途中で描き切らない")
    func rewritingTheSameNoiseDoesNotFlush() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        let layer = try canvas.createGraphics(8, 8)
        decideNoise(on: canvas)
        var pending: [Bool] = []
        try canvas.draw {
            canvas.rect(0, 0, 4, 4)
            decideNoise(on: layer)
            pending.append(canvas.hasPendingDrawing)
            layer.noiseSeed(Self.noiseSeed + 1)
            pending.append(canvas.hasPendingDrawing)
        }
        #expect(pending == [true, false], "書き直す前後で溜めた図形が \(pending)")
    }

    /// 完了条件 4 のうち直に作った面 ([#1503])。本体を持たない面は、それぞれ自分の置き場を
    /// 持つ — 片方で決めても、もう片方は既定のまま。
    ///
    /// [#1503]: https://github.com/mokume-metal/mokume/issues/1503
    @Test("直に作った面どうしは、揺らぎの種と細かさを共有しない")
    func directCanvasesKeepTheirOwnNoise() throws {
        let first = try makeCanvas(width: 8, height: 8)
        let second = try makeCanvas(width: 8, height: 8)
        decideNoise(on: first)
        #expect(first.noiseSettings != ValueNoise())
        #expect(second.noiseSettings == ValueNoise())
    }

    // MARK: - 呼び方が対になっていないとき (ADR-0020 決定 5)

    @Test("描き切る前の描き場所を置いたら知らせる")
    func placingBeforeTheDrawIsFinishedIsReported() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(16, 16)

        try canvas.draw {
            canvas.background(black)
            layer.beginDraw()
            layer.background(red)
            // endDraw() を呼ばずに置く
            canvas.image(layer, 0, 0)
            layer.endDraw()
        }

        #expect(canvas.warnings.hasWarned(.placingWhileDrawing))
    }

    @Test("描き切りに失敗しても投げず、前の絵が残る")
    func aFailedEndDrawKeepsTheLastPicture() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(16, 16)
        paint(layer, red)

        layer.beginDraw()
        layer.background(blue)
        layer.failureForTesting = .encoderUnavailable
        layer.endDraw()
        layer.failureForTesting = nil

        // 投げないので、ここまで来ていること自体が半分の答え。絵は前のまま
        let color = layer.get(8, 8)
        #expect(color.red > 0.9)
        #expect(color.blue < 0.01)
    }

    // MARK: - 長く回しても増えない (ADR-0023 決定 5)

    @Test("長く回しても、置いた記録が積み上がらない")
    func nothingGrowsWhileItRuns() throws {
        let canvas = try makeCanvas()
        // **1 度だけ焼いて、毎フレーム置くほう。** 描き換えないので描き場所は描き切らず、
        // 覚えた相手を落とす機会がそもそも来ない。ここが積み上がると、長く回した人だけが踏む
        let still = try canvas.createGraphics(32, 32)
        paint(still, red)
        // **毎フレーム描き換えるほう。**
        let moving = try canvas.createGraphics(32, 32)

        func frame() throws {
            paint(moving, blue)
            try canvas.draw {
                canvas.background(black)
                canvas.image(still, 0, 0)
                canvas.image(moving, 32, 0)
            }
        }

        try frame()
        let first = try pixels(of: canvas).bytes
        for _ in 0..<120 { try frame() }

        // 覚えておく相手は 1 つのまま。同じ相手を毎フレーム足すと、ここが 121 になる
        #expect(still.placers.count == 1)
        #expect(moving.placers.count == 1)
        // フレームの終わりに落ちるので、置いた記録は残らない
        #expect(canvas.placedGraphics.isEmpty)
        #expect(moving.framesDrawn == 121)
        #expect(try pixels(of: canvas).bytes == first)
    }

    /// #1592 の再現そのもの。描き場所に `beginDraw()` を書かずに置いた図形は、描き切りが
    /// 来ないので捨てられず、1 枚ごとに 1000 個ずつ溜まっていた (`formInstances` が
    /// 1000 × フレーム数)。**置いてよいのは持ち越しを約束する区間だけ**で、描き場所の区間は
    /// `beginDraw()`〜`endDraw()` である (ADR-0021 決定 4 の追補 (2026-09-27)・[#1672])。
    ///
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    @Test("beginDraw() を書かずに描き場所へ置き続けても、溜まらない (#1592)")
    func placingWithoutBeginDrawDoesNotPileUp() throws {
        let canvas = try makeCanvas()
        let layer = try canvas.createGraphics(32, 32)
        for frame in 1...30 {
            try canvas.draw {
                canvas.background(black)
                layer.noStroke()
                for index in 0..<1000 {
                    layer.circle(Float(index % 32), Float(index / 32), 6)
                }
                canvas.image(layer, 0, 0)
            }
            try #require(layer.formInstances.isEmpty, "\(frame) 枚目の後に \(layer.formInstances.count) 個溜まった")
            #expect(layer.vertices.isEmpty)
            #expect(layer.solidVertices.isEmpty)
            #expect(layer.solidInstances.isEmpty)
            #expect(layer.batches.isEmpty)
            #expect(layer.flatInstances.count == 1)
            #expect(layer.hasNothingPending)
        }
        #expect(layer.warnings.hasWarned(.placingOutsideFrame))
        // 置いた相手 (画面) は、描き場所の区間とは関係なく今までどおり置ける
        #expect(!canvas.warnings.hasWarned(.placingOutsideFrame))
    }

    // MARK: - 描き場所を持たないスケッチは何も払わない

    @Test("描き場所を作らなければ、置いた記録も相手も 1 つも立たない")
    func aSketchWithoutGraphicsPaysNothing() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(red)
            canvas.circle(32, 32, 20)
        }
        #expect(canvas.placedGraphics.isEmpty)
        #expect(canvas.placers.isEmpty)
    }

    // MARK: - 大きすぎる指定は失敗として返る (#885)

    /// **落ちないことを見ている。** 守りが無いと Metal の検証層がアサーションで
    /// プロセスを終わらせるので、この検査は失敗ではなく SIGABRT で消える
    /// ([#885](https://github.com/mokume-metal/mokume/issues/885))。
    @Test("大きすぎる描き場所を頼んでも、落ちずに失敗として返る")
    func rejectsOversizedGraphics() throws {
        let canvas = try makeCanvas()
        #expect(throws: RenderFailure.invalidSize(width: 20000, height: 20000)) {
            _ = try canvas.createGraphics(20000, 20000)
        }
    }

    @Test("上限ちょうどの描き場所は作れる")
    func acceptsGraphicsAtTheLimit() throws {
        let canvas = try makeCanvas()
        let graphics = try canvas.createGraphics(RenderDevice.maxTextureSide, 1)
        #expect(graphics.output.width == RenderDevice.maxTextureSide)
    }
}
