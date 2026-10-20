// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 隣り合う画素ごとの組み込みの効果を 1 段にまとめる直し ([#2371] の直し 2) の検査。
///
/// まとめ方 (``Effect/fusingPixelStages(_:)``) は GPU を使わず、並びだけで決まる。画素は GPU を要し、
/// 段ごとに別のパスで描いた絵と**段の間の `.rgba16Float` への丸めの分だけ**しか違わない約束である。
///
/// [#2371]: https://github.com/mokume-metal/mokume/issues/2371
struct EffectFusionPlanTests {
    private func passes(_ effects: [Effect]) -> [EffectPass] {
        effects.flatMap { $0.passes(drawnPerOutput: 1) }
    }

    private func kinds(_ passes: [EffectPass]) -> [BuiltinEffectKind] { passes.map(\.builtinKind) }

    @Test("隣り合う画素ごとの効果は 1 段にまとまり、段の数と中身が設定に並ぶ")
    func adjacentPixelStagesBecomeOnePass() {
        let fused = Effect.fusingPixelStages(
            passes([.invert(), .monochrome(amount: 0.5), .vignette(amount: 0.4), .adjust(brightness: 0.1)]))
        #expect(kinds(fused) == [.fused])
        let pass = fused[0]
        #expect(pass.control.0.y == 4, "段の数")
        #expect(pass.program.map { BuiltinEffectKind(rawValue: UInt32($0.x)) } == [.invert, .monochrome, .vignette, .adjust])
        #expect(pass.program[1].y == 0.5 && pass.program[2].y == 0.4)
        #expect(pass.program[3].y == 0.1, "色調整の p0 (明るさ)")
        #expect(pass.input == .current && pass.output == .next && pass.shader == nil)
    }

    @Test("1 段だけの並びはそのまま。まとめた段を作らない")
    func aSinglePixelStageStaysAsItIs() {
        let single = passes([.invert(amount: 0.3)])
        let fused = Effect.fusingPixelStages(single)
        #expect(kinds(fused) == [.invert])
        #expect(fused[0].control.0 == single[0].control.0)
    }

    @Test("近所を読む段はまとめず、まとめられる連なりを分ける")
    func neighbourReadingStagesBreakTheRun() {
        let fused = Effect.fusingPixelStages(
            passes([.invert(), .monochrome(), .blur(radius: 2), .vignette(amount: 0.5), .fringe(amount: 0.3), .adjust(contrast: 0.2), .invert()]))
        // 反転 + 単色化 | ぼかし(横・縦) | 周辺減光(1 段) | 色ずれ | 色調整 + 反転
        #expect(kinds(fused) == [.fused, .blurX, .blurY, .vignette, .fringe, .fused])
        #expect(fused[0].control.0.y == 2)
        #expect(fused[5].control.0.y == 2)
    }

    @Test("まとめる段の数には上限があり、越えたら次のまとめた段へ回る")
    func theRunIsCappedAndContinues() {
        let limit = Effect.fusedStageLimit
        let fused = Effect.fusingPixelStages(passes(Array(repeating: .invert(), count: limit + 1)))
        // 上限ちょうどの 1 本 + 余りの 1 段 (1 段だけなのでそのまま)
        #expect(kinds(fused) == [.fused, .invert])
        #expect(fused[0].control.0.y == Float(limit))
        let twice = Effect.fusingPixelStages(passes(Array(repeating: .invert(), count: limit + 2)))
        #expect(kinds(twice) == [.fused, .fused])
        #expect(twice[1].control.0.y == 2)
    }

    @Test("上限の段が設定の枠に収まる")
    func theLimitFitsTheControlBlock() {
        let used = (Effect.fusedStageLimit + 2) * MemoryLayout<SIMD4<Float>>.stride
        #expect(used <= EffectPipeline.controlSize)
        #expect(EffectPipeline.controlOffset + EffectPipeline.controlSize <= EffectPipeline.frameOffset)
        #expect(EffectPipeline.frameOffset + EffectPipeline.frameSize <= EffectPipeline.valuesOffset)
        #expect(
            EffectPipeline.valuesOffset + EffectPipeline.valueSlotCapacity * MemoryLayout<Float>.stride
                <= EffectPipeline.passStride)
        #expect(EffectPipeline.passStride % 256 == 0)
    }
}

