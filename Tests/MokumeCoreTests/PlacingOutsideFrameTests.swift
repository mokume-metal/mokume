// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 置く口 (図形・絵・背景・形を組んで置く口)。**口ごとに、区間の外で呼ぶと断ることを回す**
/// ([#1672])。
///
/// 約束は ADR-0021 決定 4 の追補 (2026-09-27) の「置いたものをフレームの外に置いてよいのは、
/// 持ち越しを約束する区間だけ」である。守りは口ではなく、図形が溜め場に入る合流点の
/// `guard canPlace` で持つので、口の列は**合流点をどれか 1 つは通る**ように選んである —
/// 距離関数の経路 (`appendForm`)・畳みの経路 (`draw(folding:)`)・周の経路 (`draw(_:)`)・
/// 三角形 (`appendTriangle`)・字 (`appendGlyphQuad`)・絵 (`appendImageQuad`)・立体の塗り
/// (`placeMesh`)・立体の稜線 (`strokeSolidEdges`)・その場で並べる立体 (`inSolidBatch`)・
/// 保持した形 (`place(_:at:)`)・背景の 2 つ。
///
/// **書き落とした合流点は、フレームの頭の検めが拾う** (`Canvas.beginFrame()`)。この列は
/// 注意と溜め場を見る側で、検めの側は ``PlacementLeakTests`` が見る。
///
/// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
enum PlacingCall: CaseIterable, CustomTestStringConvertible {
    case rect
    case circle
    case ellipse
    case arc
    case square
    case line
    case point
    case triangle
    case quad
    /// 貼る絵を持ち、輪郭の無い矩形。2 つ続けて畳みの経路 (`draw(folding:)`) を通る。
    case rectFolded
    /// 断片を効かせた矩形 (#1592 の完了条件 2 の「畳みの経路を通る形」)。三角形の経路を通る。
    case rectWithShader
    /// 貼る絵と輪郭が同居する矩形。畳まずに周の経路 (`draw(_:)`) を通る。
    case rectTexturedWithStroke
    case text
    case image
    case imageOfGraphics
    case box
    /// 塗りの無い立体。稜線の経路 (`strokeSolidEdges`) だけを通る。
    case boxWithoutFill
    case sphere
    case plane
    case cylinder
    case cone
    case torus
    case ellipsoid
    case model
    case shapeFlat
    case shapeSolid
    case beginShapeFlat
    /// 奥行きのある形。その場で並べる立体 (`inSolidBatch`) と、奥行きのある輪郭
    /// (`strokeSolidRing`) を通る。
    case beginShapeSolid
    case beginShapeWithContour
    case background
    case backgroundSurroundings

    var testDescription: String { "\(self)" }

    /// 口が読む道具。**置く面で作る** — 形は組み立てた面の面を記録するので。
    struct Props {
        let image: Image
        let other: Canvas
        let model: Model
        let shader: Shader
        let flatShape: Shape
        let solidShape: Shape

        /// `canvas` で道具を作る。形の組み立て (`createShape`) はフレームの外でも効く。
        init(on canvas: Canvas) throws {
            image = try canvas.createImage(4, 4)
            image.fill(.linear(red: 1, green: 1, blue: 1))
            other = try canvas.createGraphics(8, 8)
            model = try canvas.loadModel(ModelFixture.pyramid)
            shader = try canvas.makeShader(
                "float4 paint(Fragment in, Values values) { return float4(0.0, 1.0, 0.0, 1.0); }")
            flatShape = canvas.createShape { canvas.rect(0, 0, 4, 4) }
            solidShape = canvas.createShape { canvas.box(4) }
        }
    }

    func call(on canvas: Canvas, _ props: Props) {
        switch self {
        case .rect: canvas.rect(1, 1, 6, 6)
        case .circle: canvas.circle(8, 8, 6)
        case .ellipse: canvas.ellipse(8, 8, 6, 4)
        case .arc: canvas.arc(8, 8, 6, 6, 0, 1)
        case .square: canvas.square(1, 1, 6)
        case .line: canvas.line(1, 1, 12, 12)
        case .point: canvas.point(4, 4)
        case .triangle: canvas.triangle(1, 1, 12, 1, 1, 12)
        case .quad: canvas.quad(1, 1, 12, 1, 12, 12, 1, 12)
        case .rectFolded:
            canvas.texture(props.image)
            canvas.noStroke()
            canvas.rect(0, 0, 3, 3)
            canvas.rect(4, 0, 3, 3)
        case .rectWithShader:
            canvas.shader(props.shader)
            canvas.rect(1, 1, 6, 6)
        case .rectTexturedWithStroke:
            canvas.texture(props.image)
            canvas.rect(1, 1, 6, 6)
        case .text: canvas.text("abc", 1, 12)
        case .image: canvas.image(props.image, 0, 0)
        case .imageOfGraphics: canvas.image(props.other, 0, 0)
        case .box: canvas.box(4)
        case .boxWithoutFill:
            canvas.noFill()
            canvas.box(4)
        case .sphere: canvas.sphere(4)
        case .plane: canvas.plane(4, 4)
        case .cylinder: canvas.cylinder(2, 4)
        case .cone: canvas.cone(2, 4)
        case .torus: canvas.torus(3, 1)
        case .ellipsoid: canvas.ellipsoid(2, 3, 4)
        case .model: canvas.model(props.model)
        case .shapeFlat: canvas.shape(props.flatShape, 2, 2)
        case .shapeSolid: canvas.shape(props.solidShape, 2, 2)
        case .beginShapeFlat:
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(8, 0)
            canvas.vertex(0, 8)
            canvas.endShape(.close)
        case .beginShapeSolid:
            canvas.beginShape()
            canvas.vertex(0, 0, 1)
            canvas.vertex(8, 0, 1)
            canvas.vertex(0, 8, 1)
            canvas.endShape(.close)
        case .beginShapeWithContour:
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(12, 0)
            canvas.vertex(12, 12)
            canvas.vertex(0, 12)
            canvas.beginContour()
            canvas.vertex(4, 4)
            canvas.vertex(8, 4)
            canvas.vertex(8, 8)
            canvas.endContour()
            canvas.endShape(.close)
        case .background: canvas.background(.linear(red: 0, green: 0, blue: 0))
        case .backgroundSurroundings: canvas.background(.sky)
        }
    }
}

