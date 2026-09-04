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

    @Test("書いた目盛りで読み出せる")
    func readingReturnsTheWrittenScale() {
        let written = color(255, 204, 0)
        #expect(abs(red(written) - 255) < 0.01)
        #expect(abs(green(written) - 204) < 0.01)
        #expect(abs(blue(written) - 0) < 0.01)
        #expect(abs(alpha(written) - 255) < 0.01)
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
        #expect(red(color(-255, 0, 0)) < 0)
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
