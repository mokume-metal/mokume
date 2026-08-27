// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

@Suite("出力段")
struct OutputStageTests {
    // MARK: - 手ごとの検査 (GPU を要さない)

    @Test("0 と 1 は端に落ちる")
    func endpointsMapToEnds() {
        #expect(OutputStage.quantize(OutputStage.encodeForDisplay(0)) == 0)
        #expect(OutputStage.quantize(OutputStage.encodeForDisplay(1)) == 255)
    }

    @Test("線形の中間値は、伝達関数を経て明るい側へ寄る")
    func midtoneIsEncoded() {
        // 線形 0.5 は sRGB の伝達関数で約 0.7354 → 188。
        // 伝達関数を掛け忘れると 128 になるので、この 1 点で掛け忘れが分かる。
        #expect(OutputStage.quantize(OutputStage.encodeForDisplay(0.5)) == 188)
    }

    @Test("伝達関数の折れ目の下は直線")
    func lowEndIsLinearSegment() {
        // 0.0031308 以下は 12.92 倍の直線。曲線側の式をそのまま使うと暗部が
        // 持ち上がるので、折れ目を持っていることを傾きで確かめる。
        let first = OutputStage.encodeForDisplay(0.001)
        let second = OutputStage.encodeForDisplay(0.002)
        #expect(abs(first - 12.92 * 0.001) < 1e-6)
        #expect(abs((second - first) / 0.001 - 12.92) < 1e-3)
    }

    @Test("標準レンジの外側は端へ寄せる")
    func outOfRangeIsClamped() {
        #expect(OutputStage.quantize(OutputStage.encodeForDisplay(4)) == 255)
        #expect(OutputStage.quantize(OutputStage.encodeForDisplay(-0.25)) == 0)
    }

    @Test("標準レンジの内側は曲げない")
    func insideStandardRangeIsUntouched() {
        // ここを曲線で圧縮すると、指定した色がそのまま出るという前提が崩れる
        for value in [Float(0), 0.25, 0.5, 0.75, 1] {
            #expect(OutputStage.clampToStandardRange(value) == value)
        }
    }

    @Test("アルファの乗算を戻す")
    func alphaIsStraightenedAtTheBoundary() {
        // 半透明の白は作業空間では (0.5, 0.5, 0.5, 0.5) として運ばれる。
        // 戻さずに書き出すと灰色になる。
        let pixels = PixelBuffer(width: 1, height: 1, components: [0.5, 0.5, 0.5, 0.5])
        let image = OutputStage.encode(pixels)
        #expect(image[0, 0].red == 255)
        #expect(image[0, 0].alpha == 128)
    }

    @Test("完全に透明な画素は成分も 0")
    func fullyTransparentHasNoColor() {
        let pixels = PixelBuffer(width: 1, height: 1, components: [0, 0, 0, 0])
        let image = OutputStage.encode(pixels)
        #expect(image[0, 0] == (0, 0, 0, 0))
    }

    @Test("値になっていない成分は 0 へ倒す")
    func notANumberFallsToZero() {
        // 比較がすべて false になるので、範囲へ収める処理が素通ししやすい
        #expect(OutputStage.clampToStandardRange(.nan) == 0)
        #expect(OutputStage.quantize(.nan) == 0)
    }
}
