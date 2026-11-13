// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 合成の単位の中間面をフレームをまたいで使い回す (#4029)。GPU を要する。
///
/// 約束は 3 つ — 絵は 1 ビットも変わらない (毎回作る面で描いた絵と同じ)・同じ大きさの面は次のフレームで
/// 作り直さない・持ち越す面は 1 フレーム使わなければ手放し、合計は上限まで。絵は、使い回す面で何フレームか
/// 描いた後の読み出しを、そのフレームだけを作りたての面 (作りたての中間面) で描いた読み出しとビット列で比べる。
@Suite(
    "合成の単位の中間面の使い回し",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CompositeSurfacePoolTests {
    /// #2878 の群の例: `opacity='0.5'` の群の中に重なる白い矩形 2 つ (外接 20…170 × 20…140)。
    private static let group = SVGCompositeGroupTests.group

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
        _ frames: [(Canvas, Shape) -> Void], body: String = Self.group, on canvas: Canvas
    ) throws -> [PixelBuffer] {
        let shape = try logo(body, on: canvas)
        var pictures: [PixelBuffer] = []
        for frame in frames {
            try canvas.draw {
                canvas.background(10, 20, 30)
                frame(canvas, shape)
            }
            pictures.append(try canvas.output.readPixels())
        }
        return pictures
    }

    /// `frames` をそれぞれ作りたての canvas で 1 フレームだけ描いた読み出し (中間面も作りたて)。
    private func freshPictures(
        _ frames: [(Canvas, Shape) -> Void], body: String = Self.group, outputScale: Int = 1
    ) throws -> [PixelBuffer] {
        try frames.map { frame in
            let canvas = try makeCanvas(outputScale: outputScale)
            #expect(canvas.compositeSurfaces.reused == 0)
            return try render([frame], body: body, on: canvas)[0]
        }
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
        let body =
            "<g opacity='0.5'>\(Self.group)</g>"
            + "<rect x='30' y='30' width='120' height='90' fill='white' stroke='white' stroke-width='20' opacity='0.5'/>"
        let frames: [(Canvas, Shape) -> Void] = (0..<3).map { frame in
            { canvas, shape in canvas.shape(shape, at: [Placement(x: Float(frame), y: 4), Placement(x: 100, y: 50)]) }
        }
        let canvas = try makeCanvas()
        let pictures = try render(frames, body: body, on: canvas)
        #expect(canvas.compositeSurfaces.reused > 0)
        let fresh = try freshPictures(frames, body: body)
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

    @Test("描き場所 (createGraphics) の中で置いても、描き場所が面を持ち回り、作りたての面と同じ絵")
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
            #expect(main.compositeSurfaces.made == 0, "本体は単位を開かない")
            if frames.count > 1 { #expect(graphics.compositeSurfaces.reused > 0) }
            return pictures
        }
        let pooled = try run(on: try makeCanvas(), frames: 0..<3)
        for frame in 0..<3 {
            let fresh = try run(on: try makeCanvas(), frames: frame..<(frame + 1))[0]
            #expect(pooled[frame] == fresh, "フレーム \(frame)")
        }
    }

    // MARK: - 寿命と上限

    @Test("単位を置かなかったフレームの後に、持ち越した面を手放す")
    func unusedSurfacesAreReleasedAfterAFrame() throws {
        let canvas = try makeCanvas()
        let shape = try logo(on: canvas)
        try canvas.draw { canvas.shape(shape, at: [Placement(x: 0, y: 0), Placement(x: 40, y: 0)]) }
        #expect(canvas.compositeSurfaces.free.count == 2)
        try canvas.draw { canvas.rect(0, 0, 10, 10) }
        #expect(canvas.compositeSurfaces.free.isEmpty, "使わなかったフレームの後は 1 枚も持たない")
        #expect(canvas.compositeSurfaces.inUse.isEmpty)
        // 大きさの違う置き方に替えたら、前の大きさの面は次のフレームで手放す
        try canvas.draw { canvas.shape(shape, at: [Placement(x: 0, y: 0)]) }
        try canvas.draw { canvas.shape(shape, at: [Placement(x: 0, y: 0, scale: 0.5)]) }
        #expect(canvas.compositeSurfaces.free.count == 1)
        #expect(canvas.compositeSurfaces.free.first?.width != 152, "\(String(describing: canvas.compositeSurfaces.free.first?.width))")
    }

    @Test("上限を越える分は持ち越さずに作り直し、絵は作りたての面と同じ")
    func surfacesBeyondTheLimitAreNotKept() throws {
        let place: (Canvas, Shape) -> Void = { canvas, shape in
            canvas.shape(shape, at: [Placement(x: 0, y: 0), Placement(x: 40, y: 0), Placement(x: 80, y: 0)])
        }
        let canvas = try makeCanvas()
        // 152×122 の面 1 枚ぶん (12 B/画素) だけ持ち越せる上限
        canvas.compositeSurfaces.byteLimit = 152 * 122 * 12
        let pictures = try render([place, place], on: canvas)
        #expect(canvas.compositeSurfaces.free.count == 1)
        #expect(canvas.compositeSurfaces.made == 5, "1 フレーム目に 3 枚・2 フレーム目に越えた 2 枚")
        #expect(canvas.compositeSurfaces.reused == 1)
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
        #expect(canvas.compositeSurfaces.free.isEmpty)
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
        #expect(canvas.compositeSurfaces.free.isEmpty)
    }
}
