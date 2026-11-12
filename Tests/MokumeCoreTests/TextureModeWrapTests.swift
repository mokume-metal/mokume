// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 読み取り位置の単位 (`textureMode`) と端の外の読み方 (`textureWrap`) (#3717)。GPU を要する。
///
/// 期待は貼る画像の画素 (`Image.get`) と手で数えた位置から作り、検査の対象と同じ口から作らない。
@Suite(
    "textureMode・textureWrap",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct TextureModeWrapTests {
    private func makeCanvas(width: Int, height: Int) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// 120 画素四方の、横に赤が増え縦に青が増える画像。**位置ごとに色が違う**ので、どこを読んだかが分かる。
    private func makeGradient(_ canvas: Canvas) throws -> Image {
        let image = try canvas.createImage(120, 120)
        for y in 0..<120 {
            for x in 0..<120 {
                image.set(x, y, .linear(red: Float(x) / 119, green: 0.25, blue: Float(y) / 119))
            }
        }
        return image
    }

    /// 2 つの色が `tolerance` の内で同じか (半精度と線形の読みの丸めを許す)。
    private func close(_ a: LinearRGBA, _ b: LinearRGBA, _ tolerance: Float = 0.02) -> Bool {
        abs(a.red - b.red) <= tolerance && abs(a.green - b.green) <= tolerance && abs(a.blue - b.blue) <= tolerance
    }

    /// 左上 (0, 0) から右下 (`width`, `height`) の四角を、`uv` の右下の角を指定して置く。
    private func quad(_ canvas: Canvas, width: Float, height: Float, u: Float, v: Float) {
        canvas.beginShape()
        canvas.vertex(0, 0, 0, 0)
        canvas.vertex(width, 0, u, 0)
        canvas.vertex(width, height, u, v)
        canvas.vertex(0, height, 0, v)
        canvas.endShape(.close)
    }

    private func prepare(_ canvas: Canvas, _ image: Image) {
        canvas.background(.linear(red: 0, green: 0, blue: 0))
        canvas.noStroke()
        canvas.fill(.linear(red: 1, green: 1, blue: 1))
        canvas.texture(image)
    }

    // MARK: - textureMode (完了条件 1)

    @Test("(0, 0)〜(1, 1) を書くと、.normal では画像の全体が、既定の .image では左上の 1 画素が引き伸ばされて貼られる")
    func normalReadsTheWholeImage() throws {
        for normal in [true, false] {
            let canvas = try makeCanvas(width: 120, height: 120)
            let image = try makeGradient(canvas)
            try canvas.draw {
                prepare(canvas, image)
                if normal { canvas.textureMode(.normal) }
                quad(canvas, width: 120, height: 120, u: 1, v: 1)
            }
            let (topLeft, bottomRight) = (canvas.get(5, 5), canvas.get(114, 114))
            if normal {
                #expect(close(topLeft, image.get(5, 5)), "\(topLeft)")
                #expect(close(bottomRight, image.get(114, 114)), "\(bottomRight)")
            } else {
                #expect(close(topLeft, image.get(0, 0)) && close(bottomRight, image.get(0, 0)), "\(topLeft)・\(bottomRight)")
            }
        }
    }

    @Test("単位は vertex() を呼んだ時点で決まる。endShape() の前に .image へ戻しても、置いた頂点は 0〜1 で読む")
    func modeAppliesWhenTheVertexIsPlaced() throws {
        let canvas = try makeCanvas(width: 120, height: 120)
        let image = try makeGradient(canvas)
        try canvas.draw {
            prepare(canvas, image)
            canvas.textureMode(.normal)
            canvas.beginShape()
            canvas.vertex(0, 0, 0, 0)
            canvas.vertex(120, 0, 1, 0)
            canvas.vertex(120, 120, 1, 1)
            canvas.vertex(0, 120, 0, 1)
            canvas.textureMode(.image)
            canvas.endShape(.close)
        }
        #expect(close(canvas.get(114, 114), image.get(114, 114)), "\(canvas.get(114, 114))")
    }

    @Test(".normal でも、画像を貼っていなければ書いた値のまま in.uv へ届く")
    func normalLeavesUnboundCoordinatesAlone() throws {
        func drawn(_ mode: TextureMode) throws -> (LinearRGBA, LinearRGBA) {
            let canvas = try makeCanvas(width: 64, height: 64)
            let shader = try canvas.makeShader(
                """
                float4 paint(Fragment in, Values values) {
                    return float4(in.uv.x / 64.0, in.uv.y / 64.0, 0.0, 1.0);
                }
                """)
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.noStroke()
                canvas.textureMode(mode)
                canvas.shader(shader)
                quad(canvas, width: 64, height: 64, u: 64, v: 64)
            }
            return (canvas.get(8, 8), canvas.get(56, 56))
        }
        let normal = try drawn(.normal)
        let image = try drawn(.image)
        #expect(normal.0 == image.0 && normal.1 == image.1)
        #expect(abs(normal.1.red - 56.5 / 64) < 0.02, "書いた値が割られた: \(normal.1)")
    }

    // MARK: - textureWrap (完了条件 2)

    @Test("u の終わりを 240 にすると、既定の .clamp では右半分が右端の色で延び、.repeat では画像が横に 2 回並ぶ")
    func repeatTilesTheImage() throws {
        for repeats in [false, true] {
            let canvas = try makeCanvas(width: 240, height: 120)
            let image = try makeGradient(canvas)
            try canvas.draw {
                prepare(canvas, image)
                if repeats { canvas.textureWrap(.repeat) }
                quad(canvas, width: 240, height: 120, u: 240, v: 120)
            }
            let left = canvas.get(60, 60)
            let right = canvas.get(180, 60)
            #expect(close(left, image.get(60, 60)), "左半分は画像のまま: \(left)")
            if repeats {
                #expect(close(right, image.get(60, 60)), "繰り返していない: \(right)")
            } else {
                #expect(close(right, image.get(119, 60)), "右端の色で延びていない: \(right)")
            }
        }
    }

    @Test("読み方は塗りを置いた時点で決まる。同じ画像を、繰り返す形と延ばす形に並べて貼れる")
    func wrapAppliesPerFill() throws {
        let canvas = try makeCanvas(width: 240, height: 120)
        let image = try makeGradient(canvas)
        try canvas.draw {
            prepare(canvas, image)
            canvas.textureWrap(.repeat)
            canvas.beginShape()
            canvas.vertex(0, 0, 0, 0)
            canvas.vertex(240, 0, 240, 0)
            canvas.vertex(240, 60, 240, 60)
            canvas.vertex(0, 60, 0, 60)
            canvas.endShape(.close)
            canvas.textureWrap(.clamp)
            canvas.beginShape()
            canvas.vertex(0, 60, 0, 60)
            canvas.vertex(240, 60, 240, 60)
            canvas.vertex(240, 120, 240, 120)
            canvas.vertex(0, 120, 0, 120)
            canvas.endShape(.close)
        }
        #expect(close(canvas.get(180, 30), image.get(60, 30)), "上は繰り返す: \(canvas.get(180, 30))")
        #expect(close(canvas.get(180, 90), image.get(119, 90)), "下は延ばす: \(canvas.get(180, 90))")
    }

    @Test(".repeat は断片の mokume_sample には効かず、端の外は .clamp のときと同じ端の色")
    func repeatDoesNotReachTheFragmentSampler() throws {
        func drawn(_ wrap: TextureWrap) throws -> LinearRGBA {
            let canvas = try makeCanvas(width: 64, height: 32)
            let image = try makeGradient(canvas)
            let shader = try canvas.makeShader(
                """
                float4 paint(Fragment in, Values values, Surfaces surfaces) {
                    return mokume_sample(surfaces.probe, float2(in.place.x * 2.0, 0.5));
                }
                """,
                surfaces: ["probe": .image(image)])
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.noStroke()
                canvas.texture(image)
                canvas.textureWrap(wrap)
                canvas.shader(shader)
                canvas.rect(0, 0, 64, 32)
            }
            return canvas.get(56, 16)
        }
        let clamped = try drawn(.clamp)
        let repeated = try drawn(.repeat)
        #expect(clamped == repeated)
        #expect(clamped.red > 0.95, "端の外が端の色でない: \(clamped)")
    }

    // MARK: - push / pop (完了条件 3)

    @Test("push() の中で変えた textureMode と textureWrap は、pop() で戻る")
    func pushAndPopRestoreBoth() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        try canvas.draw {
            canvas.push()
            canvas.textureMode(.normal)
            canvas.textureWrap(.repeat)
            #expect(canvas.style.textureMode == .normal && canvas.style.textureWrap == .repeat)
            canvas.pop()
            #expect(canvas.style.textureMode == .image)
            #expect(canvas.style.textureWrap == .clamp)
        }
    }
}
