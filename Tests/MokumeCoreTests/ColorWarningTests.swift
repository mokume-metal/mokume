// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 色の受け口が「初回だけ」言う注意 ([#833])。
///
/// 見るのは 1 つ — **口ごとに数えていること**。旗を 1 つ共有していたときは、先に鳴った
/// 口が後の口を永久に黙らせていた (`fill(.nan, 0, 0)` の後は `background(.nan, 0, 0)` が
/// 無音になる)。黙ったことは絵にもログにも出ないので、控えを直に読んで確かめる。
///
/// [#833]: https://github.com/mokume-metal/mokume/issues/833
@Suite(
    "色の受け口が言う注意",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ColorWarningTests {
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    @Test("塗りで鳴っても、下地は黙らない")
    func fillDoesNotSilenceBackground() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.fill(Float.nan, 0, 0)
            canvas.background(Float.nan, 0, 0)
        }
        #expect(canvas.warnings.hasWarned(.notANumberFill))
        #expect(canvas.warnings.hasWarned(.notANumberBackground))
        // 文面は口ごとに違う — どちらが起きたのか読めることまで見る
        #expect(canvas.warnings.message(for: .notANumberFill)?.hasPrefix("fill()") == true)
        #expect(
            canvas.warnings.message(for: .notANumberBackground)?.hasPrefix("background()") == true)
    }

    @Test("光と質感も、互いに黙らせない")
    func lightsAndMaterialsCountSeparately() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.ambientLight(Float.nan, 0, 0)
            canvas.directionalLight(Float.nan, 0, 0, 0, 1, 0)
            canvas.emissive(Float.nan, 0, 0)
        }
        #expect(canvas.warnings.hasWarned(.notANumberAmbientLight))
        #expect(canvas.warnings.hasWarned(.notANumberDirectionalLight))
        #expect(canvas.warnings.hasWarned(.notANumberEmissive))
    }

    /// 色の値と不透明度の形 ([#1553]) も、数値の口と同じ鍵で数え、同じ倒し方をする —
    /// 色は直前のまま残し、止めていた塗りも戻さない。
    ///
    /// [#1553]: https://github.com/mokume-metal/mokume/issues/1553
    @Test("色の値と不透明度の形は、数でない不透明度を弾く")
    func colorWithOpacityRejectsNonFinite() throws {
        let canvas = try makeCanvas()
        let previous = color(20, 40, 60)
        let tinted = color(230, 120, 40, 128)
        try canvas.draw {
            canvas.fill(previous)
            canvas.fill(tinted, Float.nan)
            #expect(canvas.style.fill == previous)
            canvas.fill(tinted, Float.infinity)
            #expect(canvas.style.fill == previous)
            canvas.noFill()
            canvas.fill(tinted, -Float.infinity)
            #expect(!canvas.style.hasFill)

            canvas.stroke(previous)
            canvas.stroke(tinted, Float.nan)
            #expect(canvas.style.stroke == previous)
            canvas.noStroke()
            canvas.stroke(tinted, Float.infinity)
            #expect(!canvas.style.hasStroke)
        }
        #expect(canvas.warnings.hasWarned(.notANumberFill))
        #expect(canvas.warnings.hasWarned(.notANumberStroke))
        // 口ごとの文面 — 塗りと線は互いに黙らせない
        #expect(canvas.warnings.message(for: .notANumberFill)?.hasPrefix("fill()") == true)
        #expect(canvas.warnings.message(for: .notANumberStroke)?.hasPrefix("stroke()") == true)
    }

    /// 不透明度を 0–255 へ締めたら、口の名前・範囲・渡した値・使った値を 1 度だけ言う ([#1842])。
    /// 範囲の中の値は何も言わない。絵は変わらない (締める先は直す前と同じ)。
    ///
    /// [#1842]: https://github.com/mokume-metal/mokume/issues/1842
    @Test("不透明度を締めたら、口ごとに 1 度だけ言う")
    func clampedOpacityIsSaidOncePerEntry() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.fill(255, 400)
            canvas.stroke(255, 0, 0, -100)
            canvas.tint(255, 255, 255, 300)
            canvas.background(10, 20, 30, 256)
            // 2 度目は組み立て直さない — 別の値でも最初の文面のまま
            canvas.fill(255, 1000)
            canvas.fill(255, -5)
        }
        #expect(
            canvas.warnings.message(for: .roundedFillOpacity)
                == "fill(): the opacity takes 0 to 255, but 400.0 was passed, so 255 was used")
        #expect(
            canvas.warnings.message(for: .roundedStrokeOpacity)
                == "stroke(): the opacity takes 0 to 255, but -100.0 was passed, so 0 was used")
        #expect(
            canvas.warnings.message(for: .roundedTintOpacity)
                == "tint(): the opacity takes 0 to 255, but 300.0 was passed, so 255 was used")
        #expect(
            canvas.warnings.message(for: .roundedBackgroundOpacity)
                == "background(): the opacity takes 0 to 255, but 256.0 was passed, so 255 was used")
        // 数でない値の注意は別の鍵で、締めただけでは鳴らない
        #expect(!canvas.warnings.hasWarned(.notANumberFill))
    }

    @Test("色の値と不透明度の形 fill(c, alpha)・stroke(c, alpha) も、同じ鍵で言う")
    func clampedOpacityOfTheFadingForm() throws {
        let canvas = try makeCanvas()
        let base = color(230, 120, 40)
        try canvas.draw {
            canvas.fill(base, 400)
            canvas.stroke(base, -100)
        }
        #expect(
            canvas.warnings.message(for: .roundedFillOpacity)
                == "fill(): the opacity takes 0 to 255, but 400.0 was passed, so 255 was used")
        #expect(
            canvas.warnings.message(for: .roundedStrokeOpacity)
                == "stroke(): the opacity takes 0 to 255, but -100.0 was passed, so 0 was used")
    }

    @Test("範囲の内側の不透明度と、数でない不透明度では、締めた注意を言わない")
    func opacityInRangeIsSilent() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.fill(255, 0)
            canvas.fill(255, 255)
            canvas.stroke(1, 2, 3, 128)
            canvas.tint(255, 255, 255, 0.5)
            canvas.background(10, 20, 30, 255)
            canvas.fill(color(230, 120, 40), 255)
            // 数でない値は締めずに断る (別の鍵)
            canvas.fill(255, Float.nan)
        }
        #expect(!canvas.warnings.hasWarned(.roundedFillOpacity))
        #expect(!canvas.warnings.hasWarned(.roundedStrokeOpacity))
        #expect(!canvas.warnings.hasWarned(.roundedTintOpacity))
        #expect(!canvas.warnings.hasWarned(.roundedBackgroundOpacity))
        #expect(canvas.warnings.hasWarned(.notANumberFill))
    }

    @Test("触っていない口は、言ったことになっていない")
    func untouchedEntriesStaySilent() throws {
        let canvas = try makeCanvas()
        try canvas.draw { canvas.fill(255, 204, 0) }
        #expect(!canvas.warnings.hasWarned(.notANumberFill))
    }
}

