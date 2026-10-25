// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics
import Testing

@testable import MokumeCore

/// 色の値を作る口が、範囲の外を締めた・丸めたことを 1 度だけ言う ([#1842])。GPU は要らない。
///
/// 控えはプロセスで 1 つで、並んで走る他の検査も同じ鍵を鳴らしうる。**鳴らした値までは比べず**、鍵が鳴った
/// ことと、文面の形 (口の名前・量・範囲) と、2 度目で文面が変わらないことを見る。範囲の中の値が鳴らさない
/// ことは、判定そのもの (`DisplayScale.roundedOpacity`) と、`Diagnostics.takeUnreported()` に新しい行が
/// 増えないことで見る。
///
/// [#1842]: https://github.com/mokume-metal/mokume/issues/1842
@Suite("色の値を作る口が言う、締めた・丸めた注意", .ownWarningDigest)
nonisolated struct ColorValueRoundedWarningTests {
    @Test("不透明度の判定は、範囲の外だけが締めた値を返す")
    func opacityJudgement() {
        #expect(DisplayScale.roundedOpacity(-0.5) == 0)
        #expect(DisplayScale.roundedOpacity(255.5) == 255)
        #expect(DisplayScale.roundedOpacity(.infinity) == nil)
        #expect(DisplayScale.roundedOpacity(.nan) == nil)
        for inside: Float in [0, 0.5, 128, 255] {
            #expect(DisplayScale.roundedOpacity(inside) == nil, "\(inside)")
        }
    }

    @Test("color(r, g, b, alpha) と color(c, alpha) は、不透明度を締めたら言う")
    func opacityOfTheValueForms() {
        _ = color(255, 204, 0, 400)
        _ = color(color(28, 28, 30), -100)
        let said = ColorValues.warnings.message(for: .roundedOpacity)
        #expect(said?.hasPrefix("color(): the opacity takes 0 to 255, but ") == true, "\(said ?? "")")
        let fading = ColorValues.warnings.message(for: .roundedFading)
        #expect(fading?.hasPrefix("color(): the opacity takes 0 to 255, but ") == true, "\(fading ?? "")")
        // 2 度目は組み立て直さない
        _ = color(255, 204, 0, 9999)
        #expect(ColorValues.warnings.message(for: .roundedOpacity) == said)
    }

    @Test("色相・彩度・明度の口は、負の彩度・明度と、範囲の外の不透明度を、量ごとに言う")
    func hueSaturationBrightness() {
        _ = color(hue: 200, saturation: -20, brightness: -30, alpha: 400)
        let prefix = "color(hue:saturation:brightness:): "
        for (key, quantity) in [
            (ColorValues.Warning.roundedSaturation, "saturation takes 0 or more, but "),
            (.roundedBrightness, "brightness takes 0 or more, but "),
            (.roundedHSBOpacity, "the opacity takes 0 to 255, but "),
        ] {
            let said = ColorValues.warnings.message(for: key)
            #expect(said?.hasPrefix(prefix + quantity) == true, "\(key): \(said ?? "")")
            #expect(said?.hasSuffix("was used") == true)
        }
        // 上へ突き抜ける値は丸めないので、新しい注意が増えない
        _ = Diagnostics.takeUnreported()
        _ = color(hue: 200, saturation: 150, brightness: 150, alpha: 255)
        #expect(Diagnostics.takeUnreported().isEmpty)
    }

    @Test("lerpColor と paletteLerp は、amount を締めたら言う")
    func amountOfTheMixers() {
        let start = color(236, 238, 240)
        let stop = color(232, 96, 72)
        _ = lerpColor(start, stop, 1.5)
        let said = ColorValues.warnings.message(for: .roundedLerpColor)
        #expect(said?.hasPrefix("lerpColor(): amount takes 0 to 1, but ") == true, "\(said ?? "")")
        _ = lerpColor(start, stop, -3)
        #expect(ColorValues.warnings.message(for: .roundedLerpColor) == said)
        _ = paletteLerp([(start, 0), (stop, 1)], 2)
        let palette = PaletteValues.warnings.message(for: .roundedAmount)
        #expect(palette?.hasPrefix("paletteLerp(): amount takes 0 to 1, but ") == true, "\(palette ?? "")")
    }

    @Test("範囲の中の値では、新しい注意を言わない")
    func inRangeValuesSayNothingNew() {
        let start = color(236, 238, 240)
        let stop = color(232, 96, 72)
        _ = Diagnostics.takeUnreported()
        _ = color(255, 204, 0, 255)
        _ = color(255, 204, 0, 0)
        _ = color(color(28, 28, 30), 128)
        _ = color(hue: 200, saturation: 0, brightness: 0, alpha: 128)
        _ = lerpColor(start, stop, 0)
        _ = lerpColor(start, stop, 1)
        _ = lerpColor(start, stop, 0.5)
        _ = paletteLerp([(start, 0), (stop, 1)], 0.25)
        #expect(Diagnostics.takeUnreported().isEmpty)
    }
}