/// 画素を書く口。書いた画素も次の描き切りで面に載るので、置くことと同じ規則に従う
/// (ADR-0021 決定 4 の追補 (2026-09-27)・#1654・#1655)。
enum PixelWriteCall: CaseIterable, CustomTestStringConvertible {
    case set
    case subscriptSet
    case fill

    var testDescription: String { "\(self)" }

    static let color = LinearRGBA.linear(red: 1, green: 0, blue: 0)

    func call(on canvas: Canvas) {
        switch self {
        case .set: canvas.set(2, 2, Self.color)
        case .subscriptSet: canvas.pixels[2, 2] = Self.color
        case .fill: canvas.pixels.fill(Self.color)
        }
    }
}

/// 区間の外で置いたときの面。描き場所の区間の外と、直に使う `Canvas` の `draw { }` の外。
enum PlacingSurface: CaseIterable, CustomTestStringConvertible {
    /// `createGraphics` で作った描き場所。区間は `beginDraw()`〜`endDraw()` (#1592)。
    case graphics
    /// 直に使う `Canvas`。区間は `draw { }` の中だけ。
    case direct

    var testDescription: String { "\(self)" }

    func make(gpu: RenderDevice) throws -> Canvas {
        let host = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        switch self {
        case .graphics: return try host.createGraphics(16, 16)
        case .direct: return host
        }
    }
}