/// 色の**値**を作る口が言う注意。GPU は要らない。
///
/// 控えはモジュールに 1 つなので、鍵ごとに数えていることだけを見る (この控えを触るのは
/// この suite だけである)。
@Suite("色の値を作る口が言う注意")
struct ColorValueWarningTests {
    @Test("素の数値の口と、色相の口は互いに黙らせない")
    func numericAndHSBCountSeparately() {
        #expect(color(Float.nan, 0, 0) == .transparent)
        #expect(color(hue: Float.nan, saturation: 80, brightness: 90) == .transparent)
        #expect(ColorValues.warnings.hasWarned(.notANumber))
        #expect(ColorValues.warnings.hasWarned(.notANumberHSB))
        #expect(ColorValues.warnings.message(for: .notANumber)?.hasPrefix("color()") == true)
        #expect(
            ColorValues.warnings.message(for: .notANumberHSB)?.hasPrefix("color(hue:") == true)
    }

    /// 2 色の間を取る口も、専用の鍵で数える ([#1552])。`color()` と鍵を共有すると、先に
    /// 鳴ったほうが他方を永久に黙らせる。
    ///
    /// [#1552]: https://github.com/mokume-metal/mokume/issues/1552
    @Test("2 色の間を取る口と、素の数値の口は互いに黙らせない")
    func lerpColorCountsSeparately() {
        let start = color(236, 238, 240)
        #expect(lerpColor(start, color(232, 96, 72), Float.nan) == start)
        #expect(color(Float.nan, 0, 0) == .transparent)
        #expect(ColorValues.warnings.hasWarned(.notANumberLerpColor))
        #expect(ColorValues.warnings.hasWarned(.notANumber))
        #expect(
            ColorValues.warnings.message(for: .notANumberLerpColor)?.hasPrefix("lerpColor()")
                == true)
        #expect(ColorValues.warnings.message(for: .notANumber)?.hasPrefix("color()") == true)
    }
}
