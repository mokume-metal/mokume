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
