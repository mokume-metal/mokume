// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import Testing
import simd

@testable import MokumeCore

/// 畳んだ頂点の置き方 ([#3555]) の検査。GPU を要する。
///
/// 畳まずに置くときは、周を置き場所の位置ぶんずらしてから (`Outline.moved(by:)`) `Transform.placed` で移す。
/// 畳んだ雛形は頂点段が同じ順 (位置を足す → `fma(列 y, y, 列 x·x)` → 平行移動) で置き、貼る絵の読み取り位置も
/// ずらした周の箱から作り、細い矩形の額縁の片 (#3733) も 1 つ目と同じ式で広げる。**畳みの入口へ来る 4 口
/// (角丸 rect・rect・ellipse / circle・arc) のどれも、畳んだ絵が畳まない道 (`draw(_:)` に `moved(by:)` した周を
/// 渡す本物の道) と許容 0 で一致する**ことを見る。
///
/// [#3555]: https://github.com/mokume-metal/mokume/issues/3555
@Suite(
    "畳んだ頂点の置き方",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FoldedPlacementTests {
    private static let size = 128
    private static let plain = "float4 paint(Fragment in, Values values) { return in.color; }"

    private static func makeCanvas(density: Float) throws -> Canvas {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: size, height: size)
        return try Canvas(output: output, gpu: gpu, pixelDensity: density, upscale: .spatial)
    }

    // MARK: - 形

    /// 畳みの入口へ来る形。どれも原点でない位置に置く (位置が 0 だと足す順の違いが出ない)。
    enum Form: CustomStringConvertible {
        case rect
        case roundedRect
        case ellipse
        case circle
        /// `.pie` の弧 (輪郭の有無によらず畳む)
        case pie
        /// 一周の弧 (楕円と同じ形)
        case fullTurn
        /// 輪郭を引かない既定の弧 (塗りは扇)
        case standardArc
        /// 輪郭も貼る絵も無い `.chord` の弧 (弦で結んだ形の塗り)
        case chord

        var description: String {
            switch self {
            case .rect: "rect"
            case .roundedRect: "角丸 rect"
            case .ellipse: "ellipse"
            case .circle: "circle"
            case .pie: ".pie の arc"
            case .fullTurn: "一周の arc"
            case .standardArc: "既定の arc"
            case .chord: ".chord の arc"
            }
        }

        /// 畳む口で描く (`rect` / `ellipse` / `circle` / `arc`)。
        func drawFolding(_ canvas: Canvas) {
            switch self {
            case .rect: canvas.rect(3.1, -4.3, 13, 9)
            case .roundedRect: canvas.rect(3.1, -4.3, 13, 9, 2.5)
            case .ellipse: canvas.ellipse(2.3, -1.7, 14, 9)
            case .circle: canvas.circle(-2.9, 1.3, 11)
            case .pie: canvas.arc(2.3, -1.7, 14, 10, 0.3, 4.1, .pie)
            case .fullTurn: canvas.arc(2.3, -1.7, 14, 10, 0.3, 0.3 + 2 * .pi + 0.1, .pie)
            case .standardArc: canvas.arc(2.3, -1.7, 14, 10, 0.3, 4.1)
            case .chord: canvas.arc(2.3, -1.7, 14, 10, 0.3, 4.1, .chord)
            }
        }

        /// 畳まない道: 畳む口と同じ周を形自身の座標で組み、位置ぶん `moved(by:)` して `draw(_:)` へ渡す。
        /// 座標の読み方は既定 (`rectMode(.corner)`・`ellipseMode(.center)`) で、口と同じく ``Canvas/resolveBox`` で解く。
        func drawUnfolded(_ canvas: Canvas) {
            let scale = Canvas.splitScale(of: canvas.transform.matrix)
            switch self {
            case .rect:
                canvas.draw(Canvas.rectOutline(width: 13, height: 9).moved(by: SIMD2(3.1, -4.3)))
            case .roundedRect:
                let segments = Canvas.segmentCount(forRadius: 2.5, scale: scale)
                canvas.draw(
                    Canvas.roundedRectOutline(width: 13, height: 9, radius: 2.5, segments: segments)
                        .moved(by: SIMD2(3.1, -4.3)))
            case .ellipse:
                Self.ring(canvas, 2.3, -1.7, 14, 9, start: 0, sweep: 2 * .pi, piece: .sector, scale: scale)
            case .circle:
                Self.ring(canvas, -2.9, 1.3, 11, 11, start: 0, sweep: 2 * .pi, piece: .sector, scale: scale)
            case .pie, .standardArc:
                Self.ring(canvas, 2.3, -1.7, 14, 10, start: 0.3, sweep: 4.1 - 0.3, piece: .sector, scale: scale)
            case .fullTurn:
                Self.ring(
                    canvas, 2.3, -1.7, 14, 10, start: 0.3, sweep: min((0.3 + 2 * .pi + 0.1) - 0.3, 2 * .pi),
                    piece: .sector, scale: scale)
            case .chord:
                Self.ring(canvas, 2.3, -1.7, 14, 10, start: 0.3, sweep: 4.1 - 0.3, piece: .chord, scale: scale)
            }
        }

        private static func ring(
            _ canvas: Canvas, _ a: Float, _ b: Float, _ c: Float, _ d: Float, start: Float, sweep: Float,
            piece: Canvas.Outline.Ring.Piece, scale: Float
        ) {
            let box = Canvas.resolveBox(a, b, c, d, mode: .center)
            let (radiusX, radiusY) = (box.width / 2, box.height / 2)
            let segments = Canvas.segmentCount(forRadius: max(radiusX, radiusY), scale: scale)
            canvas.draw(
                Canvas.ringOutline(
                    Canvas.Outline.Ring(
                        radiusX: radiusX, radiusY: radiusY, start: start, sweep: sweep, segments: segments,
                        piece: piece)
                ).moved(by: SIMD2(box.x + radiusX, box.y + radiusY)))
        }
    }

    /// 輪郭の設定。`nil` なら輪郭を引かない。
    struct Stroke: CustomStringConvertible {
        var weight: Float
        var join: StrokeJoin = .round
        var description: String { "輪郭 \(weight) \(join)" }
    }

    /// 置き場所の並べ方。
    enum Arrangement: CaseIterable, CustomStringConvertible {
        /// 置き場所ごとに回転 (`index * 0.21 + 0.03`) と倍率 (回転だけ・鏡映と一様な拡大・非一様・鏡映と非一様) が違う
        case mixed
        /// 2 つずつ同じ回転と倍率 (位置だけが違う)。細い輪郭は 2x2 そのものが畳みの鍵なので、2 つずつ畳まれる
        case paired
        /// 2 つずつ同じ回転と倍率で、副画素ずつずらして 400 個を半透明の足し算で重ねる。縁の画素の入れ替わりが
        /// 1 つでもあれば、重なった値に出る
        case dense

        var description: String {
            switch self {
            case .mixed: "全部違う"
            case .paired: "2 つずつ同じ"
            case .dense: "400 個を足し算で重ねる"
            }
        }

        var count: Int { self == .dense ? 400 : 30 }

        func apply(_ canvas: Canvas, _ index: Int) {
            if self == .dense {
                canvas.translate(10 + Float(index % 20) * 5.37, 10 + Float(index / 20) * 5.41)
            } else {
                canvas.translate(14 + Float(index % 6) * 20, 14 + Float(index / 6) * 22)
            }
            let pose = self == .mixed ? index : index / 2
            canvas.rotate(Float(pose) * 0.21 + 0.03)
            let scales: [(Float, Float)] = [(1, 1), (-1.15, 1.15), (1.25, 0.8), (-0.9, 1.1)]
            let (sx, sy) = scales[pose % scales.count]
            canvas.scale(sx, sy)
        }
    }

    private static func gradient(_ canvas: Canvas) throws -> Image {
        let made = try canvas.createImage(8, 8)
        for y in 0..<8 {
            for x in 0..<8 {
                made.set(x, y, .linear(red: Float(x) / 7, green: Float(y) / 7, blue: Float((x + y) % 2)))
            }
        }
        return made
    }

    /// 並べ方の数だけ置いた絵と、畳んだ置き場所の数。
    private static func picture(
        _ form: Form, density: Float, stroke: Stroke?, texture: Bool, arrangement: Arrangement,
        folding: Bool
    ) throws -> (pixels: PixelBuffer, folded: Int) {
        let canvas = try makeCanvas(density: density)
        let shader = try canvas.makeShader(plain)
        let image = texture ? try gradient(canvas) : nil
        var folded = 0
        let dense = arrangement == .dense
        try canvas.draw {
            canvas.background(0)
            canvas.fill(255, dense ? 40 : 255)
            if let stroke {
                canvas.stroke(200, dense ? 60 : 255)
                canvas.strokeWeight(stroke.weight)
                canvas.strokeCap(.round)
                canvas.strokeJoin(stroke.join)
            } else {
                canvas.noStroke()
            }
            if dense { canvas.blendMode(.add) }
            if let image { canvas.texture(image) } else { canvas.shader(shader) }
            for index in 0..<arrangement.count {
                canvas.pushMatrix()
                arrangement.apply(canvas, index)
                if folding { form.drawFolding(canvas) } else { form.drawUnfolded(canvas) }
                canvas.popMatrix()
            }
            // 置き場所の並びの先頭は、畳めない列が通る何も動かさない置き場所
            folded = canvas.flatInstances.count - 1
        }
        return (try canvas.target.readPixels(), folded)
    }

    /// 畳む口と畳まない道の絵を比べ、違う成分の数を返す。
    private static func differences(
        _ form: Form, density: Float, stroke: Stroke?, texture: Bool, arrangement: Arrangement
    ) throws -> (differing: Int, lit: Int, folded: Int) {
        let unfolded = try picture(
            form, density: density, stroke: stroke, texture: texture, arrangement: arrangement, folding: false)
        let folded = try picture(
            form, density: density, stroke: stroke, texture: texture, arrangement: arrangement, folding: true)
        #expect(unfolded.folded == 0, "畳まない道が畳まれた: \(unfolded.folded)")
        var differing = 0
        var lit = 0
        for index in unfolded.pixels.components.indices {
            if unfolded.pixels.components[index] != folded.pixels.components[index] { differing += 1 }
            // 不透明度の成分は背景でも 1 なので数えない
            if index % 4 != 3, unfolded.pixels.components[index] > 0 { lit += 1 }
        }
        return (differing, lit, folded.folded)
    }

    /// 場面の組: 形 × 輪郭 (または貼る絵) × 細かさ × 並べ方。
    private static func expectSameAsUnfolded(
        _ form: Form, strokes: [Stroke?], texture: Bool = false, densities: [Float] = [1, 0.5]
    ) throws {
        for density in densities {
            for stroke in strokes {
                for arrangement in Arrangement.allCases {
                    let name = "\(form) \(stroke.map(\.description) ?? (texture ? "貼る絵" : "塗りだけ")) 細かさ \(density) \(arrangement)"
                    let result = try differences(
                        form, density: density, stroke: stroke, texture: texture, arrangement: arrangement)
                    #expect(result.lit > 0, "\(name): 絵が空")
                    // 2 つずつ同じ置き場所は、どの鍵でも全部畳まれる (畳まれないまま比べると検査が空になる)
                    if arrangement != .mixed {
                        #expect(result.folded == arrangement.count, "\(name): 畳まれた置き場所 \(result.folded)")
                    }
                    #expect(
                        result.differing == 0,
                        "\(name): 畳まない道と画素の成分が \(result.differing) 個違う (点いている成分 \(result.lit)・畳んだ置き場所 \(result.folded))")
                }
            }
        }
    }

    private static let roundStrokes: [Stroke?] = [nil, Stroke(weight: 0.7), Stroke(weight: 2)]

    // MARK: - 畳まない道と同じ絵

    @Test("畳んだ rect は、輪郭 (丸い角・miter・bevel) も貼る絵も、畳まない道と画素が同じ (許容 0)")
    func rectsKeepTheirPixels() throws {
        // miter と bevel の細い輪郭は、相似な置き場所で額縁の片を頂点段で広げ直す経路 (#3733) に入る
        try Self.expectSameAsUnfolded(
            .rect,
            strokes: Self.roundStrokes + [
                Stroke(weight: 0.7, join: .miter), Stroke(weight: 0.7, join: .bevel), Stroke(weight: 2, join: .miter),
            ])
        try Self.expectSameAsUnfolded(.rect, strokes: [nil], texture: true)
        // 相似な置き場所の細い miter の rect は、額縁の片を頂点段で広げ直す雛形に畳まれる (上の場面がその経路を通る)
        let canvas = try Self.makeCanvas(density: 1)
        let shader = try canvas.makeShader(Self.plain)
        try canvas.draw {
            canvas.stroke(200)
            canvas.strokeWeight(0.7)
            canvas.strokeJoin(.miter)
            canvas.shader(shader)
            for index in 0..<2 {
                canvas.pushMatrix()
                canvas.translate(40 + Float(index) * 30, 50)
                canvas.rotate(Float(index) * 0.21 + 0.03)
                Form.rect.drawFolding(canvas)
                canvas.popMatrix()
            }
            #expect(canvas.openFlat?.thinStrokeParams != nil, "額縁の経路に入っていない")
        }
    }

    @Test("畳んだ角丸 rect (塗りだけ・貼る絵) は、畳まない道と画素が同じ (許容 0)")
    func roundedRectsKeepTheirPixels() throws {
        // 輪郭つきの角丸は畳まない (#3170・畳む条件はこの検査の外)
        try Self.expectSameAsUnfolded(.roundedRect, strokes: [nil])
        try Self.expectSameAsUnfolded(.roundedRect, strokes: [nil], texture: true)
    }

    @Test("畳んだ ellipse と circle は、輪郭も貼る絵も、畳まない道と画素が同じ (許容 0)")
    func ellipsesKeepTheirPixels() throws {
        try Self.expectSameAsUnfolded(.ellipse, strokes: Self.roundStrokes)
        try Self.expectSameAsUnfolded(.ellipse, strokes: [nil], texture: true)
        try Self.expectSameAsUnfolded(.circle, strokes: Self.roundStrokes)
        try Self.expectSameAsUnfolded(.circle, strokes: [nil], texture: true)
    }

    @Test("畳んだ arc (.pie・一周・既定・.chord) は、輪郭も貼る絵も、畳まない道と画素が同じ (許容 0)")
    func arcsKeepTheirPixels() throws {
        try Self.expectSameAsUnfolded(.pie, strokes: Self.roundStrokes)
        try Self.expectSameAsUnfolded(.pie, strokes: [nil], texture: true)
        try Self.expectSameAsUnfolded(.fullTurn, strokes: Self.roundStrokes)
        // 輪郭を引かない既定の弧と、輪郭も貼る絵も無い `.chord` だけが畳まれる (#3248)
        try Self.expectSameAsUnfolded(.standardArc, strokes: [nil])
        try Self.expectSameAsUnfolded(.standardArc, strokes: [nil], texture: true)
        try Self.expectSameAsUnfolded(.chord, strokes: [nil])
    }

    // MARK: - 1 つだけ置く・続けて置く

    /// 同じ形を 1 つだけ置くと、畳む相手を待ったまま畳まずに置かれる (``Canvas/pendingFlat``)。続けて置くと、
    /// 1 つ目も雛形へ移って頂点段で置かれる。**どちらでも、その形の画素は同じ**。
    ///
    /// 場面: 左半分に比べる形を 48 個 (回転・倍率・鏡映・副画素の位置を変えて、半透明の足し算で重ねる)。1 つ置く
    /// たびに、右半分へ「1 つだけの絵」では寸法の違う矩形 (鍵が違い畳む相手にならない) を、「続けた絵」では同じ形を
    /// 同じ回転と倍率で置く。左半分の成分だけを比べる。
    @Test(
        "同じ形を 1 つだけ置いた絵と続けて置いた絵で、その形の画素が同じ (許容 0)",
        arguments: [Float(1), 0.5])
    func lonePlacementsMatchFoldedOnes(density: Float) throws {
        let scenes: [(Form, Stroke?, Bool)] = [
            (.rect, Stroke(weight: 0.7), false), (.rect, Stroke(weight: 2), false),
            (.rect, Stroke(weight: 0.7, join: .miter), false), (.rect, Stroke(weight: 0.7, join: .bevel), false),
            (.rect, nil, true), (.roundedRect, nil, false), (.roundedRect, nil, true),
            (.ellipse, Stroke(weight: 0.7), false), (.ellipse, Stroke(weight: 2), false), (.ellipse, nil, true),
            (.circle, Stroke(weight: 0.7), false), (.pie, Stroke(weight: 0.7), false), (.pie, Stroke(weight: 2), false),
            (.pie, nil, true), (.fullTurn, Stroke(weight: 0.7), false), (.chord, nil, false),
        ]
        let count = 48
        let scales: [(Float, Float)] = [(1, 1), (-1.15, 1.15), (1.25, 0.8), (-0.9, 1.1)]
        for (form, stroke, texture) in scenes {
            func picture(followed: Bool) throws -> (pixels: PixelBuffer, folded: Int) {
                let canvas = try Self.makeCanvas(density: density)
                let shader = try canvas.makeShader(Self.plain)
                let image = texture ? try Self.gradient(canvas) : nil
                var folded = 0
                try canvas.draw {
                    canvas.background(0)
                    canvas.fill(255, 40)
                    if let stroke {
                        canvas.stroke(200, 60)
                        canvas.strokeWeight(stroke.weight)
                        canvas.strokeCap(.round)
                        canvas.strokeJoin(stroke.join)
                    } else {
                        canvas.noStroke()
                    }
                    canvas.blendMode(.add)
                    if let image { canvas.texture(image) } else { canvas.shader(shader) }
                    for index in 0..<count {
                        let x = Float(index % 4) * 4.37
                        let y = 20 + Float(index / 4) * 7.9
                        let rotation = Float(index) * 0.81 + 0.03
                        let (sx, sy) = scales[index % scales.count]
                        // 左半分: 比べる形
                        canvas.pushMatrix()
                        canvas.translate(22 + x, y)
                        canvas.rotate(rotation)
                        canvas.scale(sx, sy)
                        form.drawFolding(canvas)
                        canvas.popMatrix()
                        // 右半分: 同じ回転と倍率で、続けた絵は同じ形、1 つだけの絵は寸法の違う矩形
                        canvas.pushMatrix()
                        canvas.translate(86 + x, y)
                        canvas.rotate(rotation)
                        canvas.scale(sx, sy)
                        if followed { form.drawFolding(canvas) } else { canvas.rect(-3, -2, 5, 7) }
                        canvas.popMatrix()
                    }
                    folded = canvas.flatInstances.count - 1
                }
                return (try canvas.target.readPixels(), folded)
            }
            let lone = try picture(followed: false)
            let followed = try picture(followed: true)
            let name = "\(form) \(stroke.map(\.description) ?? (texture ? "貼る絵" : "塗りだけ")) 細かさ \(density)"
            #expect(lone.folded == 0, "\(name): 1 つだけの形が畳まれた (\(lone.folded))")
            #expect(followed.folded == count * 2, "\(name): 続けた形が畳まれない (\(followed.folded))")
            // 左半分 (座標の x < 60) の成分だけを比べる。読み戻す絵は描く画素の大きさ (細かさ 0.5 なら 64 列)
            let width = lone.pixels.width
            let border = width * 60 / Self.size
            var differing = 0
            var lit = 0
            for index in lone.pixels.components.indices where (index / 4) % width < border {
                if lone.pixels.components[index] != followed.pixels.components[index] { differing += 1 }
                if index % 4 != 3, lone.pixels.components[index] > 0 { lit += 1 }
            }
            #expect(lit > 0, "\(name): 絵が空")
            #expect(differing == 0, "\(name): 画素の成分が \(differing) 個違う (点いている成分 \(lit))")
        }
    }

    // MARK: - 額縁の頂点の数

    /// 細い矩形の輪郭の額縁は、留め継ぎ (`miter`) で 24・面取り (`bevel`) で 60 頂点を積む (#3733 の片)。帯を縁の写しの
    /// 平行四辺形と両端の片に割ると 120・156 頂点になり、回した輪郭つきの `rect` を 5,000 個描く 1 フレームの CPU 時間が
    /// 28 ms から 37 ms に増えた (#3862)。直に描く 1 つ目 (``Canvas/appendThinRectFrame(_:)``) と、2 つ目が来て積み直す
    /// 雛形 (``Canvas/appendWidenedTemplateStroke(_:)``) の両方を数える。3 つ目からは置き場所を足すだけで頂点を積まない。
    @Test(
        "細い矩形の輪郭の額縁は、直に描いても雛形でも miter で 24・bevel で 60 頂点を積む",
        arguments: [(StrokeJoin.miter, 24), (.bevel, 60)] as [(StrokeJoin, Int)])
    func thinRectFrameKeepsItsVertexCount(join: StrokeJoin, expected: Int) throws {
        let canvas = try Self.makeCanvas(density: 0.5)
        let shader = try canvas.makeShader(Self.plain)
        try canvas.draw {
            canvas.background(0)
            canvas.noFill()
            canvas.stroke(255)
            canvas.strokeWeight(1)
            canvas.strokeJoin(join)
            canvas.shader(shader)
            // 描く画素で 12×8・太さ 0.5 の相似な置き場所なので、どれも額縁で組む
            @MainActor func place(_ x: Float, _ turn: Float) {
                canvas.pushMatrix()
                canvas.translate(x, 64)
                canvas.rotate(turn)
                canvas.rect(-12, -8, 24, 16)
                canvas.popMatrix()
            }
            let start = canvas.vertices.count
            let instances = canvas.flatInstances.count
            place(30, 0.3)
            #expect(canvas.openFlat == nil, "\(join): 1 つ目で雛形が開いた")
            #expect(canvas.vertices.count - start == expected, "\(join): 直に描く 1 つ目の頂点 \(canvas.vertices.count - start)")
            // 2 つ目で 1 つ目の頂点を抜き、雛形を積み直す
            place(70, .pi / 4)
            #expect(canvas.openFlat?.thinStrokeParams != nil, "\(join): 雛形が頂点段で広げ直す形で積まれていない")
            #expect(canvas.vertices.count - start == expected, "\(join): 雛形の頂点 \(canvas.vertices.count - start)")
            place(100, 1.1)
            #expect(canvas.vertices.count - start == expected, "\(join): 3 つ目で頂点が増えた (\(canvas.vertices.count - start))")
            #expect(canvas.flatInstances.count - instances == 3, "\(join): 置き場所 \(canvas.flatInstances.count - instances)")
        }
    }

    // MARK: - 頂点段の出力を読み戻す

    /// 頂点段の置き方 (`mokume_flatMove` → `mokume_flatPlace`)・貼る絵の読み取り位置 (`mokume_flatFillUV`)・額縁の
    /// 半幅と被覆 (`mokume_thinRectBand`) を、Shapes.metal の原文に足した計算の入口から呼び、CPU の式と **1 ビットずつ**
    /// 突き合わせる。画素の比べでは 1 ulp の差は縁の画素が振れたときしか見えない。
    @Test("頂点段の置き方・読み取り位置・額縁の半幅は、CPU の式と 1 ビットも違わない")
    func vertexStageMatchesTheCPUBitForBit() throws {
        let gpu = try RenderDevice()
        let shapes = try gpu.shaders.bundledShaderSource(named: "Shapes")
        let probe = """

        kernel void probeFlatPlacement(
            constant float4 *linears [[buffer(0)]], constant float4 *offsets [[buffer(1)]],
            constant float4 *boxes [[buffer(2)]], constant float2 *inputs [[buffer(3)]],
            constant float4 *bands [[buffer(4)]],
            device float2 *placed [[buffer(5)]], device float2 *uvs [[buffer(6)]], device float2 *widths [[buffer(7)]],
            uint id [[thread_position_in_grid]])
        {
            float2 moved = mokume_flatMove(inputs[id], offsets[0].xy);
            placed[id] = mokume_flatPlace(linears[0], offsets[0].zw, moved);
            uvs[id] = mokume_flatFillUV(boxes[0], offsets[0].xy, moved);
            widths[id] = mokume_thinRectBand(linears[id], bands[0].xy, bands[0].z, bands[0].w);
        }
        """
        let library = try gpu.shaders.makeShapeLibrary(named: "FlatPlacementProbe", body: shapes + probe)
        let function = try #require(library.makeFunction(name: "probeFlatPlacement"))
        let pipeline = try gpu.device.makeComputePipelineState(function: function)
        let queue = try #require(gpu.device.makeCommandQueue())

        var seed: UInt64 = 3555
        func next() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
        }
        func buffer<T>(_ values: [T]) throws -> any MTLBuffer {
            try #require(
                values.withUnsafeBytes {
                    gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
                })
        }
        func output(_ count: Int) throws -> any MTLBuffer {
            try #require(
                gpu.device.makeBuffer(length: count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared))
        }
        func read(_ buffer: any MTLBuffer, _ count: Int) -> [SIMD2<Float>] {
            Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: count), count: count))
        }
        let count = 64
        var compared = 0
        for density in [Float(1), 0.5] {
            // 額縁の半幅は、いまの細かさの描く画素で測る (CPU の `thinRectFrame` は Canvas の状態を読む)
            let canvas = try Self.makeCanvas(density: density)
            canvas.strokeJoin(.miter)
            for round in 0..<150 {
                let angle = next() * 6.2831853
                let (c, s) = (cos(angle), sin(angle))
                let stretch: Float = 0.3 + next() * 3
                let flip: Float = round % 3 == 0 ? -1 : 1
                let shear = round % 5 == 0 ? (next() - 0.5) * 2 : 0
                let linear = simd_float2x2(
                    SIMD2(c, s) * stretch, SIMD2(-s + shear * c, c + shear * s) * flip * (0.2 + next() * 2))
                let anchor = SIMD2(next() * 300 - 150, next() * 300 - 150)
                let translation = SIMD2(next() * 600 - 300, next() * 600 - 300)
                let placement = SIMD4(linear.columns.0.x, linear.columns.0.y, linear.columns.1.x, linear.columns.1.y)
                let points = (0..<count).map { _ in SIMD2(next() * 70 - 35, next() * 50 - 25) }
                let box = Canvas.uvBounds(of: points)
                // 額縁の半幅は相似な置き場所 (回転と一様な拡大・鏡映) で測る
                let weight = 0.1 + next() * 0.9
                let similar = (0..<count).map { _ -> simd_float2x2 in
                    let turn = next() * 6.2831853
                    let grow = (0.3 + next() * 2) * (next() < 0.5 ? -1 : 1)
                    return simd_float2x2(
                        SIMD2(cos(turn), sin(turn)) * grow, SIMD2(-sin(turn), cos(turn)) * abs(grow))
                }
                let commands = try #require(queue.makeCommandBuffer())
                let encoder = try #require(commands.makeComputeCommandEncoder())
                let (placedBuffer, uvBuffer, widthBuffer) = (try output(count), try output(count), try output(count))
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(
                    try buffer(
                        [placement]
                            + similar.map { SIMD4($0.columns.0.x, $0.columns.0.y, $0.columns.1.x, $0.columns.1.y) }
                            .dropFirst()),
                    offset: 0, index: 0)
                encoder.setBuffer(
                    try buffer([SIMD4(anchor.x, anchor.y, translation.x, translation.y)]), offset: 0, index: 1)
                encoder.setBuffer(try buffer([box]), offset: 0, index: 2)
                encoder.setBuffer(try buffer(points), offset: 0, index: 3)
                let units = canvas.unitsPerDrawnPixel
                encoder.setBuffer(
                    try buffer([SIMD4(units.x, units.y, weight, Float(1 - Canvas.thinStrokeTolerance))]),
                    offset: 0, index: 4)
                encoder.setBuffer(placedBuffer, offset: 0, index: 5)
                encoder.setBuffer(uvBuffer, offset: 0, index: 6)
                encoder.setBuffer(widthBuffer, offset: 0, index: 7)
                encoder.dispatchThreads(
                    MTLSize(width: count, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: count, height: 1, depth: 1))
                encoder.endEncoding()
                commands.commit()
                commands.waitUntilCompleted()
                let (placed, uvs, widths) = (read(placedBuffer, count), read(uvBuffer, count), read(widthBuffer, count))

                // CPU: 周を位置ぶんずらし (`moved(by:)`)、`Transform.placed` で移す
                let matrix = simd_float4x4(
                    SIMD4(linear.columns.0.x, linear.columns.0.y, 0, 0), SIMD4(linear.columns.1.x, linear.columns.1.y, 0, 0),
                    SIMD4(0, 0, 1, 0), SIMD4(translation.x, translation.y, 0, 1))
                let moved = Canvas.Outline(points: points, isClosed: true).moved(by: anchor).points
                let uvOf = Canvas.boxUV(of: moved)
                for index in 0..<count {
                    let expected = Transform(matrix: matrix).placed(x: moved[index].x, y: moved[index].y)
                    #expect(placed[index] == expected, "置き場所 \(index): GPU \(placed[index]) CPU \(expected)")
                    #expect(uvs[index] == uvOf(moved[index]), "読み取り位置 \(index): GPU \(uvs[index]) CPU \(uvOf(moved[index]))")
                    compared += 1
                }
                // CPU: 額縁 (`thinRectFrame`) の半幅と被覆。先頭は剪断を含みうる置き場所なので飛ばす
                canvas.strokeWeight(weight)
                let rect = Canvas.rectOutline(width: 40, height: 30)
                for index in 1..<count {
                    let frame = canvas.thinRectFrame(rect, placedBy: Canvas.placementMatrix(
                        SIMD4(similar[index].columns.0.x, similar[index].columns.0.y,
                              similar[index].columns.1.x, similar[index].columns.1.y)))
                    // 細くない置き場所は額縁を組まない (頂点段にも来ない)
                    guard let frame else { continue }
                    #expect(
                        widths[index] == SIMD2(frame.half, frame.coverage),
                        "額縁 \(index): GPU \(widths[index]) CPU \(SIMD2(frame.half, frame.coverage))")
                    compared += 1
                }
            }
        }
        #expect(compared > 20_000)
    }
}
