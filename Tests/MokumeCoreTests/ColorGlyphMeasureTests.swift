// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import Testing

@testable import MokumeCore

/// 色を持つ字形 (絵文字) を `textBounds` で測り、`text()` で描くとき、CPU で字形を描くのは 1 回で済む
/// ([#2560])。GPU を要する。
///
/// `textBounds` は色を持つ字形の墨を、焼き場と同じ描き方で CPU に描かせて測る ([#2308])。測った結果の
/// 控えは書体ごと (= 大きさごと) なので、`textSize()` を毎フレーム動かすスケッチでは控えが外れ、測る
/// たびに描き直す。`text()` も同じ大きさで焼き直すので、CPU の描画が二重になっていた。測る側が描いた
/// 画素を焼き場に預け、焼くときに同じ升目なら使うことで、描くのを 1 回にする。
///
/// [#2308]: https://github.com/mokume-metal/mokume/issues/2308
/// [#2560]: https://github.com/mokume-metal/mokume/issues/2560
@Suite(
    "色を持つ字形の測りと焼き",
    .enabled(if: RenderDevice.isAvailable, "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"),
    .enabled(if: TextTests.hasColoredGlyphs, "この環境には色を持つ字形の書体が無い")
)
struct ColorGlyphMeasureTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
    private static let tree = "\u{1F332}"

    private func makeCanvas() throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 96)
        canvas.textFont("Helvetica")
        return canvas
    }

    /// 1 フレーム描く。`measure` なら先に `textBounds` を呼ぶ。返すのは、枠・このフレームの CPU の描画の数・絵。
    private func frame(
        _ canvas: Canvas, size: Float, measure: Bool
    ) throws -> (bounds: TextBounds?, renders: Int, image: DisplayImage) {
        let before = canvas.atlas.cpuRenders
        var bounds: TextBounds?
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(size)
            if measure { bounds = canvas.textBounds(Self.tree, 8, 80) }
            canvas.text(Self.tree, 8, 80)
        }
        return (bounds, canvas.atlas.cpuRenders - before, try canvas.target.encodeForDisplay())
    }

    @Test("大きさを毎フレーム動かして測って描いても、絵文字を CPU で描くのは 1 フレームに 1 回")
    func aMovingSizeDrawsTheEmojiOncePerFrame() throws {
        let canvas = try makeCanvas()
        for size in [20, 28, 36, 44, 52, 60] as [Float] {
            let result = try frame(canvas, size: size, measure: true)
            #expect(result.renders == 1, "大きさ \(size): CPU の描画が \(result.renders) 回")
        }
    }

    @Test("預けた画素から焼いても、枠と焼いた絵は、預けずに描き直して焼いたものと 1 ビットも変わらない")
    func keepingThePixelsChangesNothing() throws {
        let kept = try makeCanvas()
        let fresh = try makeCanvas()
        for size in [20, 36, 52] as [Float] {
            let measured = try frame(kept, size: size, measure: true)
            // 測らずに焼く canvas では、焼き場が自分で描く。枠は測るだけの別の canvas で出す
            let baked = try frame(fresh, size: size, measure: false)
            let alone = try makeCanvas()
            alone.textSize(size)
            let bounds = alone.textBounds(Self.tree, 8, 80)
            #expect(measured.bounds == bounds, "大きさ \(size): 枠が変わった")
            #expect(baked.renders == 1)
            let same = measured.image.bytes == baked.image.bytes
            #expect(same, "大きさ \(size): 焼いた絵が変わった")
        }
    }

    @Test("預けた画素は、焼かれなければ上限を越えて溜まらない")
    func keptPixelsAreBounded() throws {
        let canvas = try makeCanvas()
        // 40 の絵文字は 1 つ 40×40 前後 × 8 バイト。2 つ分に届かない上限にする
        canvas.atlas.keptLimitBytes = 2 * 30 * 30 * GlyphAtlas.bytesPerPixel
        for size in [20, 24, 28, 32, 36, 40] as [Float] {
            canvas.textSize(size)
            _ = canvas.textBounds(Self.tree, 8, 80)
            #expect(canvas.atlas.keptCount <= 2, "大きさ \(size): 預かりが \(canvas.atlas.keptCount) 個")
        }
    }

    @Test("上限に入らない大きさの画素は預けず、焼くときに描き直す。絵は変わらない")
    func tooBigToKeepIsRedrawn() throws {
        let kept = try makeCanvas()
        kept.atlas.keptLimitBytes = 16
        let fresh = try makeCanvas()
        let measured = try frame(kept, size: 40, measure: true)
        let baked = try frame(fresh, size: 40, measure: false)
        #expect(kept.atlas.keptCount == 0)
        // 測る側で 1 回、焼くときに描き直して 1 回
        #expect(measured.renders == 2)
        let same = measured.image.bytes == baked.image.bytes
        #expect(same)
    }
}
