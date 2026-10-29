// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 前のフレームの絵を断片から読む面 ``ShaderSurface/previousFrame`` ([#2456])。
///
/// **「前の絵」は、その面が次のフレームへ持ち越す絵** (ADR-0021 決定 4) である。フレームの終わりの
/// `effects()` を通す前の絵で、1 枚目は透明。写しを払うのは、`.previousFrame` を宣言した断片を
/// 当てた面だけである。
///
/// [#2456]: https://github.com/mokume-metal/mokume/issues/2456
@Suite(
    "前のフレームの絵を読む面",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PreviousFrameTests {
    private static let size = 32

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
    }

    /// 前の絵を 0.96 倍して返す断片。作例から回転と寄せを外した形。
    private static let echoBody = """
        float4 paint(Fragment in, Values values, Surfaces surfaces) {
            return mokume_sample(surfaces.last, in.place) * 0.96;
        }
        """

    private static let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private static let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)
    private static let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)

    /// 毎フレーム: 黒で消す → 断片で全面を塗る (前の絵を 0.96 倍で読む) → 円を 1 つ置く。
    private func frame(
        _ canvas: Canvas, echo: Shader, circle at: (x: Float, y: Float), color: LinearRGBA,
        effects: [Effect] = []
    ) throws {
        try canvas.draw {
            canvas.background(Self.black)
            canvas.noStroke()
            canvas.shader(echo)
            canvas.rect(0, 0, Float(Self.size), Float(Self.size))
            canvas.resetShader()
            canvas.fill(color)
            canvas.circle(at.x, at.y, 8)
            if !effects.isEmpty { canvas.effects(effects) }
        }
    }

    private static func near(_ pixel: LinearRGBA, _ expected: LinearRGBA, tolerance: Float = 0.02)
        -> Bool
    {
        abs(pixel.red - expected.red) <= tolerance && abs(pixel.green - expected.green) <= tolerance
            && abs(pixel.blue - expected.blue) <= tolerance
    }

    // MARK: - 1. 前の絵を 0.96 倍で読む

    @Test("1 枚目の前の絵は透明で、2 枚目は 1 枚目の絵の 0.96 倍を読む")
    func readsThePictureOfTheFrameBefore() throws {
        let canvas = try makeCanvas()
        let echo = try canvas.makeShader(Self.echoBody, surfaces: ["last": .previousFrame])

        try frame(canvas, echo: echo, circle: (8, 16), color: Self.red)
        #expect(Self.near(canvas.get(8, 16), Self.red), "1 枚目の円")
        #expect(Self.near(canvas.get(24, 16), Self.black), "1 枚目: 前の絵は透明なので、円の外は黒")

        try frame(canvas, echo: echo, circle: (24, 16), color: Self.green)
        let faded = LinearRGBA.linear(red: 0.96, green: 0, blue: 0)
        #expect(Self.near(canvas.get(8, 16), faded), "2 枚目: 1 枚目の円は 0.96 倍で残る")
        #expect(Self.near(canvas.get(24, 16), Self.green), "2 枚目の円はそのままの色")
    }

    // MARK: - 2. 効果を通す前の絵を読む

    @Test("効果を通すスケッチでも、読むのは効果を通す前の絵で、効果を 2 度掛けしない")
    func readsThePictureBeforeEffects() throws {
        let canvas = try makeCanvas()
        let echo = try canvas.makeShader(Self.echoBody, surfaces: ["last": .previousFrame])

        try frame(canvas, echo: echo, circle: (8, 16), color: Self.red, effects: [.invert()])
        // 出てくる絵は反転している (黒い所が白、赤の円は水色)
        #expect(Self.near(canvas.get(24, 16), LinearRGBA.linear(red: 1, green: 1, blue: 1)))

        try frame(canvas, echo: echo, circle: (24, 16), color: Self.green, effects: [.invert()])
        // 2 枚目が読むのは、1 枚目の反転する前の絵 (円は赤) の 0.96 倍。反転した後の絵を読むと、
        // 円の位置が水色の 0.96 倍になり、円の外は黒でなく白の 0.96 倍になる。
        // 出てくる絵はそれをもう一度反転するので、円の位置は (1 - 0.96, 1, 1)
        let invertedFaded = LinearRGBA.linear(red: 0.04, green: 1, blue: 1)
        #expect(Self.near(canvas.get(8, 16), invertedFaded), "1 枚目の円 (反転前は赤) の 0.96 倍を読んだ")
        #expect(Self.near(canvas.get(16, 4), LinearRGBA.linear(red: 1, green: 1, blue: 1)), "円の外は黒を読む")
    }

    // MARK: - 3. 止まっている間・描き直し

    @Test("止まっている間に変えた分も前の絵に入り、描き直しはそれを読む")
    func aRedrawReadsTheLastDrawnPicture() throws {
        let canvas = try makeCanvas()
        let echo = try canvas.makeShader(Self.echoBody, surfaces: ["last": .previousFrame])

        try frame(canvas, echo: echo, circle: (8, 16), color: Self.red, effects: [.invert()])
        // 止まっている間のコールバックが、持ち越す絵へ緑の画素を足す
        canvas.carriesOver = true
        canvas.set(24, 16, Self.green)
        // ランタイムは、止まっている間のコールバックを配った直後に、書いた画素を描く先と控えへ書き戻す
        canvas.catchUpOutputWithoutThrowing()
        canvas.carriesOver = false

        // 描き直し (redraw): 描かずに前の絵だけを読む
        try frame(canvas, echo: echo, circle: (16, 28), color: Self.red)
        let faded = LinearRGBA.linear(red: 0.96, green: 0, blue: 0)
        let fadedGreen = LinearRGBA.linear(red: 0, green: 0.96, blue: 0)
        #expect(Self.near(canvas.get(8, 16), faded), "最後に描いた枚の円 (効果を通す前の赤)")
        #expect(Self.near(canvas.get(24, 16), fadedGreen), "止まっている間に足した画素も前の絵に入る")
    }

    @Test("細かさを下げた面でも、前の絵は描く画素の面のもので、2 枚目は 0.96 倍を読む")
    func aLowerDensitySurfaceReadsItsDrawingPixels() throws {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 64, height: 64)
        let canvas = try Canvas(output: output, gpu: gpu, pixelDensity: 0.5, upscale: .spatial)
        let echo = try canvas.makeShader(Self.echoBody, surfaces: ["last": .previousFrame])

        func frame(_ x: Float, _ color: LinearRGBA) throws {
            try canvas.draw {
                canvas.background(Self.black)
                canvas.noStroke()
                canvas.shader(echo)
                canvas.rect(0, 0, 64, 64)
                canvas.resetShader()
                canvas.fill(color)
                canvas.circle(x, 32, 24)
            }
        }
        try frame(16, Self.red)
        try frame(48, Self.green)
        let drawn = try canvas.target.readPixels()
        // 描く画素の面は 32×32。1 枚目の円の中心は (8, 16)
        let centre = drawn[8, 16]
        #expect(abs(centre.red - 0.96) < 0.02 && centre.green < 0.02, "描く画素の面で、0.96 倍の赤が残る")
    }

    // MARK: - 4. 描き場所

    @Test("描き場所で使うと、読むのは描き場所の前の絵で、本体の前の絵ではない")
    func aGraphicsReadsItsOwnPreviousFrame() throws {
        let main = try makeCanvas()
        let layer = try main.createGraphics(Self.size, Self.size)
        let echo = try main.makeShader(Self.echoBody, surfaces: ["last": .previousFrame])

        func drawLayer(at x: Float, _ color: LinearRGBA) {
            layer.beginDraw()
            layer.background(Self.black)
            layer.noStroke()
            layer.shader(echo)
            layer.rect(0, 0, Float(Self.size), Float(Self.size))
            layer.resetShader()
            layer.fill(color)
            layer.circle(x, 16, 8)
            layer.endDraw()
        }

        try main.draw {
            // 本体は全面を青で塗る。描き場所の前の絵に青は混ざらない
            main.background(.linear(red: 0, green: 0, blue: 1))
            drawLayer(at: 8, Self.red)
        }
        try main.draw {
            main.background(.linear(red: 0, green: 0, blue: 1))
            drawLayer(at: 24, Self.green)
            main.image(layer, 0, 0)
        }
        let faded = LinearRGBA.linear(red: 0.96, green: 0, blue: 0)
        #expect(Self.near(main.get(8, 16), faded), "描き場所の 1 枚目の円が 0.96 倍で残る")
        #expect(Self.near(main.get(16, 4), Self.black), "本体の青は描き場所の前の絵に入らない")
    }

    // MARK: - 5. 払う費用

    @Test("宣言していない面は何も払わず、宣言して当てた面だけが毎フレーム 1 回の写しを払う")
    func onlyTheDeclaringSurfacePays() throws {
        let main = try makeCanvas()
        let other = try makeCanvas()
        let echo = try main.makeShader(Self.echoBody, surfaces: ["last": .previousFrame])
        let plain = try other.makeShader(
            "float4 paint(Fragment in, Values values) { return in.color; }")

        for index in 0..<3 {
            try frame(main, echo: echo, circle: (8, 16), color: Self.red)
            try other.draw {
                other.background(Self.black)
                other.shader(plain)
                other.rect(0, 0, 16, 16)
            }
            #expect(main.previousFramePicturesCopied == index + 1, "当てた面は毎フレーム 1 回")
            #expect(other.previousFramePicturesCopied == 0, "宣言していない面は写さない")
        }
        // 同じ大きさなら、写しの面を作り直さない
        #expect(main.previousFrameCopiesMade == 1)
        #expect(other.previousFrameCopiesMade == 0)
    }

    @Test("宣言した断片を作っただけで当てていない面は、写しを払わない")
    func aDeclaredButUnusedShaderPaysNothing() throws {
        let canvas = try makeCanvas()
        _ = try canvas.makeShader(Self.echoBody, surfaces: ["last": .previousFrame])
        try canvas.draw {
            canvas.background(Self.black)
            canvas.rect(0, 0, 8, 8)
        }
        #expect(canvas.previousFramePicturesCopied == 0)
        #expect(canvas.previousFrameCopiesMade == 0)
    }
}
