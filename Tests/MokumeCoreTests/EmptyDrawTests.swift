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

    @Test("細かさを下げた面 (空間方向) は、出す先が最新なら省く。描く先が変わった後は拡大を投入する")
    func spatialUpscaleSkipsOnlyWhileTheOutputIsCurrent() throws {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 48, height: 32)
        let canvas = try Canvas(output: output, gpu: gpu, pixelDensity: 0.5, upscale: .spatial)
        try canvas.draw { canvas.background(gray) }
        try gpu.settle()
        let picture = try output.readPixels()
        let submissions = gpu.submissionCount
        for _ in 0..<10 { try canvas.draw {} }
        #expect(gpu.submissionCount == submissions, "出す先が最新なのに拡大を投入した")
        #expect(try output.readPixels() == picture, "出す先の絵が変わった")
        // 描く先が変わったら、広げ直す
        try canvas.draw { canvas.background(red) }
        #expect(gpu.submissionCount > submissions, "描く先が変わったのに拡大が省かれた")
        try gpu.settle()
        let value = try output.readPixels()
        #expect(Float(value.components[0]) > 0.9, "出す先に広がっていない")
        // フレームの途中の描き切りが描く先を変え、フレームの終わりの描き切りは仕事が無くても、広げ直す
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 1))
            canvas.loadPixels()
        }
        try gpu.settle()
        let blue = try output.readPixels()
        #expect(Float(blue.components[2]) > 0.9, "途中で変わった描く先が出す先に広がっていない")
    }

    @Test("細かさを下げた面 (時間方向) は、揺らしと履歴を進めるので、仕事の無い draw でも拡大を投入する")
    func temporalUpscaleNeverSkips() throws {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 48, height: 32)
        let canvas = try Canvas(output: output, gpu: gpu, pixelDensity: 0.5, upscale: .temporal)
        try canvas.draw { canvas.background(gray) }
        try gpu.settle()
        let submissions = gpu.submissionCount
        try canvas.draw {}
        #expect(gpu.submissionCount > submissions, "時間方向の拡大が省かれた")
    }

    @Test("省く描き切りは、置いた側へ写させず、置いた側に区切りも投入も入れない。描く先が変わるときに写させる")
    func anEmptyDrawLeavesThePlacingCanvasAlone() throws {
        let (host, gpu) = try makeCanvas()
        let layer = try host.createGraphics(16, 16)
        layer.beginDraw()
        layer.background(red)
        layer.endDraw()
        try host.draw {
            host.background(gray)
            host.image(layer, 0, 0)
        }
        try gpu.settle()
        // 置いた側に溜めてから、置かれた側が何も描かずに閉じる
        host.beginDraw()
        host.image(layer, 0, 0)
        let submissions = gpu.submissionCount
        let drops = host.placedGraphicsDrops
        let limit = host.placedPictureCopyLimitReached
        layer.beginDraw()
        layer.endDraw()
        #expect(gpu.submissionCount == submissions, "空の描き場所が投入した (置いた側の写しか区切り)")
        #expect(host.placedGraphicsDrops == drops, "空の描き場所が置いた側へ写させた")
        #expect(host.placedPictureCopyLimitReached == limit)
        // 描く先が変わるときは、これまでどおり置いた時点の絵を写させる
        layer.beginDraw()
        layer.background(.linear(red: 0, green: 0, blue: 1))
        layer.endDraw()
        #expect(host.placedGraphicsDrops == drops + 1, "描く先が変わるのに写させていない")
        try host.endDraw()
    }

    @Test("フレームの途中で省かれる描き切りは、引き継ぐ奥行きを保つ")
    func anEmptyMidFrameFlushKeepsTheCarriedDepth() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 160, height: 160)
        let plane = canvas.createShape {
            canvas.noStroke()
            canvas.plane(60, 60)
        }
        let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)
        try canvas.draw {
            canvas.background(gray)
            canvas.fill(red)
            canvas.shape(plane, at: [Placement(x: 60, y: 60, z: 20, fill: red)])
            // 途中の描き切り: 立体の奥行きを残す (仕事あり)
            canvas.loadPixels()
            let submissions = gpu.submissionCount
            // 仕事の無い途中の描き切り (省かれる) を挟んでも、奥行きは次の描き切りへ引き継がれる
            try? canvas.flush(applyingEffects: false)
            #expect(gpu.submissionCount == submissions, "仕事の無い途中の描き切りが投入した")
            canvas.shape(plane, at: [Placement(x: 80, y: 80, z: -20, fill: blue)])
        }
        let overlap = canvas.get(70, 70)
        #expect(overlap.red > 0.4 && overlap.blue < 0.1, "引き継ぐ奥行きが失われ、奥の青が手前の赤を覆った: \(overlap)")
    }

    @Test("フレームの途中で省かれる描き切りは、途中の描き切りが持ち越した落とす側を保つ")
    func anEmptyMidFrameFlushKeepsTheCarriedCasters() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 96, height: 96)
        var carried = -1
        var afterEmpty = -1
        try canvas.draw {
            canvas.background(gray)
            canvas.camera(48, -36, 120, 48, 48, 0, 0, 1, 0)
            canvas.lights()
            canvas.shadows(true)
            canvas.noStroke()
            canvas.fill(.linear(red: 0.8, green: 0.8, blue: 0.8))
            canvas.push()
            canvas.translate(48, 36, 0)
            canvas.sphere(15)
            canvas.pop()
            // 途中の描き切り: 落とす側を持ち越す
            _ = canvas.get(0, 0)
            carried = canvas.frameCasters.casters.count
            let submissions = gpu.submissionCount
            try? canvas.flush(applyingEffects: false)
            #expect(gpu.submissionCount == submissions, "仕事の無い途中の描き切りが投入した")
            afterEmpty = canvas.frameCasters.casters.count
        }
        #expect(carried > 0, "前提が崩れている: 落とす側が持ち越されていない")
        #expect(afterEmpty == carried, "省いた描き切りが、持ち越した落とす側を捨てた")
    }

    @Test("止まっている間 (フレームの外) の仕事の無い描き切りは省かれ、置いた立体の奥行きは次のフレームへ引き継がれる")
    func anEmptyFlushWhileStoppedKeepsTheCarriedDepth() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 160, height: 160)
        let plane = canvas.createShape {
            canvas.noStroke()
            canvas.plane(60, 60)
        }
        let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)
        try canvas.draw { canvas.background(gray) }
        // 止まっている間のコールバックを模す (持ち越しの区間の印を立てる)。区間で置き、描き切らせて奥行きを残す
        canvas.carriesOver = true
        canvas.shape(plane, at: [Placement(x: 60, y: 60, z: 20, fill: red)])
        try canvas.flush(applyingEffects: false)
        let submissions = gpu.submissionCount
        try canvas.flush(applyingEffects: false)
        #expect(gpu.submissionCount == submissions, "仕事の無い描き切りが投入した")
        canvas.carriesOver = false
        // 次のフレームの最初のパスが、引き継いだ奥行きを読む
        try canvas.draw { canvas.shape(plane, at: [Placement(x: 80, y: 80, z: -20, fill: blue)]) }
        let overlap = canvas.get(70, 70)
        #expect(overlap.red > 0.4 && overlap.blue < 0.1, "奥行きの引き継ぎが失われた: \(overlap)")
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
