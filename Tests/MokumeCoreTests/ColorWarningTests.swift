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
            canvas.fill(.nan, 0, 0)
            canvas.background(.nan, 0, 0)
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
            canvas.ambientLight(.nan, 0, 0)
            canvas.directionalLight(.nan, 0, 0, 0, 1, 0)
            canvas.emissive(.nan, 0, 0)
        }
        #expect(canvas.warnings.hasWarned(.notANumberAmbientLight))
        #expect(canvas.warnings.hasWarned(.notANumberDirectionalLight))
        #expect(canvas.warnings.hasWarned(.notANumberEmissive))
    }

    @Test("同じ口を 2 度踏んでも、控えは 1 つ")
    func theSameEntrySpeaksOnce() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.fill(.nan, 0, 0)
            canvas.fill(.infinity, 0, 0)
        }
        // 文面が 1 度目のまま — 2 度目は組み立てられていない
        #expect(canvas.warnings.message(for: .notANumberFill)?.hasPrefix("fill()") == true)
        #expect(!canvas.warnings.hasWarned(.notANumberStroke))
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
}