/// まとめた段の画素が、段ごとに別のパスで描いた絵と**丸めの分だけ**しか違わないこと。GPU を要する。
@Suite(
    "画素ごとの効果のまとめ",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct EffectFusionPixelTests {
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
    }

    private func scene(on canvas: Canvas) {
        canvas.background(.display(red: 0.02, green: 0.03, blue: 0.06))
        canvas.noStroke()
        canvas.fill(.display(red: 1, green: 0.85, blue: 0.3))
        canvas.circle(24, 24, 26)
        canvas.fill(.display(red: 0.2, green: 0.5, blue: 1, alpha: 0.6))
        canvas.rect(34, 34, 26, 22)
    }

    /// 作業空間の値そのもの。
    private func picture(_ effects: [Effect], fuses: Bool = true) throws -> (values: [Float], passes: Int) {
        let canvas = try makeCanvas()
        try canvas.effectPipeline().fusesPixelStages = fuses
        try canvas.draw {
            scene(on: canvas)
            canvas.effects(effects)
        }
        let pixels = try canvas.target.readPixels()
        var values: [Float] = []
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let pixel = pixels[x, y]
                values += [pixel.red, pixel.green, pixel.blue, pixel.alpha]
            }
        }
        return (values, canvas.effectPassesEncoded)
    }

    private static let chains: [(name: String, effects: [Effect])] = [
        ("4 段", [.invert(amount: 0.7), .monochrome(amount: 0.6), .vignette(amount: 0.65), .adjust(brightness: 0.1, contrast: 0.2, saturation: -0.3)]),
        ("順を入れ替えた 4 段", [.adjust(brightness: -0.1, contrast: 0.3, saturation: 0.4), .vignette(amount: 0.8), .monochrome(amount: 0.3), .invert(amount: 1)]),
        ("同じ種類を重ねる", [.invert(amount: 0.5), .invert(amount: 0.5), .vignette(amount: 0.4), .vignette(amount: 0.4)]),
        ("上限を越える連なり", Array(repeating: Effect.invert(amount: 0.4), count: 8)),
    ]

    /// 段ごとに別のパスで描いた絵 (``EffectPipeline/fusesPixelStages`` を偽にして得る) と比べる。
    @Test("まとめた絵は、段ごとの絵と Float16 の丸めの分しか違わない", arguments: Array(0..<4))
    func fusedMatchesSeparatePasses(_ index: Int) throws {
        let chain = Self.chains[index]
        let fused = try picture(chain.effects)
        let apart = try picture(chain.effects, fuses: false)
        #expect(fused.passes < apart.passes, "\(chain.name): 段が減っていない")
        #expect(apart.passes == chain.effects.count, "\(chain.name): まとめない経路は効果ごとに 1 段")
        var worst: Float = 0
        for (a, b) in zip(fused.values, apart.values) {
            // 段ごとに Float16 へ丸める分 (1 付近で 2^-11 ≒ 5e-4) が段の数だけ積もりうる
            worst = max(worst, abs(a - b))
        }
        #expect(worst <= 4e-3, "\(chain.name): 差の最大が \(worst)")
    }

    @Test("まとめても、効かない段は絵を変えない (1 つの効果だけの絵と 1 ビットも変わらない)")
    func inactiveStagesAddNothing() throws {
        let alone = try picture([.invert(amount: 0.5)])
        let fused = try picture([.invert(amount: 0.5), .monochrome(amount: 0), .vignette(amount: 0), .adjust()])
        #expect(fused.passes == 1)
        #expect(alone.values == fused.values)
    }

    @Test("段の数は、まとめた数だけ減る")
    func passCountDropsByTheFusedStages() throws {
        let four = try picture([.invert(), .monochrome(), .vignette(amount: 0.5), .adjust(brightness: 0.1)])
        #expect(four.passes == 1)
        let cut = try picture([.invert(), .monochrome(), .blur(radius: 2), .vignette(amount: 0.5), .adjust(brightness: 0.1)])
        // まとめた段 + ぼかし 2 段 + まとめた段
        #expect(cut.passes == 4)
    }
}
