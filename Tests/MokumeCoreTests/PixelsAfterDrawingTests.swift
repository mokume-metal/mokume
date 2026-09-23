// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 画素に触れたあとに描いたものを、続く読み書きが描き切ってから扱うかの検査
/// ([#1368])。GPU を要する。
///
/// `loadPixels()` の説明は「`pixels` も `get` も `set` も必要なら自分で呼ぶので、省いても
/// 結果は変わらない」と約束している。同じフレームで 1 度読んだだけで描き切らなくなると、
/// 読んだあとの図形は続く読み書きに現れず、古い写しが読める。**どの検査も
/// `loadPixels()` を呼ばない** — 呼べば描き切られるので、見たいものが見えなくなる。
///
/// [#1368]: https://github.com/mokume-metal/mokume/issues/1368
@Suite(
    "画素に触れたあとの描画",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PixelsAfterDrawingTests {
    // 目印の色は作業空間の原色で書く。半精度でも 0 と 1 はそのまま載るので、期待値を
    // 完全一致で書ける
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)
    private let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    /// 図形が溜まる並び。**描き切りが積むかを決める 3 つを 1 つずつ通す** — どれか 1 つだけ
    /// 数え漏らすと、その経路で描いた図形だけが読めなくなる。
    enum Path: CaseIterable, CustomTestStringConvertible {
        /// 矩形。基本図形の置き場所に溜まる。
        case form
        /// 三角形。周から組み立てた平面の頂点に溜まる。
        case flat
        /// 面。立体の頂点に溜まる。
        case solid

        var testDescription: String {
            switch self {
            case .form: "基本図形"
            case .flat: "平面の頂点"
            case .solid: "立体"
            }
        }

        /// 面の中央 (8, 8) を覆う図形を 1 つ置く。
        func draw(on canvas: Canvas) {
            switch self {
            case .form: canvas.rect(0, 0, 16, 16)
            case .flat: canvas.triangle(0, 0, 32, 0, 0, 32)
            case .solid:
                canvas.push()
                canvas.translate(8, 8, 0)
                canvas.plane(12, 12)
                canvas.pop()
            }
        }
    }

    // MARK: - 読む口が描き切り直す

    /// 完了条件 1・2 — 「読む → 描く → `loadPixels()` を呼ばずに `get`」で描いた色が返る。
    @Test("画素を読んだあとに描いた図形の色を、続く get が読む", arguments: Path.allCases)
    func getReadsShapesDrawnAfterAnEarlierRead(path: Path) throws {
        let canvas = try makeCanvas()
        var sampled = LinearRGBA.transparent
        try canvas.draw {
            canvas.background(black)
            _ = canvas.get(8, 8)
            canvas.noStroke()
            canvas.fill(green)
            path.draw(on: canvas)
            sampled = canvas.get(8, 8)
        }
        #expect(sampled == green, "読んだあとに描いた図形が描き切られず、古い写しを読んだ")
    }

    @Test("画素を読んだあとに描いた図形の色を、続く pixels が読む")
    func pixelsReadsShapesDrawnAfterAnEarlierRead() throws {
        let canvas = try makeCanvas()
        var sampled = LinearRGBA.transparent
        try canvas.draw {
            canvas.background(black)
            _ = canvas.pixels[8, 8]
            canvas.noStroke()
            canvas.fill(green)
            canvas.rect(0, 0, 16, 16)
            sampled = canvas.pixels[8, 8]
        }
        #expect(sampled == green, "読んだあとに描いた図形が描き切られず、古い写しを読んだ")
    }

    /// **塗り直しも絵を変える。** 図形が 1 つも溜まっていなくても、読んだあとの
    /// `background()` は続く読み取りに現れる。
    @Test("画素を読んだあとに塗り直した色を、続く get が読む")
    func getReadsABackgroundPaintedAfterAnEarlierRead() throws {
        let canvas = try makeCanvas()
        var sampled = LinearRGBA.transparent
        try canvas.draw {
            canvas.background(black)
            _ = canvas.get(8, 8)
            canvas.background(blue)
            sampled = canvas.get(8, 8)
        }
        #expect(sampled == blue, "読んだあとの塗り直しが描き切られず、古い写しを読んだ")
    }

    /// `set` も描き切ってから書く。**書いた画素は、書く前に描いた図形の上に載る** —
    /// 古い写しへ書くと、フレームの終わりにその写しが戻されてから図形が上へ描かれ、
    /// 書いた画素が図形に隠れる。
    @Test("画素を読んだあとに描いた図形の上に、set で書いた画素が載る")
    func setWritesOnTopOfShapesDrawnAfterAnEarlierRead() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            _ = canvas.get(0, 0)
            canvas.noStroke()
            canvas.fill(green)
            canvas.rect(0, 0, 8, 16)
            canvas.set(4, 8, red)
        }
        let pixels = try canvas.target.readPixels()
        #expect(pixels[4, 8] == red, "書いた画素が、書く前に描いた図形に隠れた")
        #expect(pixels[2, 8] == green, "書く前に描いた図形が残っていない")
        #expect(pixels[12, 8] == black)
    }

    /// 書いた画素と、そのあとの図形の順。**図形は書いた画素の上に載り、図形の外の
    /// 書いた画素はそのまま読める** — 描き切り直すときも、書き戻しが図形より先に積まれる。
    @Test("画素へ書いたあとに描いた図形を、続く get が書いた画素の上に読む")
    func getReadsShapesDrawnOverWrittenPixels() throws {
        let canvas = try makeCanvas()
        var covered = LinearRGBA.transparent
        var uncovered = LinearRGBA.transparent
        try canvas.draw {
            canvas.background(black)
            canvas.pixels.fill(red)
            canvas.noStroke()
            canvas.fill(green)
            canvas.rect(0, 0, 8, 16)
            covered = canvas.get(4, 8)
            uncovered = canvas.get(12, 8)
        }
        #expect(covered == green, "書いた画素の上に描いた図形が読めない")
        #expect(uncovered == red, "図形の外の、書いた画素が失われた")
        let pixels = try canvas.target.readPixels()
        #expect(pixels[4, 8] == green)
        #expect(pixels[12, 8] == red)
    }

    // MARK: - 描いていなければ使い回す (#753)

    /// 完了条件 3 — 描き切り直すのは、読んだあとに描いたときだけ。**描かずに読み書き
    /// するだけなら読み戻しは増えない**ので、このフレームが積む読み戻しはちょうど 2 本
    /// (最初に触れたときと、描いたあとに触れたとき) になる。
    @Test("読んだあとに描いたときだけ描き切り直し、描いていなければ写しを使い回す")
    func reloadsOnlyAfterDrawing() throws {
        let canvas = try makeCanvas()
        var written = LinearRGBA.transparent
        try canvas.draw {
            canvas.background(black)
            for y in 0..<16 {
                for x in 0..<16 { _ = canvas.get(x, y) }
            }
            // 書くのは描くことではない。CPU の側の写しが最新なので、そのまま読める
            canvas.set(1, 1, red)
            written = canvas.get(1, 1)
            _ = canvas.pixels
            #expect(canvas.target.pixelReadbacksEncoded == 1, "描いていないのに描き切り直した")

            canvas.noStroke()
            canvas.fill(green)
            canvas.rect(4, 4, 8, 8)
            for y in 0..<16 {
                for x in 0..<16 { _ = canvas.get(x, y) }
            }
            _ = canvas.pixels
        }
        #expect(written == red)
        #expect(
            canvas.target.pixelReadbacksEncoded == 2,
            "描いたあとに 1 度だけ描き切り直すはずが、\(canvas.target.pixelReadbacksEncoded) 本積んだ")
    }
}
