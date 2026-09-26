// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 大きさ 0 の文字を測る ([#1539])。
///
/// **測る口は、描く口と同じ大きさで測る。** `textSize` は 0 未満を 0 に締め、大きさ 0 の
/// 文字は描かれない。測る口 (``Canvas/textWidth(_:)``・``Canvas/textAscent()``・
/// ``Canvas/textDescent()``) だけがその 0 を書体へ渡し、CoreText が大きさ 0 を
/// 「書体ごとの既定の大きさ」と読み替えた値 (システム書体なら 13pt) を返していた。
/// 0.001 から 0 へ下げたところで、幅が 0 付近から 52 画素へ跳んでいた。
///
/// [#1539]: https://github.com/mokume-metal/mokume/issues/1539
@Suite(
    "大きさ 0 の文字を測る",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct TextZeroSizeTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 書体の名前 (`nil` は既定の書体) と、太さ・傾き。
    ///
    /// CoreText が大きさ 0 を読み替える大きさは書体ごとに違う (既定は 13pt、Helvetica は
    /// 12pt) ので、読み替えの先が違う 3 通りを見る。
    nonisolated static var faces: [(font: String?, style: TextStyle)] {
        [(nil, .normal), ("Helvetica", .normal), (nil, .bold)]
    }

    /// 0 と、0 に締まる負の大きさ。
    nonisolated static var sizes: [Float] { [0, -5] }

    nonisolated static var cases: [(font: String?, style: TextStyle, size: Float)] {
        faces.flatMap { face in sizes.map { (face.font, face.style, $0) } }
    }

    private func makeCanvas(font: String?, style: TextStyle = .normal) throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        if let font { canvas.textFont(font) }
        canvas.textStyle(style)
        return canvas
    }

    // MARK: - 測る口 (条件 1・2)

    @Test("大きさ 0 と負の大きさでは、幅・上端・下端がどれも 0", arguments: cases)
    func measuresAreZeroAtSizeZero(_ sample: (font: String?, style: TextStyle, size: Float)) throws {
        let canvas = try makeCanvas(font: sample.font, style: sample.style)
        canvas.textSize(sample.size)
        #expect(canvas.textWidth("mokume") == 0)
        #expect(canvas.textWidth("mokume\nmokume") == 0)
        #expect(canvas.textAscent() == 0)
        #expect(canvas.textDescent() == 0)
    }

    // MARK: - 0 の手前からの連続 (条件 3)

    @Test("0 の手前から 0 へ下げても、幅は跳ばない", arguments: faces)
    func widthIsContinuousDownToZero(_ face: (font: String?, style: TextStyle)) throws {
        let canvas = try makeCanvas(font: face.font, style: face.style)
        canvas.textSize(0.001)
        let tiny = canvas.textWidth("mokume")
        #expect(tiny <= 0.01)
        canvas.textSize(0)
        #expect(canvas.textWidth("mokume") <= tiny)
    }

    // MARK: - いまの約束 (条件 4)

    @Test("大きさ 0 では、流し込みは何も置かず、輪郭も返さない")
    func otherRoutesStayEmptyAtSizeZero() throws {
        let canvas = try makeCanvas(font: nil)
        canvas.textSize(0)
        var flow = TextFlow(lineCount: 1, height: 1, remainder: "")
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            flow = canvas.text("mokume mokume", 10, 10, 100, 100)
        }
        #expect(flow == TextFlow(lineCount: 0, height: 0, remainder: "mokume mokume"))
        #expect(canvas.textOutline("mokume", 10, 80).isEmpty)
    }
}
