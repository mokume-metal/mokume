// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import MokumeTestSupport
import Testing
import UniformTypeIdentifiers

@testable import MokumeCore

/// 画像を URL から読む (#3715)。名前が `http://` か `https://` で始まれば、`loadImage`・`requestImage` は
/// その URL から受け取る。文字列・表・JSON・XML と同じ決まり (``WebFile/url(_:)``)。
///
/// **URL は外へ出ない。** 応答は ``CannedResponses`` が予約済みの `.test` の名前で返す。
@Suite(
    "画像を URL から読む",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ImageFromURLTests {
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    /// 既知の色を横に並べた 1 行の PNG。色は作業空間と同じ色域 (Display P3) で書く (``ImageTests`` と同じ理由)。
    private static func png(_ colors: [(red: Double, green: Double, blue: Double)]) -> Data {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(
            data: nil, width: colors.count, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (x, color) in colors.enumerated() {
            context.setFillColor(
                CGColor(colorSpace: space, components: [color.red, color.green, color.blue, 1])!)
            context.fill(CGRect(x: x, y: 0, width: 1, height: 1))
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static let redBlue = png([(1, 0, 0), (0, 0, 1)])
    private static let greenThree = png([(0, 1, 0), (0, 1, 0), (0, 1, 0)])

    private func pixels(of image: Image) -> [LinearRGBA] {
        (0..<image.height).flatMap { y in (0..<image.width).map { x in image.get(x, y) } }
    }

    // MARK: - 読む

    @Test("URL の PNG を requestImage・loadImage で読むと、同じ PNG をファイルから読んだ画像と同じ大きさ・同じ画素になる")
    func aPNGFromAURLMatchesTheSameFile() async throws {
        let file = TestScratch.path("mokume-url-image", pathExtension: "png")
        try Self.redBlue.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let url = CannedResponses.serve(.answer(status: 200, body: Self.redBlue), file: "a.png")

        let canvas = try makeCanvas()
        let fromFile = try canvas.loadImage(file.path)
        let requested = try await canvas.requestImage(url)
        #expect(requested.width == fromFile.width && requested.height == fromFile.height)
        #expect(pixels(of: requested) == pixels(of: fromFile))

        let other = try makeCanvas()
        let waited = try other.loadImage(CannedResponses.serve(.answer(status: 200, body: Self.redBlue), file: "b.png"))
        #expect(pixels(of: waited) == pixels(of: fromFile))
    }

    @Test("拡張子の無い URL も、種類を添えて読める。種類は中身に勝たない (PNG に jpg と添えても PNG として読む)")
    func anExtensionlessURLReadsWithAKind() async throws {
        let canvas = try makeCanvas()
        for kind in ["png", "jpg", "no-such-kind"] {
            let url = CannedResponses.serve(.answer(status: 200, body: Self.redBlue), file: "photo")
            let waited = try canvas.loadImage(url, extension: kind)
            #expect(waited.width == 2, "\(kind)")
            let again = CannedResponses.serve(.answer(status: 200, body: Self.redBlue), file: "photo")
            let requested = try await canvas.requestImage(again, extension: kind)
            #expect(pixels(of: requested) == pixels(of: waited), "\(kind)")
        }
    }

    // MARK: - 届かない・画像でない

    @Test("404 は unreachable で投げ、URL と状態を名乗る。本文を画像として読まない")
    func aMissingURLIsUnreachable() async throws {
        let url = CannedResponses.serve("<html>not here</html>", status: 404)
        let canvas = try makeCanvas()
        let expected = ImageFailure.unreachable(url: url, reason: "the server answered 404 (Not Found)")
        #expect(throws: expected) { try canvas.loadImage(url) }
        await #expect(throws: expected) { try await canvas.requestImage(url) }
        #expect(expected.description.contains(url))
        #expect(expected.description.contains("404"))
    }

    @Test("繋がらない URL も unreachable で投げる")
    func anUnconnectableURLIsUnreachable() async throws {
        let url = CannedResponses.serve(.fail(.cannotConnectToHost))
        let canvas = try makeCanvas()
        let failure = #expect(throws: ImageFailure.self) { try canvas.loadImage(url) }
        guard case .unreachable(let named, _) = failure else {
            Issue.record("unreachable で投げていない: \(String(describing: failure))")
            return
        }
        #expect(named == url)
        await #expect(throws: failure!) { try await canvas.requestImage(url) }
    }

    @Test("画像でない本文 (HTML) は、画像として読めなかったと名乗る")
    func aBodyThatIsNotAnImageIsUndecodable() async throws {
        let url = CannedResponses.serve("<!doctype html><title>hello</title>")
        let canvas = try makeCanvas()
        #expect(throws: ImageFailure.undecodable(path: url)) { try canvas.loadImage(url) }
        await #expect(throws: ImageFailure.undecodable(path: url)) { try await canvas.requestImage(url) }
    }

    @Test("file:// で始まる名前は URL でなく、ファイルの名前として探す")
    func aFileSchemeIsAFileName() throws {
        let name = "file:///nowhere/at/all.png"
        let canvas = try makeCanvas()
        let failure = #expect(throws: ImageFailure.self) { try canvas.loadImage(name) }
        guard case .notFound(let path, _) = failure else {
            Issue.record("ファイルとして探していない: \(String(describing: failure))")
            return
        }
        #expect(path == name)
    }

    // MARK: - 控え

    @Test("同じ URL を 2 度読むと、要求は 1 度だけ。サーバの側で差し替わっても 2 度目は 1 度目の画像")
    func aURLIsFetchedOncePerRun() async throws {
        let url = CannedResponses.serve(.answer(status: 200, body: Self.redBlue), file: "once.png")
        let canvas = try makeCanvas()
        let first = try canvas.loadImage(url)
        #expect(CannedResponses.requests(url) == 1)

        CannedResponses.replace(url, with: .answer(status: 200, body: Self.greenThree))
        let second = try canvas.loadImage(url)
        let requested = try await canvas.requestImage(url)
        let hinted = try canvas.loadImage(url, extension: "png")
        #expect(CannedResponses.requests(url) == 1, "2 度目からは通信しない")
        #expect(second.width == 2 && pixels(of: second) == pixels(of: first))
        #expect(pixels(of: requested) == pixels(of: first))
        #expect(pixels(of: hinted) == pixels(of: first))
        #expect(second !== first, "返る画像は毎回新しい")
    }

    @Test("待たない読み込みで受け取った URL も、控える")
    func aRequestedURLIsAlsoRemembered() async throws {
        let url = CannedResponses.serve(.answer(status: 200, body: Self.redBlue), file: "later.png")
        let canvas = try makeCanvas()
        _ = try await canvas.requestImage(url)
        _ = try canvas.loadImage(url)
        #expect(CannedResponses.requests(url) == 1)
    }

    @Test("届かなかった URL は控えず、次の読み込みで受け取り直す")
    func anUnreachableURLIsNotRemembered() throws {
        let url = CannedResponses.serve(.answer(status: 503, body: Data()), file: "flaky.png")
        let canvas = try makeCanvas()
        #expect(throws: ImageFailure.self) { try canvas.loadImage(url) }
        CannedResponses.replace(url, with: .answer(status: 200, body: Self.redBlue))
        #expect(try canvas.loadImage(url).width == 2)
        #expect(CannedResponses.requests(url) == 2)
    }
}

/// 種類の手がかりと、走っていない所で呼んだときの名乗り。GPU を要らない。
@Suite("画像の種類の手がかり")
struct ImageKindHintTests {
    @Test("拡張子は ImageIO の種類の手がかりになる。知らない拡張子・無い拡張子は手がかり無し")
    func anExtensionBecomesATypeHint() throws {
        let png = try #require(ImageFile.hints("png") as? [String: Any])
        #expect(png[kCGImageSourceTypeIdentifierHint as String] as? String == UTType.png.identifier)
        let jpg = try #require(ImageFile.hints("jpg") as? [String: Any])
        #expect(jpg[kCGImageSourceTypeIdentifierHint as String] as? String == UTType.jpeg.identifier)
        #expect(ImageFile.hints("no-such-kind") == nil)
        #expect(ImageFile.hints(nil) == nil)
    }

    final class Maker: Sketch {
        init() {}
        func draw() {}
    }

    @Test("種類を添える形も、走っていない所では自分の名前で notRunning を投げる")
    func theKindFormsNameThemselvesOutsideARun() async {
        #expect(throws: ImageFailure.notRunning(call: "loadImage(_:extension:)")) {
            try Maker().loadImage("https://example.test/a", extension: "png")
        }
        let waiting = await Task.detached { () -> ImageFailure? in
            do throws(ImageFailure) {
                _ = try await Maker().requestImage("https://example.test/a", extension: "png")
                return nil
            } catch { return error }
        }.value
        #expect(waiting == .notRunning(call: "requestImage(_:extension:)"))
    }
}
