// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 既定の混ぜ方を固定機能のブレンドへ戻したことの検査 ([#758])。GPU を要する。
///
/// 見るものは 3 つ — **列が混ぜ方でパイプラインを選び分けていること**、**固定機能の
/// ブレンドが `mokume_composite` と同じ式を出すこと** (乗算済みの source-over・
/// [ADR-0011] 決定 4)、**下地を読まなくなった断片が、形の外の余白で下地を壊さない
/// こと**である。
///
/// 3 つ目が要るのは、下地を読む入口と読まない入口で余白の扱いが違うためである —
/// 重ねる列は 0 を出せば下地がそのまま残るので捨てないが、置き換える列は書けば下地が
/// 消えるので捨てなければならない ([#771])。
///
/// [#758]: https://github.com/mokume-metal/mokume/issues/758
/// [#771]: https://github.com/mokume-metal/mokume/issues/771
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
@Suite(
    "固定機能のブレンド",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FixedFunctionBlendTests {
    private let black = LinearRGBA.opaque(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.opaque(red: 1, green: 1, blue: 1)

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    private func picture(
        _ canvas: Canvas, over ground: LinearRGBA, _ body: (Canvas) -> Void
    ) throws -> DisplayImage {
        try canvas.draw {
            canvas.background(ground)
            body(canvas)
        }
        return try canvas.target.encodeForDisplay()
    }

    // MARK: - 列が混ぜ方でパイプラインを選び分ける

    /// **既定の重ね方と置き換えは、下地を読む列とは別のパイプラインで描く。**
    ///
    /// 3 本が同じ物になっていたら、固定機能のブレンドに載っていない (あるいは載せた
    /// つもりで全部が載っている) ということである。
    @Test("重ねる・置き換える・それ以外で、パイプラインが分かれている")
    func eachBlendKindHasItsOwnPipeline() throws {
        let gpu = try RenderDevice()
        let pipeline = try ShapePipeline(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        for states in [pipeline.states, pipeline.solidStates, pipeline.formStates] {
            let blend = states.state(for: .blend)
            let replace = states.state(for: .replace)
            let multiply = states.state(for: .multiply)
            #expect(blend !== multiply, "重ねる列が下地を読む列と同じパイプラインになっている")
            #expect(replace !== multiply, "置き換える列が下地を読む列と同じパイプラインになっている")
            #expect(blend !== replace, "重ねる列と置き換える列が同じパイプラインになっている")
            // 固定機能で表せない混ぜ方は 1 本を共有する (下地を読んで断片が混ぜる)
            #expect(multiply === states.state(for: .screen))
            #expect(multiply === states.state(for: .add))
        }
    }

    // MARK: - 固定機能のブレンドが同じ式を出す

    /// 半透明を重ねた結果が、乗算済みの source-over そのものになる。
    ///
    /// 下地は白、載せるのは不透明度 0.5 の黒。乗算済みなら
    /// `source + destination × (1 − source.a)` = `0 + 1 × 0.5` で**線形のちょうど半分**
    /// になる。係数の組が違えばここがずれる (期待値は出力段と同じ変換で作るので、
    /// エンコードの綴りをこの検査へ写さない)。
    @Test("重ねた結果が乗算済みの source-over と一致する", arguments: [true, false])
    func blendMatchesPremultipliedOver(_ throughForms: Bool) throws {
        let canvas = try makeCanvas()
        let half = LinearRGBA(straightRed: 0, green: 0, blue: 0, alpha: 0.5)
        let image = try picture(canvas, over: white) { canvas in
            canvas.noStroke()
            canvas.fill(half)
            if throughForms {
                canvas.rect(8, 8, 32, 32)
            } else {
                // 三角形の経路 (基本図形ではない多角形)
                canvas.quad(8, 8, 40, 8, 40, 40, 8, 40)
            }
        }
        let expected = UInt8((TransferFunction.encode(0.5) * 255).rounded())
        #expect(image[24, 24].red == expected, "重ねた結果が線形の半分になっていない")
        #expect(image[24, 24].alpha == 255)
        #expect(image[4, 4].red == 255, "図形の外の下地が変わっている")
    }

    /// 置き換える混ぜ方は下地を見ない。**不透明度 0.5 の黒を置けば、そのまま残る。**
    @Test("置き換える混ぜ方は下地を見ない", arguments: [true, false])
    func replaceIgnoresTheGround(_ throughForms: Bool) throws {
        let canvas = try makeCanvas()
        let half = LinearRGBA(straightRed: 0, green: 0, blue: 0, alpha: 0.5)
        let image = try picture(canvas, over: white) { canvas in
            canvas.blendMode(.replace)
            canvas.noStroke()
            canvas.fill(half)
            if throughForms {
                canvas.rect(8, 8, 32, 32)
            } else {
                canvas.quad(8, 8, 40, 8, 40, 40, 8, 40)
            }
        }
        #expect(image[24, 24].red == 0, "置き換えたのに下地が混ざっている")
        #expect(image[24, 24].alpha == 128, "置いた不透明度がそのまま残っていない")
    }

    // MARK: - 形の外の余白が下地を壊さない

    /// `circle(32, 32, 20)` のクアッドの中で、形の外にある画素。
    ///
    /// 整数の座標は画素の中心を指すので、半径 10 の円の渡しは中心から 9.5〜10.5 画素に
    /// 乗る。クアッドは余白 2 画素ぶん (12 画素まで) を覆うので、**11 画素ちょうどの所は
    /// 断片が走るのに何も塗らない**。そこを指す — クアッドの外を見ても断片が 1 度も
    /// 走らないので、余白の扱いは試せない。
    private static let marginSpots = [(43, 32), (21, 32), (32, 43), (40, 40)]

    /// **重ねる列は捨てないので、余白でも色を書く。** 書く色は 0 なので、固定機能の
    /// ブレンドを通せば下地は 1 ビットも変わらない — ここが崩れると、図形のまわり
    /// 数画素に黒い枠が出る。
    @Test("重ねる列で、形の外の余白が下地を変えない")
    func blendLeavesTheMarginUntouched() throws {
        let canvas = try makeCanvas()
        let image = try picture(canvas, over: white) { canvas in
            canvas.noStroke()
            canvas.fill(black)
            canvas.circle(32, 32, 20)
        }
        // 半径 10 の円の外側。クアッドは余白 2 画素ぶん (半径 12 まで) を覆っている
        for spot in Self.marginSpots {
            let pixel = image[spot.0, spot.1]
            #expect(pixel.red == 255, "余白 \(spot) で下地が暗くなっている: \(pixel.red)")
            #expect(pixel.alpha == 255)
        }
    }

    /// **置き換える列は余白を捨てる。** 捨てないと、クアッドの余白が下地を消して
    /// 図形のまわりに透明な枠が出る。
    @Test("置き換える列で、形の外の余白が下地を消さない")
    func replaceDiscardsTheMargin() throws {
        let canvas = try makeCanvas()
        let image = try picture(canvas, over: white) { canvas in
            canvas.blendMode(.replace)
            canvas.noStroke()
            canvas.fill(black)
            canvas.circle(32, 32, 20)
        }
        for spot in Self.marginSpots {
            let pixel = image[spot.0, spot.1]
            #expect(pixel.red == 255, "余白 \(spot) で下地が消えている: \(pixel.red)")
            #expect(pixel.alpha == 255, "余白 \(spot) の不透明度が落ちている")
        }
    }
}
