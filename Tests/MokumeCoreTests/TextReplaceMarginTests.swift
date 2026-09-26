// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 置き換える混ぜ方で描いた文字の、字形の外の余白 ([#1557])。
///
/// **置き換える混ぜ方で描いた文字は、字形の掛かる画素だけを置き換える。** 字は字形の外接
/// 矩形に余白 2 画素を付けた四角として置かれ、字形の外では焼き場の α が 0 になる。置き換える
/// 列はそれを捨てずに書いていたので、字の周りの矩形 (`o` の穴の中も) の下地が透明に抜けて
/// いた。基本図形の置き換える列は、形の外の余白をすでに捨てている (`mokume_formIsBlank`)。
///
/// 「字形の被覆 0 の画素」は、同じ字を重ねる混ぜ方 (`.blend`) で描いたときに下地のまま
/// 残る画素とする。置き換えの結果を、実装から借りずに重ねる混ぜ方の絵から読む。字形の縁の
/// AA は、置き換える列で被覆の分の α がそのまま書かれる — 基本図形の縁と同じ扱いで、
/// ここでは見ない。
///
/// [#1557]: https://github.com/mokume-metal/mokume/issues/1557
@Suite(
    "置き換える混ぜ方で描いた文字の余白",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct TextReplaceMarginTests {
    private static let size = 160
    private static let tolerance: Float = 0.02

    private let red = LinearRGBA.display(red: 1, green: 0, blue: 0)
    private let blue = LinearRGBA.display(red: 0, green: 0, blue: 1)
    private let white = LinearRGBA.display(red: 1, green: 1, blue: 1)
    private let yellow = LinearRGBA.display(red: 1, green: 1, blue: 0)

    /// 描く字の一式。
    struct Sample: Sendable {
        let string: String
        let textSize: Float
        let x: Float
        let y: Float
    }

    private static let o = Sample(string: "o", textSize: 60, x: 50, y: 110)
    private static let hi = Sample(string: "Hi", textSize: 40, x: 20, y: 60)

    /// 下地を塗ってから、字を `mode` で描く。
    private func draw(
        _ sample: Sample, _ ink: LinearRGBA, on ground: LinearRGBA, mode: BlendMode,
        into canvas: Canvas
    ) {
        canvas.background(ground)
        canvas.noStroke()
        canvas.fill(ink)
        canvas.textSize(sample.textSize)
        canvas.blendMode(mode)
        canvas.text(sample.string, sample.x, sample.y)
    }

    private func render(
        _ sample: Sample, _ ink: LinearRGBA, on ground: LinearRGBA, mode: BlendMode
    ) throws -> PixelBuffer {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
        try canvas.draw { draw(sample, ink, on: ground, mode: mode, into: canvas) }
        return try canvas.target.readPixels()
    }

    /// どれかの成分の差が許容を超えるか。
    private func differs(_ a: LinearRGBA, _ b: LinearRGBA) -> Bool {
        abs(a.red - b.red) > Self.tolerance || abs(a.green - b.green) > Self.tolerance
            || abs(a.blue - b.blue) > Self.tolerance || abs(a.alpha - b.alpha) > Self.tolerance
    }

    /// 字形の被覆 0 の画素 — 重ねる混ぜ方で描いた絵で、下地のまま残った画素。
    ///
    /// **値が 1 ビットも変わらない画素**を数える。許容 (0.02) の内側で下地に近い画素には、
    /// 被覆がわずかに掛かる縁 (重ねれば下地にほぼ埋もれるが、置き換えれば被覆の分の α が
    /// そのまま書かれる) が混ざる。下地は字から遠い角 (0, 0) で読む。
    private func blankPixels(of sample: Sample, _ ink: LinearRGBA, on ground: LinearRGBA) throws
        -> [(x: Int, y: Int)]
    {
        let blended = try render(sample, ink, on: ground, mode: .blend)
        var blank: [(x: Int, y: Int)] = []
        for y in 0..<Self.size {
            for x in 0..<Self.size where blended[x, y] == blended[0, 0] {
                blank.append((x, y))
            }
        }
        return blank
    }

    /// 被覆 0 の画素のうち、置き換えで描いた絵で下地から変わった画素の数。
    private func disturbedBlankPixels(
        of sample: Sample, _ ink: LinearRGBA, on ground: LinearRGBA
    ) throws -> Int {
        let blank = try blankPixels(of: sample, ink, on: ground)
        let replaced = try render(sample, ink, on: ground, mode: .replace)
        return blank.count { differs(replaced[$0.x, $0.y], ground) }
    }

    // MARK: - 条件 1・2

    @Test("赤地に白い o を置き換えで描いても、字形の外の画素は下地のまま")
    func theMarginAroundOKeepsTheGround() throws {
        let disturbed = try disturbedBlankPixels(of: Self.o, white, on: red)
        #expect(disturbed == 0)
    }

    @Test("o の穴の中心は、置き換えで描いても下地のまま")
    func theHoleOfOKeepsTheGround() throws {
        let blended = try render(Self.o, white, on: red, mode: .blend)
        // 穴の中心は、墨の外接矩形の中心に置く
        var ink: [(x: Int, y: Int)] = []
        for y in 0..<Self.size {
            for x in 0..<Self.size where differs(blended[x, y], red) { ink.append((x, y)) }
        }
        let xs = ink.map(\.x)
        let ys = ink.map(\.y)
        let center = (
            x: (try #require(xs.min()) + xs.max()!) / 2, y: (try #require(ys.min()) + ys.max()!) / 2
        )
        // 重ねる混ぜ方では、穴の中心は下地のまま (字形が掛からない所を指している)
        try #require(!differs(blended[center.x, center.y], red))

        let replaced = try render(Self.o, white, on: red, mode: .replace)
        let pixel = replaced[center.x, center.y]
        #expect(!differs(pixel, red), "穴の中心 \(center) が下地から変わった: \(pixel)")
    }

    @Test("青地に黄の Hi を置き換えで描いても、字形の外の画素は下地のまま")
    func theMarginAroundHiKeepsTheGround() throws {
        let disturbed = try disturbedBlankPixels(of: Self.hi, yellow, on: blue)
        #expect(disturbed == 0)
    }

    // MARK: - 条件 3

    @Test("描き場所に置き換えで書いた字を貼っても、字形の外から下の色が見えない")
    func aGraphicsLayerKeepsItsGroundAroundTheGlyph() throws {
        let blank = try blankPixels(of: Self.o, white, on: red)

        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
        let layer = try canvas.createGraphics(Self.size, Self.size)
        layer.beginDraw()
        draw(Self.o, white, on: red, mode: .replace, into: layer)
        layer.endDraw()
        try canvas.draw {
            canvas.background(blue)
            canvas.image(layer, 0, 0)
        }
        let placed = try canvas.target.readPixels()
        #expect(blank.count { differs(placed[$0.x, $0.y], red) } == 0)
    }

    // MARK: - 字でないものは、いままでどおり置き換える

    @Test("貼る絵の透けた所は、置き換えでいままでどおり下地を透明にする")
    func aPictureStillReplacesWithItsTransparency() throws {
        // 捨てるのは字の焼き場を読む列だけ。絵の透けた所まで捨てると、置き換えは α 0 も
        // 置き換えるという約束 (#1542) が絵の側で崩れる
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
        let pad = try canvas.createGraphics(80, 80)
        pad.beginDraw()
        pad.noStroke()
        pad.fill(white)
        pad.circle(40, 40, 40)
        pad.endDraw()
        try canvas.draw {
            canvas.background(red)
            canvas.blendMode(.replace)
            canvas.image(pad, 40, 40)
        }
        let placed = try canvas.target.readPixels()
        // 絵の角 (透けた所) は透明に、円の中は白になる
        #expect(!differs(placed[45, 45], LinearRGBA(premultipliedRed: 0, green: 0, blue: 0, alpha: 0)))
        #expect(!differs(placed[80, 80], white))
        // 絵の外は下地のまま
        #expect(!differs(placed[20, 20], red))
    }

    // MARK: - 条件 4

    @Test("字形が掛かる画素のうち、縁を除く中の画素は置き換えた色になる", arguments: [false, true])
    func theInsideOfTheGlyphIsReplaced(_ useHi: Bool) throws {
        let (sample, ink, ground) = useHi ? (Self.hi, yellow, blue) : (Self.o, white, red)
        let blended = try render(sample, ink, on: ground, mode: .blend)
        let replaced = try render(sample, ink, on: ground, mode: .replace)
        var inside = 0
        var wrong = 0
        for y in 0..<Self.size {
            // 重ねる混ぜ方で字の色そのもの (α 1) になった画素が、縁の AA を除く中の画素
            for x in 0..<Self.size where !differs(blended[x, y], ink) {
                inside += 1
                if differs(replaced[x, y], ink) { wrong += 1 }
            }
        }
        try #require(inside > 0)
        #expect(wrong == 0)
    }
}
