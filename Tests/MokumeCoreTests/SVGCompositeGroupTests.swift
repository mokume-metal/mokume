// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// SVG の `opacity` を、群や要素をまとめて描いてから 1 度だけ掛ける (#3564・#2878)。GPU を要する。
///
/// 判定は透明地の alpha で行う (色空間はブラウザと違うので、灰色の明るさでは比べない・#2878)。どの単位で
/// まとめるかの読み解きは `SVGGroupOpacityTests` が見る。
@Suite(
    "SVG の opacity の合成の単位の絵",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SVGCompositeGroupTests {
    private static let width = 240
    private static let height = 160

    /// #2878 の群の例: `opacity='0.5'` の群の中に重なる白い矩形 2 つ。重なりは (70…120, 40…120)。
    static let group =
        "<g opacity='0.5'><rect x='20' y='20' width='100' height='100' fill='white'/>"
        + "<rect x='70' y='40' width='100' height='100' fill='white'/></g>"

    /// #2878 の単一要素の例: 塗りと線を両方持つ矩形に `opacity='0.5'`。線は x 20…40 / 140…160 の帯。
    static let element =
        "<rect x='30' y='30' width='120' height='90' fill='white' stroke='white' stroke-width='20' opacity='0.5'/>"

    /// 部分パスどうしが (80, 40) で交わる半透明の線 (#3564 の完了条件 6)。
    static let crossing =
        "<path d='M20 40 H140 M80 10 V120' fill='none' stroke='white' stroke-width='20' stroke-opacity='0.5'/>"

    private func drawing(_ body: String) throws -> SVGFile.Drawing {
        try SVGFile.parse(
            "<svg xmlns='http://www.w3.org/2000/svg' width='\(Self.width)' height='\(Self.height)'>\(body)</svg>",
            path: "composite.svg")
    }

    private func makeCanvas(pixelDensity: Float = 1) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: Self.width, height: Self.height)
        guard pixelDensity != 1 else { return try Canvas(target: target, gpu: gpu) }
        return try Canvas(output: target, gpu: gpu, pixelDensity: pixelDensity, upscale: .spatial)
    }

    /// 透明地に、`body` を読んだ形を `place` で置いた絵。
    private func rendered(
        _ body: String, on canvas: Canvas? = nil, place: (Canvas, Shape) -> Void = { $0.shape($1) }
    ) throws -> (DisplayImage, Canvas) {
        let canvas = try canvas ?? makeCanvas()
        let read = try drawing(body)
        try canvas.draw {
            let shape = canvas.shape(of: read, readFrom: "composite.svg")
            place(canvas, shape)
        }
        return (try canvas.output.encodeForDisplay(), canvas)
    }

    private func alpha(_ image: DisplayImage, _ x: Int, _ y: Int) -> Int { Int(image[x, y].alpha) }

    // MARK: - 完了条件 1・2・6

    @Test("群の例: 単独の部分 (30,30) も重なり (80,80) も alpha 128±1 (変更前は重なりが 191)")
    func groupIsFadedOnce() throws {
        let (image, canvas) = try rendered(Self.group)
        #expect(abs(alpha(image, 30, 30) - 128) <= 1, "\(image[30, 30])")
        #expect(abs(alpha(image, 80, 80) - 128) <= 1, "\(image[80, 80])")
        #expect(abs(alpha(image, 160, 130) - 128) <= 1, "\(image[160, 130])")
        #expect(alpha(image, 200, 20) == 0, "群の外は透明")
        #expect(canvas.warnings.message(for: .compositeGroupPerShape) == nil, "単位にできた")
    }

    @Test("単一要素の例: 塗りだけ・線だけ・両方が重なる所で alpha 128±1 (変更前は塗りと線の重なりが 191)")
    func elementIsFadedOnce() throws {
        let (image, _) = try rendered(Self.element)
        #expect(abs(alpha(image, 80, 80) - 128) <= 1, "塗りだけ: \(image[80, 80])")
        #expect(abs(alpha(image, 22, 80) - 128) <= 1, "線だけ: \(image[22, 80])")
        #expect(abs(alpha(image, 30, 30) - 128) <= 1, "塗りと線の重なり: \(image[30, 30])")
        #expect(abs(alpha(image, 35, 80) - 128) <= 1, "塗りと線の重なり: \(image[35, 80])")
    }

    @Test("部分パスどうしが重なる半透明の線: 交わる所 (80,40) も alpha 128±1 (変更前は 191)")
    func crossingSubpathsAreBlendedOnce() throws {
        let (image, _) = try rendered(Self.crossing)
        #expect(abs(alpha(image, 80, 40) - 128) <= 1, "交わる所: \(image[80, 40])")
        #expect(abs(alpha(image, 30, 40) - 128) <= 1, "横の線だけ: \(image[30, 40])")
        #expect(abs(alpha(image, 80, 100) - 128) <= 1, "縦の線だけ: \(image[80, 100])")
    }

    @Test(
        "不透明な線の部分パスは 1 つの図形にしない: 縦だけ細くなる置き方で、太い縦の線は細い横の線との交わりでも不透明 (前と同じ)")
    func opaqueSubpathStrokesAreNotOneFigure() throws {
        // 横の線は縦 0.04 倍で 1 画素より細くなり (被覆が 1 未満)、縦の線は横 1.5 倍で太いまま。1 つの図形にすると
        // 型板が先に引いた横の線の被覆だけを残し、交わる所 (120, 2) の縦の線が薄くなる
        let (image, _) = try rendered(
            "<path d='M20 40 H140 M80 10 V120' fill='none' stroke='white' stroke-width='20'/>"
        ) { canvas, shape in
            canvas.scale(1.5, 0.04)
            canvas.shape(shape)
        }
        #expect(alpha(image, 120, 2) == 255, "交わる所: \(image[120, 2])")
    }

    // MARK: - 完了条件 3・5

    @Test("fill-opacity / stroke-opacity は別々に掛かる (SVG と同じ): 塗りと線の重なりは 1 - 0.5 × 0.5 = 191")
    func paintOpacitiesStayIndependent() throws {
        let (image, _) = try rendered(
            "<rect x='30' y='30' width='120' height='90' fill='white' fill-opacity='0.5' stroke='white' "
                + "stroke-width='20' stroke-opacity='0.5'/>")
        #expect(abs(alpha(image, 80, 80) - 128) <= 1, "\(image[80, 80])")
        #expect(abs(alpha(image, 35, 80) - 191) <= 1, "\(image[35, 80])")
    }

    @Test("入れ子の半透明の群は掛け合わさる: 0.5 の中の 0.5 は、重なりも単独の所も 0.25 (64)")
    func nestedGroupsMultiply() throws {
        let (image, _) = try rendered("<g opacity='0.5'>\(Self.group)</g>")
        #expect(abs(alpha(image, 30, 30) - 64) <= 1, "\(image[30, 30])")
        #expect(abs(alpha(image, 80, 80) - 64) <= 1, "\(image[80, 80])")
    }

    @Test("opacity 1 の群と、重ならない群は単位にせず、色に掛ける (形は単位の範囲を持たない)")
    func opaqueAndSeparateGroupsAreNotUnits() throws {
        let canvas = try makeCanvas()
        var shapes: [Shape] = []
        let read = try [
            "<g opacity='1'><rect x='20' y='20' width='100' height='100' fill='white'/>"
                + "<rect x='70' y='40' width='100' height='100' fill='white'/></g>",
            "<g opacity='0.5'><rect x='10' y='10' width='40' height='40' fill='white'/>"
                + "<rect x='100' y='100' width='40' height='40' fill='white'/></g>",
        ].map(drawing)
        try canvas.draw {
            for drawing in read { shapes.append(canvas.shape(of: drawing, readFrom: "composite.svg")) }
            for shape in shapes { canvas.shape(shape) }
        }
        let rangeCounts = shapes.map { $0.compositeGroups.count }
        #expect(rangeCounts == [0, 0])
        let image = try canvas.output.encodeForDisplay()
        #expect(abs(alpha(image, 30, 30) - 255) <= 1, "\(image[30, 30])")
        #expect(abs(alpha(image, 120, 120) - 255) <= 1, "opacity 1 の群と 0.5 の矩形が重なる所: \(image[120, 120])")
    }

    // MARK: - 組にする・入れ子の記録・まとめて置く

    @Test("組にした形と入れ子の記録は範囲を引き継ぎ、置いた先でも 1 度だけ掛かる")
    func groupingAndNestedRecordingKeepTheUnits() throws {
        let canvas = try makeCanvas()
        var combined: Shape?
        var nested: Shape?
        let group = try drawing(Self.group)
        try canvas.draw {
            let logo = canvas.shape(of: group, readFrom: "composite.svg")
            combined = Shape.group([logo, logo])
            nested = canvas.createShape {
                canvas.translate(4, 0)
                canvas.shape(logo)
            }
            if let nested { canvas.shape(nested) }
        }
        // 入れ子の記録で置いた群も、置いた先で 1 度だけ掛かる (子ごとに掛けると重なりが 191)
        let image = try canvas.output.encodeForDisplay()
        #expect(abs(alpha(image, 30, 30) - 128) <= 1, "\(image[30, 30])")
        #expect(abs(alpha(image, 90, 80) - 128) <= 1, "\(image[90, 80])")
        let pair = try #require(combined)
        #expect(pair.compositeGroups.count == 2)
        #expect(pair.compositeGroups.map(\.runs) == [0..<1, 1..<2], "境目で区間を畳まない: \(pair.compositeGroups)")
        let moved = try #require(nested)
        #expect(moved.compositeGroups.count == 1)
        let bounds = try #require(moved.compositeGroups.first?.bounds)
        #expect(bounds.minX == 24 && bounds.maxX == 174, "外接も記録の変換で動く: \(bounds)")
        #expect(canvas.warnings.message(for: .compositeGroupInsideShape) == nil, "記録の中で単位を開かない")
    }

    @Test("置き場所を並べて置くと、置き場所ごとに単位になる (置き場所どうしの重なりは重なる)")
    func placementsAreUnitsEach() throws {
        let (image, canvas) = try rendered(Self.group) { canvas, shape in
            canvas.shape(shape, at: [Placement(x: 0, y: 0), Placement(x: 10, y: 0)])
        }
        // 2 つの置き場所の重なり: 0.5 と 0.5 を重ねて 0.75。1 つの置き場所の中の重なりは濃くならない
        #expect(abs(alpha(image, 25, 30) - 128) <= 1, "1 つ目だけ: \(image[25, 30])")
        #expect(abs(alpha(image, 40, 30) - 191) <= 1, "2 つの置き場所が重なる: \(image[40, 30])")
        #expect(canvas.warnings.message(for: .compositeGroupPerShape) == nil)
    }

    @Test("組にした形を置くと、移した範囲がそれぞれ単位になる: 同じ所に 2 つ重ねて、単独も重なりも 0.75 (191)")
    func groupedShapeIsPlacedAsTwoUnits() throws {
        let (image, canvas) = try rendered(Self.group) { canvas, shape in
            canvas.shape(Shape.group([shape, shape]))
        }
        // 単位ごとに 0.5 を 1 度だけ掛けて 2 枚重ねる: 1 - 0.5 × 0.5。範囲を失って子ごとに掛けると重なりがもっと濃い
        #expect(abs(alpha(image, 30, 30) - 191) <= 1, "\(image[30, 30])")
        #expect(abs(alpha(image, 80, 80) - 191) <= 1, "\(image[80, 80])")
        #expect(canvas.warnings.message(for: .compositeGroupPerShape) == nil)
    }

    // MARK: - 置く側の混ぜ方と断片 (反証 #1・#5)

    /// 単位にする群と、単位にしない半透明の矩形 (`fill-opacity`・x 180…220) を 1 つの形に持つ。
    static let groupBesideAPlainRect =
        group + "<rect x='180' y='20' width='40' height='40' fill='white' fill-opacity='0.5'/>"

    private func sameColor(
        _ image: DisplayImage, _ a: (Int, Int), _ b: (Int, Int)
    ) -> Bool {
        let p = image[a.0, a.1]
        let q = image[b.0, b.1]
        return abs(Int(p.red) - Int(q.red)) <= 1 && abs(Int(p.green) - Int(q.green)) <= 1
            && abs(Int(p.blue) - Int(q.blue)) <= 1 && abs(Int(p.alpha) - Int(q.alpha)) <= 1
    }

    @Test(
        "置く側の混ぜ方 (add) は、単位の部分にも単位にしない部分にも効かない (記録した blend で描き、1 つの形の中で割れない)")
    func placingBlendModeDoesNotSplitTheShape() throws {
        let (image, canvas) = try rendered(Self.groupBesideAPlainRect) { canvas, shape in
            canvas.background(LinearRGBA.linear(red: 0.2, green: 0.2, blue: 0.2))
            canvas.blendMode(.add)
            canvas.shape(shape)
        }
        #expect(sameColor(image, (30, 30), (200, 40)), "単位: \(image[30, 30]) / 単位にしない矩形: \(image[200, 40])")
        #expect(sameColor(image, (80, 80), (30, 30)), "重なり: \(image[80, 80]) / 単独: \(image[30, 30])")
        #expect(canvas.warnings.message(for: .compositeGroupPerShape) == nil, "単位にできた")
    }

    @Test("入れ子の記録の混ぜ方 (add) も、引き継いだ単位には効かない (元の範囲の blend で置く)")
    func nestedRecordingBlendModeDoesNotSplitTheShape() throws {
        let canvas = try makeCanvas()
        let read = try drawing(Self.groupBesideAPlainRect)
        try canvas.draw {
            let logo = canvas.shape(of: read, readFrom: "composite.svg")
            let nested = canvas.createShape {
                canvas.blendMode(.add)
                canvas.shape(logo)
            }
            canvas.background(LinearRGBA.linear(red: 0.2, green: 0.2, blue: 0.2))
            canvas.shape(nested)
        }
        let image = try canvas.output.encodeForDisplay()
        #expect(sameColor(image, (30, 30), (200, 40)), "単位: \(image[30, 30]) / 単位にしない矩形: \(image[200, 40])")
        #expect(sameColor(image, (80, 80), (30, 30)), "重なり: \(image[80, 80]) / 単独: \(image[30, 30])")
    }

    /// 赤を返す断片。置く側に当てても、記録した塗りで描く形には効かない。
    private static let red = "float4 paint(Fragment in, Values values) { return float4(1, 0, 0, 1); }"

    @Test("置く側の shader() は、単位の部分にも単位にしない部分にも効かない (記録した塗りで描き、1 つの形の中で割れない)")
    func placingShaderDoesNotSplitTheShape() throws {
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(Self.red)
        let (image, _) = try rendered(Self.groupBesideAPlainRect, on: canvas) { canvas, shape in
            canvas.shader(shader)
            canvas.shape(shape)
        }
        #expect(sameColor(image, (30, 30), (200, 40)), "単位: \(image[30, 30]) / 単位にしない矩形: \(image[200, 40])")
        #expect(abs(alpha(image, 30, 30) - 128) <= 1, "\(image[30, 30])")
        #expect(abs(alpha(image, 80, 80) - 128) <= 1, "\(image[80, 80])")
        #expect(canvas.warnings.message(for: .compositeGroupPerShape) == nil, "単位にできた")
    }

    // MARK: - 完了条件 9・10: 単位にできない所

    @Test("視点を決めた下では、子ごとに掛けて描き (重なりは濃い)、1 度だけ知らせる")
    func underACameraEachShapeIsFaded() throws {
        let (image, canvas) = try rendered(Self.group) { canvas, shape in
            canvas.ortho()
            canvas.shape(shape)
            canvas.shape(shape, 0, 0)
        }
        #expect(alpha(image, 30, 30) > 0, "描かれている")
        let message = try #require(canvas.warnings.message(for: .compositeGroupPerShape))
        #expect(message.contains("camera"))
        // 2 度置いたので、重なりはさらに濃い。単独の所も 2 度重なる (1 - 0.5²)
        #expect(alpha(image, 80, 80) > alpha(image, 30, 30), "\(image[80, 80]) / \(image[30, 30])")
    }

    @Test("視点の下で 1 度だけ置くと、重なりは変更前と同じく濃い (191) — 子ごとに掛けた絵")
    func underACameraTheOverlapIsAsBefore() throws {
        let (image, _) = try rendered(Self.group) { canvas, shape in
            canvas.ortho()
            canvas.shape(shape)
        }
        #expect(alpha(image, 30, 30) > 0)
        #expect(alpha(image, 80, 80) > alpha(image, 30, 30) + 40, "\(image[80, 80]) / \(image[30, 30])")
    }

    @Test("細かさが 1 未満の面でも、子ごとに掛けて描き、1 度だけ知らせる")
    func reducedDensityEachShapeIsFaded() throws {
        let (image, canvas) = try rendered(Self.group, on: try makeCanvas(pixelDensity: 0.5))
        #expect(alpha(image, 30, 30) > 0, "描かれている")
        #expect(canvas.warnings.message(for: .compositeGroupPerShape) != nil)
    }

    @Test(
        "置く側の混ぜ方が replace でも単位にする (記録した blend で置く): 重なりも単独の所も単位にしない区間と同じ色、箱の中の形の外は地のまま、知らせない")
    func replacePlacingModeStillMakesAUnit() throws {
        let (image, canvas) = try rendered(Self.groupBesideAPlainRect) { canvas, shape in
            canvas.background(LinearRGBA.linear(red: 0.2, green: 0.2, blue: 0.2))
            canvas.blendMode(.replace)
            canvas.shape(shape)
        }
        #expect(alpha(image, 200, 40) == 255, "単位にしない矩形は地と混ざる (blend): \(image[200, 40])")
        #expect(sameColor(image, (30, 30), (200, 40)), "単独: \(image[30, 30]) / 単位にしない矩形: \(image[200, 40])")
        #expect(sameColor(image, (80, 80), (30, 30)), "重なり: \(image[80, 80]) / 単独: \(image[30, 30])")
        // 箱 (20…170, 20…140) の中で形の外の画素。四角を replace で置くと、透明な画素が地を消す
        #expect(sameColor(image, (160, 30), (230, 150)), "箱の中の形の外: \(image[160, 30]) / 地: \(image[230, 150])")
        #expect(sameColor(image, (25, 135), (230, 150)), "箱の中の形の外: \(image[25, 135]) / 地: \(image[230, 150])")
        #expect(canvas.warnings.message(for: .compositeGroupPerShape) == nil, "単位にできた")
    }

    @Test("フレームの外で置くと、置く口がフレームの外として断る (単位の知らせは出ない)")
    func outsideTheFrameIsRefusedByThePlacingCall() throws {
        let canvas = try makeCanvas()
        let read = try drawing(Self.group)
        var shape: Shape?
        try canvas.draw { shape = canvas.shape(of: read, readFrom: "composite.svg") }
        canvas.shape(try #require(shape))
        #expect(canvas.warnings.message(for: .placingOutsideFrame) != nil)
        #expect(canvas.warnings.message(for: .compositeGroupPerShape) == nil)
    }
}