/// 持ち越しの区間の外で置いたもの・書いた画素を断る ([#1672])。GPU を要する。
///
/// **口ごとに新しい面を作る。** 注意は初回だけ言う仕組みに載っているので、1 つの面で続けて
/// 呼ぶと最初の 1 本しか確かめられない (`SceneOutsideFrameTests` と同じ作法)。
///
/// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
@Suite(
    "持ち越しの区間の外で置いたもの",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PlacingOutsideFrameTests {
    private let placingNotice = Canvas.OutsideFrame.placing.notice
    private let pixelWriteNotice = Canvas.OutsideFrame.pixelWrite.notice

    /// 溜め場の中身の数。開いている列の有無は入れない — 区間の外でも、描き方を替えれば列は閉じる。
    private static func stored(in canvas: Canvas) -> [Int] {
        [
            canvas.vertices.count, canvas.solidVertices.count, canvas.solidIndices.count,
            canvas.solidInstances.count, canvas.formInstances.count, canvas.flatInstances.count,
            canvas.recordedStrokeRanges.count, canvas.recordedSolidStrokes.count,
            canvas.placedGraphics.count, canvas.hasPendingDrawing ? 1 : 0,
        ]
    }

    // MARK: - 区間の外では置かない

    @Test(
        "区間の外で置くと、1 度注意して何も溜めない",
        arguments: PlacingCall.allCases, PlacingSurface.allCases)
    func refusesOutsideTheRegions(_ call: PlacingCall, _ surface: PlacingSurface) throws {
        let gpu = try RenderDevice()
        let canvas = try surface.make(gpu: gpu)
        let props = try PlacingCall.Props(on: canvas)
        try #require(canvas.hasNothingPending, "道具を作っただけで溜まっている")

        call.call(on: canvas, props)

        #expect(canvas.warnings.message(for: .placingOutsideFrame) == placingNotice)
        #expect(canvas.hasNothingPending, "区間の外の \(call) が溜め場に積んだ")
        #expect(!canvas.isBuildingShape, "区間の外の \(call) が形を開いた")
        #expect(canvas.shapePoints.isEmpty, "区間の外の \(call) が点を積んだ")
        // このフレームの数も動かさない。動かすと、次のフレームの数に足される (#1671 と同じ形)
        #expect(canvas.outlinesAssembledThisFrame == 0, "区間の外の \(call) が周を組んだと数えた")
        #expect(canvas.pointScansThisFrame == 0, "区間の外の \(call) が点を走査したと数えた")
        #expect(canvas.glyphQuadsPlaced == 0, "区間の外の \(call) が字を置いたと数えた")
        // 置いた記録も付けない。#1592 では描き場所を置いた相手の `placers` まで伸びていた
        #expect(canvas.placedGraphics.isEmpty)
        #expect(props.other.placers.isEmpty)
        // 区間の外のことだけを言う。形の外・始まりの無い形の注意は、直す先を指さない
        #expect(!canvas.warnings.hasWarned(.vertexOutsideShape))
        #expect(!canvas.warnings.hasWarned(.shapeNotBegun))

        // 次のフレームの頭の検めも、何も見つけない
        switch surface {
        case .graphics:
            canvas.beginDraw()
            canvas.endDraw()
        case .direct:
            try canvas.draw {}
        }
        #expect(canvas.placementsFoundOutsideRegions == 0)
    }

    @Test("区間の中では今までどおり置き、区間の外の注意を言わない", arguments: PlacingCall.allCases)
    func placesInsideTheRegion(_ call: PlacingCall) throws {
        let canvas = try PlacingSurface.graphics.make(gpu: try RenderDevice())
        let props = try PlacingCall.Props(on: canvas)
        var placed = false
        canvas.beginDraw()
        call.call(on: canvas, props)
        placed = !canvas.hasNothingPending
        canvas.endDraw()

        #expect(placed, "区間の中の \(call) が何も置かなかった")
        #expect(!canvas.warnings.hasWarned(.placingOutsideFrame))
    }

    @Test(
        "持ち越しの区間 (setup() と止まっている間のコールバック) では置け、次のフレームへ持ち越す",
        arguments: PlacingCall.allCases)
    func placesInsideTheCarryOverRegion(_ call: PlacingCall) throws {
        let canvas = try PlacingSurface.direct.make(gpu: try RenderDevice())
        let props = try PlacingCall.Props(on: canvas)
        canvas.carriesOver = true
        call.call(on: canvas, props)
        canvas.carriesOver = false

        #expect(!canvas.hasNothingPending, "持ち越しの区間の \(call) が何も置かなかった")
        #expect(canvas.carriedOverAmount == canvas.pendingAmount)
        #expect(!canvas.warnings.hasWarned(.placingOutsideFrame))
        try canvas.draw {}
        // 持ち越したものは頭の検めに数えない
        #expect(canvas.placementsFoundOutsideRegions == 0)
        #expect(canvas.carriedOverAmount == nil, "印がフレームの頭で下りていない")
    }

    /// 区間で置いたものが溜め場に残ったまま区間を出て、外で同じ口を呼ぶ。**区間で開いた列や
    /// 畳む相手に、外から積み足させない** — 畳む経路は、開いている雛形と同じ形なら周を組まずに
    /// 置き場所を足すだけなので、周の側の守りを通らない。
    @Test("持ち越しの区間で置いた後に、区間の外で続けても積み足さない", arguments: PlacingCall.allCases)
    func doesNotAddToWhatWasCarriedOver(_ call: PlacingCall) throws {
        let canvas = try PlacingSurface.direct.make(gpu: try RenderDevice())
        let props = try PlacingCall.Props(on: canvas)
        canvas.stopsOnPlacementOutsideRegions = false
        canvas.carriesOver = true
        call.call(on: canvas, props)
        canvas.carriesOver = false
        let carried = Self.stored(in: canvas)

        call.call(on: canvas, props)

        // 積み足しも、持ち越したものを捨てることもしない (区間の外の塗り直しは、溜めたものを
        // 捨てる前に断る)
        #expect(Self.stored(in: canvas) == carried, "区間の外の \(call) が溜め場を変えた")
        #expect(canvas.warnings.message(for: .placingOutsideFrame) == placingNotice)
        try canvas.draw {}
        #expect(canvas.placementsFoundOutsideRegions == 0)
    }

    @Test("描き場所に対して、区間の外で形を組み立てられる (#1592 の完了条件 3)")
    func createShapeWorksOutsideBeginDraw() throws {
        let canvas = try PlacingSurface.graphics.make(gpu: try RenderDevice())
        let shape = canvas.createShape {
            canvas.rect(0, 0, 4, 4)
            canvas.beginShape()
            canvas.vertex(0, 0, 1)
            canvas.vertex(4, 0, 1)
            canvas.vertex(0, 4, 1)
            canvas.endShape(.close)
        }
        #expect(!shape.isEmpty)
        #expect(!canvas.warnings.hasWarned(.placingOutsideFrame))
        #expect(canvas.hasNothingPending, "組み立てた形が溜め場に残った")
    }

    /// 塗り直しは形に焼き付かず、面を塗る予定として組み立ての外へ残る。フレームの外の組み立ての
    /// 中で通すと、描き場所の次のフレームを知らない色で塗り、頭の検めがそれを漏れと数える
    /// (#1672 の反証 4)。
    @Test("フレームの外の形の組み立ての中でも、塗り直しは断る", arguments: [false, true])
    func backgroundInsideCreateShapeOutsideIsRefused(surroundings: Bool) throws {
        let canvas = try PlacingSurface.graphics.make(gpu: try RenderDevice())
        canvas.stopsOnPlacementOutsideRegions = false
        _ = canvas.createShape {
            if surroundings {
                canvas.background(.sky)
            } else {
                canvas.background(.linear(red: 1, green: 0, blue: 0))
            }
            canvas.rect(0, 0, 4, 4)
        }
        #expect(canvas.warnings.hasWarned(.placingOutsideFrame))
        #expect(canvas.hasNothingPending, "組み立ての中の塗り直しが、溜め場に残った")
        canvas.beginDraw()
        canvas.endDraw()
        #expect(canvas.placementsFoundOutsideRegions == 0)
    }

    /// 字を置く所で断っても、焼き場へ焼くのはそれより手前である。区間の外で焼き場を作り直すと
    /// そのフレームの番号を覚えるので、次のフレームで溢れても作り直せず字が落ちる (#1672 の
    /// 反証 2 回目の 3)。
    @Test("区間の外の text() は、焼き場へ字を焼かない", arguments: PlacingSurface.allCases)
    func textOutsideTheRegionsBakesNothing(_ surface: PlacingSurface) throws {
        let canvas = try surface.make(gpu: try RenderDevice())
        let baked = canvas.atlas.bakedCount
        canvas.text("abc", 1, 12)
        _ = canvas.text("def ghi", 1, 1, 14, 14)
        #expect(canvas.atlas.bakedCount == baked)
        #expect(canvas.warnings.hasWarned(.placingOutsideFrame))
    }

    /// 描き場所で `beginDraw()` を 1 度だけ書き、`endDraw()` を忘れる。そのフレームは本体の
    /// フレームの境目を越えた時点で区間ではなくなる (次の `beginDraw()` が捨てる・#1622)。置ける
    /// ままにすると、描き切りが来ないまま溜まり続ける (#1592 と同じ形・#1672 の反証 2 回目の 1)。
    @Test("閉じ忘れたまま本体のフレームを越えた描き場所には、置いても溜まらない")
    func aFrameLeftOpenPastTheMainFrameTakesNothing() throws {
        let gpu = try RenderDevice()
        let host = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let layer = try host.createGraphics(16, 16)
        var placedInFirst = 0
        try host.draw {
            layer.beginDraw()
            layer.circle(8, 8, 6)
            placedInFirst = layer.formInstances.count
        }
        for frame in 2...4 {
            try host.draw {
                for _ in 0..<100 { layer.circle(8, 8, 6) }
                host.image(layer, 0, 0)
            }
            #expect(layer.formInstances.count == placedInFirst, "\(frame) 枚目で積み足した")
        }
        #expect(placedInFirst == 1, "同じ本体のフレームの中では置ける")
        #expect(layer.warnings.hasWarned(.placingOutsideFrame))
    }

    @Test("直に使う Canvas で、draw { } の外で置いた円は次の draw { } に出ない")
    func directCanvasDoesNotCarryWhatWasPlacedOutside() throws {
        let canvas = try PlacingSurface.direct.make(gpu: try RenderDevice())
        try canvas.draw { canvas.background(.linear(red: 0, green: 0, blue: 0)) }
        canvas.fill(.linear(red: 1, green: 1, blue: 1))
        canvas.noStroke()
        canvas.circle(8, 8, 12)
        // 塗り直さない — 持ち越していれば、ここで円が出る
        try canvas.draw {}
        #expect(canvas.get(8, 8) == .linear(red: 0, green: 0, blue: 0))
        #expect(canvas.warnings.hasWarned(.placingOutsideFrame))
    }

    // MARK: - 頂点の仲間

    @Test(
        "区間の外では、頂点の仲間も区間の外を言って何もしない",
        arguments: OutsideShapeCall.allCases)
    func shapeCallsSayOutsideTheRegionFirst(_ call: OutsideShapeCall) throws {
        let canvas = try PlacingSurface.graphics.make(gpu: try RenderDevice())
        canvas.beginShape()
        call.call(on: canvas)

        #expect(canvas.warnings.message(for: .placingOutsideFrame) == placingNotice)
        #expect(!canvas.warnings.hasWarned(.vertexOutsideShape), "形の外を先に言った")
        #expect(!canvas.isBuildingShape)
        #expect(canvas.shapePoints.isEmpty)
        #expect(canvas.shapeIndices.isEmpty)
        #expect(canvas.holePoints == nil)
        #expect(canvas.curveGuides.isEmpty)
    }

    /// #1672 の範囲の補足。区間の中で開いた形に、区間を出てから点を足すのも断る — 描き場所
    /// では境目が来ないので、足した点が捨てられないまま溜まる。
    @Test("持ち越しの区間で開いた形に、区間を出てから点を足しても溜まらない")
    func pointsAddedAfterTheRegionDoNotPileUp() throws {
        let canvas = try PlacingSurface.direct.make(gpu: try RenderDevice())
        canvas.carriesOver = true
        canvas.beginShape()
        canvas.vertex(0, 0)
        canvas.carriesOver = false
        for index in 0..<100 { canvas.vertex(Float(index), 1) }
        #expect(canvas.shapePoints.count == 1, "区間の外の vertex() が点を積んだ")
        canvas.endShape()

        #expect(canvas.shapePoints.isEmpty)
        #expect(!canvas.isBuildingShape, "区間の外の endShape() が形を閉じなかった")
        #expect(canvas.hasNothingPending, "区間の外の endShape() が描いた")
        #expect(canvas.warnings.hasWarned(.placingOutsideFrame))
    }

    // MARK: - 画素

    @Test(
        "区間の外で画素を書くと、1 度注意して書かない",
        arguments: PixelWriteCall.allCases, PlacingSurface.allCases)
    func refusesPixelWritesOutsideTheRegions(_ call: PixelWriteCall, _ surface: PlacingSurface)
        throws
    {
        let canvas = try surface.make(gpu: try RenderDevice())
        let before = canvas.get(2, 2)
        call.call(on: canvas)

        #expect(canvas.warnings.message(for: .pixelWriteOutsideFrame) == pixelWriteNotice)
        #expect(canvas.target.pixelMirror?.hasPendingWrites != true, "写しに書いた")
        #expect(canvas.get(2, 2) == before, "読む口 (get) に書いた画素が出た")
        #expect(!canvas.warnings.hasWarned(.placingOutsideFrame), "画素を図形として言った")
    }

    @Test("区間の中では今までどおり書ける", arguments: PixelWriteCall.allCases)
    func writesPixelsInsideTheRegion(_ call: PixelWriteCall) throws {
        let canvas = try PlacingSurface.graphics.make(gpu: try RenderDevice())
        canvas.beginDraw()
        call.call(on: canvas)
        canvas.endDraw()

        #expect(canvas.get(2, 2) == PixelWriteCall.color)
        #expect(!canvas.warnings.hasWarned(.pixelWriteOutsideFrame))
    }

    /// 窓はプロパティに取っておける。**取った時点ではなく、書く時点で区間を見る。**
    @Test("区間の中で取った窓に、区間の外で書いても書かない")
    func aWindowTakenInsideCannotWriteOutside() throws {
        let canvas = try PlacingSurface.graphics.make(gpu: try RenderDevice())
        canvas.beginDraw()
        let window = canvas.pixels
        canvas.endDraw()
        window[2, 2] = PixelWriteCall.color
        window.fill(PixelWriteCall.color)

        #expect(canvas.warnings.hasWarned(.pixelWriteOutsideFrame))
        #expect(canvas.get(2, 2) != PixelWriteCall.color)
    }

    /// 前のフレームで取った窓に、このフレームの区間の中で書く (#1672 の反証 1)。写しは前の
    /// フレームの絵 (効果を通した後) のままなので、書く前に読み直さないと、このフレームの最初の
    /// 描き切りが写し全体を書き戻し、効果が 2 回掛かる (#1655 と同じ形)。
    @Test("前のフレームで取った窓に書いても、効果は 1 回だけ掛かる")
    func aWindowKeptFromAnEarlierFrameWritesOnTheCurrentPicture() throws {
        func secondFrame(writes: Bool) throws -> LinearRGBA {
            let canvas = try PlacingSurface.graphics.make(gpu: try RenderDevice())
            canvas.beginDraw()
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            canvas.rect(0, 0, 8, 16)
            canvas.effects([.invert()])
            canvas.endDraw()
            let window = canvas.pixels
            canvas.beginDraw()
            if writes { window[15, 15] = window[15, 15] }
            canvas.effects([.invert()])
            canvas.endDraw()
            return canvas.get(4, 8)
        }
        // 白い矩形は反転 1 回で黒。写し全体を書き戻すと、2 回掛かって白に戻る
        #expect(try secondFrame(writes: true) == secondFrame(writes: false))
    }

    // MARK: - 鍵が食い合わない (#1592 の完了条件 5)

    @Test("区間の外の注意と endDraw() の書き違いの注意は、互いに黙らせない", arguments: [true, false])
    func placingAndNotDrawingDoNotSilenceEachOther(placingFirst: Bool) throws {
        let canvas = try PlacingSurface.graphics.make(gpu: try RenderDevice())
        func place() { canvas.rect(0, 0, 4, 4) }
        func endWithoutBegin() { canvas.endDraw() }
        if placingFirst {
            place()
            endWithoutBegin()
        } else {
            endWithoutBegin()
            place()
        }
        #expect(canvas.warnings.hasWarned(.placingOutsideFrame))
        #expect(canvas.warnings.hasWarned(.notDrawing))
    }

    @Test("区間の外の注意と形の外の注意は、互いに黙らせない", arguments: [true, false])
    func placingAndVertexOutsideShapeDoNotSilenceEachOther(placingFirst: Bool) throws {
        let canvas = try PlacingSurface.graphics.make(gpu: try RenderDevice())
        func place() { canvas.rect(0, 0, 4, 4) }
        func vertexWithoutShape() {
            canvas.beginDraw()
            canvas.vertex(1, 1)
            canvas.endDraw()
        }
        if placingFirst {
            place()
            vertexWithoutShape()
        } else {
            vertexWithoutShape()
            place()
        }
        #expect(canvas.warnings.hasWarned(.placingOutsideFrame))
        #expect(canvas.warnings.hasWarned(.vertexOutsideShape))
    }

    @Test("区間の外の注意と描き切る前に置いた注意は、互いに黙らせない", arguments: [true, false])
    func placingAndPlacingWhileDrawingDoNotSilenceEachOther(placingFirst: Bool) throws {
        let gpu = try RenderDevice()
        let host = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let layer = try host.createGraphics(8, 8)
        func place() { host.rect(0, 0, 4, 4) }
        func placeUnfinished() throws {
            try host.draw {
                layer.beginDraw()
                host.image(layer, 0, 0)
                layer.endDraw()
            }
        }
        if placingFirst {
            place()
            try placeUnfinished()
        } else {
            try placeUnfinished()
            place()
        }
        #expect(host.warnings.hasWarned(.placingOutsideFrame))
        #expect(host.warnings.hasWarned(.placingWhileDrawing))
    }

    /// フレームの終わりの描き切りは、フレームを閉じた印を下ろしてから列を閉じる。断片に渡した
    /// 描き場所をそこで記録するので、区間の外で記録を飛ばす守りが、描き切りの最中まで飛ばすと
    /// この注意が出なくなる (#1672 の反証 7)。
    @Test("断片に渡した描き切る前の描き場所は、フレームの終わりの描き切りでも注意する")
    func placingWhileDrawingIsToldAtTheLastFlush() throws {
        let gpu = try RenderDevice()
        let host = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let layer = try host.createGraphics(8, 8)
        let shader = try host.makeShader(
            """
            float4 paint(Fragment in, Values values, Surfaces surfaces) {
                return mokume_sample(surfaces.painted, in.place);
            }
            """,
            surfaces: ["painted": .graphics(layer)])
        try host.draw {
            layer.beginDraw()
            host.shader(shader)
            host.rect(0, 0, 16, 16)
        }
        layer.endDraw()
        #expect(host.warnings.hasWarned(.placingWhileDrawing))
    }

    @Test("区間の外の注意と画素の注意は、鍵が分かれている", arguments: [true, false])
    func placingAndPixelWriteDoNotSilenceEachOther(placingFirst: Bool) throws {
        let canvas = try PlacingSurface.graphics.make(gpu: try RenderDevice())
        if placingFirst {
            canvas.rect(0, 0, 4, 4)
            canvas.set(1, 1, PixelWriteCall.color)
        } else {
            canvas.set(1, 1, PixelWriteCall.color)
            canvas.rect(0, 0, 4, 4)
        }
        #expect(canvas.warnings.message(for: .placingOutsideFrame) == placingNotice)
        #expect(canvas.warnings.message(for: .pixelWriteOutsideFrame) == pixelWriteNotice)
    }
}

/// フレームの頭の検め ([#1672])。**合流点の守りを 1 つ書き落としても、ここで拾う。** GPU を要する。
///
/// 検めは debug 組みで止まる (`assertionFailure`)。検査はすべて debug 組みで走るので、全検査を
/// 通して漏れが 0 であることは、検査の全体が確かめている。ここは検め自身が見つけることを、
/// 止まる旗を下ろした面で見る。
///
/// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
@Suite(
    "フレームの頭の検め",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PlacementLeakTests {
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    /// 守りの無い合流点で置いたことにする。その場で並べる立体の頂点は `inSolidBatch` の中で
    /// だけ呼ばれ、自分では区間を見ない — 守りを書き落とした口の代わりになる。
    private func placeWithoutAGuard(on canvas: Canvas) {
        canvas.appendSolidVertex(
            position: .zero, normal: .zero, color: .linear(red: 1, green: 1, blue: 1))
    }

    @Test("区間の外で置いたものが溜め場に残っていれば、フレームの頭で見つけて捨てる")
    func findsWhatNoGuardRefused() throws {
        let canvas = try makeCanvas()
        canvas.stopsOnPlacementOutsideRegions = false
        placeWithoutAGuard(on: canvas)
        try #require(!canvas.hasNothingPending)

        try canvas.draw {
            // 見つけたものは描かずに捨てる (release 組みでも溜めない)
            #expect(canvas.solidVertices.isEmpty)
        }
        #expect(canvas.placementsFoundOutsideRegions == 1)
    }

    @Test("持ち越しの区間で置いたものは、見つけたことにしない")
    func carriedPlacementsAreNotFound() throws {
        let canvas = try makeCanvas()
        canvas.stopsOnPlacementOutsideRegions = false
        canvas.carriesOver = true
        placeWithoutAGuard(on: canvas)
        canvas.carriesOver = false

        var carried = 0
        try canvas.draw { carried = canvas.solidVertices.count }
        #expect(carried == 1, "持ち越しの区間で置いたものが最初のフレームに届かない")
        #expect(canvas.placementsFoundOutsideRegions == 0)
    }

    /// `setup()` で本体の面の `draw { }` を呼ぶと、持ち越しの区間の中でフレームが開く (#1672 の
    /// 反証 5)。区間はまだ閉じていないので量は覚えていないが、溜まっているものは区間の中で
    /// 置いたものである。
    @Test("持ち越しの区間の中で開いたフレームは、区間で置いたものを見つけたことにしない")
    func aFrameOpenedInsideTheRegionKeepsWhatWasPlaced() throws {
        let canvas = try makeCanvas()
        canvas.stopsOnPlacementOutsideRegions = false
        canvas.carriesOver = true
        canvas.background(.linear(red: 1, green: 0, blue: 0))
        try canvas.draw {}
        canvas.carriesOver = false
        #expect(canvas.placementsFoundOutsideRegions == 0)
        #expect(canvas.get(8, 8) == .linear(red: 1, green: 0, blue: 0), "区間で置いた塗り直しが出ない")
    }

    /// 印は有無ではなく量である。区間で置いた後に、区間の外で守りの無い口から積み足したものも
    /// 見つける。
    @Test("持ち越しの区間の後に、区間の外で積み足したものは見つける")
    func findsWhatWasAddedAfterTheRegion() throws {
        let canvas = try makeCanvas()
        canvas.stopsOnPlacementOutsideRegions = false
        canvas.carriesOver = true
        placeWithoutAGuard(on: canvas)
        canvas.carriesOver = false
        // 列を閉じるだけの操作は、積み足しに数えない
        canvas.blendMode(.add)
        try canvas.draw {}
        #expect(canvas.placementsFoundOutsideRegions == 0, "列を閉じただけで漏れと数えた")

        canvas.carriesOver = true
        placeWithoutAGuard(on: canvas)
        canvas.carriesOver = false
        placeWithoutAGuard(on: canvas)
        try canvas.draw {}
        #expect(canvas.placementsFoundOutsideRegions == 1)
    }

    /// 印は区間の出口で付き、フレームの頭で下りる。**下りないと、次に区間の外で漏れたものを
    /// 持ち越しと取り違える。**
    @Test("持ち越しの印は 1 フレームで下り、その後の漏れは見つける")
    func theCarryOverMarkLastsOneFrame() throws {
        let canvas = try makeCanvas()
        canvas.stopsOnPlacementOutsideRegions = false
        canvas.carriesOver = true
        placeWithoutAGuard(on: canvas)
        canvas.carriesOver = false
        try canvas.draw {}

        placeWithoutAGuard(on: canvas)
        try canvas.draw {}
        #expect(canvas.placementsFoundOutsideRegions == 1)
    }

    /// 置き漏れは mokume の不具合なので、利用者の作品 (debug 組みを含む) は止めず、捨てて名乗る
    /// ([#1682])。止まるのは mokume の検査の中だけで、ここでは旗を下ろして作品の中を模す。
    ///
    /// [#1682]: https://github.com/mokume-metal/mokume/issues/1682
    @Test("検査の外では止まらず、漏れたものを捨てて 1 度だけ原文のまま名乗る")
    func outsideTheTestsItDropsAndSaysSoOnce() throws {
        let canvas = try makeCanvas()
        canvas.stopsOnPlacementOutsideRegions = false
        placeWithoutAGuard(on: canvas)
        try canvas.draw { #expect(canvas.solidVertices.isEmpty) }
        #expect(canvas.warnings.message(for: .placementLeak) == Self.placementLeakNotice)

        placeWithoutAGuard(on: canvas)
        try canvas.draw {}
        #expect(canvas.placementsFoundOutsideRegions == 2)
        #expect(canvas.warnings.message(for: .placementLeak) == Self.placementLeakNotice)
    }

    /// 検査の中では、旗は既定で立っている。**下りていると、全検査を通す網が働かない** — 守りを
    /// 書き落とした口があっても、注意が出るだけで検査は緑のままになる。
    @Test("mokume の検査の中では、置き漏れで止まる旗が既定で立っている")
    func insideTheTestsItStopsByDefault() throws {
        #expect(try makeCanvas().stopsOnPlacementOutsideRegions)
    }

    /// 原文の写し。組み立てた文は壊れても気付けない (#947) ので、写しと突き合わせる。
    static let placementLeakNotice =
        "Something was placed outside a frame through a path that mokume does not guard, so it "
        + "was dropped without being drawn. This is most likely a fault inside mokume — please "
        + "report it with this message at https://github.com/mokume-metal/mokume/issues (#1672)"
}

/// 本体の約束は変わらない、と #1654・#1655 の再現 ([#1672])。ランタイムを通す。GPU を要する。
///
/// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
@Suite(
    "持ち越しの区間 (ランタイム)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CarryOverRegionTests {
    /// `setup()` だけで 1 枚を描く。Processing の Examples を移した 157 本のうち 16 本がこの
    /// 書き方で、`setup()` で描くものは 40 本ある (#1603 の実測)。
    final class DrawnInSetup: Sketch {
        var settings = SketchSettings(width: 16, height: 16)
        init() {}
        func setup() {
            background(0, 0, 0)
            noStroke()
            fill(255, 0, 0)
            rect(0, 0, 8, 16)
        }
    }

    @Test("setup() だけで描いた 1 枚が、最初のフレームに出る")
    func whatSetupDrawsShowsInTheFirstFrame() throws {
        let runtime = try SketchRuntime(sketch: DrawnInSetup(), gpu: try RenderDevice())
        defer { runtime.closePlugins() }
        try runtime.advance()

        let image = try runtime.target.encodeForDisplay()
        #expect(image[4, 8].red > 200)
        #expect(image[12, 8] == (0, 0, 0, 255))
        #expect(!runtime.canvas.warnings.hasWarned(.placingOutsideFrame))
        #expect(!runtime.canvas.carriesOver, "setup() を抜けても区間の印が立ったまま")
    }

    /// #1654 の再現。`setup()` で、`beginDraw()` で囲まずに描き場所へ `set()` する。
    final class GraphicsSetInSetup: Sketch {
        var settings = SketchSettings(width: 16, height: 16)
        let wrapped: Bool
        var layer: Canvas!
        init(wrapped: Bool) { self.wrapped = wrapped }
        convenience init() { self.init(wrapped: false) }
        func setup() {
            layer = try! createGraphics(16, 16)
            if wrapped { layer.beginDraw() }
            for y in 0..<16 {
                for x in 0..<8 { layer.set(x, y, color(255, 0, 0)) }
            }
            if wrapped { layer.endDraw() }
        }
        func draw() {
            background(0)
            image(layer, 0, 0)
        }
    }

    @Test("描き場所に囲まずに書いた画素は、get() でも image() でも見えない (#1654)", arguments: [false, true])
    func graphicsSetOutsideIsSeenTheSameWayByEveryReader(wrapped: Bool) throws {
        let scene = GraphicsSetInSetup(wrapped: wrapped)
        let runtime = try SketchRuntime(sketch: scene, gpu: try RenderDevice())
        defer { runtime.closePlugins() }
        try runtime.advance()

        let shown = try runtime.target.readPixels()[4, 8].red
        let read = scene.layer.get(4, 8).red
        // 読む口と置く口が同じ絵を見る。直す前は get が 0.82・image が 0 だった
        #expect(abs(shown - read) < 0.004)
        if wrapped {
            #expect(read > 0.8)
            #expect(!scene.layer.warnings.hasWarned(.pixelWriteOutsideFrame))
        } else {
            #expect(read < 0.004)
            #expect(scene.layer.warnings.hasWarned(.pixelWriteOutsideFrame))
        }
    }

    /// #1655 の再現。効果を掛けた描き場所に、`endDraw()` の後で 1 画素を値を変えずに書き戻す。
    final class EffectsWriteBack: Sketch {
        var settings = SketchSettings(width: 16, height: 16)
        let writesBack: Bool
        var layer: Canvas!
        init(writesBack: Bool) { self.writesBack = writesBack }
        convenience init() { self.init(writesBack: false) }
        func setup() { layer = try! createGraphics(16, 16) }
        func draw() {
            layer.beginDraw()
            if frameCount == 1 {
                layer.background(0)
                layer.noStroke()
                layer.fill(255)
                layer.rect(0, 0, 8, 16)
            }
            layer.effects([.invert()])
            layer.endDraw()
            if frameCount == 1 && writesBack { layer.set(15, 15, layer.get(15, 15)) }
            background(0)
            image(layer, 0, 0)
        }
    }

    @Test("効果を掛けた描き場所にフレームの外で書き戻しても、効果は 1 回だけ掛かる (#1655)")
    func effectsApplyOnceAfterAWriteOutsideTheFrame() throws {
        func secondFrame(writesBack: Bool) throws -> (DisplayImage, EffectsWriteBack) {
            let scene = EffectsWriteBack(writesBack: writesBack)
            let runtime = try SketchRuntime(sketch: scene, gpu: try RenderDevice())
            defer { runtime.closePlugins() }
            try runtime.advance()
            try runtime.advance()
            return (try runtime.target.encodeForDisplay(), scene)
        }
        let (written, scene) = try secondFrame(writesBack: true)
        let (untouched, _) = try secondFrame(writesBack: false)

        // 白い矩形は反転 1 回で黒。直す前は 2 回掛かって白に戻った
        #expect(written[4, 8] == (0, 0, 0, 255))
        #expect(written.bytes == untouched.bytes)
        #expect(scene.layer.warnings.hasWarned(.pixelWriteOutsideFrame))
    }
}
