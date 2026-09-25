// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 素の数値で色を指定する面 ([ADR-0033])。
///
/// 見るのは 2 つ。**同じ色が綴りを変えても同じ値になること**と、**書いた目盛りで
/// 読み出せること**である。前者が崩れると 0–255 の綴りは別の色を作る口になり、
/// 後者が崩れると往復が成立しない。
///
/// GPU は要らない — 目盛りの変換は作業空間へ入る手前の純粋な計算である。
///
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
@Suite("色を指定する面")
struct ColorSurfaceTests {
    /// 成分ごとの差。0–255 の割り算とリテラルの 0–1 は最下位ビットで揺れるので、
    /// 「同じ色か」を等値では見ない。
    private func isSame(_ one: LinearRGBA, _ other: LinearRGBA, within tolerance: Float = 1e-6)
        -> Bool
    {
        abs(one.red - other.red) < tolerance && abs(one.green - other.green) < tolerance
            && abs(one.blue - other.blue) < tolerance && abs(one.alpha - other.alpha) < tolerance
    }

    @Test("素の数値の色は 0–1 の指定と一致する")
    func numericMatchesDisplayScale() {
        #expect(isSame(color(255, 204, 0), .display(red: 1, green: 0.8, blue: 0)))
        #expect(isSame(color(0, 0, 0), .display(red: 0, green: 0, blue: 0)))
    }

    @Test("1 つなら灰色、2 つ目は不透明度")
    func grayFormsSpreadTheValue() {
        #expect(isSame(color(128), color(128, 128, 128)))
        #expect(isSame(color(128, 64), color(128, 128, 128, 64)))
    }

    @Test("不透明度は伝達関数を通さない")
    func alphaIsNotEncoded() {
        #expect(isSame(color(255, 204, 0, 128), .display(red: 1, green: 0.8, blue: 0, alpha: 128 / 255)))
    }

    @Test("16 進は下位 24 bit を読み、上位は落とす")
    func hexReadsTheLowTwentyFourBits() {
        #expect(isSame(color(hex: 0xFF_CC00), color(255, 204, 0)))
        // 手本の習慣で不透明度を上位バイトに付けても、色は同じになる
        #expect(isSame(color(hex: 0xFFFF_CC00), color(255, 204, 0)))
    }

    @Test("数で書いた色は sRGB の原色の値として作業空間へ入る")
    func numbersAreSRGBPrimaries() {
        // 期待値は CoreGraphics に変換させて導く。実装の行列を使わないので、行列の係数が
        // 誤っていても一致しない (ADR-0011 決定 3)
        let expected = SRGBReference.working(red: 204.0 / 255, green: 153.0 / 255, blue: 0)
        #expect(isSame(color(204, 153, 0), expected, within: 1e-4))
        #expect(isSame(LinearRGBA.display(red: 0.8, green: 0.6, blue: 0), expected, within: 1e-4))
    }

    @Test("灰色は原色の取り方に依らず、転送関数だけが効く")
    func grayIgnoresPrimaries() {
        let gray = color(128)
        let level = TransferFunction.decode(128 / 255)
        #expect(isSame(gray, .linear(red: level, green: level, blue: level), within: 1e-6))
    }

    @Test("書いた目盛りで読み出せる")
    func readingReturnsTheWrittenScale() {
        let written = color(255, 204, 0)
        #expect(abs(red(written) - 255) < 0.01)
        #expect(abs(green(written) - 204) < 0.01)
        #expect(abs(blue(written) - 0) < 0.01)
        #expect(abs(alpha(written) - 255) < 0.01)

        // 原色の行列を往復しても、彩度のある色の 3 成分がそれぞれ戻る (ADR-0033 決定 6)
        let saturated = color(129, 206, 15)
        #expect(abs(red(saturated) - 129) < 0.01)
        #expect(abs(green(saturated) - 206) < 0.01)
        #expect(abs(blue(saturated) - 15) < 0.01)
    }

    @Test("半透明の色でも、書いた成分がそのまま読める")
    func translucentColorsReadBackUnpremultiplied() {
        // 作業空間はアルファ乗算済み (ADR-0011 決定 4) なので、掛け戻さずに読むと
        // 半透明の色だけ暗く読める。ここが straighten を通っていることの検査になる
        let veil = color(255, 204, 0, 128)
        #expect(abs(red(veil) - 255) < 0.01)
        #expect(abs(green(veil) - 204) < 0.01)
        #expect(abs(alpha(veil) - 128) < 0.01)
    }

