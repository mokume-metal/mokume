// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MokumeCore

/// 画像の検査。GPU を要する。
///
/// 元の絵は**検査の中で作る**。既知の色で作ってから読み直すので、期待値を保存された
/// 画像ではなく仕様から導ける ([ADR-0019] 決定 4)。
///
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "画像",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ImageTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    /// 既知の色で並べた PNG を書き出す。色は表示のエンコード値 (0…1)。
    ///
    /// **作業空間と同じ色域で書く。** 別の色域で書くと、読み込みが色を正しく
    /// 移した結果として値が動き、期待値を書けなくなる (それ自体は
    /// ``sourceColorSpaceIsHonoured()`` で別に見る)。
    private func writePNG(
        _ colors: [(red: Double, green: Double, blue: Double, alpha: Double)], width: Int,
        height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    ) throws -> URL {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (index, color) in colors.enumerated() {
            let x = index % width
            let y = index / width
            // **色は書き込む色域の成分として渡す。** 数を渡すだけの口は装置の色域と
            // して解釈され、そこから変換された値が書かれてしまう
            context.setFillColor(
                CGColor(
                    colorSpace: space,
                    components: [
                        CGFloat(color.red), CGFloat(color.green), CGFloat(color.blue),
                        CGFloat(color.alpha),
                    ])!)
            // 描く道具は下から上へ数えるので、上から数えた行に合わせて反転する
            context.fill(CGRect(x: x, y: height - 1 - y, width: 1, height: 1))
        }
        let made = context.makeImage()!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-image-\(UUID().uuidString).png")
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, made, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    // MARK: - 読む

    @Test("読んだ絵を等倍で置くと、元の色がそのまま出る")
    func drawingAtNaturalSizeReproducesTheSource() throws {
        let url = try writePNG(
            [
                (1, 0, 0, 1), (0, 1, 0, 1),
                (0, 0, 1, 1), (1, 1, 1, 1),
            ], width: 2, height: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let canvas = try makeCanvas()
        let image = try canvas.loadImage(url.path)
        #expect(image.width == 2)
        #expect(image.height == 2)

        try canvas.draw {
            canvas.background(black)
            canvas.image(image, 10, 10)
        }
        let drawn = try pixels(of: canvas)
        #expect(drawn[10, 10] == (255, 0, 0, 255))
        #expect(drawn[11, 10] == (0, 255, 0, 255))
        #expect(drawn[10, 11] == (0, 0, 255, 255))
        #expect(drawn[11, 11] == (255, 255, 255, 255))
    }

    @Test("見つからない絵は投げ、説明に探した場所と宣言の話が載る")
    func aMissingImageExplainsWhereItLooked() throws {
        let canvas = try makeCanvas()
        #expect(throws: ImageFailure.self) { try canvas.loadImage("nowhere/at/all.png") }
        do {
            _ = try canvas.loadImage("nowhere/at/all.png")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("探した場所"))
            #expect(text.contains("resources:"))
        }
    }

    @Test("画像として読めないものは、その旨を投げる")
    func anUndecodableFileSaysSo() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-not-an-image-\(UUID().uuidString).png")
        try "これは画像ではない".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let canvas = try makeCanvas()
        #expect(throws: ImageFailure.undecodable(path: url.path)) {
            try canvas.loadImage(url.path)
        }
    }

    @Test("待たない読み込みでも、同じ絵になる")
    func theNonBlockingLoadGivesTheSameImage() async throws {
        let url = try writePNG([(1, 0, 0, 1), (0, 0, 1, 1)], width: 2, height: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let canvas = try makeCanvas()
        let waited = try canvas.loadImage(url.path)
        let requested = try await canvas.requestImage(url.path)
        #expect(waited.width == requested.width)
        #expect(waited.get(0, 0) == requested.get(0, 0))
        #expect(waited.get(1, 0) == requested.get(1, 0))
    }

    // MARK: - 置き方

    @Test("4 つの数の読み方が置き場所を決める")
    func imageModeDecidesWhereItLands() throws {
        let url = try writePNG(Array(repeating: (1.0, 1.0, 1.0, 1.0), count: 4), width: 2, height: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let corner = try makeCanvas()
        let cornerImage = try corner.loadImage(url.path)
        try corner.draw {
            corner.background(black)
            corner.image(cornerImage, 10, 10, 20, 20)
        }
        let center = try makeCanvas()
        let centerImage = try center.loadImage(url.path)
        try center.draw {
            center.background(black)
            center.imageMode(.center)
            center.image(centerImage, 20, 20, 20, 20)
        }
        #expect(try pixels(of: corner).bytes == pixels(of: center).bytes)
    }

    @Test("色掛けは掛け算で、白は何も変えない")
    func tintMultipliesAndWhiteChangesNothing() throws {
        let url = try writePNG(Array(repeating: (1.0, 1.0, 1.0, 1.0), count: 4), width: 2, height: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let plain = try makeCanvas()
        let plainImage = try plain.loadImage(url.path)
        try plain.draw {
            plain.background(black)
            plain.image(plainImage, 8, 8, 16, 16)
        }
        let tinted = try makeCanvas()
        let tintedImage = try tinted.loadImage(url.path)
        try tinted.draw {
            tinted.background(black)
            tinted.tint(white)
            tinted.image(tintedImage, 8, 8, 16, 16)
        }
        #expect(try pixels(of: plain).bytes == pixels(of: tinted).bytes)

        let red = try makeCanvas()
        let redImage = try red.loadImage(url.path)
        try red.draw {
            red.background(black)
            red.tint(.display(red: 1, green: 0, blue: 0))
            red.image(redImage, 8, 8, 16, 16)
        }
        let sample = try pixels(of: red)[12, 12]
        #expect(sample.red == 255)
        #expect(sample.green == 0)
        #expect(sample.blue == 0)
    }

    @Test("切り出した部分だけが出る")
    func croppingShowsOnlyThatPart() throws {
        // 左が赤・右が青の 2x1
        let url = try writePNG([(1, 0, 0, 1), (0, 0, 1, 1)], width: 2, height: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let canvas = try makeCanvas()
        let image = try canvas.loadImage(url.path)
        try canvas.draw {
            canvas.background(black)
            // 右半分だけを 16x16 へ引き伸ばす
            canvas.image(image, 10, 10, 16, 16, 1, 0, 1, 1)
        }
        let drawn = try pixels(of: canvas)
        #expect(drawn[18, 18] == (0, 0, 255, 255))
    }

    @Test("切り出しが絵の外を指しても落ちない", arguments: [
        (Float(-10), Float(-10), Float(4), Float(4)),
        (Float(5), Float(5), Float(10), Float(10)),
        (Float(0), Float(0), Float(-4), Float(-4)),
    ])
    func croppingOutsideTheImageIsSafe(_ box: (Float, Float, Float, Float)) throws {
        let url = try writePNG(Array(repeating: (1.0, 1.0, 1.0, 1.0), count: 4), width: 2, height: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let canvas = try makeCanvas()
        let image = try canvas.loadImage(url.path)
        try canvas.draw {
            canvas.background(black)
            canvas.image(image, 10, 10, 20, 20, box.0, box.1, box.2, box.3)
        }
        #expect(try pixels(of: canvas)[0, 0] == (0, 0, 0, 255))
    }

    // MARK: - 色の規範

    @Test("元の絵が持つ色の記述が尊重される")
    func sourceColorSpaceIsHonoured() throws {
        let wide = try writePNG([(1, 0, 0, 1)], width: 1, height: 1)
        let narrow = try writePNG(
            [(1, 0, 0, 1)], width: 1, height: 1,
            space: CGColorSpace(name: CGColorSpace.sRGB)!)
        defer {
            try? FileManager.default.removeItem(at: wide)
            try? FileManager.default.removeItem(at: narrow)
        }

        func drawn(_ url: URL) throws -> DisplayImage {
            let canvas = try makeCanvas()
            let image = try canvas.loadImage(url.path)
            try canvas.draw {
                canvas.background(black)
                canvas.image(image, 8, 8, 16, 16)
            }
            return try pixels(of: canvas)
        }

        let fromWide = try drawn(wide)[16, 16]
        let fromNarrow = try drawn(narrow)[16, 16]
        // 同じ「赤」でも、狭い色域の赤は広い色域では**より控えめな赤**になる。
        // 記述を無視して数だけを運ぶと、この 2 つは同じ色になってしまう
        #expect(fromWide != fromNarrow)
        #expect(fromNarrow.red < fromWide.red)
        #expect(fromNarrow.green > fromWide.green)
    }

    @Test("半透明の絵を重ねても沈まない")
    func translucentImagesDoNotSinkWhenComposited() throws {
        // 半透明の白 1 画素
        let url = try writePNG([(1, 1, 1, 0.5)], width: 1, height: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let viaImage = try makeCanvas()
        let image = try viaImage.loadImage(url.path)
        try viaImage.draw {
            viaImage.background(.display(red: 0.2, green: 0.1, blue: 0.4))
            viaImage.image(image, 8, 8, 20, 20)
        }

        // 同じ色を図形として重ねたものと突き合わせる。**経路が違っても同じ絵になる**
        let viaShape = try makeCanvas()
        try viaShape.draw {
            viaShape.background(.display(red: 0.2, green: 0.1, blue: 0.4))
            viaShape.noStroke()
            viaShape.fill(.display(red: 1, green: 1, blue: 1, alpha: 0.5))
            viaShape.rect(8, 8, 20, 20)
        }

        let fromImage = try pixels(of: viaImage)[16, 16]
        let fromShape = try pixels(of: viaShape)[16, 16]
        // 元の絵は 8 bit で量子化されているので、1 段のずれまでは許す
        #expect(abs(Int(fromImage.red) - Int(fromShape.red)) <= 1)
        #expect(abs(Int(fromImage.green) - Int(fromShape.green)) <= 1)
        #expect(abs(Int(fromImage.blue) - Int(fromShape.blue)) <= 1)
    }

    // MARK: - 作る・書き換える

    @Test("作った絵に書き込むと、送り直しを呼ばなくても描かれる")
    func writingToACreatedImageShowsUpWithoutAnExplicitUpload() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 2)
        image.set(0, 0, .linear(red: 1, green: 0, blue: 0))
        image.set(1, 1, .linear(red: 0, green: 1, blue: 0))

        try canvas.draw {
            canvas.background(black)
            canvas.image(image, 10, 10)
        }
        let drawn = try pixels(of: canvas)
        #expect(drawn[10, 10] == (255, 0, 0, 255))
        #expect(drawn[11, 11] == (0, 255, 0, 255))
        // 書いていない画素は透明のまま
        #expect(drawn[11, 10] == (0, 0, 0, 255))
    }

    @Test("読んだ色をそのまま書き戻しても、絵は変わらない")
    func writingBackWhatWasReadIsIdentity() throws {
        let url = try writePNG(
            [(1, 0.25, 0, 1), (0, 0.5, 1, 0.5), (0.75, 0.75, 0.75, 1), (0, 0, 0, 0)],
            width: 2, height: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let canvas = try makeCanvas()
        let image = try canvas.loadImage(url.path)
        let before = image.pixels
        for y in 0..<image.height {
            for x in 0..<image.width {
                image.set(x, y, image.get(x, y))
            }
        }
        #expect(image.pixels == before)
    }

    @Test("範囲の外は、読めば透明・書いても何も起きない")
    func outsideTheImageReadsTransparentAndIgnoresWrites() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 2)
        #expect(image.get(-1, 0).alpha == 0)
        #expect(image.get(0, 5).alpha == 0)
        let before = image.pixels
        image.set(-1, 0, white)
        image.set(9, 9, white)
        #expect(image.pixels == before)
    }

    // MARK: - まとめて書き込む

    /// 表示できる形の絵を組み立てる。成分は 0…255 のまま渡す。
    private func makePicture(
        _ texels: [(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)], width: Int, height: Int
    ) -> DisplayImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (index, texel) in texels.enumerated() {
            bytes[index * 4] = texel.red
            bytes[index * 4 + 1] = texel.green
            bytes[index * 4 + 2] = texel.blue
            bytes[index * 4 + 3] = texel.alpha
        }
        return DisplayImage(width: width, height: height, bytes: bytes)
    }

    @Test("まとめて書き込んだ絵を等倍で置くと、書き込んだ画素がそのまま出る")
    func aWrittenPictureIsDrawnBackByteForByte() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 2)
        // 端 (0・255) だけでなく**曲線の途中**も入れる。表を引く実装が伝達関数と
        // 食い違っていれば、途中の値で先に出る
        image.write(
            makePicture(
                [
                    (255, 0, 0, 255), (0, 128, 64, 255),
                    (200, 200, 200, 255), (17, 96, 233, 255),
                ], width: 2, height: 2))

        try canvas.draw {
            canvas.background(black)
            canvas.image(image, 10, 10)
        }
        let drawn = try pixels(of: canvas)
        #expect(drawn[10, 10] == (255, 0, 0, 255))
        #expect(drawn[11, 10] == (0, 128, 64, 255))
        #expect(drawn[10, 11] == (200, 200, 200, 255))
        #expect(drawn[11, 11] == (17, 96, 233, 255))
    }

    @Test("出口が出した絵を書き戻すと、元の絵に戻る")
    func writingBackWhatTheOutletProducedRestoresTheImage() throws {
        let source = try makeCanvas(width: 32, height: 32)
        try source.draw {
            source.background(.display(red: 0.1, green: 0.2, blue: 0.4))
            source.noStroke()
            source.fill(.display(red: 0.95, green: 0.6, blue: 0.2))
            source.circle(16, 16, 20)
        }
        let produced = try pixels(of: source)

        let canvas = try makeCanvas(width: 32, height: 32)
        let image = try canvas.createImage(32, 32)
        image.write(produced)
        try canvas.draw {
            canvas.background(black)
            canvas.image(image, 0, 0)
        }
        #expect(try pixels(of: canvas) == produced)
    }

    @Test("まとめて書き込んだ画素は、CPU 側から読んでも同じ色になる")
    func aWrittenPictureReadsBackOnTheCPU() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 1)
        image.write(makePicture([(255, 128, 0, 255), (64, 64, 64, 128)], width: 2, height: 1))

        // 不透明な画素は、指定した表示の値がそのまま線形へ戻る
        let opaque = image.get(0, 0)
        #expect(abs(opaque.red - 1) < 0.001)
        #expect(abs(opaque.green - TransferFunction.decode(128.0 / 255)) < 0.001)
        #expect(opaque.blue == 0)
        #expect(opaque.alpha == 1)

        // 半透明の画素は**乗算済み**で入る (作業空間の不変条件)
        let translucent = image.get(1, 0)
        let straight = TransferFunction.decode(64.0 / 255)
        let alpha = Float(128) / 255
        #expect(abs(translucent.alpha - alpha) < 0.001)
        #expect(abs(translucent.red - straight * alpha) < 0.001)
    }

    @Test("まとめて書き込むと、前の中身は残らない")
    func writingReplacesEverythingThatWasThere() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 1)
        image.fill(white)
        image.write(makePicture([(0, 0, 0, 255), (0, 0, 0, 255)], width: 2, height: 1))
        #expect(image.get(0, 0) == LinearRGBA.linear(red: 0, green: 0, blue: 0))
        #expect(image.get(1, 0) == LinearRGBA.linear(red: 0, green: 0, blue: 0))
    }

    @Test("大きさの違う絵を書き込んでも、絵は変わらない")
    func writingAPictureOfADifferentSizeChangesNothing() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 2)
        image.fill(white)
        let before = image.pixels
        image.write(makePicture([(0, 0, 0, 255)], width: 1, height: 1))
        #expect(image.pixels == before)
        #expect(image.width == 2)
        #expect(image.height == 2)
    }

    // MARK: - 他の描画と混ざらない

    @Test("画像の後に置いた図形が、画像の面を読まない")
    func shapesAfterAnImageDoNotSampleIt() throws {
        let url = try writePNG(Array(repeating: (0.0, 0.0, 1.0, 1.0), count: 4), width: 2, height: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let mixed = try makeCanvas()
        let image = try mixed.loadImage(url.path)
        try mixed.draw {
            mixed.background(black)
            mixed.image(image, 0, 0, 16, 16)
            mixed.noStroke()
            mixed.fill(.display(red: 1, green: 0, blue: 0))
            mixed.rect(32, 32, 16, 16)
        }

        // 画像を描かなかった場合と、四角の中身が一致する
        let alone = try makeCanvas()
        try alone.draw {
            alone.background(black)
            alone.noStroke()
            alone.fill(.display(red: 1, green: 0, blue: 0))
            alone.rect(32, 32, 16, 16)
        }
        #expect(try pixels(of: mixed)[40, 40] == pixels(of: alone)[40, 40])
        #expect(try pixels(of: mixed)[40, 40] == (255, 0, 0, 255))
    }

    @Test("画像の後に置いた文字が、画像の面を読まない")
    func textAfterAnImageDoesNotSampleIt() throws {
        let url = try writePNG(Array(repeating: (0.0, 1.0, 0.0, 1.0), count: 4), width: 2, height: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let mixed = try makeCanvas(width: 160, height: 96)
        let image = try mixed.loadImage(url.path)
        try mixed.draw {
            mixed.background(black)
            mixed.image(image, 0, 0, 16, 16)
            mixed.fill(white)
            mixed.textFont("Helvetica")
            mixed.textSize(32)
            mixed.text("L", 60, 70)
        }
        let alone = try makeCanvas(width: 160, height: 96)
        try alone.draw {
            alone.background(black)
            alone.fill(white)
            alone.textFont("Helvetica")
            alone.textSize(32)
            alone.text("L", 60, 70)
        }
        // 文字の乗る領域だけを比べる
        let a = try pixels(of: mixed)
        let b = try pixels(of: alone)
        for y in 40..<80 {
            for x in 55..<90 {
                #expect(a[x, y] == b[x, y])
            }
        }
    }
}
