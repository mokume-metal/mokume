// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 値の側の `color(c, alpha)` の検査 ([#2422])。
///
/// 約束は 3 つ — 不透明度は**置き換えずに掛ける** (`fill(c, alpha)` と同じ式)、率は 0–1 に締める、
/// 数でない値・無限は受けずに透明な色を返して 1 度だけ知らせる。式を置き換えに変えると、
/// 半透明の色に 255 を渡した行と、128 を渡した行が赤になる。
///
/// [#2422]: https://github.com/mokume-metal/mokume/issues/2422
@Suite("値の側の color(c, alpha)")
struct ColorWithOpacityTests {
    /// 不透明度 128 の色。**不透明な色では掛け算と置き換えが一致する**ので、置き換えの実装を
    /// 見分けるにはこれが要る。
    private let half = color(28, 28, 30, 128)
    private let opaque = color(230, 120, 40)

    @Test("不透明度は置き換えずに掛ける: 128 の色に 128 を渡すと約 64 になる")
    func multipliesTheOpacity() {
        let faded = color(half, 128)
        #expect(abs(alpha(faded) - 128 * 128 / 255) < 1e-3, "\(alpha(faded))")
        // 置き換えなら 128 になる。比べる側も見せる
        #expect(abs(alpha(faded) - 128) > 60)
        // 色みは動かない (乗算済みの 4 成分を同じ率で縮めるだけ)
        #expect(abs(MokumeCore.red(faded) - 28) < 0.01, "\(MokumeCore.red(faded))")
        #expect(abs(MokumeCore.blue(faded) - 30) < 0.01, "\(MokumeCore.blue(faded))")
    }

    @Test("半透明の色に 255 を渡しても不透明にならず、400 でも元のまま")
    func fullOpacityKeepsTheColor() {
        #expect(color(half, 255) == half)
        #expect(color(half, 400) == half, "締めるのは掛ける率で、積ではない")
        #expect(color(opaque, 255) == opaque)
    }

    @Test("負の不透明度は、成分も不透明度も 0 の透明な色になる")
    func negativeOpacityIsTransparent() {
        let gone = color(half, -100)
        #expect(gone.red == 0 && gone.green == 0 && gone.blue == 0 && gone.alpha == 0)
        #expect(color(opaque, 0) == gone)
    }

    @Test("不透明な色では、4 つ目に不透明度を書いた色と同じになる")
    func opaqueColorMatchesTheFourComponentForm() {
        #expect(color(opaque, 200) == color(230, 120, 40, 200))
    }

    /// 作品が手で書いていた `fade(c, 0.72)` — 乗算済みの 4 成分を同じ率で縮める式。
    @Test("0–1 の率は 255 を掛けて渡し、乗算済みの 4 成分が同じ率で縮む")
    func scalesEveryPremultipliedComponent() {
        let ink = LinearRGBA.display(red: 0.114, green: 0.110, blue: 0.118)
        let faded = color(ink, 0.72 * 255)
        #expect(abs(faded.red - ink.red * 0.72) < 1e-6, "\(faded)")
        #expect(abs(faded.green - ink.green * 0.72) < 1e-6, "\(faded)")
        #expect(abs(faded.blue - ink.blue * 0.72) < 1e-6, "\(faded)")
        #expect(abs(faded.alpha - ink.alpha * 0.72) < 1e-6, "\(faded)")
    }

    @Test("不透明度は Int の変数も Double の式も受け、色は暗黙メンバでも書ける")
    func acceptsTheUsualSpellings() {
        let expected = color(half, 128)
        let count = 128
        #expect(color(half, count) == expected)
        let two: Double = 64
        #expect(color(half, two * 2.0) == expected)
        let red = LinearRGBA.display(red: 1, green: 0, blue: 0)
        #expect(color(.display(red: 1, green: 0, blue: 0), 128) == color(red, 128))
    }

    /// 数でない値・無限の不透明度は受けない。**色の成分は検めない** (受ける口が断る)。
    @Test("数でない値・無限の不透明度は透明な色を返し、1 度だけ知らせる", arguments: [Float.nan, Float.infinity, -Float.infinity] as [Float])
    func nonFiniteOpacityIsRefused(_ value: Float) {
        #expect(color(half, value) == .transparent)
        #expect(ColorValues.warnings.hasWarned(.notANumberFading))
        // 文面は口の名前で始まり、他の口の鍵を使わない (控えは鍵ごと)
        let message = ColorValues.warnings.message(for: .notANumberFading)
        #expect(message?.hasPrefix("color(): got an opacity that is not a number") == true, "\(message ?? "")")
        // 2 度目は組み立て直さない — 最初の文面のまま
        #expect(color(opaque, Float.nan) == .transparent)
        #expect(ColorValues.warnings.message(for: .notANumberFading) == message)
    }

    @Test("成分が数でない色は検めずに掛ける。断るのは受ける口")
    func doesNotInspectTheComponents() {
        let broken = LinearRGBA(premultipliedRed: .nan, green: 0.4, blue: 0.6, alpha: 1)
        let faded = color(broken, 128)
        #expect(faded.red.isNaN)
        #expect(abs(faded.green - 0.4 * 128 / 255) < 1e-6)
    }
}

/// `fill(c, alpha)` / `stroke(c, alpha)` が置く色と、`color(c, alpha)` が作る色が同じ (#2422 の
/// 完了条件 2)。式の正本が 1 つで、描く口と値の口で食い違わないことを見る。GPU を要する。
@Suite(
    "color(c, alpha) と fill / stroke の色",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ColorWithOpacityMatchesDrawingTests {
    /// 元の不透明度が 255・128・30 の 3 色 (番号で渡す — 色の値は検査の引数の置き場に置けない)。
    private static func source(_ index: Int) -> LinearRGBA {
        [color(230, 120, 40), color(230, 120, 40, 128), color(28, 28, 30, 30)][index]
    }
    /// 範囲の外 (-100・400) と端 (0・255)、0.12 の率 (0.12 × 255) を含む。
    nonisolated static let opacities: [Float] = [-100, 0, 30.6, 128, 255, 400]

    @Test("fill(c, a) が塗りに置く色と color(c, a) が等しい", arguments: [0, 1, 2], opacities)
    func fillMatches(_ index: Int, _ opacity: Float) throws {
        let source = Self.source(index)
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
        try canvas.draw {
            canvas.fill(source, opacity)
            #expect(canvas.style.fill == color(source, opacity))
        }
    }

    @Test("stroke(c, a) が線に置く色と color(c, a) が等しい", arguments: [0, 1, 2], opacities)
    func strokeMatches(_ index: Int, _ opacity: Float) throws {
        let source = Self.source(index)
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
        try canvas.draw {
            canvas.stroke(source, opacity)
            #expect(canvas.style.stroke == color(source, opacity))
        }
    }
}
