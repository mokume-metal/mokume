// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 色相・彩度・明度で色を指定する面 ([ADR-0033] 決定 5)。
///
/// 手本が割れている量なので、**この面が名乗る目盛りどおりに効くこと**を検査で固定する。
/// 見るのは 3 つ — 既知の色と一致すること、範囲の外がそれぞれの量の作法どおりに畳まれる
/// こと、非有限の値で落ちないこと。
///
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
@Suite("色相・彩度・明度の面")
struct HueSaturationBrightnessTests {
    private func isSame(_ one: LinearRGBA, _ other: LinearRGBA, within tolerance: Float = 1e-5)
        -> Bool
    {
        abs(one.red - other.red) < tolerance && abs(one.green - other.green) < tolerance
            && abs(one.blue - other.blue) < tolerance && abs(one.alpha - other.alpha) < tolerance
    }

    @Test("既知の色が、素の数値の指定と一致する")
    func matchesKnownNumericColors() {
        // 彩度 100 / 明度 100 の原色 3 つ
        #expect(isSame(color(hue: 0, saturation: 100, brightness: 100), color(255, 0, 0)))
        #expect(isSame(color(hue: 120, saturation: 100, brightness: 100), color(0, 255, 0)))
        #expect(isSame(color(hue: 240, saturation: 100, brightness: 100), color(0, 0, 255)))
        // 彩度 0 は灰色
        #expect(isSame(color(hue: 200, saturation: 0, brightness: 50), color(127.5)))
    }

    @Test("色相は巻き戻る")
    func hueWrapsAround() {
        // 剰余を書かずにフレーム番号を渡せることが、この口の値打ち
        #expect(isSame(color(hue: 380, saturation: 80, brightness: 90), color(hue: 20, saturation: 80, brightness: 90)))
        #expect(isSame(color(hue: -40, saturation: 80, brightness: 90), color(hue: 320, saturation: 80, brightness: 90)))
        #expect(isSame(color(hue: 360, saturation: 80, brightness: 90), color(hue: 0, saturation: 80, brightness: 90)))
        #expect(isSame(color(hue: 720, saturation: 80, brightness: 90), color(hue: 0, saturation: 80, brightness: 90)))
    }

    @Test("書いた目盛りで読み出せる")
    func readingReturnsTheWrittenScale() {
        let written = color(hue: 200, saturation: 80, brightness: 90)
        #expect(abs(hue(written) - 200) < 0.1)
        #expect(abs(saturation(written) - 80) < 0.1)
        #expect(abs(brightness(written) - 90) < 0.1)
    }

    @Test("彩度と明度は上へ突き抜けられる")
    func saturationAndBrightnessPassThroughAbove() {
        // 表示範囲を超えた明るさと色域の外の色は、作業空間が保つ (ADR-0011 決定 1)
        #expect(brightness(color(hue: 0, saturation: 0, brightness: 150)) > 100)
        #expect(red(color(hue: 200, saturation: 180, brightness: 90)) < 0)
    }

    @Test("彩度と明度の負は 0 として扱う")
    func negativeSaturationAndBrightnessFallToZero() {
        // 負にすると最大の成分が入れ替わり、色相が 180 度回る — 値を保つのではなく
        // 引数の意味が変わるので、ここは丸める側に倒す (ADR-0033 決定 5)
        #expect(isSame(
            color(hue: 200, saturation: -50, brightness: 90),
            color(hue: 200, saturation: 0, brightness: 90)))
        #expect(isSame(
            color(hue: 200, saturation: 80, brightness: -50),
            color(hue: 200, saturation: 80, brightness: 0)))
    }

    @Test("数でない色相で落ちない")
    func notANumberDoesNotTrap() {
        // 区画の添字は Int(hue / 60) で取るので、弾かないと変換で trap する
        #expect(color(hue: .nan, saturation: 80, brightness: 90) == .transparent)
        #expect(color(hue: .infinity, saturation: 80, brightness: 90) == .transparent)
        #expect(color(hue: 200, saturation: .nan, brightness: 90) == .transparent)
        #expect(color(hue: 200, saturation: 80, brightness: .infinity) == .transparent)
    }

    @Test("灰色の色相は 0")
    func grayHasNoHue() {
        #expect(hue(color(128)) == 0)
        #expect(saturation(color(128)) == 0)
    }
}
