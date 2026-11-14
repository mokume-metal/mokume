// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeTestSupport
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
        _ pool: CompositeSurfacePool<Canvas>, _ comment: String = "", sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            pool.heldBytes == pool.entries.reduce(0) { $0 + $1.surface.allocatedBytes },
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
        canvas.compositeSurfaces.byteLimit = CompositeSurfacePool<Canvas>.defaultByteLimit
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
        #expect(pool.entries.allSatisfy { $0.surface.compositeSurfaces.entries.isEmpty }, "中間面が自分の置き場を持った")
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

    /// 常駐の集合が持つバイト数 (投入を待って、終わった番の解放を済ませてから数える)。
    private func resident() throws -> Int {
        try gpu.settle()
        return gpu.residencySet.allAllocations.reduce(0) { $0 + $1.allocatedSize }
    }

    /// 置き場がいま持つ面を弱く覚える。帳簿から消えた後に、面そのものが解放されたかを見る。
    private static func watch(_ pool: CompositeSurfacePool<Canvas>) -> [Canvas.WeakCanvas] {
        pool.entries.map { Canvas.WeakCanvas(canvas: $0.surface) }
    }

    /// 覚えた面が全部解放され、常駐の集合が持っていた重さ (`held`) ぶん減ったこと。帳簿 (`entries`・`heldBytes`)
    /// だけを見ると、置き場の外の強い参照が面を生かしていても通る。
    private func expectFreed(
        _ watched: [Canvas.WeakCanvas], held: Int, residentBefore: Int, _ comment: String = "",
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(!watched.isEmpty, "覚えた面が無い \(comment)", sourceLocation: sourceLocation)
        let alive = watched.filter { $0.canvas != nil }.count
        #expect(alive == 0, "手放したはずの面が \(alive) 枚生きている \(comment)", sourceLocation: sourceLocation)
        let dropped = residentBefore - (try resident())
        #expect(
            dropped >= held - 4096 * watched.count, "常駐が \(dropped) バイトしか減らない (持っていた \(held)) \(comment)",
            sourceLocation: sourceLocation)
    }

    @Test("単位を置かなかったフレームの後に、持ち越した面を手放し、面そのものも解放される")
    func unusedSurfacesAreReleasedAfterAFrame() throws {
        let canvas = try makeCanvas()
        let shape = try logo(on: canvas)
        try canvas.draw { canvas.shape(shape, at: [Placement(x: 0, y: 0), Placement(x: 40, y: 0)]) }
        #expect(canvas.compositeSurfaces.free.count == 2)
        let watched = Self.watch(canvas.compositeSurfaces)
        let held = canvas.compositeSurfaces.heldBytes
        let before = try resident()
        try canvas.draw { canvas.rect(0, 0, 10, 10) }
        #expect(canvas.compositeSurfaces.entries.isEmpty, "使わなかったフレームの後は 1 枚も持たない")
        #expect(canvas.compositeSurfaces.heldBytes == 0)
        try expectFreed(watched, held: held, residentBefore: before)
        // 大きさの違う置き方に替えたら、前の大きさの面は次のフレームで手放す
        try canvas.draw { canvas.shape(shape, at: [Placement(x: 0, y: 0)]) }
        try canvas.draw { canvas.shape(shape, at: [Placement(x: 0, y: 0, scale: 0.5)]) }
        #expect(canvas.compositeSurfaces.free.count == 1)
        #expect(canvas.compositeSurfaces.free.first.map { Int($0.surface.width) } != 152)
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
        let watched = Self.watch(main.compositeSurfaces)
        let held = main.compositeSurfaces.heldBytes
        let before = try resident()
        try main.draw { main.image(graphics, 0, 0) }
        #expect(main.compositeSurfaces.entries.isEmpty, "使われないまま持ち主のフレームを過ぎた面を持ち続けた")
        try expectFreed(watched, held: held, residentBefore: before)
    }

    @Test("noLoop() で止めたスケッチは、止まったフレームの後に持つ面を全部手放す")
    func stoppedSketchReleasesItsSurfaces() throws {
        let sketch = PlacingSketch()
        sketch.stops = true
        let runtime = try SketchRuntime(sketch: sketch, gpu: gpu)
        sketch.canvas = runtime.canvas
        try runtime.advance()
        #expect(sketch.placed, "1 枚目で単位を置いていない")
        #expect(runtime.canvas.compositeSurfaces.made == 2)
        #expect(
            runtime.canvas.compositeSurfaces.entries.isEmpty,
            "止まった後も \(runtime.canvas.compositeSurfaces.entries.count) 枚持つ")
        #expect(runtime.canvas.compositeSurfaces.heldBytes == 0)
        let alive = sketch.watched.filter { $0.canvas != nil }.count
        #expect(!sketch.watched.isEmpty && alive == 0, "止まった後も面が \(alive) 枚生きている")
    }

    @Test("外から pause() で止めている回は、前のフレームの空きの面を全部手放す")
    func pausedSketchReleasesItsSurfaces() throws {
        let sketch = PlacingSketch()
        let runtime = try SketchRuntime(sketch: sketch, gpu: gpu)
        sketch.canvas = runtime.canvas
        let pool = runtime.canvas.compositeSurfaces
        try runtime.advance()
        try runtime.advance()
        #expect(pool.made == 2 && pool.reused == 2, "回っている間は使い回す (作った \(pool.made)・使い回した \(pool.reused))")
        #expect(pool.free.count == 2)
        let watched = Self.watch(pool)
        let held = pool.heldBytes
        let before = try resident()
        runtime.pause()
        try runtime.advance()
        #expect(pool.entries.isEmpty, "外から止めている間に \(pool.entries.count) 枚持つ")
        #expect(pool.heldBytes == 0)
        try expectFreed(watched, held: held, residentBefore: before)
        // 再開したフレームは作り直して描く
        runtime.resume()
        try runtime.advance()
        #expect(pool.made == 4)
    }

    @Test("止まっている間の入力のコールバックで置いた単位は、描かない回の後に面を 1 枚も残さない")
    func inputWhileStoppedKeepsNoSurfaces() throws {
        let facet = try TestScratch.directory("mokume-composite-pool")
        let sketch = PlacingSketch()
        sketch.stops = true
        sketch.placesOnPress = true
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: gpu, clock: nil, now: { 0 }, observer: nil, inbox: InputInbox(directory: facet))
        sketch.canvas = runtime.canvas
        let pool = runtime.canvas.compositeSurfaces
        try runtime.advance()
        #expect(pool.entries.isEmpty)
        try AtomicFile.write(
            Data(
                #"{"id":"press","events":[{"type":"mouseDown","x":4,"y":4,"button":0},{"type":"mouseUp","x":4,"y":4,"button":0}]}"#
                    .utf8),
            to: facet.appendingPathComponent("request.json"))
        let made = pool.made
        try runtime.advance()
        #expect(sketch.pressed, "コールバックが配られていない")
        #expect(runtime.frameCount == 1, "描き直していない回を見る")
        // 本体が持ち越しの区間で置いた単位は置き場を通さない (入れ子と描き場所の単位は通す)
        #expect(sketch.pooledByMainOnPress == 0, "持ち越しの区間で置いた単位の面を置き場が \(sketch.pooledByMainOnPress) 枚持った")
        #expect(pool.made > made, "コールバックの中で置き場を通る単位を置いていない")
        #expect(pool.entries.isEmpty, "描かない回の後に \(pool.entries.count) 枚持つ")
        #expect(pool.heldBytes == 0)
        let alive = sketch.watched.filter { $0.canvas != nil }.count
        #expect(!sketch.watched.isEmpty && alive == 0, "描かない回の後も面が \(alive) 枚生きている")
    }

    @Test("renderFrame(to:) の 1 枚描きの後は、面を 1 枚も持ち越さない")
    func renderFrameKeepsNoSurfaces() throws {
        let sketch = PlacingSketch()
        let runtime = try SketchRuntime(sketch: sketch, gpu: gpu)
        sketch.canvas = runtime.canvas
        let pool = runtime.canvas.compositeSurfaces
        let url = try TestScratch.directory("mokume-composite-pool").appendingPathComponent("frame.png")
        try runtime.renderFrame(to: url)
        #expect(sketch.placed)
        #expect(pool.made == 2)
        #expect(pool.entries.isEmpty, "1 枚描きの後に \(pool.entries.count) 枚持つ")
        #expect(pool.heldBytes == 0)
        let alive = sketch.watched.filter { $0.canvas != nil }.count
        #expect(!sketch.watched.isEmpty && alive == 0, "1 枚描きの後も面が \(alive) 枚生きている")
    }

    /// `draw()` のたびに単位を 2 つ置くスケッチ。`stops` なら置いた後に `noLoop()` で止まる。`placesOnPress` なら、
    /// 押したときのコールバック (止まっている間は持ち越しの区間) で、本体に入れ子の単位を 1 つ置き、描き場所の中に
    /// 単位を 1 つ置く。置き場が持った面は `watched` に弱く覚える。
    final class PlacingSketch: Sketch {
        var canvas: Canvas?
        var stops = false
        var placesOnPress = false
        private var shape: Shape?
        private var nested: Shape?
        private var graphics: Canvas?
        private(set) var placed = false
        private(set) var pressed = false
        /// 押したときに本体が置いた単位のうち、置き場が使用中で持った面の数。
        private(set) var pooledByMainOnPress = 0
        private(set) var watched: [Canvas.WeakCanvas] = []
        var settings: SketchSettings { SketchSettings(width: 360, height: 240) }

        private static func read(_ canvas: Canvas, _ body: String) -> Shape? {
            guard
                let read = try? SVGFile.parse(
                    "<svg xmlns='http://www.w3.org/2000/svg' width='240' height='160'>\(body)</svg>", path: "pool.svg")
            else { return nil }
            return canvas.shape(of: read, readFrom: "pool.svg")
        }

        private func remember(_ canvas: Canvas) {
            watched += CompositeSurfacePoolTests.watch(canvas.compositeSurfaces)
        }

        func draw() {
            guard let canvas else { return }
            if stops { noLoop() }
            if shape == nil {
                shape = Self.read(canvas, CompositeSurfacePoolTests.group)
                nested = Self.read(canvas, CompositeSurfacePoolTests.nested)
                graphics = try? canvas.createGraphics(300, 200)
            }
            guard let shape else { return }
            canvas.shape(shape, at: [Placement(x: 0, y: 0), Placement(x: 40, y: 0)])
            placed = true
            remember(canvas)
        }

        func mousePressed() {
            pressed = true
            guard placesOnPress, let canvas, let nested, let shape, let graphics else { return }
            canvas.shape(nested, at: [Placement(x: 10, y: 10)])
            pooledByMainOnPress = canvas.compositeSurfaces.inUse.filter { $0.placer === canvas }.count
            graphics.beginDraw()
            graphics.shape(shape, at: [Placement(x: 3, y: 2)])
            graphics.endDraw()
            remember(canvas)
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
        let placements: [Placement] = (0..<100).map { (index: Int) -> Placement in
            let column: Int = index % 10
            let row: Int = index / 10
            return Placement(x: Float(column * 112), y: Float(row * 58))
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

/// 中間面の置き場の帳簿だけを、GPU を使わずに回す (#4029)。面は中身を持たない印で、重さは決め打ちにする。
@Suite("合成の単位の中間面の置き場の帳簿")
struct CompositeSurfacePoolLedgerTests {
    /// 面の代わり (同一性だけを持つ)。
    final class Surface {}

    private static func shape(_ width: Int) -> CompositeSurfaceShape {
        CompositeSurfaceShape(
            width: width, height: 1, outputScale: 1, placesGlyphs: true, gpu: ObjectIdentifier(Surface.self))
    }

    /// 置き方 1 つ: 置いた側 (`placer`) と面の形。
    private struct Unit {
        let placer: AnyObject
        let width: Int
        /// 置いた側が、置いた直後にフレームを出るか (描き場所が閉じる・入れ子の外側が描き切る)。
        let placerLeaves: Bool
    }

    /// 持ち主 `owner` のフレームを 1 つ回す。製品の経路 (``Canvas/withCompositeGroup(opacity:covering:placedWith:_:)``) と
    /// 同じ順で、取る (無ければ作って載せる) → 面が描き切る (面自身がフレームを出る) → 重さを数え直す → 置いた側が
    /// フレームを出る、を単位ごとに行い、最後に持ち主のフレームの終わりを告げる。
    private static func frame(
        _ pool: CompositeSurfacePool<Surface>, owner: AnyObject, _ units: [Unit], bytes: Int = 100
    ) {
        for unit in units {
            let shape = shape(unit.width)
            let surface: Surface
            if let kept = pool.take(shape, for: unit.placer) {
                surface = kept
            } else {
                surface = Surface()
                pool.keep(surface, shape: shape, for: unit.placer)
            }
            pool.leaveFrame(of: surface, sweeping: false)
            pool.measure(surface, bytes: bytes)
            if unit.placerLeaves { pool.leaveFrame(of: unit.placer, sweeping: false) }
        }
        pool.leaveFrame(of: owner, sweeping: true)
    }

    @Test("上限の際では、このフレームでまだ使われていない空きから手放すので、2 フレーム目より後は面を作らない")
    func theLimitReleasesSurfacesNotYetUsedThisFrameFirst() {
        let pool = CompositeSurfacePool<Surface>()
        pool.byteLimit = 200  // 面 2 枚ぶん
        let owner = Surface()
        let graphics = Surface()
        // 1 フレーム目は A と C。2 フレーム目からは A と B で、C はもう使わない
        func place(_ widths: [Int]) -> [Unit] {
            widths.map { Unit(placer: graphics, width: $0, placerLeaves: true) }
        }
        Self.frame(pool, owner: owner, place([10, 30]))
        Self.frame(pool, owner: owner, place([10, 20]))
        #expect(pool.made == 3, "1 フレーム目の 2 枚と 2 フレーム目の B")
        for index in 0..<4 {
            Self.frame(pool, owner: owner, place([10, 20]))
            #expect(pool.heldBytes <= pool.byteLimit)
            #expect(pool.made == 3, "\(index + 3) フレーム目に作り直した: このフレームで使った A を、使わない C より先に手放した")
        }
        #expect(pool.entries.count == 2)
    }

    @Test("上限を越えても、使用中の面は手放さない")
    func theLimitNeverReleasesSurfacesInUse() {
        let pool = CompositeSurfacePool<Surface>()
        pool.byteLimit = 200
        let owner = Surface()
        // 本体が置いた面は持ち主のフレームの終わりまで使用中。3 枚目は越えるので残さない
        let units = (0..<3).map { Unit(placer: owner, width: 10 + $0, placerLeaves: false) }
        Self.frame(pool, owner: owner, units)
        let kept = pool.entries.map(\.shape.width).sorted()
        #expect(kept == [10, 11], "\(kept)")
        #expect(pool.heldBytes == 200)
    }

    /// `units` 個を 1 フレームに置く書き方で、使い回すフレームを `frames` 回回す間に帳簿が面の項目を見た回数
    /// (``CompositeSurfacePool/entryVisits``)。時間でなく回数で見るので、機械の負荷でぶれない。
    private static func ledgerVisits(units count: Int, frames: Int = 10) -> Int {
        let pool = CompositeSurfacePool<Surface>()
        let owner = Surface()
        // 入れ子の外側の面のように、単位ごとに置いた側が違う形も混ぜる
        let inner = (0..<count / 4).map { _ in Surface() }
        let units =
            (0..<count).map { Unit(placer: owner, width: 10 + $0 % 3, placerLeaves: false) }
            + inner.map { Unit(placer: $0, width: 5, placerLeaves: true) }
        frame(pool, owner: owner, units)
        let before = pool.entryVisits
        for _ in 0..<frames { frame(pool, owner: owner, units) }
        #expect(pool.made == units.count - inner.count + 1, "2 フレーム目からは使い回す")
        return pool.entryVisits - before
    }

    @Test("帳簿の仕事は単位の数に比例する: 1,000 個で面の項目を見る回数は 100 個の 9〜11 倍 (2 乗なら 100 倍)")
    func ledgerWorkGrowsLinearly() {
        let small = Self.ledgerVisits(units: 100)
        let large = Self.ledgerVisits(units: 1_000)
        #expect(small > 0)
        // 単位の数が 10 倍でも、形ごとの数の端数で回数はちょうど 10 倍にはならない (9.96 倍)。2 乗なら 100 倍になる
        #expect(small * 9 <= large && large <= small * 11, "1,000 個で \(large) 回・100 個で \(small) 回 (\(Double(large) / Double(small)) 倍)")
    }
}
