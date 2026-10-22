// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing

@testable import MokumeCore

/// 組み込みの図形のパイプラインを、面どうしで分け合うことの検査 (#2785)。GPU を要する。
///
/// 組み込みのライブラリとパイプラインは、面の寸法にも内容にも依らない。面を作るたびに組み直すと、
/// 描き場所を動的に作る場面が同じ費用を払い続ける。分け合うのは**組み上がったら変わらないもの
/// だけ**で、描くたびに番地を書き換える引数のテーブルは面ごとに持つ。
@Suite(
    "組み込みの図形のパイプラインは面で分け合う",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShapePipelineSharingTests {
    private let black = Color.linear(red: 0, green: 0, blue: 0)

    /// パイプラインが抱える描画用の状態を、実体で見分けられる形で全部並べる。
    ///
    /// 奥行きの扱いは含めない手もある (`includingDepth: false`)。同じ物理 GPU の上で作った別の
    /// ``RenderDevice`` のあいだでは、同じ記述の奥行きの扱いを Metal が同じ実体で返すことがある。
    private func objects(of pipeline: ShapePipeline, includingDepth: Bool = true) -> [ObjectIdentifier] {
        let groups =
            [
                pipeline.states, pipeline.solidStates, pipeline.unitShapeStates,
                pipeline.solidStrokeStates,
            ] + ShapePipeline.formFlagCombinations.map { pipeline.formStates(for: $0) }
        var all: [ObjectIdentifier] = []
        for group in groups {
            all += [
                ObjectIdentifier(group.composite), ObjectIdentifier(group.blend),
                ObjectIdentifier(group.replace),
            ]
        }
        all += [
            ObjectIdentifier(pipeline.unitShapeShadowState),
            ObjectIdentifier(pipeline.solidStrokeShadowState),
            ObjectIdentifier(pipeline.shadowState),
        ]
        for depth in [pipeline.flatDepthState, pipeline.solidDepthState, pipeline.replaceDepthState]
        where includingDepth {
            if let depth { all.append(ObjectIdentifier(depth)) }
        }
        return all
    }

    // MARK: - 組む回数

    @Test("同じ GPU の面を 12 個作っても、組み込みのライブラリは組み直さず、パイプラインは同じ実体")
    func manySurfacesShareTheBuiltIns() throws {
        let gpu = try RenderDevice()
        let first = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let builtAfterFirst = gpu.shaders.librariesBuilt
        #expect(builtAfterFirst["Shapes"] == 1)
        #expect(builtAfterFirst["UnitShape"] == 1)

        var surfaces: [Canvas] = [first]
        for _ in 0..<6 { surfaces.append(try CanvasFixture.make(gpu: gpu, width: 16, height: 16)) }
        for _ in 0..<5 { surfaces.append(try first.createGraphics(16, 16)) }

        #expect(surfaces.count == 12)
        #expect(gpu.shaders.librariesBuilt == builtAfterFirst, "面を足してライブラリを組み直した")
        let reference = objects(of: first.pipeline)
        #expect(reference.count == 30 + 3 + 3, "混ぜ方別 10 組 (30 本) + 影 3 本 + 奥行きの扱い 3 つ")
        for surface in surfaces {
            #expect(surface.pipeline === first.pipeline)
            let own = objects(of: surface.pipeline)
            #expect(own == reference, "パイプラインが面ごとの実体になっている")
        }
    }

    @Test("別の GPU とは分け合わない — GPU ごとに組む")
    func devicesDoNotShare() throws {
        let first = try RenderDevice()
        let second = try RenderDevice()
        let a = try CanvasFixture.make(gpu: first, width: 16, height: 16)
        let b = try CanvasFixture.make(gpu: second, width: 16, height: 16)
        #expect(a.pipeline !== b.pipeline)
        #expect(first.shaders.librariesBuilt["Shapes"] == 1)
        #expect(second.shaders.librariesBuilt["Shapes"] == 1)
        #expect(
            Set(objects(of: a.pipeline, includingDepth: false))
                .isDisjoint(with: objects(of: b.pipeline, includingDepth: false)))
    }

    @Test("引数のテーブルは分け合わない — 面ごとに持つ")
    func argumentTablesAreOwnedBySurface() throws {
        let gpu = try RenderDevice()
        let a = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let b = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        let layer = try a.createGraphics(16, 16)
        let tables = [a, b, layer].map { ObjectIdentifier($0.argumentTable) }
        #expect(Set(tables).count == 3)
    }

    // MARK: - 面どうしで漏れない

    /// 面ごとに違う色・シェーダの値・切り抜き・混ぜ方・光・影で描く。
    @MainActor
    private func scene(_ canvas: Canvas, _ shader: Shader, round: Int, hue: Float) throws {
        try canvas.draw {
            canvas.background(.linear(red: hue * 0.2, green: 0.1, blue: 0.1 + Float(round) * 0.05))
            canvas.noStroke()
            canvas.lights()
            canvas.shadows(round % 2 == 0)
            canvas.clip(4, 4, 60 - Float(round) * 4, 60)
            canvas.fill(.linear(red: hue, green: 0.4, blue: 1 - hue))
            canvas.rect(0, 0, 64, 32)
            canvas.blendMode(round % 2 == 0 ? .add : .blend)
            canvas.circle(32, 32, 40)
            canvas.blendMode(.blend)
            canvas.shader(shader)
            shader.set("level", .number(hue))
            canvas.rect(8, 40, 20, 20)
            canvas.resetShader()
            canvas.push()
            canvas.translate(44, 44, 0)
            canvas.box(14)
            canvas.pop()
        }
    }

    private static let level = """
        float4 paint(Fragment in, Values values) { return float4(values.level, 0.3, 0.2, 1); }
        """

    @Test("2 面を交互に描いても、面どうしで束ねが漏れず、それぞれ単独で描いた絵と全 Float16 bit 一致する")
    func interleavedSurfacesMatchTheirSoloPictures() throws {
        let hues: [Float] = [0.9, 0.2]
        func bits(_ canvas: Canvas) throws -> [UInt16] {
            try canvas.target.readPixels().components.map(\.bitPattern)
        }

        // 単独 — 別々の GPU で、それぞれ自分の絵だけを描く
        var solo: [[UInt16]] = []
        for hue in hues {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
            let shader = try canvas.makeShader(Self.level, values: ["level": 0])
            for round in 0..<4 { try scene(canvas, shader, round: round, hue: hue) }
            solo.append(try bits(canvas))
        }

        // 交互 — 1 つの GPU で、待たずに投入して重ねる
        let gpu = try RenderDevice()
        let canvases = try hues.map { _ in try CanvasFixture.make(gpu: gpu, width: 64, height: 64) }
        let shaders = try canvases.map { try $0.makeShader(Self.level, values: ["level": 0]) }
        for round in 0..<4 {
            for (index, hue) in hues.enumerated() {
                try scene(canvases[index], shaders[index], round: round, hue: hue)
            }
        }
        for index in hues.indices {
            let image = try bits(canvases[index])
            #expect(!image.isEmpty)
            #expect(image == solo[index], "面 \(index) の絵が、単独で描いた絵と違う")
        }
        #expect(solo[0] != solo[1], "2 面の絵が同じでは、漏れを見分けられない")
    }

    // MARK: - 寿命

    @Test("面を作っては捨てても、分け合うパイプラインは 1 つのまま累積しない")
    func discardingSurfacesDoesNotAccumulate() throws {
        let gpu = try RenderDevice()
        weak var survivor: ShapePipeline?
        weak var lastSurface: Canvas?
                try autoreleasepool {
            let keeper = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
            survivor = keeper.pipeline
        }
        // 面は全部捨てた。GPU が生きている間は、分け合うものは残る
        #expect(survivor != nil, "最初の面を捨てたら、分け合うパイプラインまで消えた")
        try autoreleasepool {
            for _ in 0..<12 {
                let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
                #expect(canvas.pipeline === survivor)
                try canvas.draw { canvas.background(black) }
                lastSurface = canvas
            }
        }
        try gpu.settle()
        #expect(lastSurface == nil, "面が捨てられていない")
        #expect(gpu.shaders.librariesBuilt["Shapes"] == 1)
    }

    @Test("GPU を畳めば、分け合うパイプラインも一緒に畳まれる")
    func pipelineDoesNotKeepTheDeviceAlive() throws {
        weak var device: RenderDevice?
        weak var pipeline: ShapePipeline?
        try autoreleasepool {
            let gpu = try RenderDevice()
            device = gpu
            let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
            pipeline = canvas.pipeline
            try canvas.draw { canvas.background(black) }
            try gpu.settle()
        }
        #expect(device == nil, "分け合うパイプラインが GPU を抱え返している")
        #expect(pipeline == nil, "GPU を畳んでもパイプラインが残っている")
    }
}
