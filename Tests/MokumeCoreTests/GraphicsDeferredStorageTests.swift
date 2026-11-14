// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import Testing

@testable import MokumeCore

/// 描き場所は字形の焼き場の頁と列の置き場を使うときまで取らず、本体の面は以前と同じ時点で取る (#4082)。
/// GPU を要する。
///
/// **数えるのは頁の大きさ・頁を替えた回数・置き場の容量と取った回数**で、確保の量 (`allocatedSize`) や
/// 時間は比べない。絵は、遅らせない描き場所 (本体と同じ作り方) と画素ごとに比べる。
@Suite(
    "描き場所の遅らせた確保",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct GraphicsDeferredStorageTests {
    private let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let white = LinearRGBA.display(red: 1, green: 1, blue: 1)

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
    }

    /// 遅らせない描き場所。`createGraphics` と同じ繋ぎ方で、確保の時点だけが本体と同じ。
    private func eagerGraphics(on canvas: Canvas) throws -> Canvas {
        let target = try RenderTarget(gpu: canvas.gpu, width: 64, height: 64)
        let graphics = try Canvas(
            output: target, gpu: canvas.gpu, pixelDensity: 1, upscale: .spatial, outputScale: 1)
        canvas.bind(graphics)
        graphics.placesGlyphs = canvas.placesGlyphs
        return graphics
    }

    /// 本体と描き場所のフレームを 1 つ描き、描き場所を置く。
    private func frame(_ graphics: Canvas, on canvas: Canvas, _ body: () -> Void) throws {
        try canvas.draw {
            graphics.beginDraw()
            body()
            graphics.endDraw()
            canvas.image(graphics, 0, 0)
        }
    }

    /// 遅らせる置き場の名前と置き場。
    private func trackedStorages(of canvas: Canvas) -> [(String, GrowableBuffer)] {
        [
            ("vertices", canvas.vertexStorage), ("coverages", canvas.coverageStorage),
            ("flatInstances", canvas.flatInstanceStorage), ("formInstances", canvas.formInstanceStorage),
            ("thinFillRecords", canvas.thinFillRecordStorage), ("thinFillSpans", canvas.thinFillSpanStorage),
            ("solidVertices", canvas.solidVertexStorage), ("solidIndices", canvas.solidIndexStorage),
            ("solidInstances", canvas.solidInstanceStorage), ("lights", canvas.lightStorageBuffer),
            ("lighting", canvas.lightingStorage), ("materials", canvas.materialStorage),
            ("surroundings", canvas.surroundingsStorage), ("values", canvas.valuesStorage),
        ]
    }

    private func takenStorages(of canvas: Canvas) -> Set<String> {
        Set(trackedStorages(of: canvas).filter { $0.1.capacity > 0 }.map(\.0))
    }

    // MARK: - 本体の面は以前と同じ時点で取る (Issue の禁じ手)

    @Test("本体の面は作った時点で字の頁を持ち、最初の描き切りで列の置き場を全種類取る")
    func theMainCanvasAllocatesAsBefore() throws {
        let canvas = try makeCanvas()
        #expect(canvas.atlas.size == GlyphAtlas.initialSize, "本体の面が字の頁を持たずに始まった")
        try canvas.draw {
            canvas.fill(white)
            canvas.circle(32, 32, 20)
        }
        let missing = trackedStorages(of: canvas).filter { $0.1.capacity == 0 }.map(\.0)
        #expect(missing.isEmpty, "本体の面が最初の描き切りで取らなかった置き場: \(missing)")
        let page = canvas.atlas.pageSerial
        try canvas.draw { canvas.text("Hi", 4, 20) }
        #expect(canvas.atlas.pageSerial == page, "本体の面が最初の字で頁を替えた")
    }

    // MARK: - 描き場所は使う種類だけ取る

    enum Scene: String, CaseIterable, Sendable {
        case nothing, circle, text, polygon, box
    }

    /// 描いた種類ごとに取る置き場。**並びの無い種類は取らない** (0 個の要求は空の置き場で埋まる)。
    static let expectedStorages: [Scene: Set<String>] = [
        .nothing: [],
        // 基本図形は置き場所だけを読む。平面の置き場所は添字 0 の動かさない置き場所を常に持つ
        .circle: ["flatInstances", "formInstances"],
        // 字は平面の頂点と、列ごとの区画を読む
        .text: ["vertices", "flatInstances", "lighting", "materials", "surroundings", "values"],
        .polygon: ["vertices", "flatInstances", "lighting", "materials", "surroundings", "values"],
        // 箱は添字を持たない三角形の並びで描く (添字の置き場は取らない)
        .box: [
            "flatInstances", "solidVertices", "solidInstances", "lighting", "materials", "surroundings", "values",
        ],
    ]

    @Test("描き場所は、描いた種類の置き場だけを取る", arguments: Scene.allCases)
    func aGraphicsTakesOnlyTheStorageItDraws(scene: Scene) throws {
        let canvas = try makeCanvas()
        let graphics = try canvas.createGraphics(64, 64)
        try frame(graphics, on: canvas) {
            graphics.background(blue)
            graphics.fill(white)
            switch scene {
            case .nothing: break
            case .circle: graphics.circle(32, 32, 20)
            case .text: graphics.text("Hi", 4, 20)
            case .polygon:
                graphics.beginShape()
                graphics.vertex(4, 4)
                graphics.vertex(60, 10)
                graphics.vertex(30, 60)
                graphics.endShape(.close)
            case .box:
                graphics.translate(32, 32)
                graphics.box(20)
            }
        }
        let expected = try #require(Self.expectedStorages[scene])
        #expect(takenStorages(of: graphics) == expected)
        #expect(
            (graphics.atlas.size == GlyphAtlas.initialSize) == (scene == .text),
            "字を置いたときだけ字の頁を持つはずが、頁の一辺は \(graphics.atlas.size)")
    }

    @Test("最初の字を置いたフレームで焼き場の頁を 1 度だけ替え、次のフレームでは替えない")
    func theFirstGlyphReplacesTheWhiteOnlyPageOnce() throws {
        let canvas = try makeCanvas()
        let graphics = try canvas.createGraphics(64, 64)
        try frame(graphics, on: canvas) { graphics.circle(32, 32, 20) }
        #expect(graphics.atlas.size == GlyphAtlas.whiteOnlySize, "検査の前提: 字の前に頁が替わった")
        let whitePage = graphics.atlas.pageSerial

        try frame(graphics, on: canvas) { graphics.text("Hi", 4, 20) }
        #expect(graphics.atlas.size == GlyphAtlas.initialSize, "最初の字で、最初の大きさの頁へ替わっていない")
        #expect(graphics.atlas.pageSerial == whitePage + 1, "最初の字で、頁を 1 度より多く替えた")
        #expect(graphics.whiteUV == graphics.atlas.whiteUV, "替えた頁の白い区画を指していない")

        let textPage = graphics.atlas.pageSerial
        try frame(graphics, on: canvas) { graphics.text("Hi", 4, 20) }
        #expect(graphics.atlas.pageSerial == textPage, "2 度目の字で、頁をまた替えた")
    }

    // MARK: - 絵は遅らせない描き場所と 1 ビットも変わらない

    enum Order: String, CaseIterable, Sendable {
        /// 図形 → 字 → 図形 (頁がフレームの途中で替わる)
        case shapesThenText
        /// 字 → 図形
        case textThenShapes
        /// 図形だけのフレームの後に、字と図形のフレーム
        case shapesFrameThenTextFrame
        /// 字の前に描き場所で記録した立体の形を、字の後に置き直す (記録した形は白い区画だけの頁を抱える)
        case recordedShapeAcrossFirstGlyph
    }

    @Test("遅らせた描き場所の絵は、遅らせない描き場所と画素ごとに同じ", arguments: Order.allCases)
    func deferredGraphicsDrawTheSamePixels(order: Order) throws {
        let canvas = try makeCanvas()
        let deferred = try canvas.createGraphics(64, 64)
        let eager = try eagerGraphics(on: canvas)
        try #require(deferred.atlas.size == GlyphAtlas.whiteOnlySize && eager.atlas.size == GlyphAtlas.initialSize)

        for graphics in [deferred, eager] {
            func shapes() {
                graphics.fill(white)
                graphics.circle(20, 44, 16)
                graphics.stroke(red)
                graphics.strokeWeight(3)
                graphics.line(4, 60, 60, 30)
                graphics.noStroke()
                graphics.fill(red)
                graphics.beginShape()
                graphics.vertex(40, 4)
                graphics.vertex(60, 10)
                graphics.vertex(50, 30)
                graphics.endShape(.close)
            }
            func text() {
                graphics.fill(white)
                graphics.textSize(14)
                graphics.text("Hi", 4, 20)
            }
            switch order {
            case .shapesThenText:
                try frame(graphics, on: canvas) {
                    graphics.background(blue)
                    shapes()
                    text()
                    graphics.fill(white)
                    graphics.circle(50, 50, 6)
                }
            case .textThenShapes:
                try frame(graphics, on: canvas) {
                    graphics.background(blue)
                    text()
                    shapes()
                }
            case .shapesFrameThenTextFrame:
                try frame(graphics, on: canvas) {
                    graphics.background(blue)
                    shapes()
                }
                try frame(graphics, on: canvas) {
                    text()
                    shapes()
                }
            case .recordedShapeAcrossFirstGlyph:
                var recorded: Shape?
                try frame(graphics, on: canvas) {
                    graphics.background(blue)
                    recorded = graphics.createShape {
                        graphics.fill(white)
                        graphics.box(18)
                    }
                    if let recorded { graphics.shape(recorded, 20, 40) }
                }
                let shape = try #require(recorded)
                try frame(graphics, on: canvas) {
                    text()
                    graphics.shape(shape, 44, 40)
                    graphics.fill(red)
                    graphics.translate(44, 14)
                    graphics.box(10)
                }
            }
        }
        #expect(deferred.atlas.size == GlyphAtlas.initialSize, "検査の前提: 遅らせた描き場所が字の頁へ替わっていない")
        let deferredPixels = try deferred.output.readPixels()
        let eagerPixels = try eager.output.readPixels()
        #expect(deferredPixels != (try canvas.createGraphics(64, 64).output.readPixels()), "検査の前提: 何も描かれていない")
        #expect(deferredPixels == eagerPixels, "遅らせた描き場所の絵が、遅らせない描き場所と違う (\(order))")
    }

    // MARK: - 空の置き場 (GrowableBuffer)

    @Test("0 個の要求は空の置き場で埋め、1 個以上を要求されて初めて全スロットの置き場を取る")
    func anEmptyRequestTakesNoStorage() throws {
        let gpu = try RenderDevice()
        let ring = FrameRing(gpu: gpu)
        let storage = GrowableBuffer(
            gpu: gpu, ring: ring, stride: MemoryLayout<Float>.stride, minimumCapacity: 16,
            label: "mokume.test.empty", lendsEmptyBuffer: true)
        try ring.advance()

        let empty = try storage.buffer(holding: 0)
        #expect(empty === (try gpu.emptyBuffer()), "0 個の要求に、空の置き場を返していない")
        #expect(storage.capacity == 0 && storage.reallocations == 0, "0 個の要求で置き場を取った")
        #expect(ring.bufferBytes == 0, "0 個の要求で、環の確保が増えた")

        let taken = try storage.buffer(holding: 1)
        #expect(taken !== empty, "1 個の要求に、空の置き場を返した")
        #expect(storage.capacity == 16 && storage.reallocations == 1)
        #expect(try gpu.emptyBuffer() === empty, "空の置き場が装置に 1 本ではない")

        // **取るときは全スロットを揃えて取る。** 別のスロットへ進んでから 0 個を頼んでも、空の置き場へは
        // 戻らず、そのスロットの自分の置き場を返す
        var slots: Set<ObjectIdentifier> = [ObjectIdentifier(taken)]
        for _ in 1..<ring.slotCount {
            ring.noteSubmission()
            try ring.advance()
            let buffer = try storage.buffer(holding: 0)
            #expect(buffer !== empty, "スロット \(ring.slot) の 0 個の要求に、空の置き場を返した")
            slots.insert(ObjectIdentifier(buffer))
        }
        #expect(slots.count == ring.slotCount, "スロットごとの置き場が揃っていない")
        #expect(storage.reallocations == 1, "別のスロットで取り直した")
    }

    @Test("空の置き場を貸さない置き場は、0 個の要求でも最小の容量を取る (本体の面の置き場)")
    func anEagerStorageTakesTheMinimumForAnEmptyRequest() throws {
        let gpu = try RenderDevice()
        let ring = FrameRing(gpu: gpu)
        let storage = GrowableBuffer(
            gpu: gpu, ring: ring, stride: MemoryLayout<Float>.stride, minimumCapacity: 16,
            label: "mokume.test.eager")
        try ring.advance()
        let buffer = try storage.buffer(holding: 0)
        #expect(buffer !== (try gpu.emptyBuffer()))
        #expect(storage.capacity == 16 && storage.reallocations == 1)
    }
}
