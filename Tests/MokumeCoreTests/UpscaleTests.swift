// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Testing

@testable import MokumeCore

/// 描く細かさと出す細かさを分ける (拡大の段)。GPU を要する。
@Suite(
    "描く細かさと出す細かさ",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct UpscaleTests {
    private static let width = 128
    private static let height = 96

    /// ここだけ `CanvasFixture` を通さない。**細かさと拡大の仕方が引数**なので、
    /// `Canvas(output:gpu:pixelDensity:upscale:)` を直に呼ぶ必要がある — fixture が
    /// 使う `Canvas(target:gpu:)` は細かさ 1・`.spatial` に決め打った convenience で、
    /// ここで確かめたいものがそこで潰れる。
    private func makeCanvas(density: Float, upscale: Upscale = .spatial) throws -> Canvas {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: Self.width, height: Self.height)
        return try Canvas(output: output, gpu: gpu, pixelDensity: density, upscale: upscale)
    }

    /// 位置が分かる絵。**左上の 4 分の 1 だけを塗る。**
    private func quadrant(on canvas: Canvas) {
        canvas.background(.display(red: 0, green: 0, blue: 0))
        canvas.noStroke()
        canvas.fill(.display(red: 1, green: 1, blue: 1))
        canvas.rect(0, 0, Float(Self.width) / 2, Float(Self.height) / 2)
    }

    private func fingerprint(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 分かれていること

    @Test("細かさを下げても、出す先の大きさは宣言したまま")
    func theOutputKeepsItsDeclaredSize() throws {
        let canvas = try makeCanvas(density: 0.5)
        #expect(canvas.output.width == Self.width)
        #expect(canvas.output.height == Self.height)
        #expect(canvas.pixelWidth == Self.width / 2)
        #expect(canvas.pixelHeight == Self.height / 2)
        // スケッチが見る座標は出す細かさのまま
        #expect(canvas.width == Float(Self.width))
        #expect(canvas.height == Float(Self.height))
        #expect(canvas.screenX(Float(Self.width), 0) == Float(Self.width))
    }

    @Test("細かさを変えても、描いたものは同じ場所に出る")
    func theSamePlaceIsDrawnAtEveryDensity() throws {
        for density in [Float(1), 0.5, 0.25] {
            let canvas = try makeCanvas(density: density)
            try canvas.draw { quadrant(on: canvas) }
            let pixels = canvas.output.pixels
            // 境目からは離れて見る (拡大は境目をなめらかにする)
            #expect(pixels[16, 12].red > 0.9, "\(density) の内側")
            #expect(pixels[Self.width - 16, Self.height - 12].red < 0.1, "\(density) の外側")
            #expect(pixels[Self.width - 16, 12].red < 0.1, "\(density) の右上")
            #expect(pixels[16, Self.height - 12].red < 0.1, "\(density) の左下")
        }
    }

    @Test("切り抜きも、細かさを変えても同じ場所で切れる")
    func theClipLandsInTheSamePlaceAtEveryDensity() throws {
        for density in [Float(1), 0.5, 0.25] {
            let canvas = try makeCanvas(density: density)
            try canvas.draw {
                canvas.background(.display(red: 0, green: 0, blue: 0))
                canvas.noStroke()
                canvas.fill(.display(red: 1, green: 1, blue: 1))
                // 切り抜きは出す細かさの座標で指定する
                canvas.clip(0, 0, Float(Self.width) / 2, Float(Self.height) / 2)
                canvas.rect(0, 0, Float(Self.width), Float(Self.height))
            }
            let pixels = canvas.output.pixels
            #expect(pixels[16, 12].red > 0.9, "\(density) の内側")
            #expect(pixels[Self.width - 16, 12].red < 0.1, "\(density) の外側")
            #expect(pixels[16, Self.height - 12].red < 0.1, "\(density) の下")
        }
    }

    @Test("細かさが 1 なら、段も置き場も 1 つも増えない")
    func nothingIsAddedAtFullDensity() throws {
        let canvas = try makeCanvas(density: 1)
        #expect(canvas.upscaleStage == nil)
        #expect(canvas.output === canvas.target)
        #expect(canvas.usesFrameHistory == false)
        try canvas.draw { quadrant(on: canvas) }
        // 効果も拡大も頼まれていないので、段のパイプラインは作られない
        #expect(canvas.effectPipelineStorage == nil)
        #expect(canvas.stagePassesUsed == 0)
    }

    @Test("細かさを下げると、描く先と出す先が別々の絵になる")
    func theDrawnAndTheShownAreSeparate() throws {
        let canvas = try makeCanvas(density: 0.5)
        #expect(canvas.upscaleStage != nil)
        #expect(canvas.output !== canvas.target)
        #expect(canvas.target.width == Self.width / 2)
    }

    // MARK: - 決定論

    @Test("空間方向では、同じ入力から 2 回とも同じ絵が返る")
    func theSpatialPathIsDeterministic() throws {
        let canvas = try makeCanvas(density: 0.5, upscale: .spatial)
        #expect(canvas.usesFrameHistory == false)
        try canvas.draw { quadrant(on: canvas) }
        let first = fingerprint(try canvas.output.encodeForDisplay().bytes)
        try canvas.draw { quadrant(on: canvas) }
        let second = fingerprint(try canvas.output.encodeForDisplay().bytes)
        #expect(first == second)
    }

    @Test("時間方向では、同じ入力から違う絵が返る — そしてそれが読める")
    func theTemporalPathDependsOnWhatCameBefore() throws {
        let canvas = try makeCanvas(density: 0.5, upscale: .temporal)
        // **代償は走っている側から読める** (ADR-0015 の影響欄)
        #expect(canvas.usesFrameHistory == true)
        try canvas.draw { quadrant(on: canvas) }
        let first = fingerprint(try canvas.output.encodeForDisplay().bytes)
        try canvas.draw { quadrant(on: canvas) }
        let second = fingerprint(try canvas.output.encodeForDisplay().bytes)
        #expect(first != second)
    }

    /// 描く細かさでは捉えきれない細かさの模様。**低い細かさで描くと嘘の絵になる。**
    ///
    /// 縞は `quad` (三角形の経路) で描く。`rect` は距離関数で縁を滑らかにする (#752) ので、
    /// 描く細かさに収まらない縞を 1 枚の中で平均してしまい、「嘘の縞」が出ない —
    /// ここで見たいのは、縁を滑らかにしない絵の嘘を時間方向が平均へ収めることである
    private func tooFine(on canvas: Canvas) {
        canvas.background(.display(red: 0, green: 0, blue: 0))
        canvas.noStroke()
        canvas.fill(.display(red: 1, green: 1, blue: 1))
        for column in stride(from: 0, to: Self.width, by: 3) {
            let left = Float(column), right = left + 1, bottom = Float(Self.height)
            canvas.quad(left, 0, right, 0, right, bottom, left, bottom)
        }
    }

    /// 中ほどの 1 行を横に読んだときの、明るさの並び。
    private func row(_ canvas: Canvas) -> [Float] {
        let pixels = canvas.output.pixels
        return (8..<(Self.width - 8)).map { pixels[$0, Self.height / 2].red }
    }

    @Test("時間方向は、描く細かさで捉えきれない模様を平均へ収める")
    func theTemporalPathAveragesWhatCannotBeResolved() throws {
        let spatial = try makeCanvas(density: 0.5, upscale: .spatial)
        try spatial.draw { tooFine(on: spatial) }
        let single = row(spatial)

        let temporal = try makeCanvas(density: 0.5, upscale: .temporal)
        for _ in 0..<32 { try temporal.draw { tooFine(on: temporal) } }
        let stacked = row(temporal)

        func spread(_ values: [Float]) -> Float {
            (values.max() ?? 0) - (values.min() ?? 0)
        }
        func mean(_ values: [Float]) -> Float {
            values.reduce(0, +) / Float(values.count)
        }
        // **嘘の縞が消える。** 揺らして重ねるほど、描く細かさでは決められなかった
        // 明暗が平均へ収まる
        #expect(spread(stacked) < spread(single) / 2, "\(spread(stacked)) / \(spread(single))")
        // **平均は動かない。** 揺らしを戻す向きが逆なら、絵が流れて明暗の重心がずれる。
        // 3 画素に 1 画素が白いので、真の平均は 1/3
        #expect(abs(mean(stacked) - 1.0 / 3) < 0.06, "\(mean(stacked))")
    }

    // MARK: - 不透明度

    @Test("透明なところは、拡大を通しても透明のまま")
    func transparentAreasStayTransparent() throws {
        let canvas = try makeCanvas(density: 0.5)
        try canvas.draw {
            canvas.background(LinearRGBA(premultipliedRed: 0, green: 0, blue: 0, alpha: 0))
            canvas.noStroke()
            canvas.fill(LinearRGBA(straightRed: 1, green: 0.8, blue: 0.2, alpha: 0.5))
            canvas.rect(32, 24, 64, 48)
        }
        let pixels = canvas.output.pixels
        let corner = pixels[4, 4]
        #expect(corner.alpha < 0.02)
        #expect(corner.red < 0.02)
        #expect(corner.green < 0.02)
        #expect(corner.blue < 0.02)
        // 一様な内側の濃さは動かない
        #expect(abs(pixels[64, 48].alpha - 0.5) < 0.05)
    }

    @Test("表示できる範囲を超えた明るさが、拡大を通しても超えたまま残る")
    func brightnessBeyondTheDisplayRangeSurvives() throws {
        let canvas = try makeCanvas(density: 0.5)
        try canvas.draw {
            canvas.background(.display(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.fill(LinearRGBA(straightRed: 4, green: 4, blue: 4, alpha: 1))
            canvas.rect(32, 24, 64, 48)
        }
        // ADR-0011 決定 2 — 出力段まで捨てずに運ぶ
        #expect(canvas.output.pixels[64, 48].red > 1.5)
    }

    // MARK: - 増えないこと

    /// 前のフレームの控えは色だけの GPU 専用の絵で、奥行きも CPU から読める置き場も伴わない (#753)。
    @Test("時間方向の控えは色だけの GPU 専用の絵")
    func historyIsColourOnlyAndPrivate() throws {
        let canvas = try makeCanvas(density: 0.5, upscale: .temporal)
        let history = try #require(canvas.upscaleStage?.history)
        #expect(history.texture.storageMode == .private)
        #expect(history.texture.buffer == nil, "控えが置き場の上に載っている")
        #expect(history.width == Self.width)
        #expect(history.height == Self.height)
    }

    @Test("長く回しても、段の置き場が積み上がらない")
    func nothingGrowsWhileItRuns() throws {
        let canvas = try makeCanvas(density: 0.5)
        try canvas.draw { quadrant(on: canvas) }
        let pipeline = try #require(canvas.effectPipelineStorage)
        let scratch = pipeline.scratchBuilt
        let buffers = pipeline.buffersBuilt
        let tables = pipeline.tablesBuilt
        for _ in 0..<120 { try canvas.draw { quadrant(on: canvas) } }
        #expect(pipeline.scratchBuilt == scratch)
        #expect(pipeline.buffersBuilt == buffers)
        #expect(pipeline.tablesBuilt == tables)
        #expect(canvas.upscaleStage?.framesScaled == 121)
        // 段は毎フレーム 1 枠しか取らない (効果を頼んでいないので)
        #expect(canvas.stagePassesUsed == 1)
    }

    // MARK: - 効果と同居すること

    @Test("効果をかけたまま細かさを下げても、段どうしが取り合わない")
    func effectsAndUpscaleShareTheSameNumbering() throws {
        let canvas = try makeCanvas(density: 0.5)
        try canvas.draw { quadrant(on: canvas) }
        let plain = fingerprint(try canvas.output.encodeForDisplay().bytes)

        try canvas.draw {
            quadrant(on: canvas)
            canvas.effects([.invert(), .vignette(amount: 0.8)])
        }
        let affected = fingerprint(try canvas.output.encodeForDisplay().bytes)
        #expect(plain != affected)
        // 効果 2 つ (2 枠: 反転・周辺減光。最後の段が描く先へ直接書くので写し戻しは無い)
        // + 拡大の 1 枠
        #expect(canvas.stagePassesUsed == 3)
        #expect(canvas.output.width == Self.width)
    }

    // MARK: - 断ること

    @Test("引き受けない細かさは、組み立ての時点で断られる")
    func refusesADensityItCannotHonour() throws {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 32, height: 32)
        for density in [Float(0), -1, 2, .nan, .infinity] {
            #expect(throws: RenderFailure.self) {
                _ = try Canvas(
                    output: output, gpu: gpu, pixelDensity: density, upscale: .spatial)
            }
        }
    }

    // MARK: - 出口が揃うこと

    @Test("画面へ差し出す絵も、書き出す絵も、同じ 1 枚から出る")
    func everyExitReceivesTheSamePicture() throws {
        let gpu = try RenderDevice()
        let sketch = HalfDensitySketch()
        let runtime = try SketchRuntime(sketch: sketch, gpu: gpu, clock: .frameIndex(frameRate: 60))
        try runtime.advance()
        // 走らせる側が持つ描画先そのものが出す先なので、出口ごとの分岐が要らない
        #expect(runtime.target === runtime.canvas.output)
        #expect(runtime.target.width == 128)
        #expect(runtime.canvas.pixelWidth == 64)
        #expect(runtime.usesFrameHistory == false)
    }

    /// 細かさを下げた作品。設定から通っていることを見るために置く。
    private final class HalfDensitySketch: Sketch {
        var settings: SketchSettings {
            SketchSettings(width: 128, height: 96, pixelDensity: 0.5)
        }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            noStroke()
            fill(.display(red: 1, green: 1, blue: 1))
            rect(0, 0, 64, 48)
        }
    }
}
