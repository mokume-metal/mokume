// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// GPU に頼む仕事が無い `draw { }` が、描く先へのパスも投入も作らないことの検査 ([#2787])。GPU を要する。
///
/// 見るのは 2 つ — **省くこと** (仕事を足さない描き切りを繰り返しても投入が増えず、絵が 1 ビットも
/// 変わらず、フレームの意味 (描き切った回数) は進む)、**省かないこと** (背景・書き込んだ画素・効果・
/// 読み戻しを持つ描き切りは、仕事として投入する)。
///
/// [#2787]: https://github.com/mokume-metal/mokume/issues/2787
@Suite(
    "仕事の無い描き切り",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct EmptyDrawTests {
    private let gray = LinearRGBA.linear(red: 0.2, green: 0.2, blue: 0.2)
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)

    private func makeCanvas() throws -> (canvas: Canvas, gpu: RenderDevice) {
        let gpu = try RenderDevice()
        return (try CanvasFixture.make(gpu: gpu, width: 48, height: 32), gpu)
    }

    /// 1 枚描いて、GPU が終わるまで待つ。
    private func drawOnce(_ canvas: Canvas, _ gpu: RenderDevice) throws -> PixelBuffer {
        try canvas.draw {
            canvas.background(gray)
            canvas.noStroke()
            canvas.fill(red)
            canvas.circle(24, 16, 10)
        }
        try gpu.settle()
        return try canvas.target.readPixels()
    }

    @Test("仕事を足さない draw を 40 回呼んでも、投入は増えず、絵は変わらず、描き切った回数は進む")
    func emptyDrawsSubmitNothing() throws {
        let (canvas, gpu) = try makeCanvas()
        let picture = try drawOnce(canvas, gpu)
        let submissions = gpu.submissionCount
        let frames = canvas.framesDrawn
        let passes = canvas.depthLoadsEncoded + canvas.depthStoresEncoded
        for _ in 0..<40 { try canvas.draw {} }
        #expect(gpu.submissionCount == submissions, "空の draw が投入した")
        #expect(canvas.framesDrawn == frames + 40, "フレームの意味が進んでいない")
        #expect(canvas.depthLoadsEncoded + canvas.depthStoresEncoded == passes)
        #expect(canvas.drawCallsInLastFrame == 0)
        try gpu.settle()
        #expect(try canvas.target.readPixels() == picture, "絵が変わった")
    }

    @Test("背景だけの draw は仕事として投入し、絵を塗り直す")
    func backgroundOnlyDrawSubmitsAndRepaints() throws {
        let (canvas, gpu) = try makeCanvas()
        _ = try drawOnce(canvas, gpu)
        let submissions = gpu.submissionCount
        try canvas.draw { canvas.background(red) }
        #expect(gpu.submissionCount > submissions, "背景だけの draw が投入されていない")
        let pixel = canvas.get(2, 2)
        #expect(pixel.red > 0.9 && pixel.green < 0.1, "背景が塗られていない: \(pixel)")
    }

    @Test("書き込んだ画素だけの draw は、仕事として投入し、画素を面へ戻す")
    func pixelWriteOnlyDrawSubmitsAndWritesBack() throws {
        let (canvas, gpu) = try makeCanvas()
        _ = try drawOnce(canvas, gpu)
        let submissions = gpu.submissionCount
        try canvas.draw { canvas.set(3, 3, red) }
        #expect(gpu.submissionCount > submissions, "書き込みだけの draw が投入されていない")
        try gpu.settle()
        let value = try canvas.target.readPixels()
        let offset = (3 * value.width + 3) * 4
        #expect(Float(value.components[offset]) > 0.9, "書いた画素が面に戻っていない")
    }

    @Test("効果だけの draw は、仕事として投入する")
    func effectOnlyDrawSubmits() throws {
        let (canvas, gpu) = try makeCanvas()
        _ = try drawOnce(canvas, gpu)
        // 効果の置き場を作る投入が数に混ざらないよう、1 度通して戻しておく
        try canvas.draw { canvas.effects([.vignette(amount: 0.6)]) }
        try canvas.draw {}
        try gpu.settle()
        let submissions = gpu.submissionCount
        try canvas.draw { canvas.effects([.vignette(amount: 0.6)]) }
        #expect(gpu.submissionCount > submissions, "効果だけの draw が投入されていない")
    }

    @Test("計算だけの draw は、図形が無くても計算を投入して数の並びを書く")
    func computeOnlyDrawSubmitsAndRuns() throws {
        let (canvas, gpu) = try makeCanvas()
        _ = try drawOnce(canvas, gpu)
        let numbers = try canvas.makeNumbers(count: 1)
        let fill = try canvas.makeComputation(
            """
            kernel void fill(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]])
            { out[id] = 7.0; }
            """,
            name: "fill")
        let submissions = gpu.submissionCount
        try canvas.draw { canvas.compute(fill, over: 1, writes: [numbers]) }
        #expect(gpu.submissionCount > submissions, "計算だけの draw が投入されていない")
        // 省くと、頼んだ計算は走らないまま溜め場から捨てられる
        let values = canvas.read(numbers)
        #expect(values == [7], "計算が走っていない: \(values)")
    }

    @Test("数の並びへ書いただけの draw は、控えを届ける投入を省かない")
    func numbersWriteOnlyDrawDeliversTheUpload() throws {
        let (canvas, gpu) = try makeCanvas()
        _ = try drawOnce(canvas, gpu)
        let numbers = try canvas.makeNumbers(count: 1)
        try canvas.draw {}
        try gpu.settle()
        numbers.set(3, at: 0)
        let submissions = gpu.submissionCount
        try canvas.draw {}
        #expect(gpu.submissionCount > submissions, "届けていない控えがあるのに投入されていない")
    }

    @Test("細かさを下げた面は、仕事の無い draw でも拡大を投入する")
    func loweredDensitySurfaceStillUpscales() throws {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 48, height: 32)
        let canvas = try Canvas(output: output, gpu: gpu, pixelDensity: 0.5, upscale: .spatial)
        try canvas.draw { canvas.background(gray) }
        try gpu.settle()
        let submissions = gpu.submissionCount
        try canvas.draw {}
        #expect(gpu.submissionCount > submissions, "拡大の段が省かれた")
    }

    @Test("画素を読む draw は、読み戻しを投入する")
    func readingDrawSubmits() throws {
        let (canvas, gpu) = try makeCanvas()
        _ = try drawOnce(canvas, gpu)
        let submissions = gpu.submissionCount
        try canvas.draw { _ = canvas.get(24, 16) }
        #expect(gpu.submissionCount > submissions, "読み戻しの draw が投入されていない")
    }

    @Test("効果を通した後の、仕事の無い draw は、効果を通す前の絵を戻すので投入する")
    func emptyDrawAfterEffectRestoresThePictureBeforeEffects() throws {
        let (canvas, gpu) = try makeCanvas()
        try canvas.draw {
            canvas.background(gray)
            canvas.effects([.vignette(amount: 0.6)])
        }
        try gpu.settle()
        let submissions = gpu.submissionCount
        try canvas.draw {}
        #expect(gpu.submissionCount > submissions, "効果を通す前の絵の戻しが省かれた")
        // 効果を掛けない空の draw が続く間は省く
        try gpu.settle()
        let afterRestore = gpu.submissionCount
        for _ in 0..<5 { try canvas.draw {} }
        #expect(gpu.submissionCount == afterRestore)
    }
}
