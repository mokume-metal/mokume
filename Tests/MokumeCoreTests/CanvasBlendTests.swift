// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

extension CanvasTests {
    /// 混ぜ方 (`blendMode`) と、置き換える混ぜ方の例外。
    @Suite(
        "混ぜ方",
        .enabled(
            if: RenderDevice.isAvailable,
            "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
    )
    struct Blending {
        private let black = Color.linear(red: 0, green: 0, blue: 0)
        private let white = Color.linear(red: 1, green: 1, blue: 1)
        private let red = Color.display(red: 1, green: 0, blue: 0)

        private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
            try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        }

        private func pixels(of canvas: Canvas) throws -> DisplayImage {
            try canvas.target.encodeForDisplay()
        }

        // MARK: - 混ぜ方 (#236)

        /// 下地の上に色を 1 つ塗り、真ん中の画素を返す。
        private func blended(
            mode: BlendMode, base: Color, top: Color
        ) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
            let canvas = try makeCanvas(width: 16, height: 16)
            try canvas.draw {
                canvas.background(base)
                canvas.noStroke()
                canvas.blendMode(mode)
                canvas.fill(top)
                canvas.rect(0, 0, 16, 16)
            }
            return try pixels(of: canvas)[8, 8]
        }

        @Test(
            "置き換える (replace) 以外のどの混ぜ方でも、アルファ 0 の色は下地を変えない",
            arguments: BlendMode.allCases.filter { $0 != .replace })
        func fullyTransparentColorsNeverDisturbTheBackground(_ mode: BlendMode) throws {
            let base = Color.display(red: 0.4, green: 0.3, blue: 0.2)
            let untouched = try blended(
                mode: .blend, base: base, top: .display(red: 0, green: 0, blue: 0, alpha: 0))
            let painted = try blended(
                mode: mode, base: base, top: .display(red: 0.25, green: 0.55, blue: 0.15, alpha: 0))
            #expect(painted == untouched, "\(mode) がアルファ 0 で下地を変えた")
        }

        // MARK: 置き換える混ぜ方の例外 (#1542)

        /// 白い下地に `color` を置き換えで置き、真ん中の画素を作業空間の値 (線形・乗算済み) で返す。
        ///
        /// **置き換える列の断片は経路ごとに別である** — 基本図形 (`rect`) は
        /// `mokume_formFragmentReplace`、三角形の経路 (`quad`) は `mokume_fragmentDirect` で描く
        /// (一覧は `ShapePipeline.BlendStates` の doc)。片方だけがアルファ 0 を捨てるように
        /// なっても気付けるよう、両方で置く。
        private func replaced(with color: Color, throughForms: Bool) throws -> Color {
            let canvas = try makeCanvas(width: 16, height: 16)
            try canvas.draw {
                canvas.background(white)
                canvas.noStroke()
                canvas.blendMode(.replace)
                canvas.fill(color)
                if throughForms {
                    canvas.rect(0, 0, 16, 16)
                } else {
                    canvas.quad(0, 0, 16, 0, 16, 16, 0, 16)
                }
            }
            return try canvas.target.readPixels()[8, 8]
        }

