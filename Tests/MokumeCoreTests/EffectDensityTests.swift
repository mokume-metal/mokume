// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// ぼかし・にじみの半径は出す画素で測る ([#1545])。GPU を要する。
///
/// `pixelDensity` の説明は「座標は出す細かさのままなので、スケッチのコードは 1 行も
/// 変わらない」と言う。線の太さは #1488 でそう揃えた。半径も同じで、細かさを変えても
/// ぼけの幅は変わらない。直す前は、半径を描く画素で測っていたので、ぼけの幅が
/// ちょうど 1/細かさ 倍に広がっていた (細かさ 0.5 で 2 倍)。
///
/// 面は出す大きさ 160×160。「幅」は、黒地に白い縦帯 `rect(80, 0, 80, 160)` を描いて
/// 効果を掛け、出す画素の 80 行目の線形の赤が縁で 0.1 から 0.9 へ上がるまでの距離
/// (出す画素・線形補間) である。
///
/// [#1545]: https://github.com/mokume-metal/mokume/issues/1545
@Suite(
    "ぼかし・にじみの半径は出す画素で測る",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct EffectDensityTests {
    /// 出す大きさ 160×160 の面。`CanvasFixture` を通さない理由は `UpscaleTests.makeCanvas`
    /// と同じ (細かさが引数なので、`Canvas(output:gpu:pixelDensity:upscale:)` を直に呼ぶ)。
    private func makeCanvas(density: Float) throws -> Canvas {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 160, height: 160)
        return try Canvas(output: output, gpu: gpu, pixelDensity: density, upscale: .spatial)
    }

    /// 黒地に白い縦帯。
    private static func band(on canvas: Canvas) {
        canvas.background(0)
        canvas.noStroke()
        canvas.fill(255)
        canvas.rect(80, 0, 80, 160)
    }

    /// 行の赤が `low` から `high` へ上がるまでの距離 (画素・線形補間)。
    private static func rise(of row: [Float], from low: Float = 0.1, to high: Float = 0.9) -> Float {
        func crossing(_ level: Float) -> Float {
            for x in 1..<row.count where row[x - 1] < level && row[x] >= level {
                return Float(x - 1) + (level - row[x - 1]) / (row[x] - row[x - 1])
            }
            return .nan
        }
        return crossing(high) - crossing(low)
    }

    /// 80 行目の赤 (線形)。
    private static func row(of buffer: PixelBuffer) -> [Float] {
        (0..<buffer.width).map { buffer[$0, 80].red }
    }

    /// 帯に効果を掛けた縁の幅 (出す画素)。
    private func width(of effect: Effect, density: Float) throws -> Float {
        let canvas = try makeCanvas(density: density)
        try canvas.draw {
            Self.band(on: canvas)
            canvas.effects([effect])
        }
        return Self.rise(of: Self.row(of: try canvas.output.readPixels()))
    }

    // MARK: - ぼかし (完了条件 1・2)

    /// ±15% は、拡大の段そのものが縁を 0.80 → 2.08 画素に柔らかくする分を見込んだ幅。
    /// 直す前は細かさ 0.75 で 1.33 倍、0.5 で 2.0 倍だった。
    @Test(
        "ぼかしの幅は、細かさを下げても変わらない",
        arguments: [Float(8), 20], [Float(0.75), 0.5])
    func blurWidthDoesNotDependOnTheDensity(radius: Float, density: Float) throws {
        let full = try width(of: .blur(radius: radius), density: 1)
        let reduced = try width(of: .blur(radius: radius), density: density)
        #expect(full.isFinite && reduced.isFinite, "幅が測れない: \(full) / \(reduced)")
        #expect(
            abs(reduced / full - 1) <= 0.15,
            "細かさ \(density) の幅 \(reduced)、細かさ 1 の幅 \(full) (比 \(reduced / full))")
    }

    // MARK: - にじみ (完了条件 3)

    /// 黒地の白い円に掛けたにじみの、中心から 10 画素より外の赤の和。
    private func glowOutside(density: Float) throws -> Float {
        let canvas = try makeCanvas(density: density)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.circle(80, 80, 8)
            canvas.effects([.bloom(amount: 1, threshold: 0.3, radius: 12)])
        }
        let buffer = try canvas.output.readPixels()
        var sum: Float = 0
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let dx = Float(x) + 0.5 - 80
                let dy = Float(y) + 0.5 - 80
                if dx * dx + dy * dy > 100 { sum += buffer[x, y].red }
            }
        }
        return sum
    }

    /// 直す前は、細かさ 0.5 の和が細かさ 1 の 2.37 倍だった (9.35 → 22.17)。
    @Test("にじみの広がりは、細かさを下げても変わらない")
    func bloomSpreadDoesNotDependOnTheDensity() throws {
        let full = try glowOutside(density: 1)
        let reduced = try glowOutside(density: 0.5)
        #expect(full > 0, "にじみが出ていない")
        let ratio = reduced / full
        #expect((0.67...1.5).contains(ratio), "細かさ 0.5 の和 \(reduced)、細かさ 1 の和 \(full) (比 \(ratio))")
    }

    // MARK: - 変わらないもの (完了条件 4)

    /// 細かさ 1 では描く画素と出す画素が同じなので、掛ける数はちょうど 1 — 半径のビットが
    /// そのまま段へ渡り、絵は 1 ビットも変わらない。描き場所の面 (いつも細かさ 1) も同じ。
    @Test("細かさ 1 の面と描き場所の面では、半径をそのまま使う")
    func keepsTheRadiusWhereTheDensityIsOne() throws {
        let canvas = try makeCanvas(density: 1)
        #expect(canvas.effectRadiusScale == 1)
        let host = try makeCanvas(density: 0.5)
        let layer = try host.createGraphics(160, 160)
        #expect(layer.effectRadiusScale == 1)
        #expect(host.effectRadiusScale == 0.5)
        // にじみを回す段の下限も、細かさ 1 ではこれまでと同じ 1/4
        #expect(Effect.bloomFloor(drawnPerOutput: 1) == 2)
        #expect(Effect.bloomFloor(drawnPerOutput: 0.5) == 1)
    }

    /// 描き場所の面はいつも細かさ 1 で作られるので、細かさ 0.5 のスケッチでも幅は変わらない
    /// (直す前も 9.82 / 9.72 で、ここは見張り)。
    @Test("細かさ 0.5 のスケッチの描き場所でも、ぼかしの幅は変わらない")
    func graphicsLayerKeepsItsBlurWidth() throws {
        let full = try width(of: .blur(radius: 8), density: 1)
        let host = try makeCanvas(density: 0.5)
        let layer = try host.createGraphics(160, 160)
        layer.beginDraw()
        Self.band(on: layer)
        layer.effects([.blur(radius: 8)])
        layer.endDraw()
        let got = Self.rise(of: Self.row(of: try layer.output.readPixels()))
        #expect(abs(got / full - 1) <= 0.05, "描き場所の幅 \(got)、細かさ 1 の幅 \(full)")
    }

    /// 周辺減光は面の大きさに比べて決まるので、細かさによらない (ここは見張り)。
    @Test("周辺減光の隅の値は、細かさによらない")
    func vignetteCornerDoesNotDependOnTheDensity() throws {
        func corner(density: Float) throws -> Float {
            let canvas = try makeCanvas(density: density)
            try canvas.draw {
                canvas.background(255)
                canvas.effects([.vignette(amount: 0.8)])
            }
            return try canvas.output.readPixels()[2, 2].red
        }
        let full = try corner(density: 1)
        let reduced = try corner(density: 0.5)
        #expect(abs(reduced - full) <= 0.01, "細かさ 0.5 で \(reduced)、細かさ 1 で \(full)")
    }
}
