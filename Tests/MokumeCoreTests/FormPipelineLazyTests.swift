// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing

@testable import MokumeCore

/// 基本図形のパイプラインを、使うフレームの頭で 1 本ずつ組むことの検査 (#3114)。GPU を要する。
///
/// 旗の組 12 × 混ぜ方 3 列の 36 本を `Canvas` を作るときに全部組むと、Metal のコンパイルの
/// キャッシュが無い起動が 1.5 秒延びた。使うまで組まない形にして、そのフレームの絵が
/// 先に組んでおいた場合と変わらないことを固定する。
@Suite(
    "基本図形のパイプラインは使うときに組む",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FormPipelineLazyTests {
    private func makeCanvas(gpu: RenderDevice) throws -> Canvas {
        try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
    }

    /// 旗の組も混ぜ方も違う基本図形を、初めて使うフレームに並べる。
    @MainActor
    private func scene(_ canvas: Canvas) throws {
        try canvas.draw {
            canvas.background(.linear(red: 0.1, green: 0.1, blue: 0.2))
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(3)
            canvas.fill(.linear(red: 0.9, green: 0.3, blue: 0.2))
            canvas.circle(20, 20, 24)
            canvas.rect(36, 6, 20, 20)
            canvas.noFill()
            canvas.line(4, 40, 60, 52)
            canvas.noStroke()
            canvas.fill(.linear(red: 0.2, green: 0.8, blue: 0.4))
            canvas.blendMode(.add)
            canvas.rect(8, 44, 40, 14)
            canvas.blendMode(.multiply)
            canvas.circle(44, 44, 30)
            canvas.blendMode(.replace)
            canvas.rect(0, 0, 6, 6)
        }
    }

    private func bits(_ canvas: Canvas) throws -> [UInt16] {
        try canvas.target.readPixels().components.map(\.bitPattern)
    }

    @Test("Canvas を作った時点で組んでいる基本図形のパイプラインは、既定の描き方の 1 本だけ")
    func creatingACanvasBuildsOnlyTheDefaultForm() throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu: gpu)
        #expect(canvas.pipeline.builtFormStateCount == 1)
        // 全部組むと 36 本。1 本だけなのは、36 本の組み方 (12 組 × 3 列) が崩れていないからでもある
        #expect(ShapePipeline.formFlagCombinations.count * 3 == 36)
    }

    @Test("使った組だけが増え、同じ組は 2 度目のフレームで組み直さない")
    func onlyUsedFormsAreBuiltAndReused() throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu: gpu)
        try canvas.draw {
            canvas.fill(.linear(red: 1, green: 0, blue: 0))
            canvas.noStroke()
            canvas.rect(8, 8, 16, 16)  // 軸に沿う矩形の塗りだけ・重ねる = 旗 1 の blend
        }
        // 起動の 1 本 (circle の既定) + 旗 1 の blend
        #expect(canvas.pipeline.builtFormStateCount == 2)
        let first = canvas.pipeline.builtFormState(for: FormInstance.fillsFlag, mode: .blend)

        try canvas.draw {
            canvas.fill(.linear(red: 0, green: 1, blue: 0))
            canvas.noStroke()
            canvas.rect(30, 8, 16, 16)
        }
        #expect(canvas.pipeline.builtFormStateCount == 2, "同じ組を 2 度目のフレームで組み直した")
        #expect(
            canvas.pipeline.builtFormState(for: FormInstance.fillsFlag, mode: .blend) === first)

        // 同じ旗でも混ぜ方の列が違えば別の 1 本
        try canvas.draw {
            canvas.blendMode(.replace)
            canvas.fill(.linear(red: 0, green: 0, blue: 1))
            canvas.noStroke()
            canvas.rect(8, 30, 16, 16)
        }
        #expect(canvas.pipeline.builtFormStateCount == 3)
    }

    @Test("初めて使う組を組むフレームの絵は、全部を先に組んでおいた場合と全 Float16 bit 一致する")
    func firstUseFrameMatchesPrebuiltPicture() throws {
        let lazy = try makeCanvas(gpu: RenderDevice())
        let prebuilt = try makeCanvas(gpu: RenderDevice())
        for flags in ShapePipeline.formFlagCombinations {
            for mode: BlendMode in [.multiply, .blend, .replace] {
                _ = try prebuilt.pipeline.formState(for: flags, mode: mode)
            }
        }
        #expect(prebuilt.pipeline.builtFormStateCount == 36)
        #expect(lazy.pipeline.builtFormStateCount == 1)

        try scene(lazy)
        try scene(prebuilt)
        let lazyBits = try bits(lazy)
        #expect(lazyBits == (try bits(prebuilt)), "組みながら描いたフレームの絵が、先に組んだ場合と違う")
        #expect(lazy.pipeline.builtFormStateCount > 1, "この絵が新しい組を使っていない")
        #expect(lazy.pipeline.builtFormStateCount < 36)
        // 絵が空では、一致の意味が無い
        #expect(lazyBits.contains { $0 != 0 })
    }
}
