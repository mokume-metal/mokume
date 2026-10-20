// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 組み込みの効果を種別ごとに特化したパイプラインで走らせる直し ([#2371] の直し 1) の検査。
/// GPU を要する。
///
/// 特化は**速さだけの変更**で、画素は全種入りの 1 本と 1 ビットも変わらない約束である。台帳の
/// 効果の場面が通らない種別 (反転・単色化・色調整・縮める段) があるので、種別ごとに特化した絵と
/// 全種入りの絵を直に突き合わせる。パイプラインは使った種別の数だけ組まれ、使わない種別は組まれない。
///
/// [#2371]: https://github.com/mokume-metal/mokume/issues/2371
@Suite(
    "組み込みの効果の種別ごとの特化",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct EffectSpecializationTests {
    private func makeCanvas(density: Float = 1) throws -> Canvas {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 64, height: 64)
        return try Canvas(output: output, gpu: gpu, pixelDensity: density, upscale: .spatial)
    }

    private func scene(on canvas: Canvas) {
        canvas.background(.display(red: 0.02, green: 0.03, blue: 0.06))
        canvas.noStroke()
        canvas.fill(.display(red: 1, green: 0.85, blue: 0.3))
        canvas.circle(24, 24, 26)
        canvas.fill(.display(red: 0.2, green: 0.5, blue: 1))
        canvas.rect(34, 34, 26, 22)
    }

    /// 作業空間の値そのもの (4 成分のビット)。
    private func bits(
        _ effects: [Effect], specialized: Bool, density: Float = 1
    ) throws -> (bits: [UInt32], built: Int) {
        let canvas = try makeCanvas(density: density)
        try canvas.effectPipeline().specializesBuiltinEffects = specialized
        try canvas.draw {
            scene(on: canvas)
            canvas.effects(effects)
        }
        let pixels = try canvas.target.readPixels()
        var out: [UInt32] = []
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let pixel = pixels[x, y]
                out += [pixel.red, pixel.green, pixel.blue, pixel.alpha].map { $0.bitPattern }
            }
        }
        return (out, try canvas.effectPipeline().builtinStatesBuilt)
    }

    /// 組み込みの効果すべてと、それが通る段 (横・縦のぼかし・縮める / 広げる・にじみの取り出しと
    /// 合成・色ずれ…)。
    private static let effects: [(name: String, effects: [Effect], density: Float)] = [
        ("blur 全解像度", [.blur(radius: 6)], 1),
        ("blur 縮めた絵", [.blur(radius: 40)], 1),
        ("bloom", [.bloom(amount: 0.8, threshold: 0.3, radius: 10)], 1),
        ("invert", [.invert(amount: 0.7)], 1),
        ("monochrome", [.monochrome(amount: 0.6)], 1),
        ("vignette", [.vignette(amount: 0.65)], 1),
        ("fringe", [.fringe(amount: 0.7)], 1),
        ("adjust", [.adjust(brightness: 0.1, contrast: 0.2, saturation: -0.3)], 1),
        ("拡大 (細かさ 0.5)", [.invert(amount: 0.3)], 0.5),
        ("並び", [.invert(), .monochrome(amount: 0.5), .vignette(amount: 0.5), .adjust(brightness: 0.1)], 1),
    ]

    @Test("特化したパイプラインは、全種入りの 1 本と 1 ビットも違わない絵を出す", arguments: Array(0..<10))
    func specializedMatchesGeneral(_ index: Int) throws {
        let item = Self.effects[index]
        let general = try bits(item.effects, specialized: false, density: item.density)
        let specialized = try bits(item.effects, specialized: true, density: item.density)
        #expect(general.built == 0, "\(item.name): 全種入りの経路で特化したパイプラインを組んだ")
        #expect(specialized.built > 0, "\(item.name): 特化したパイプラインを通っていない")
        let differing = zip(general.bits, specialized.bits).filter { $0 != $1 }.count
        #expect(differing == 0, "\(item.name): 全種入りと \(differing) 成分違う")
    }

    @Test("組むのは使った種別の数だけで、2 フレーム目以降は組み直さない")
    func buildsOnlyTheKindsUsed() throws {
        let canvas = try makeCanvas()
        let pipeline = try canvas.effectPipeline()
        #expect(pipeline.builtinStatesBuilt == 0, "効果を使う前に組んでいる")
        for _ in 0..<3 {
            try canvas.draw {
                scene(on: canvas)
                // 反転 2 回 + 周辺減光は隣り合うので 1 段にまとまる (``Effect/fusingPixelStages(_:)``)。
                // 種別は「まとめた段」の 1 つ
                canvas.effects([.invert(), .vignette(amount: 0.5), .invert(amount: 0.5)])
            }
        }
        #expect(pipeline.builtinStatesBuilt == 1)
        try canvas.draw {
            scene(on: canvas)
            canvas.effects([.blur(radius: 4)])  // 横・縦で種別は 2 つ増える
        }
        #expect(pipeline.builtinStatesBuilt == 3)
    }

    @Test("利用者の効果は、組み込みの特化したパイプラインを組まない")
    func customEffectsDoNotBuildBuiltinStates() throws {
        let canvas = try makeCanvas()
        let tint = try canvas.makeEffect(
            "float4 effect(Pixel in, Values values) { return in.color * 0.5; }")
        try canvas.draw {
            scene(on: canvas)
            canvas.effects([.custom(tint)])
        }
        #expect(try canvas.effectPipeline().builtinStatesBuilt == 0)
    }
}
