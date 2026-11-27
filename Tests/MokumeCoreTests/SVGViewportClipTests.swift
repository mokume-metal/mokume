// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 読み込んだ SVG の入れ子の `<svg>` を、表示枠で切り抜いて描く (#2879)。GPU を要する。
///
/// 判定は透明地の alpha で行う。どの入れ子が切り抜きを持つかの読み解きは `SVGNestedViewportTests` が見る。
@Suite(
    "入れ子の svg の表示枠の切り抜きの絵",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SVGViewportClipTests {
    private static let width = 240
    private static let height = 160

    /// #2879 の最小例: 表示枠 x=40, y=40, width=80, height=60 の入れ子の `<svg>` に、枠から 20 ずつはみ出す白い矩形。
    static let minimal =
        "<svg x='40' y='40' width='80' height='60' viewBox='0 0 80 60'>"
        + "<rect x='-20' y='-20' width='120' height='100' fill='white'/></svg>"

    private func drawing(_ body: String) throws -> SVGFile.Drawing {
        try SVGFile.parse(
            "<svg xmlns='http://www.w3.org/2000/svg' width='\(Self.width)' height='\(Self.height)'>\(body)</svg>",
            path: "panel.svg")
    }

    /// 透明地に、`body` を読んだ形を `place` で置いた絵。
    private func rendered(
        _ body: String = minimal, place: (Canvas, Shape) -> Void = { $0.shape($1) }
    ) throws -> (DisplayImage, Canvas) {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: Self.width, height: Self.height)
        let canvas = try Canvas(target: target, gpu: gpu)
        let read = try drawing(body)
        try canvas.draw {
            let shape = canvas.shape(of: read, readFrom: "panel.svg")
            place(canvas, shape)
        }
        return (try canvas.output.encodeForDisplay(), canvas)
    }

    private func alpha(_ image: DisplayImage, _ x: Int, _ y: Int) -> Int { Int(image[x, y].alpha) }

    // MARK: - 完了条件 1: 最小例

    @Test("最小例: 枠の中 (45,45) は 255、枠の外 (30,30)・(130,80) は 0 (変更前は 255)")
    func minimalExampleIsClipped() throws {
        let (image, canvas) = try rendered()
        #expect(alpha(image, 45, 45) == 255)
        #expect(alpha(image, 30, 30) == 0, "\(image[30, 30])")
        #expect(alpha(image, 130, 80) == 0, "\(image[130, 80])")
        #expect(alpha(image, 119, 99) == 255, "枠の右下の内側")
        #expect(alpha(image, 120, 100) == 0, "枠の右下の外側")
        #expect(!canvas.warnings.hasWarned(.viewportClipTooDeep))
    }

    @Test("置いた後に描くものは切らない (表示枠は区間を置く間だけ当たる)")
    func laterDrawingIsNotClipped() throws {
        let (image, _) = try rendered { canvas, shape in
            canvas.shape(shape)
            canvas.noStroke()
            canvas.fill(255)
            canvas.rect(25, 25, 10, 10)
        }
        #expect(alpha(image, 30, 30) == 255)
        #expect(alpha(image, 130, 80) == 0)
    }

    // MARK: - 完了条件 2: 置く変換に追従する

    @Test("shape(logo, 50, 0): (95,45) は 255、(80,45) と (175,80) は 0")
    func movedPlacementMovesTheClip() throws {
        let (image, _) = try rendered { canvas, shape in canvas.shape(shape, 50, 0) }
        #expect(alpha(image, 95, 45) == 255)
        #expect(alpha(image, 80, 45) == 0, "\(image[80, 45])")
        #expect(alpha(image, 175, 80) == 0, "\(image[175, 80])")
    }

    @Test("回して置いた形は、写した表示枠の 4 隅の内側だけに色が載る")
    func rotatedPlacementClipsToTheRotatedViewport() throws {
        // 形の座標の点 p は (120, 80) + R(30°)(p - (80, 70)) に置かれる
        let (image, _) = try rendered { canvas, shape in
            canvas.translate(120, 80)
            canvas.rotate(Float.pi / 6)
            canvas.translate(-80, -70)
            canvas.shape(shape)
        }
        #expect(alpha(image, 120, 80) == 255, "表示枠の中心 (80, 70)")
        #expect(alpha(image, 137, 119) == 255, "表示枠の中 (115, 95)")
        #expect(alpha(image, 96, 20) == 0, "矩形の中で表示枠の外 (30, 30): \(image[96, 20])")
        #expect(alpha(image, 153, 122) == 0, "矩形の中で表示枠の外 (130, 90): \(image[153, 122])")
    }

    @Test("shape(_:at:) で 2 か所に置くと、それぞれの置き場所の表示枠で切れる")
    func eachPlacementHasItsOwnViewport() throws {
        let (image, _) = try rendered { canvas, shape in
            canvas.shape(shape, at: [Placement(), Placement(x: 100, y: 50)])
        }
        #expect(alpha(image, 45, 45) == 255, "1 つ目の枠の中")
        #expect(alpha(image, 30, 30) == 0, "1 つ目の枠の外")
        #expect(alpha(image, 145, 95) == 255, "2 つ目の枠の中")
        #expect(alpha(image, 130, 80) == 0, "2 つ目の矩形の中で、どちらの枠の外: \(image[130, 80])")
        #expect(alpha(image, 230, 155) == 0, "2 つ目の枠の外: \(image[230, 155])")
    }

    @Test("形の組み立ての中で置いた形は、外側の形を置くときに、両方の置く変換で写した表示枠で切れる")
    func clipsCarryThroughANestedAssembly() throws {
        let (image, _) = try rendered { canvas, shape in
            let outer = canvas.createShape {
                canvas.shape(shape, 50, 0)
                // 中で置いた形の後に記録したものは切らない
                canvas.noStroke()
                canvas.fill(255)
                canvas.rect(0, 0, 10, 10)
            }
            #expect(outer.runs.contains { !$0.viewportClips.isEmpty })
            #expect(outer.runs.last?.viewportClips.isEmpty == true, "後に記録した矩形の区間は表示枠を持たない")
            canvas.shape(outer, 0, 20)
        }
        #expect(alpha(image, 95, 65) == 255)
        #expect(alpha(image, 80, 65) == 0, "\(image[80, 65])")
        #expect(alpha(image, 175, 100) == 0, "\(image[175, 100])")
        #expect(alpha(image, 5, 25) == 255, "組み立ての中で後に描いた矩形")
    }

    @Test("組にした形 (+) も、区間ごとの表示枠を持ち続ける。表示枠の無い形の区間とは畳まない")
    func groupedShapesKeepTheirClips() throws {
        let (image, _) = try rendered { canvas, shape in
            let square = canvas.createShape {
                canvas.noStroke()
                canvas.fill(255)
                canvas.rect(0, 0, 10, 10)
            }
            canvas.shape(square + shape)
        }
        #expect(alpha(image, 5, 5) == 255)
        #expect(alpha(image, 45, 45) == 255)
        #expect(alpha(image, 30, 30) == 0, "\(image[30, 30])")
    }

    // MARK: - 完了条件 3: 切り抜きと交わる

    @Test("clip(0, 0, 60, 160) の後: (45,45) は 255、(70,50) は 0 (表示枠の中だが clip の外)")
    func intersectsTheRectangleClip() throws {
        let (image, _) = try rendered { canvas, shape in
            canvas.clip(0, 0, 60, 160)
            canvas.shape(shape)
        }
        #expect(alpha(image, 45, 45) == 255)
        #expect(alpha(image, 70, 50) == 0, "\(image[70, 50])")
        #expect(alpha(image, 30, 30) == 0, "clip の中だが表示枠の外")
    }

    @Test("回した clip() と clip { } の中で置いても交わる")
    func intersectsTheShapeClips() throws {
        let (shaped, _) = try rendered { canvas, shape in
            canvas.clip { canvas.rect(0, 0, 60, 160) }
            canvas.shape(shape)
        }
        #expect(alpha(shaped, 45, 45) == 255)
        #expect(alpha(shaped, 70, 50) == 0, "\(shaped[70, 50])")
        #expect(alpha(shaped, 30, 30) == 0)
        // 回した矩形の clip() は型板の段で切る。表示枠の段はその子として積む
        let (rotated, _) = try rendered { canvas, shape in
            canvas.pushMatrix()
            canvas.rotate(0.01)
            canvas.clip(0, 0, 60, 160)
            canvas.popMatrix()
            canvas.shape(shape)
        }
        #expect(alpha(rotated, 45, 45) == 255)
        #expect(alpha(rotated, 70, 50) == 0, "\(rotated[70, 50])")
        #expect(alpha(rotated, 30, 30) == 0)
    }

    @Test("入れ子の svg の中の入れ子は、両方の表示枠の交わりで切れる")
    func nestedViewportsIntersect() throws {
        // 外側の枠はファイルの (40…120, 40…100)、内側の枠は (80…160, 30…110)。交わりは (80…120, 40…100)
        let body =
            "<svg x='40' y='40' width='80' height='60'><svg x='40' y='-10' width='80' height='80'>"
            + "<rect x='-100' y='-100' width='400' height='400' fill='white'/></svg></svg>"
        #expect(try drawing(body).viewportClips.count == 2)
        let (image, _) = try rendered(body)
        #expect(alpha(image, 100, 70) == 255)
        #expect(alpha(image, 60, 70) == 0, "外側の中で内側の外: \(image[60, 70])")
        #expect(alpha(image, 140, 70) == 0, "内側の中で外側の外: \(image[140, 70])")
        #expect(alpha(image, 100, 35) == 0, "内側の中で外側の外: \(image[100, 35])")
    }

    @Test("表示枠の中の半透明の群 (合成の単位) も切る。重なりは 1 度だけ薄くなる")
    func compositeUnitsInsideTheViewport() throws {
        let body =
            "<svg x='40' y='40' width='80' height='60'><g opacity='0.5'>"
            + "<rect x='-20' y='-20' width='120' height='100' fill='white'/>"
            + "<rect x='0' y='0' width='40' height='40' fill='white'/></g></svg>"
        let (image, canvas) = try rendered(body)
        #expect(alpha(image, 30, 30) == 0, "\(image[30, 30])")
        #expect(abs(alpha(image, 45, 45) - 128) <= 1, "重なり: \(image[45, 45])")
        #expect(abs(alpha(image, 100, 80) - 128) <= 1, "\(image[100, 80])")
        #expect(canvas.warnings.message(for: .compositeGroupPerShape) == nil, "単位にできた")
    }

    // MARK: - 完了条件 4: overflow の値

    @Test("overflow が visible・auto の入れ子は切らない", arguments: ["visible", "auto"])
    func visibleOverflowIsNotClipped(value: String) throws {
        let (image, _) = try rendered(Self.minimal.replacingOccurrences(of: "<svg ", with: "<svg overflow='\(value)' "))
        #expect(alpha(image, 30, 30) == 255)
        #expect(alpha(image, 130, 80) == 255)
    }

    @Test("overflow が hidden・scroll・clip の入れ子は切る", arguments: ["hidden", "scroll", "clip"])
    func clippingOverflowIsClipped(value: String) throws {
        let (image, _) = try rendered(Self.minimal.replacingOccurrences(of: "<svg ", with: "<svg overflow='\(value)' "))
        #expect(alpha(image, 45, 45) == 255)
        #expect(alpha(image, 30, 30) == 0)
    }

    @Test("根の svg は切らない (形は枠の無い図形として置く)")
    func theRootIsNotClipped() throws {
        let (image, _) = try rendered("<rect x='-20' y='-20' width='400' height='300' fill='white'/>") { canvas, shape in
            canvas.shape(shape, 10, 10)
        }
        #expect(alpha(image, 235, 155) == 255, "根の枠 (240×160) を 10 ずらした外")
    }

    // MARK: - 完了条件 5: 上限を越えたとき

    @Test("型板の段が上限に達していたら、1 度知らせて、越えた表示枠は切らずに描く")
    func depthLimitDrawsUnclippedAndWarns() throws {
        let (image, canvas) = try rendered { canvas, shape in
            canvas.noStroke()
            canvas.fill(255)
            for _ in 0..<Canvas.clipDepthLimit { canvas.clip { canvas.rect(0, 0, 240, 160) } }
            canvas.shape(shape)
            canvas.shape(shape, 50, 0)
        }
        #expect(canvas.warnings.hasWarned(.viewportClipTooDeep))
        #expect(alpha(image, 30, 30) == 255, "切らずに描く (黙って消さない)")
        #expect(alpha(image, 45, 45) == 255)
    }

    @Test("上限の 1 段手前なら表示枠を積めて、切れる")
    func oneBelowTheLimitStillClips() throws {
        let (image, canvas) = try rendered { canvas, shape in
            canvas.noStroke()
            canvas.fill(255)
            for _ in 0..<(Canvas.clipDepthLimit - 1) { canvas.clip { canvas.rect(0, 0, 240, 160) } }
            canvas.shape(shape)
        }
        #expect(!canvas.warnings.hasWarned(.viewportClipTooDeep))
        #expect(alpha(image, 45, 45) == 255)
        #expect(alpha(image, 30, 30) == 0)
    }

    // MARK: - 完了条件 6: 入れ子の svg を持たない SVG は変わらない

    @Test("枠に収まる入れ子と入れ子の無い SVG は、表示枠を持たず、描く回数も変わらない")
    func fittingContentKeepsTheDrawCount() throws {
        let nested = "<svg x='40' y='40' width='80' height='60'><rect x='10' y='10' width='60' height='40' fill='white'/></svg>"
        let flat = "<rect x='50' y='50' width='60' height='40' fill='white'/>"
        #expect(try drawing(nested).viewportClips.isEmpty)
        #expect(try drawing(flat).viewportClips.isEmpty)
        var shapes: [Shape] = []
        let (nestedImage, nestedCanvas) = try rendered(nested) { canvas, shape in
            shapes.append(shape)
            canvas.shape(shape, at: [Placement(), Placement(x: 100)])
        }
        let (flatImage, flatCanvas) = try rendered(flat) { canvas, shape in
            canvas.shape(shape, at: [Placement(), Placement(x: 100)])
        }
        #expect(shapes.first?.hasViewportClips == false)
        #expect(nestedCanvas.drawCallsInLastFrame == flatCanvas.drawCallsInLastFrame)
        #expect(alpha(nestedImage, 60, 60) == 255 && alpha(flatImage, 60, 60) == 255)
    }

    // MARK: - 視点を通る置き

    /// 最小例を `overflow='visible'` にしたもの (切らない入れ子)。
    private static let unclipped = minimal.replacingOccurrences(of: "<svg ", with: "<svg overflow='visible' ")

    /// 視点を通る置き方。どれも、表示枠を面の上の範囲で当てると形とずれる。
    enum ThroughView: String, CaseIterable {
        /// 奥行きのある変換。
        case depth
        /// 既定と違う視点 (x へ 40 ずらして正面から見る)。
        case camera
        /// 既定と違う投影 (画角を広げる)。
        case perspective

        func apply(to canvas: Canvas) {
            switch self {
            case .depth:
                canvas.translate(0, 0, -100)
            case .camera:
                let fitting = canvas.defaultCamera
                let shift = Vector3(40, 0, 0)
                canvas.camera(eye: fitting.eye + shift, center: fitting.center + shift, up: fitting.up)
            case .perspective:
                canvas.perspective(Float.pi / 2, Float(SVGViewportClipTests.width) / Float(SVGViewportClipTests.height), 1, 2000)
            }
        }
    }

    @Test("視点を通る置きでは表示枠で切らず、overflow='visible' の入れ子と同じ絵で描いて 1 度知らせる", arguments: ThroughView.allCases)
    func throughViewDrawsUnclippedAndWarns(view: ThroughView) throws {
        let place: (Canvas, Shape) -> Void = { canvas, shape in
            view.apply(to: canvas)
            canvas.shape(shape)
            canvas.shape(shape, 10, 0)
        }
        let (clipped, canvas) = try rendered(place: place)
        let (visible, _) = try rendered(Self.unclipped, place: place)
        #expect(clipped == visible, "表示枠で切った分が欠けている (枠と形がずれて切れている)")
        #expect(canvas.warnings.hasWarned(.viewportClipThroughView))
        #expect(canvas.warnings.message(for: .viewportClipThroughView)?.hasPrefix("shape():") == true)
        #expect(!canvas.warnings.hasWarned(.viewportClipTooDeep))
    }

    @Test("視点を既定へ戻して置けば、また表示枠で切る (判定は置き場所ごと)")
    func plainViewAfterACameraClipsAgain() throws {
        let (image, canvas) = try rendered { canvas, shape in
            ThroughView.camera.apply(to: canvas)
            canvas.camera()
            canvas.shape(shape)
        }
        #expect(!canvas.warnings.hasWarned(.viewportClipThroughView))
        #expect(alpha(image, 45, 45) == 255)
        #expect(alpha(image, 30, 30) == 0, "\(image[30, 30])")
    }

    // MARK: - 描く回数

    @Test("はみ出す形を N か所に置くと、置き場所ごとに 1 回描き、型板の段も置き場所ごとに積み替える", arguments: [1, 2, 5])
    func drawCountGrowsPerPlacement(count: Int) throws {
        let placements = (0..<count).map { Placement(x: Float($0) * 10, y: 0) }
        let (_, canvas) = try rendered { canvas, shape in
            #expect(shape.drawCallCount == 1, "前提: 区間は 1 つ")
            canvas.shape(shape, at: placements)
        }
        // 区間が 1 つの形でも、置き場所ごとに写した表示枠で切るので、置き場所の数だけ描く
        #expect(canvas.drawCallsInLastFrame == count)
        // 型板は、最初の置き場所で 1 段積み、続く置き場所では前の段を外して積む (1 + 2 × (N - 1))。最後の段は残る
        #expect(canvas.drawsEncodedInLastFrame == count + 1 + 2 * (count - 1))
    }

    // MARK: - 型板を共にするもの

    @Test("表示枠の中の半透明の線は、部分パスどうしの交わりでも 1 度だけ混ぜ、枠の外は描かない")
    func translucentStrokeInsideTheViewport() throws {
        // 2 本の部分パスは入れ子の座標 (40, 30)、ファイルの (80, 70) で交わる
        let body =
            "<svg x='40' y='40' width='80' height='60'>"
            + "<path d='M-20 -20 L100 80 M100 -20 L-20 80' stroke='white' stroke-opacity='0.5' stroke-width='6'"
            + " fill='none'/></svg>"
        #expect(try drawing(body).viewportClips.count == 1)
        let (image, _) = try rendered(body)
        #expect(abs(alpha(image, 80, 70) - 128) <= 1, "交わり: \(image[80, 70])")
        #expect(abs(alpha(image, 50, 45) - 128) <= 1, "1 本だけの所: \(image[50, 45])")
        #expect(alpha(image, 30, 28) == 0, "枠の外の線: \(image[30, 28])")
    }

    @Test("入れ子 2 枠で、2 枠目だけが段の上限を越えるなら、1 枠目では切り、2 枠目では切らずに知らせる")
    func onlyTheInnerViewportExceedsTheLimit() throws {
        // 外側の枠はファイルの (40…120, 40…100)、内側の枠は (80…160, 30…110)
        let body =
            "<svg x='40' y='40' width='80' height='60'><svg x='40' y='-10' width='80' height='80'>"
            + "<rect x='-100' y='-100' width='400' height='400' fill='white'/></svg></svg>"
        let (image, canvas) = try rendered(body) { canvas, shape in
            canvas.noStroke()
            canvas.fill(255)
            for _ in 0..<(Canvas.clipDepthLimit - 1) { canvas.clip { canvas.rect(0, 0, 240, 160) } }
            canvas.shape(shape)
        }
        #expect(canvas.warnings.hasWarned(.viewportClipTooDeep))
        #expect(alpha(image, 100, 70) == 255)
        #expect(alpha(image, 60, 70) == 255, "外側の中で内側の外 (内側は切らない): \(image[60, 70])")
        #expect(alpha(image, 140, 70) == 0, "外側の外 (外側は切る): \(image[140, 70])")
        #expect(alpha(image, 100, 35) == 0, "外側の外: \(image[100, 35])")
    }

    @Test("入れ子の svg を囲む <g opacity> も、表示枠で切った中身を 1 枚にまとめて 1 度だけ薄くする")
    func groupOpacityAroundTheNestedSVG() throws {
        let body =
            "<g opacity='0.5'><svg x='40' y='40' width='80' height='60'>"
            + "<rect x='-20' y='-20' width='120' height='100' fill='white'/>"
            + "<rect x='0' y='0' width='40' height='40' fill='white'/></svg></g>"
        let read = try drawing(body)
        #expect(read.units.count == 1 && read.viewportClips.count == 1, "前提: 群が単位で、入れ子が表示枠を持つ")
        let (image, canvas) = try rendered(body)
        #expect(alpha(image, 30, 30) == 0, "\(image[30, 30])")
        #expect(alpha(image, 130, 110) == 0, "\(image[130, 110])")
        #expect(abs(alpha(image, 45, 45) - 128) <= 1, "重なり: \(image[45, 45])")
        #expect(abs(alpha(image, 100, 80) - 128) <= 1, "\(image[100, 80])")
        #expect(canvas.warnings.message(for: .compositeGroupPerShape) == nil, "単位にできた")
    }

    // MARK: - 画素の細かさ

    /// 座標の大きさ 240×160 の面を、細かさ `density`・出力の倍率 `scale` で作り、最小例を置いた絵。
    private func renderedScaled(density: Float = 1, scale: Int = 1) throws -> PixelBuffer {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: Self.width * scale, height: Self.height * scale)
        let canvas = try Canvas(output: output, gpu: gpu, pixelDensity: density, upscale: .spatial, outputScale: scale)
        let read = try drawing(Self.minimal)
        try canvas.draw { canvas.shape(canvas.shape(of: read, readFrom: "panel.svg")) }
        return try canvas.output.readPixels()
    }

    @Test("出力の倍率 2 では、表示枠は座標で読まれ、倍率を掛けた画素 (80…239・80…199) を通す")
    func outputScaleTwoClipsAtTheScaledPixels() throws {
        let pixels = try renderedScaled(scale: 2)
        func drawn(_ x: Int, _ y: Int) -> Bool { pixels[x, y].alpha > 0.99 }
        func empty(_ x: Int, _ y: Int) -> Bool { pixels[x, y].alpha < 0.01 }
        #expect(drawn(80, 80) && drawn(239, 199), "枠の内側の縁: \(pixels[80, 80]) \(pixels[239, 199])")
        #expect(empty(79, 120) && empty(120, 79), "枠の左・上の外: \(pixels[79, 120]) \(pixels[120, 79])")
        #expect(empty(240, 120) && empty(120, 200), "枠の右・下の外: \(pixels[240, 120]) \(pixels[120, 200])")
        #expect(empty(60, 60), "矩形の中で枠の外: \(pixels[60, 60])")
    }

    @Test("細かさ 0.5 でも、枠の中は描き、枠の外は描かない")
    func halfDensityClips() throws {
        let pixels = try renderedScaled(density: 0.5)
        #expect(pixels[80, 70].alpha > 0.99, "枠の中: \(pixels[80, 70])")
        #expect(pixels[25, 25].alpha < 0.01, "矩形の中で枠の外: \(pixels[25, 25])")
        #expect(pixels[130, 110].alpha < 0.01, "矩形の中で枠の外: \(pixels[130, 110])")
    }
}
