// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing

@testable import MokumeCore

/// 合成の単位の中間面をフレームをまたいで使い回す (#4029)。GPU を要する。
///
/// 約束は 3 つ — 絵は 1 ビットも変わらない (毎回作る面で描いた絵と同じ)・同じ大きさの面は次のフレームで
/// 作り直さない・持つ面はスケッチに 1 つの置き場が数え、合計は上限まで・持ち主のフレームを 1 つ使われずに
/// 過ぎたら手放す。絵は、使い回す面で何フレームか描いた後の読み出しを、そのフレームだけを作りたての面
/// (作りたての中間面) で描いた読み出しとビット列で比べる。
@Suite(
    "合成の単位の中間面の使い回し",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CompositeSurfacePoolTests {
    /// #2878 の群の例: `opacity='0.5'` の群の中に重なる白い矩形 2 つ (外接 20…170 × 20…140)。
    private static let group = SVGCompositeGroupTests.group
    /// 入れ子の単位 (群の中の群) と、塗りと線を両方持つ半透明の要素。
    private static let nested =
        "<g opacity='0.5'>\(group)</g>"
        + "<rect x='30' y='30' width='120' height='90' fill='white' stroke='white' stroke-width='20' opacity='0.5'/>"

    private let gpu: RenderDevice

    init() throws {
        gpu = try RenderDevice()
    }

    private func makeCanvas(width: Int = 360, height: Int = 240, outputScale: Int = 1) throws -> Canvas {
        let target = try RenderTarget(gpu: gpu, width: width * outputScale, height: height * outputScale)
        return try Canvas(
            output: target, gpu: gpu, pixelDensity: 1, upscale: .spatial, outputScale: outputScale)
    }

    private func logo(_ body: String = Self.group, on canvas: Canvas) throws -> Shape {
        let read = try SVGFile.parse(
            "<svg xmlns='http://www.w3.org/2000/svg' width='240' height='160'>\(body)</svg>",
            path: "pool.svg")
        var shape: Shape?
        try canvas.draw { shape = canvas.shape(of: read, readFrom: "pool.svg") }
        return try #require(shape)
    }

    /// 同じ canvas で `frames` を順に描き、フレームごとの読み出しを返す。
    private func render(
        _ frames: [(Canvas, Shape) -> Void], body: String = Self.group, on canvas: Canvas,
        afterEachFrame: (Int) -> Void = { _ in }
    ) throws -> [PixelBuffer] {
        let shape = try logo(body, on: canvas)
        var pictures: [PixelBuffer] = []
        for (index, frame) in frames.enumerated() {
            try canvas.draw {
                canvas.background(10, 20, 30)
                frame(canvas, shape)
            }
            afterEachFrame(index)
            pictures.append(try canvas.output.readPixels())
        }
        return pictures
    }

    /// `frames` をそれぞれ作りたての canvas で 1 フレームだけ描いた読み出し (中間面も作りたて)。
    private func freshPictures(
        _ frames: [(Canvas, Shape) -> Void], body: String = Self.group, outputScale: Int = 1,
        failing failure: RenderFailure? = nil
    ) throws -> [PixelBuffer] {
        try frames.map { frame in
            let canvas = try makeCanvas(outputScale: outputScale)
            canvas.compositeSurfaces.failSurfacesForTesting = failure
            let picture = try render([frame], body: body, on: canvas)[0]
            #expect(canvas.compositeSurfaces.reused == 0)
            return picture
        }
    }

    /// 置き場の数え方の不変条件: 持つ面の重さの合計は、面ごとにいま確保しているバイト数の合計と同じで、上限を越えない。
    private func expectWithinLimit(
        _ pool: CompositeSurfacePool, _ comment: String = "", sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            pool.heldBytes == pool.entries.reduce(0) { $0 + $1.canvas.allocatedBytes },
            "数えた重さが面の確保と違う \(comment)", sourceLocation: sourceLocation)
        #expect(
            pool.heldBytes <= pool.byteLimit, "上限 \(pool.byteLimit) を越えて \(pool.heldBytes) 持つ \(comment)",
            sourceLocation: sourceLocation)
    }

    // MARK: - 絵は変わらない・作り直さない

    @Test("同じ置き方を 3 フレーム続けると、面は最初のフレームの 3 枚だけを作り、後は使い回す。絵は作りたての面と同じ")
    func sameSizesAreReusedAcrossFrames() throws {
        let place: (Canvas, Shape) -> Void = { canvas, shape in
            canvas.shape(shape, at: [Placement(x: 0, y: 0), Placement(x: 10.5, y: 3.25), Placement(x: 90, y: 60)])
        }
        let canvas = try makeCanvas()
        let pictures = try render([place, place, place], on: canvas)
        // 10.5 ずらした置き場所は箱の端の丸めで幅が 1 違うので、大きさは 2 種・面は 3 枚
        #expect(canvas.compositeSurfaces.made == 3, "\(canvas.compositeSurfaces.made)")
        #expect(canvas.compositeSurfaces.reused == 6, "\(canvas.compositeSurfaces.reused)")
        let fresh = try freshPictures([place])[0]
        for (index, picture) in pictures.enumerated() {
            #expect(picture == fresh, "フレーム \(index) が作りたての面の絵と違う")
        }
    }

    @Test("置いた側が読み終える前には使い回さない: 同じ大きさの単位を 1 フレームに 3 つ置いても、置いた側に写しを取らせない")
    func surfacesAreNotReusedBeforeThePlacerReadsThem() throws {
        // 同じフレームの中で使い回すと、置いた側の写し (`settlePlacersBeforeChange`) が置いた時点の絵を守るので、
        // 絵の比較では赤にならない (#4029 の反証 6)。写しを取った数で見る
        let place: (Canvas, Shape) -> Void = { canvas, shape in
            canvas.shape(shape, at: [Placement(x: 0, y: 0), Placement(x: 40, y: 0), Placement(x: 80, y: 30)])
        }
        let canvas = try makeCanvas()
        _ = try render([place, place, place], on: canvas)
        #expect(canvas.compositeSurfaces.made == 3, "\(canvas.compositeSurfaces.made)")
        #expect(canvas.placedPicturesCopied == 0, "置いた側が写しを \(canvas.placedPicturesCopied) 回取った")
        #expect(canvas.placedPictureCopyLimitReached == 0)
    }

    @Test("使い回す面は前のフレームの絵を引きずらない: 不透明に置いた次のフレームで薄い色で置いても、作りたての面と同じ")
    func reusedSurfacesStartTransparent() throws {
        let frames: [(Canvas, Shape) -> Void] = [
            { $0.shape($1, at: [Placement(x: 5, y: 5)]) },
            // 同じ箱の大きさ (整数だけずらす)・薄い色。前の絵が残ると、中間面の上で重なって濃く出る
            {
                $0.shape(
                    $1,
                    at: [Placement(x: 40, y: 25, fill: LinearRGBA(premultipliedRed: 0.1, green: 0.05, blue: 0, alpha: 0.2))])
            },
            // 置き場所の無い所: 前の面の内容が出ないこと
            { canvas, _ in canvas.rect(0, 0, 10, 10) },
            { $0.shape($1, at: [Placement(x: 7, y: 2)]) },
        ]
        let canvas = try makeCanvas()
        let pictures = try render(frames, on: canvas)
        #expect(canvas.compositeSurfaces.reused == 1, "2 フレーム目だけが使い回す (3 フレーム目で手放す)")
        let fresh = try freshPictures(frames)
        #expect(pictures == fresh)
    }

    @Test("置き場所ごとに倍率・回転・色が違い、数がフレームごとに変わっても、どのフレームも作りたての面と同じ絵")
    func mixedPlacementsMatchFreshSurfaces() throws {
        let frames: [(Canvas, Shape) -> Void] = (0..<4).map { frame in
            { canvas, shape in
                var placements: [Placement] = []
                for index in 0..<(2 + frame) {
                    var placement = Placement(x: Float(index * 37 + frame * 3) + 0.3, y: Float(index * 11) + 0.7)
                    if index % 2 == 1 {
                        let scale = 0.5 + Float(index) * 0.1
                        placement.scale = Vector3(scale, scale * 1.2, 1)
                    }
                    if index % 3 == 2 { placement.rotation = Vector3(0, 0, 0.3 * Float(index)) }
                    if index == 1 {
                        placement.fill = LinearRGBA(premultipliedRed: 0.5, green: 0.2, blue: 0.1, alpha: 0.6)
                    }
                    placements.append(placement)
                }
                canvas.shape(shape, at: placements)
                canvas.push()
                canvas.translate(Float(frame * 5), 3)
                canvas.scale(1.3)
                canvas.shape(shape)
                canvas.pop()
            }
        }
        let canvas = try makeCanvas()
        let pictures = try render(frames, on: canvas)
        #expect(canvas.compositeSurfaces.reused > 0, "使い回しが起きている")
        let fresh = try freshPictures(frames)
        #expect(pictures == fresh)
    }

    @Test("入れ子の単位と、塗りと線を両方持つ要素も、使い回して作りたての面と同じ絵")
    func nestedUnitsMatchFreshSurfaces() throws {
        let frames: [(Canvas, Shape) -> Void] = (0..<3).map { frame in
            { canvas, shape in canvas.shape(shape, at: [Placement(x: Float(frame), y: 4), Placement(x: 100, y: 50)]) }
        }
        let canvas = try makeCanvas()
        let pictures = try render(frames, body: Self.nested, on: canvas)
        #expect(canvas.compositeSurfaces.reused > 0)
        let fresh = try freshPictures(frames, body: Self.nested)
        #expect(pictures == fresh)
    }

    @Test("書き出しの倍率 2 の面でも、使い回して作りたての面と同じ絵")
    func outputScaleMatchesFreshSurfaces() throws {
        let place: (Canvas, Shape) -> Void = { $0.shape($1, at: [Placement(x: 3, y: 4), Placement(x: 60.5, y: 20)]) }
        let canvas = try makeCanvas(outputScale: 2)
        let pictures = try render([place, place], on: canvas)
        #expect(canvas.compositeSurfaces.reused == 2)
        let fresh = try freshPictures([place], outputScale: 2)[0]
        #expect(pictures[1] == fresh)
    }

    @Test("描き場所 (createGraphics) の中で置いても、本体の置き場から取って使い回し、作りたての面と同じ絵")
    func insideGraphicsMatchesFreshSurfaces() throws {
        func run(on main: Canvas, frames: Range<Int>) throws -> [PixelBuffer] {
            let shape = try logo(on: main)
            let graphics = try main.createGraphics(300, 200)
            var pictures: [PixelBuffer] = []
            for frame in frames {
                try main.draw {
                    main.background(40)
                    graphics.beginDraw()
                    graphics.background(0, 0, 0, 0)
                    graphics.shape(shape, at: [Placement(x: Float(frame), y: 2), Placement(x: 60, y: 30)])
                    graphics.endDraw()
                    main.image(graphics, 10, 10)
                }
                pictures.append(try main.output.readPixels())
            }
            #expect(graphics.compositeSurfaces.entries.isEmpty, "描き場所は自分の置き場を使わない")
            if frames.count > 1 { #expect(main.compositeSurfaces.reused > 0) }
            return pictures
        }
        let pooled = try run(on: try makeCanvas(), frames: 0..<3)
        for frame in 0..<3 {
            let fresh = try run(on: try makeCanvas(), frames: frame..<(frame + 1))[0]
            #expect(pooled[frame] == fresh, "フレーム \(frame)")
        }
    }

    @Test("描き切れなかった中間面は貼らない: 使い回した面が前の絵を持っていても出ず、作りたての面で失敗したときと同じ絵")
    func failedSurfacesAreNotPlaced() throws {
        let tinted = LinearRGBA(premultipliedRed: 0.1, green: 0.05, blue: 0, alpha: 0.2)
        let frames: [(Canvas, Shape) -> Void] = [
            { $0.shape($1, at: [Placement(x: 5, y: 5)]) },
            // 同じ箱の大きさ。使い回した面は 1 フレーム目の絵 (不透明に置いた群) を持っている
            { $0.shape($1, at: [Placement(x: 40, y: 25, fill: tinted)]) },
        ]
        let canvas = try makeCanvas()
        let pictures = try render(frames, on: canvas) { index in
            if index == 0 { canvas.compositeSurfaces.failSurfacesForTesting = .deviceUnavailable }
        }
        #expect(canvas.compositeSurfaces.reused == 1, "2 フレーム目は使い回した面で失敗する")
        #expect(canvas.compositeSurfaces.entries.isEmpty, "描き切れなかった面を置き場へ戻した")
        let fresh = try freshPictures([frames[1]], failing: .deviceUnavailable)[0]
        #expect(pictures[1] == fresh, "使い回した面の前の絵が出た")
        // 作りたての面で失敗すると何も出ない (背景だけ)
        let background = try freshPictures([{ _, _ in }])[0]
        #expect(fresh == background)
    }

    // MARK: - 数え方・寿命・上限

    @Test("数える重さは、面を持ったことで常駐の集合が増えたバイト数と合う")
    func heldBytesMatchTheResidencySet() throws {
        func resident() throws -> Int {
            try gpu.settle()
            return gpu.residencySet.allAllocations.reduce(0) { $0 + $1.allocatedSize }
        }
        let place: (Canvas, Shape) -> Void = { canvas, shape in
            canvas.shape(shape, at: [Placement(x: 0, y: 0), Placement(x: 40, y: 0), Placement(x: 80, y: 30)])
        }
        let canvas = try makeCanvas()
        // 1 フレーム目は持たずに描き、本体の置き場を伸ばし切る
        canvas.compositeSurfaces.byteLimit = 0
        _ = try render([place], body: Self.nested, on: canvas)
        #expect(canvas.compositeSurfaces.entries.isEmpty)
        let before = try resident()
        canvas.compositeSurfaces.byteLimit = CompositeSurfacePool.defaultByteLimit
        _ = try render([place], body: Self.nested, on: canvas)
        let held = canvas.compositeSurfaces.heldBytes
        let grown = try resident() - before
        #expect(canvas.compositeSurfaces.entries.count == 6, "外側 3 枚と入れ子 3 枚")
        // 面が持つ数百バイトの置き場 (混ぜ方の番号など) は数えない
        #expect(abs(grown - held) <= 4096 * canvas.compositeSurfaces.entries.count, "常駐の増え \(grown)・数えた重さ \(held)")
        #expect(held > canvas.compositeSurfaces.entries.count * 152 * 122 * 12, "色と奥行きだけを数えている")
    }

    @Test("入れ子の単位の面も、描き場所の中で置いた面も、本体の 1 つの置き場が上限の内で数える")
    func nestedAndGraphicsSurfacesShareOneLimit() throws {
        let main = try makeCanvas()
        let shape = try logo(Self.nested, on: main)
        let graphics = try main.createGraphics(300, 200)
        let frame = {
            try main.draw {
                main.shape(shape, at: [Placement(x: 0, y: 0), Placement(x: 120, y: 60)])
                graphics.beginDraw()
                graphics.shape(shape, at: [Placement(x: 3, y: 2)])
                graphics.endDraw()
                main.image(graphics, 0, 0)
            }
        }
        try frame()
        let pool = main.compositeSurfaces
        // 本体の 2 か所・描き場所の 1 か所に、外側と入れ子が 1 枚ずつ
        #expect(pool.entries.count == 6, "\(pool.entries.count)")
        #expect(pool.entries.allSatisfy { $0.canvas.compositeSurfaces.entries.isEmpty }, "中間面が自分の置き場を持った")
        #expect(graphics.compositeSurfaces.entries.isEmpty)
        expectWithinLimit(pool)
        // 上限を 1 枚ぶん下げると、どこの面でも合計で収める
        pool.byteLimit = pool.heldBytes - 1
        for index in 0..<3 {
            try frame()
            expectWithinLimit(pool, "フレーム \(index)")
        }
        #expect(pool.entries.count < 6)
    }

    @Test("新しい大きさの面を先に作ってから前のフレームの面を使い回しても、合計は上限を越えない")
    func newSizesBeforeReuseStayWithinTheLimit() throws {
        let kept: [Placement] = [Placement(x: 0, y: 0), Placement(x: 40, y: 0), Placement(x: 80, y: 30)]
        let canvas = try makeCanvas()
        let pool = canvas.compositeSurfaces
        let frames: [(Canvas, Shape) -> Void] = [
            { $0.shape($1, at: kept) },
            { canvas, shape in
                // 新しい大きさを 2 つ先に置き、その後で前のフレームと同じ 3 つを置く
                canvas.shape(shape, at: [Placement(x: 0, y: 0, scale: 0.5), Placement(x: 9, y: 9, scale: 0.7)])
                expectWithinLimit(pool, "新しい大きさを作った後")
                canvas.shape(shape, at: kept)
                expectWithinLimit(pool, "使い回した後")
            },
        ]
        let pictures = try render(frames, on: canvas) { index in
            // 1 フレーム目の 3 枚ちょうどを上限にする
            if index == 0 { pool.byteLimit = pool.heldBytes }
        }
        expectWithinLimit(pool)
        #expect(pool.reused > 0, "前のフレームの面を 1 枚も使い回せていない")
        let fresh = try freshPictures([frames[1]])[0]
        #expect(pictures[1] == fresh)
    }

    @Test("大きさが毎フレーム変わる置き方では、前のフレームの面を抱えたまま上限を越えて作らない")
    func changingSizesDoNotHoldTwoFrames() throws {
        let canvas = try makeCanvas()
        let pool = canvas.compositeSurfaces
        let frames: [(Canvas, Shape) -> Void] = (0..<5).map { frame in
            { canvas, shape in
                let scale = 1 - Float(frame) * 0.1
                canvas.shape(shape, at: [Placement(x: 0, y: 0, scale: scale)])
                expectWithinLimit(pool, "フレーム \(frame) の 1 つ目")
                canvas.shape(shape, at: [Placement(x: 100, y: 50, scale: scale)])
                expectWithinLimit(pool, "フレーム \(frame) の 2 つ目")
            }
        }
        let pictures = try render(frames, on: canvas) { index in
            // 1 フレームぶん (2 枚) だけを持てる上限。前のフレームの 2 枚を抱えたまま作ると越える
            if index == 0 { pool.byteLimit = pool.heldBytes }
            #expect(pool.entries.count <= 2, "フレーム \(index) の後に \(pool.entries.count) 枚持つ")
        }
        #expect(pool.reused == 0)
        #expect(pictures == (try freshPictures(frames)))
    }

    @Test("単位を置かなかったフレームの後に、持ち越した面を手放す")
    func unusedSurfacesAreReleasedAfterAFrame() throws {
        let canvas = try makeCanvas()
        let shape = try logo(on: canvas)
        try canvas.draw { canvas.shape(shape, at: [Placement(x: 0, y: 0), Placement(x: 40, y: 0)]) }
        #expect(canvas.compositeSurfaces.free.count == 2)
        try canvas.draw { canvas.rect(0, 0, 10, 10) }
        #expect(canvas.compositeSurfaces.entries.isEmpty, "使わなかったフレームの後は 1 枚も持たない")
        #expect(canvas.compositeSurfaces.heldBytes == 0)
        // 大きさの違う置き方に替えたら、前の大きさの面は次のフレームで手放す
        try canvas.draw { canvas.shape(shape, at: [Placement(x: 0, y: 0)]) }
        try canvas.draw { canvas.shape(shape, at: [Placement(x: 0, y: 0, scale: 0.5)]) }
        #expect(canvas.compositeSurfaces.free.count == 1)
        #expect(canvas.compositeSurfaces.free.first.map { Int($0.canvas.width) } != 152)
    }

    @Test("持ち主のフレームの外で 1 度だけ描いた描き場所の面も、持ち主のフレームを 1 つ使われずに過ぎたら手放す")
    func surfacesFromAGraphicsDrawnOnceAreReleased() throws {
        let main = try makeCanvas()
        let shape = try logo(on: main)
        let graphics = try main.createGraphics(300, 200)
        // `setup()` で 1 度だけ描く描き場所と同じ: 持ち主のフレームの外で開いて閉じる
        graphics.beginDraw()
        graphics.shape(shape, at: [Placement(x: 0, y: 0), Placement(x: 40, y: 0)])
        graphics.endDraw()
        #expect(main.compositeSurfaces.free.count == 2, "描き場所が閉じたら空きへ戻る")
        // 描き場所の絵は持ち主の次のフレームに属するので、そのフレームでは持つ
        try main.draw { main.image(graphics, 0, 0) }
        #expect(main.compositeSurfaces.entries.count == 2)
        try main.draw { main.image(graphics, 0, 0) }
        #expect(main.compositeSurfaces.entries.isEmpty, "使われないまま持ち主のフレームを過ぎた面を持ち続けた")
    }

    @Test("noLoop() で止めたスケッチは、止まったフレームの後に持つ面を全部手放す")
    func stoppedSketchReleasesItsSurfaces() throws {
        let sketch = StoppingSketch()
        let runtime = try SketchRuntime(sketch: sketch, gpu: gpu)
        sketch.canvas = runtime.canvas
        try runtime.advance()
        #expect(sketch.placed, "1 枚目で単位を置いていない")
        #expect(runtime.canvas.compositeSurfaces.made == 2)
        #expect(runtime.canvas.compositeSurfaces.entries.isEmpty, "止まった後も \(runtime.canvas.compositeSurfaces.entries.count) 枚持つ")
        #expect(runtime.canvas.compositeSurfaces.heldBytes == 0)
    }

    /// 1 枚目の `draw()` で単位を 2 つ置き、`noLoop()` で止まるスケッチ。
    final class StoppingSketch: Sketch {
        var canvas: Canvas?
        var shape: Shape?
        var placed = false
        var settings: SketchSettings { SketchSettings(width: 360, height: 240) }

        func draw() {
            guard let canvas else { return }
            noLoop()
            if shape == nil, let read = try? SVGFile.parse(
                "<svg xmlns='http://www.w3.org/2000/svg' width='240' height='160'>\(CompositeSurfacePoolTests.group)</svg>",
                path: "pool.svg")
            {
                shape = canvas.shape(of: read, readFrom: "pool.svg")
            }
            guard let shape else { return }
            canvas.shape(shape, at: [Placement(x: 0, y: 0), Placement(x: 40, y: 0)])
            placed = true
        }
    }

    @Test("上限を越える分は持ち越さずに作り直し、絵は作りたての面と同じ")
    func surfacesBeyondTheLimitAreNotKept() throws {
        let place: (Canvas, Shape) -> Void = { canvas, shape in
            canvas.shape(shape, at: [Placement(x: 0, y: 0), Placement(x: 40, y: 0), Placement(x: 80, y: 0)])
        }
        // 152×122 の面 1 枚の重さを、別の canvas で測る
        let probe = try makeCanvas()
        _ = try render([{ $0.shape($1, at: [Placement(x: 0, y: 0)]) }], on: probe)
        let one = probe.compositeSurfaces.heldBytes
        #expect(one > 0)
        let canvas = try makeCanvas()
        canvas.compositeSurfaces.byteLimit = one
        let pictures = try render([place, place], on: canvas)
        #expect(canvas.compositeSurfaces.free.count == 1)
        #expect(canvas.compositeSurfaces.made == 5, "1 フレーム目に 3 枚・2 フレーム目に越えた 2 枚")
        #expect(canvas.compositeSurfaces.reused == 1)
        expectWithinLimit(canvas.compositeSurfaces)
        let fresh = try freshPictures([place])[0]
        #expect(pictures[1] == fresh)
    }

    @Test("上限 0 なら 1 枚も持ち越さない (前と同じく毎回作る)")
    func zeroLimitKeepsNothing() throws {
        let canvas = try makeCanvas()
        canvas.compositeSurfaces.byteLimit = 0
        let shape = try logo(on: canvas)
        for _ in 0..<2 { try canvas.draw { canvas.shape(shape) } }
        #expect(canvas.compositeSurfaces.made == 2)
        #expect(canvas.compositeSurfaces.reused == 0)
        #expect(canvas.compositeSurfaces.entries.isEmpty)
    }

    @Test("#4029 の再現 (1280×720 に同じ形を 100 個) は既定の上限に収まり、2 フレーム目からは 1 枚も作らない")
    func theIssueExampleIsReusedWithinTheDefaultLimit() throws {
        let placements = (0..<100).map { index in
            Placement(x: Float(index % 10 * 112), y: Float(index / 10 * 58))
        }
        let canvas = try makeCanvas(width: 1280, height: 720)
        _ = try render([{ $0.shape($1, at: placements) }, { $0.shape($1, at: placements) }], on: canvas)
        let pool = canvas.compositeSurfaces
        #expect(pool.made == 100, "\(pool.made)")
        #expect(pool.reused == 100, "\(pool.reused)")
        expectWithinLimit(pool)
        print("CompositeSurfacePoolTests: the #4029 example holds \(pool.heldBytes) bytes in \(pool.entries.count) surfaces")
    }

    @Test("保持した形でない単位 (中の描き方を書き換えうる) は使い回さない")
    func plainGroupsAreNotPooled() throws {
        let canvas = try makeCanvas()
        var box = PlaneBox(SIMD2(0, 0))
        box.add(SIMD2(50, 50))
        for _ in 0..<2 {
            try canvas.draw {
                canvas.withCompositeGroup(opacity: 0.5, covering: box) { group in
                    group.fill(255)
                    group.rect(0, 0, 40, 40)
                }
            }
        }
        #expect(canvas.compositeSurfaces.made == 0)
        #expect(canvas.compositeSurfaces.entries.isEmpty)
    }
}