    @Test("不透明度が 0 の色は成分 0 を返す")
    func fullyTransparentReadsAsZero() {
        // 乗算済みの表現からは元の色を復元できない (ADR-0011 決定 4 の代償)
        let invisible = color(255, 204, 0, 0)
        #expect(red(invisible) == 0)
        #expect(green(invisible) == 0)
        #expect(alpha(invisible) == 0)
    }

    @Test("範囲の外の値は丸めずに読み出せる")
    func valuesOutsideTheScaleSurvive() {
        // 「0–255」は目盛りであって上限ではない (ADR-0033 決定 6・ADR-0011 決定 1)
        #expect(abs(red(color(510, 0, 0)) - 510) < 0.01)
        #expect(abs(green(color(510, 0, 0))) < 0.01)
        #expect(abs(blue(color(510, 0, 0))) < 0.01)
        #expect(red(color(-255, 0, 0)) < 0)
    }

    /// 上の検査と**逆向き**の扱いを並べて置く。成分は目盛りであって上限ではないが、
    /// 不透明度は「どれだけ効かせるか」なので、0 より透明にも 255 より不透明にもならない
    /// ([ADR-0033] 決定 3 の改訂)。締めないと、`fill(255, -100)` は下地を負の値へ落とす
    /// ([#1450])。
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    /// [#1450]: https://github.com/mokume-metal/mokume/issues/1450
    @Test("不透明度は範囲の外を 0–255 に締める")
    func opacityOutsideTheScaleIsClamped() {
        // **等値で見る。** 締めた値は端の値そのものなので、最下位ビットまで一致する
        #expect(color(255, 204, 0, -100) == color(255, 204, 0, 0))
        #expect(color(255, 400) == color(255, 255))
        #expect(
            color(hue: 200, saturation: 80, brightness: 90, alpha: 400)
                == color(hue: 200, saturation: 80, brightness: 90))
        // 読み出しも締めた値を返す。締めないと `alpha(_:)` だけが範囲の外を返し、
        // 成分の読み出し (不透明度が 0 以下なら 0) と食い違う
        #expect(alpha(color(0, 0, 0, 400)) == 255)
        #expect(alpha(color(0, 0, 0, -100)) == 0)
    }

    @Test("0–1 の口でも不透明度は 0–1 に締め、乗算済みの口は締めない")
    func opacityClampsOnTheUnitScaleButNotWhenPremultiplied() {
        // 締めるのは乗算する点 (ADR-0011 決定 4 の変換点) なので、straight で書くどの綴りも揃う
        #expect(
            LinearRGBA.display(red: 1, green: 1, blue: 1, alpha: 1.5)
                == .display(red: 1, green: 1, blue: 1))
        #expect(
            LinearRGBA(straightRed: 1, green: 0, blue: 0, alpha: -0.5)
                == LinearRGBA(straightRed: 1, green: 0, blue: 0, alpha: 0))
        // 乗算済みの層は作業空間の「計算のための値」(ADR-0011 決定 1) なので、渡したまま
        let premultiplied = LinearRGBA(premultipliedRed: 1, green: 0, blue: 0, alpha: 2)
        #expect(premultiplied.alpha == 2)
        #expect(premultiplied.red == 1)
    }

    @Test("数でない不透明度は、締めても不透明に化けない")
    func notANumberOpacityStaysNotANumber() {
        // Swift の `min` / `max` は第 1 引数の NaN を返すので、`max(0, min(1, a))` の順に
        // 書くと NaN が 1 (不透明) に化ける。数値の口は手前で弾く (下の検査) ので、
        // ここへ NaN が届くのは 0–1 の口から直に作ったときだけで、扱いは変えない
        let made = LinearRGBA(straightRed: 1, green: 1, blue: 1, alpha: .nan)
        #expect(made.alpha.isNaN, "NaN の不透明度が \(made.alpha) に化けた")
    }

    @Test("数でない値は色を作らず、読み出しは 0 へ倒れる")
    func notANumberFallsToSafeValues() {
        #expect(color(.nan, 0, 0) == .transparent)
        #expect(color(.infinity, 0, 0) == .transparent)
        #expect(color(255, 204, 0, .nan) == .transparent)

        let broken = LinearRGBA(premultipliedRed: .nan, green: 0, blue: 0, alpha: .nan)
        #expect(red(broken) == 0)
        #expect(alpha(broken) == 0)
    }
}