        /// **置き換える混ぜ方は、形が掛かる画素を置いた色でアルファごと置き換える。** アルファ 0
        /// の色なら、その画素は透明になる — 「アルファ 0 の色は下地を変えない」の唯一の例外で、
        /// 面の一部を透明にする手段でもある。
        ///
        /// 置く色は成分を持たせたアルファ 0 にする。乗算済みの 4 成分がすべて 0 になるので、
        /// 白い下地 (1, 1, 1, 1) が 1 成分でも残れば落ちる。
        @Test("置き換える混ぜ方は下地を見ず、アルファ 0 の色なら透明に置き換える", arguments: [true, false])
        func replaceIgnoresWhatIsUnderneath(_ throughForms: Bool) throws {
            let result = try replaced(
                with: .display(red: 0.25, green: 0.55, blue: 1, alpha: 0), throughForms: throughForms)
            #expect(
                result == Color(premultipliedRed: 0, green: 0, blue: 0, alpha: 0),
                "アルファ 0 の色で置き換えたのに、透明になっていない: \(result)")
        }

        /// **アルファ 0 とその 1 段上の間に継ぎ目が無い。** アルファ 1/255 の色で置き換えれば
        /// ほぼ透明になり、下地 (アルファ 1) へは戻らない。アルファを 0 へ下げていく動きで、
        /// 最後の 1 段だけ下地がいきなり現れる振る舞いを見張る。
        @Test("置き換える混ぜ方で、アルファ 1/255 の色はほぼ透明に置き換わる", arguments: [true, false])
        func replaceWithANearlyTransparentColorStaysNearlyTransparent(_ throughForms: Bool) throws {
            let step: Float = 1 / 255
            let result = try replaced(
                with: .display(red: 0.25, green: 0.55, blue: 1, alpha: step), throughForms: throughForms)
            #expect(
                abs(result.alpha - step) <= step,
                "アルファ 1/255 で置き換えた画素のアルファが \(result.alpha) になった")
        }

        /// **絵を置き換えで貼ると、絵の透けた画素がそのまま透明として写る。** 絵の α 0 の画素を
        /// 数え、貼った結果で同じ位置が 1 つ残らず透明になっていることと、絵の外の下地が
        /// 1 画素も透けないことを見る (絵を貼る列も三角形の経路の断片で描く)。
        @Test("透けた所を持つ絵を置き換えで貼ると、絵の透けた画素がそのまま透明になる")
        func replacingWithAPictureCopiesItsTransparentPixels() throws {
            let canvas = try makeCanvas(width: 160, height: 160)
            let pad = try canvas.createGraphics(80, 80)
            pad.beginDraw()
            pad.noStroke()
            pad.fill(white)
            pad.circle(40, 40, 40)
            pad.endDraw()
            let picture = try pad.target.readPixels()
            try canvas.draw {
                canvas.background(red)
                canvas.blendMode(.replace)
                canvas.image(pad, 40, 40)
            }
            let placed = try canvas.target.readPixels()

            let clear = Color(premultipliedRed: 0, green: 0, blue: 0, alpha: 0)
            var clearInPicture = 0
            var clearWhenPlaced = 0
            for y in 0..<80 {
                for x in 0..<80 where picture[x, y].alpha == 0 {
                    clearInPicture += 1
                    if placed[40 + x, 40 + y] == clear { clearWhenPlaced += 1 }
                }
            }
            // 円の外の四隅が透けている (直径 40 の円を 80×80 の絵に描いた)
            try #require(clearInPicture > 80 * 80 / 2)
            #expect(clearWhenPlaced == clearInPicture, "絵の透けた画素のうち、貼った結果で透明でないものがある")

            var seeThroughOutside = 0
            for y in 0..<160 {
                for x in 0..<160 where !(40..<120).contains(x) || !(40..<120).contains(y) {
                    if placed[x, y].alpha < 1 { seeThroughOutside += 1 }
                }
            }
            #expect(seeThroughOutside == 0, "絵の外で下地が透けた")
        }

        @Test("掛ける混ぜ方は暗いほうへ寄る")
        func multiplyDarkens() throws {
            let result = try blended(
                mode: .multiply,
                base: .display(red: 1, green: 1, blue: 1),
                top: .display(red: 0.5, green: 0.5, blue: 0.5))
            let plain = try blended(
                mode: .blend,
                base: .display(red: 1, green: 1, blue: 1),
                top: .display(red: 0.5, green: 0.5, blue: 0.5))
            // 白に掛けるので、そのまま塗ったのと同じ明るさになる
            #expect(abs(Int(result.red) - Int(plain.red)) <= 1)

            let onGray = try blended(
                mode: .multiply,
                base: .display(red: 0.5, green: 0.5, blue: 0.5),
                top: .display(red: 0.5, green: 0.5, blue: 0.5))
            #expect(onGray.red < plain.red)  // 灰色どうしなら暗くなる
        }

        @Test("明るいほうを採る混ぜ方と、暗いほうを採る混ぜ方が逆に働く")
        func lightestAndDarkestPickOppositeSides() throws {
            let base = Color.display(red: 0.8, green: 0.2, blue: 0.2)
            let top = Color.display(red: 0.2, green: 0.8, blue: 0.2)
            let lightest = try blended(mode: .lightest, base: base, top: top)
            let darkest = try blended(mode: .darkest, base: base, top: top)
            #expect(lightest.red > darkest.red)
            #expect(lightest.green > darkest.green)
        }

        @Test("足す混ぜ方は明るくなり、引く混ぜ方は暗くなる")
        func addBrightensAndSubtractDarkens() throws {
            let base = Color.display(red: 0.4, green: 0.4, blue: 0.4)
            let top = Color.display(red: 0.3, green: 0.3, blue: 0.3)
            let added = try blended(mode: .add, base: base, top: top)
            let subtracted = try blended(mode: .subtract, base: base, top: top)
            let plain = try blended(mode: .blend, base: base, top: base)
            #expect(added.red > plain.red)
            #expect(subtracted.red < plain.red)
        }

        @Test("差を採る混ぜ方は、同じ色どうしで黒になる")
        func differenceOfEqualColorsIsBlack() throws {
            let color = Color.display(red: 0.6, green: 0.4, blue: 0.8)
            let result = try blended(mode: .difference, base: color, top: color)
            #expect(result.red <= 1)
            #expect(result.green <= 1)
            #expect(result.blue <= 1)
        }

        /// **合成の出口では切らない。** 作業空間は 1.0 超を保ち、畳むのは出力段だけである
        /// ([ADR-0011] 決定 1・決定 3)。下の
        /// ``outOfRangeComponentsAreSaturatedByTheOutputStage`` と**対で読む** — あちらが
        /// 「出力段が畳む」側、こちらが「作業空間には残る」側である。
        ///
        /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
        @Test("足す混ぜ方は、光を重ねるほど明るさを積み上げられる")
        func addingLightAccumulatesBeyondTheDisplayRange() throws {
            let canvas = try makeCanvas(width: 16, height: 16)
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.blendMode(.add)
                canvas.fill(.linear(red: 0.6, green: 0, blue: 0))
                canvas.rect(0, 0, 16, 16)
                canvas.rect(0, 0, 16, 16)  // 同じところへもう 1 枚重ねる
            }
            // 0.6 を 2 回足せば 1.2。合成の出口で飽和させていると 1.0 で頭打ちになる
            #expect(canvas.get(8, 8).premultipliedRed > 1.1)
        }

        /// **飽和の担い手は出力段である** (`OutputStage` の `clampToStandardRange`)。
        ///
        /// もとは #258 の「範囲の外の成分を渡しても下地が壊れない」という表題だったが、
        /// 見ているのは `pixels(of:)` を通した 8 bit の画素なので、実際に守られているのは
        /// 「**出力**が壊れない」である。合成の出口には飽和が無い (上の
        /// ``addingLightAccumulatesBeyondTheDisplayRange`` が作業空間の側を見る) ので、
        /// 名前が担い手を名乗るようにした ([#1057])。**#258 が守っていた保証は減っていない。**
        ///
        /// [#1057]: https://github.com/mokume-metal/mokume/issues/1057
        @Test("範囲の外の成分を渡しても、出力段が飽和させるので絵が壊れない")
        func outOfRangeComponentsAreSaturatedByTheOutputStage() throws {
            let result = try blended(
                mode: .add,
                base: .display(red: 0.5, green: 0.5, blue: 0.5),
                top: Color(straightRed: 8, green: -4, blue: 0.5, alpha: 1))
            #expect(result.red == 255)  // 上へ飽和
            #expect(result.green == 0)  // 下へ飽和 (負の値が巻き返さない)
        }

        @Test("透明な下地を作れる")
        func aTransparentBackgroundCanBeMade() throws {
            let canvas = try makeCanvas(width: 16, height: 16)
            try canvas.draw {
                canvas.background(.display(red: 0, green: 0, blue: 0, alpha: 0))
            }
            #expect(try pixels(of: canvas)[8, 8].alpha == 0)
        }

        @Test("透明な下地の上に半透明を重ねられる")
        func semiTransparentPaintLandsOnATransparentBackground() throws {
            let canvas = try makeCanvas(width: 16, height: 16)
            try canvas.draw {
                canvas.background(.display(red: 0, green: 0, blue: 0, alpha: 0))
                canvas.noStroke()
                canvas.fill(.display(red: 1, green: 0, blue: 0, alpha: 0.5))
                canvas.rect(0, 0, 16, 16)
            }
            let center = try pixels(of: canvas)[8, 8]
            #expect(center.alpha > 100 && center.alpha < 160)  // おおよそ半分
            #expect(center.red > 200)  // 色は戻して出る (暗く沈まない)
        }

        @Test("混ぜ方を変えると、その前に置いた図形は影響を受けない")
        func changingTheModeClosesTheRunSoFar() throws {
            let canvas = try makeCanvas(width: 32, height: 16)
            try canvas.draw {
                canvas.background(.display(red: 1, green: 1, blue: 1))
                canvas.noStroke()
                canvas.fill(.display(red: 0.5, green: 0.5, blue: 0.5))
                canvas.rect(0, 0, 16, 16)  // 重ねる (白の上に灰色 = 灰色)
                canvas.blendMode(.multiply)
                canvas.rect(16, 0, 16, 16)  // 掛ける (白に掛けるので灰色)
            }
            let image = try pixels(of: canvas)
            // 左は「重ねる」で描かれたまま。後から掛ける指定に変えても影響しない
            #expect(abs(Int(image[8, 8].red) - Int(image[24, 8].red)) <= 1)
        }

        @Test("積み降ろしは混ぜ方も戻す")
        func styleStackCarriesTheBlendMode() throws {
            let canvas = try makeCanvas(width: 16, height: 16)
            try canvas.draw {
                canvas.background(.display(red: 0.5, green: 0.5, blue: 0.5))
                canvas.noStroke()
                canvas.pushStyle()
                canvas.blendMode(.add)
                canvas.popStyle()
                canvas.fill(.display(red: 0.3, green: 0.3, blue: 0.3))
                canvas.rect(0, 0, 16, 16)
            }
            // 戻っているので「重ねる」で描かれ、塗った色そのものになる
            let plain = try blended(
                mode: .blend,
                base: .display(red: 0.5, green: 0.5, blue: 0.5),
                top: .display(red: 0.3, green: 0.3, blue: 0.3))
            #expect(try pixels(of: canvas)[8, 8].red == plain.red)
        }
    }
}
