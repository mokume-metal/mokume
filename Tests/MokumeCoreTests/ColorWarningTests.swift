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

    @Test("同じ口を 2 度踏んでも、控えは 1 つ")
    func theSameEntrySpeaksOnce() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.fill(Float.nan, 0, 0)
            canvas.fill(Float.infinity, 0, 0)
        }
        // 文面が 1 度目のまま — 2 度目は組み立てられていない
        #expect(canvas.warnings.message(for: .notANumberFill)?.hasPrefix("fill()") == true)
        #expect(!canvas.warnings.hasWarned(.notANumberStroke))
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
        #expect(color(.nan, 0, 0) == .transparent)
        #expect(color(hue: .nan, saturation: 80, brightness: 90) == .transparent)
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
        #expect(lerpColor(start, color(232, 96, 72), .nan) == start)
        #expect(color(.nan, 0, 0) == .transparent)
        #expect(ColorValues.warnings.hasWarned(.notANumberLerpColor))
        #expect(ColorValues.warnings.hasWarned(.notANumber))
        #expect(
            ColorValues.warnings.message(for: .notANumberLerpColor)?.hasPrefix("lerpColor()")
                == true)
        #expect(ColorValues.warnings.message(for: .notANumber)?.hasPrefix("color()") == true)
    }
}
