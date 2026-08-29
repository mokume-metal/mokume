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

    // MARK: - 間引きは出力段の前で効く (#382)

    /// 特異な値を含む作業空間の画素を組む。
    ///
    /// 左上には**変換の特異点を集める** — 値になっていない成分・範囲を超えた明るさ・
    /// 負の明るさ。ここは間引きの倍率によらず必ず拾われる位置なので、どの倍率でも
    /// 特異点が照合に載る。残りは半透明と範囲外を混ぜて埋める。
    private func makeVariedPixels(width: Int, height: Int) -> PixelBuffer {
        var components = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let alpha = Float16(Double(index % 5) / 4)
                let tone = Float16(Double(index) / Double(width * height))
                let base = index * 4
                components[base] = tone * alpha
                components[base + 1] = (1 - tone) * alpha
                // 乗算を戻すと 1 を超えるものを混ぜる (範囲へ収める手を通す)
                components[base + 2] = 2 * tone * alpha
                components[base + 3] = alpha
            }
        }
        components[0] = .nan
        components[1] = 4
        components[2] = -1
        components[3] = 1
        return PixelBuffer(width: width, height: height, components: components)
    }

    @Test(
        "間引いてから変換しても、変換してから間引いたのと同じバイト列になる",
        arguments: [0.5, 0.3, 0.75, 0.1])
    func decimatingBeforeEncodingGivesTheSameBytes(factor: Double) {
        let pixels = makeVariedPixels(width: 7, height: 5)
        // 変換してから間引いた側。オラクルはここが持つ — 生産側に間引きの実装を
        // 2 つ置くと「同じ点を拾う」が二重管理になる
        let full = OutputStage.encode(pixels)
        let small = OutputStage.encode(pixels.scaled(by: factor))

        #expect(small.width == max(1, Int((7 * factor).rounded())))
        #expect(small.height == max(1, Int((5 * factor).rounded())))
        for y in 0..<small.height {
            for x in 0..<small.width {
                let sourceX = min(full.width - 1, x * full.width / small.width)
                let sourceY = min(full.height - 1, y * full.height / small.height)
                #expect(
                    small[x, y] == full[sourceX, sourceY],
                    "(\(x), \(y)) が元の (\(sourceX), \(sourceY)) と違う")
            }
        }
    }

    /// 完了条件「出力段が受け取る画素数が、要求した `scale` の画素数と一致する」。
    ///
    /// 出力段の費用は画素数にそのまま比例するので、**渡す前に減っていること**が
    /// 捨てるぶんを変換していないことにあたる。この画素を出力段へ渡す唯一の場所が
    /// `RenderTarget.encodeForDisplay(scale:)` である。
    @Test("間引いた画素の数は、要求した倍率のぶんしかない")
    func onlyTheRequestedPixelsReachTheOutputStage() {
        let pixels = makeVariedPixels(width: 960, height: 540)
        let small = pixels.scaled(by: 0.5)
        #expect(small.width == 480)
        #expect(small.height == 270)
        #expect(small.components.count == small.width * small.height * 4)
        // 実寸の 4 分の 1 — 出力段の費用もここまで落ちる
        #expect(small.width * small.height == pixels.width * pixels.height / 4)
    }

    @Test("倍率が範囲の外なら実寸のまま返す", arguments: [1.0, 1.5, 0.0, -0.5])
    func factorsOutsideTheRangeLeaveThePixelsAlone(factor: Double) {
        let pixels = makeVariedPixels(width: 7, height: 5)
        let same = pixels.scaled(by: factor)
        #expect(same.width == pixels.width)
        #expect(same.height == pixels.height)
        // 値になっていない成分は自分自身とも等しくならないので、ビット列で比べる
        #expect(same.components.map(\.bitPattern) == pixels.components.map(\.bitPattern))
    }
}
