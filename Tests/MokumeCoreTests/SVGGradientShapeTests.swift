// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// SVG に書いた勾配で塗った形の絵 (#3031)。GPU を要する。
///
/// 読み解き (どの勾配をどの座標で読むか) は ``SVGGradientTests`` が見る。ここは、読んだ勾配が本体の
/// `fill(_: Gradient)` の経路で形に焼き付き、画素がその色になることを見る。画素は描く面の線形の値で読む。
/// 描く面は sRGB より広い色域なので、SVG の `red` は赤 0.82・緑 0.03 ほどになる (``Self/red``)。
@Suite(
    "SVG の勾配の絵",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SVGGradientShapeTests {
    private static let width = 240
    private static let height = 160
    private static let stops = "<stop offset='0' stop-color='red'/><stop offset='1' stop-color='blue'/>"
    private static let path = "gradient.svg"

    private func drawing(_ body: String) throws -> SVGFile.Drawing {
        try SVGFile.parse(
            "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' "
                + "width='\(Self.width)' height='\(Self.height)'>\(body)</svg>",
            path: Self.path)
    }

    /// 透明地に、`body` を読んだ形を `place` で置き、描く面の線形の値と面を返す。
    private func rendered(
        _ body: String, place: (Canvas, Shape) -> Void = { $0.shape($1) }
    ) throws -> (PixelBuffer, Canvas) {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.width, height: Self.height)
        let read = try drawing(body)
        try canvas.draw {
            let shape = canvas.shape(of: read, readFrom: Self.path)
            place(canvas, shape)
        }
        return (try canvas.target.readPixels(), canvas)
    }

    /// SVG の `red` (sRGB の 1, 0, 0) の、描く面の値。
    private static let red = LinearRGBA.display(red: 1, green: 0, blue: 0)

    /// 赤寄り (赤が `red` の 85% より上・青 < 0.15) か。
    private func isReddish(_ pixel: LinearRGBA) -> Bool { pixel.red > Self.red.red * 0.85 && pixel.blue < 0.15 }
    /// 青寄り (青 > 0.8・赤 < 0.15) か。
    private func isBluish(_ pixel: LinearRGBA) -> Bool { pixel.blue > 0.8 && pixel.red < 0.15 }
    /// 赤と青を半分ずつ混ぜた所か (線形の空間で混ぜる)。
    private func isHalfway(_ pixel: LinearRGBA) -> Bool { abs(pixel.red - Self.red.red / 2) < 0.04 }

    // MARK: - 条件 4・5

    @Test("線形 (条件 4): 矩形の左端に近い画素は赤寄り、右端に近い画素は青寄り。捨てた知らせは出ない (変更前は塗られない)")
    func linearGradientPaintsTheRect() throws {
        let (pixels, canvas) = try rendered(
            "<linearGradient id='g'>\(Self.stops)</linearGradient><rect width='80' height='50' fill='url(#g)'/>")
        #expect(isReddish(pixels[2, 25]), "左端: \(pixels[2, 25])")
        #expect(isBluish(pixels[77, 25]), "右端: \(pixels[77, 25])")
        // 真ん中は両方が混ざる (線形の空間で 0.5 ずつ)
        #expect(isHalfway(pixels[40, 25]), "\(pixels[40, 25])")
        #expect(pixels[100, 25].alpha == 0, "矩形の外は透明")
        #expect(canvas.warnings.message(for: .svgSkipped(path: Self.path)) == nil)
        #expect(canvas.warnings.message(for: .badGradient) == nil)
    }

    @Test("放射 (条件 5): 中心の画素は最初の区切りの色、縁の手前は最後の区切りの色に寄る")
    func radialGradientPaintsTheCircle() throws {
        let (pixels, _) = try rendered(
            "<radialGradient id='r' cx='0.5' cy='0.5' r='0.5'>\(Self.stops)</radialGradient>"
                + "<circle cx='60' cy='40' r='30' fill='url(#r)'/>")
        #expect(isReddish(pixels[60, 40]), "中心: \(pixels[60, 40])")
        #expect(isBluish(pixels[87, 40]), "縁の手前 (右): \(pixels[87, 40])")
        #expect(isBluish(pixels[60, 67]), "縁の手前 (下): \(pixels[60, 67])")
    }

    @Test("放射の objectBoundingBox は外接矩形に沿って楕円になる: 横長の楕円の横と縦の縁の手前がどちらも青寄り")
    func radialGradientFollowsAWideBox() throws {
        let (pixels, _) = try rendered(
            "<radialGradient id='r'>\(Self.stops)</radialGradient>"
                + "<ellipse cx='120' cy='80' rx='100' ry='40' fill='url(#r)'/>")
        #expect(isReddish(pixels[120, 80]), "中心: \(pixels[120, 80])")
        #expect(isBluish(pixels[216, 80]), "横の縁の手前: \(pixels[216, 80])")
        #expect(isBluish(pixels[120, 118]), "縦の縁の手前: \(pixels[120, 118])")
        // 縦の 20 画素は、横の 50 画素と同じ位置 (半分)
        #expect(abs(pixels[120, 100].red - pixels[170, 80].red) < 0.05, "\(pixels[120, 100]) / \(pixels[170, 80])")
    }

    // MARK: - 条件 6・7・8

    @Test("userSpaceOnUse (条件 6): x2 = 40 の勾配は、幅 80 の矩形の x = 40 より右を最後の色で塗る")
    func userSpaceGradientStopsAtItsEnd() throws {
        let (pixels, _) = try rendered(
            "<linearGradient id='g' gradientUnits='userSpaceOnUse' x1='0' x2='40'>\(Self.stops)</linearGradient>"
                + "<rect width='80' height='50' fill='url(#g)'/>")
        #expect(isReddish(pixels[1, 25]), "\(pixels[1, 25])")
        #expect(pixels[60, 25] == pixels[79, 25] && pixels[60, 25].red < 0.001, "端の外は最後の色: \(pixels[60, 25])")
        #expect(isHalfway(pixels[20, 25]), "x = 20 で半分: \(pixels[20, 25])")
    }

    @Test("gradientTransform (条件 7): rotate(90) で左右の勾配が上下になる")
    func gradientTransformTurnsTheGradient() throws {
        let (pixels, _) = try rendered(
            "<linearGradient id='g' gradientTransform='rotate(90)'>\(Self.stops)</linearGradient>"
                + "<rect width='80' height='50' fill='url(#g)'/>")
        #expect(isReddish(pixels[40, 1]), "上: \(pixels[40, 1])")
        #expect(isBluish(pixels[40, 48]), "下: \(pixels[40, 48])")
        #expect(abs(pixels[2, 25].red - pixels[77, 25].red) < 0.02, "左右には変わらない")
    }

    @Test("href (条件 8): 区切りを持たない勾配が、xlink:href で指した勾配の色で塗る")
    func hrefGradientPaintsWithInheritedStops() throws {
        let (pixels, canvas) = try rendered(
            "<defs><linearGradient id='a'>\(Self.stops)</linearGradient>"
                + "<linearGradient id='b' xlink:href='#a' x1='0' x2='1'/></defs>"
                + "<rect width='80' height='50' fill='url(#b)'/>")
        #expect(isReddish(pixels[2, 25]), "\(pixels[2, 25])")
        #expect(isBluish(pixels[77, 25]), "\(pixels[77, 25])")
        #expect(canvas.warnings.message(for: .svgSkipped(path: Self.path)) == nil)
    }

    @Test("href の指す先が無いなら塗らず、捨てた知らせを 1 度出す")
    func brokenHrefPaintsNothing() throws {
        let (pixels, canvas) = try rendered(
            "<linearGradient id='b' href='#none'/><rect width='80' height='50' fill='url(#b)' stroke='white'/>")
        #expect(pixels[40, 25].alpha == 0, "塗らない: \(pixels[40, 25])")
        #expect(pixels[0, 25].alpha > 0, "線は引く")
        let notice = try #require(canvas.warnings.message(for: .svgSkipped(path: Self.path)))
        #expect(notice.contains(##"<linearGradient href="#none">"##), "\(notice)")
    }

    // MARK: - 置き方・不透明度・単位 (#3564)

    @Test("勾配は形に焼き付き、置き場所と一緒に動く")
    func gradientMovesWithThePlacement() throws {
        let (pixels, _) = try rendered(
            "<linearGradient id='g'>\(Self.stops)</linearGradient><rect width='80' height='50' fill='url(#g)'/>"
        ) { canvas, shape in
            canvas.shape(shape, 100, 60)
        }
        #expect(isReddish(pixels[102, 85]), "\(pixels[102, 85])")
        #expect(isBluish(pixels[177, 85]), "\(pixels[177, 85])")
        #expect(pixels[40, 25].alpha == 0, "元の場所には無い")
    }

    @Test("fill-opacity は勾配の不透明度に掛かる: 0.5 の勾配は透明地で alpha 0.5")
    func fillOpacityFadesTheGradient() throws {
        let (pixels, _) = try rendered(
            "<linearGradient id='g'>\(Self.stops)</linearGradient>"
                + "<rect width='80' height='50' fill='url(#g)' fill-opacity='0.5'/>")
        #expect(abs(pixels[2, 25].alpha - 0.5) < 0.01, "\(pixels[2, 25])")
        #expect(abs(pixels[77, 25].alpha - 0.5) < 0.01, "\(pixels[77, 25])")
    }

    @Test("半透明の群の単位の中の勾配: 重なりも単独の所も alpha 128±1 で、色は勾配のまま")
    func gradientInsideACompositeUnit() throws {
        let body =
            "<linearGradient id='g'>\(Self.stops)</linearGradient><g opacity='0.5'>"
            + "<rect x='20' y='20' width='100' height='100' fill='url(#g)'/>"
            + "<rect x='70' y='40' width='100' height='100' fill='url(#g)'/></g>"
        let read = try drawing(body)
        #expect(read.units.count == 1, "群が単位になる: \(read.units)")
        let (_, canvas) = try rendered(body)
        let image = try canvas.output.encodeForDisplay()
        for (x, y) in [(25, 30), (100, 80), (160, 130)] {
            #expect(abs(Int(image[x, y].alpha) - 128) <= 1, "(\(x), \(y)): \(image[x, y])")
        }
        #expect(image[25, 30].red > image[25, 30].blue, "左の矩形の左端は赤寄り: \(image[25, 30])")
        #expect(image[165, 130].blue > image[165, 130].red, "右の矩形の右端は青寄り: \(image[165, 130])")
        #expect(canvas.warnings.message(for: .compositeGroupPerShape) == nil, "単位にできた")
    }

    @Test("塗りと線を両方持つ半透明の要素の単位の中の勾配: 塗りだけ・塗りと線の重なりが alpha 128±1")
    func gradientInsideAnElementUnit() throws {
        let body =
            "<linearGradient id='g'>\(Self.stops)</linearGradient>"
            + "<rect x='30' y='30' width='120' height='90' fill='url(#g)' stroke='white' stroke-width='20' opacity='0.5'/>"
        #expect(try drawing(body).units.count == 1)
        let (_, canvas) = try rendered(body)
        let image = try canvas.output.encodeForDisplay()
        #expect(abs(Int(image[80, 80].alpha) - 128) <= 1, "塗りだけ: \(image[80, 80])")
        #expect(abs(Int(image[35, 80].alpha) - 128) <= 1, "塗りと線の重なり: \(image[35, 80])")
    }
}
