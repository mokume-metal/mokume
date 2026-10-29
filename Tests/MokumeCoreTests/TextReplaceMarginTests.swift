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
/// AA は、被覆の残りに下地を残す (基本図形の縁と同じ読み・[#3111]) — 不透明な字を不透明な
/// 下地へ描くと、置き換える混ぜ方は重ねる混ぜ方と同じ絵になる (縁の検査は条件 5)。
///
/// [#1557]: https://github.com/mokume-metal/mokume/issues/1557
/// [#3111]: https://github.com/mokume-metal/mokume/issues/3111
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

    // MARK: - 条件 5

    @Test("字形の縁の画素は、置き換えで描いても下地を被覆の残りだけ残す (不透明な字は重ねる絵と同じ)", arguments: [false, true])
    func theEdgeOfTheGlyphKeepsTheGround(_ useHi: Bool) throws {
        let (sample, ink, ground) = useHi ? (Self.hi, yellow, blue) : (Self.o, white, red)
        let blended = try render(sample, ink, on: ground, mode: .blend)
        let replaced = try render(sample, ink, on: ground, mode: .replace)
        var edge = 0
        var wrong = 0
        for y in 0..<Self.size {
            for x in 0..<Self.size {
                let b = blended[x, y]
                // 縁の画素: 下地でも字の色そのものでもない
                if differs(b, ground) && differs(b, ink) { edge += 1 }
                let r = replaced[x, y]
                let gap = max(
                    abs(r.red - b.red), abs(r.green - b.green), abs(r.blue - b.blue),
                    abs(r.alpha - b.alpha))
                if gap > 1.0 / 255 { wrong += 1 }
            }
        }
        try #require(edge > 20)
        #expect(wrong == 0, "\(wrong) 画素が重ねる絵と違う。縁の画素が下地を消している")
    }

    // MARK: - 条件 6 — 縁で下地を残さない字

    /// 置き換えで描いた絵が、下地に依らないか。2 つの下地へ同じ絵を描き、**下地のまま残った画素を除いて**
    /// 全画素が一致することを見る。下地を混ぜる画素 (縁で下地を残す) があれば、下地ごとに値が違う。
    private func groundIndependence(
        _ body: (Canvas) -> Void
    ) throws -> (touched: Int, dependent: Int, brightest: Float) {
        func render(on ground: LinearRGBA) throws -> PixelBuffer {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
            try canvas.draw {
                canvas.background(ground)
                body(canvas)
            }
            return try canvas.target.readPixels()
        }
        let (first, second) = (red, blue)
        let (a, b) = (try render(on: first), try render(on: second))
        var touched = 0
        var dependent = 0
        var brightest: Float = 0
        for y in 0..<Self.size {
            for x in 0..<Self.size {
                let (p, q) = (a[x, y], b[x, y])
                brightest = max(brightest, p.red, p.green, p.blue, p.alpha)
                if !differs(p, first) && !differs(q, second) { continue }
                touched += 1
                if differs(p, q) { dependent += 1 }
            }
        }
        return (touched, dependent, brightest)
    }

    @Test("色を持つ字形 (絵文字) は、置き換えで描くと透けた画素をそのまま写し、縁で下地を残さない")
    func aColoredGlyphCopiesItsTransparentPixels() throws {
        let result = try groundIndependence { canvas in
            canvas.noStroke()
            canvas.fill(white)
            canvas.textSize(70)
            canvas.blendMode(.replace)
            canvas.text("\u{1F600}", 40, 110)
        }
        try #require(result.touched > 200, "絵文字が描けていない (\(result.touched))")
        #expect(result.dependent == 0, "\(result.dependent) 画素が下地と混ざった")
    }

    @Test("利用者の断片が効いている字は、置き換えで描くと色をそのまま置き、1 を越えず下地にも依らない")
    func aShaderedGlyphKeepsItsOwnCoverage() throws {
        let result = try groundIndependence { canvas in
            // 字の被覆 (in.texel) を掛けない断片。`S + D·(1 − 被覆)` にすると縁で 1 を越える
            guard
                let shader = try? canvas.makeShader(
                    "float4 paint(Fragment in, Values values) { return in.color; }")
            else { return }
            canvas.noStroke()
            canvas.fill(white)
            canvas.textSize(60)
            canvas.shader(shader)
            canvas.blendMode(.replace)
            canvas.text("o", 50, 110)
        }
        try #require(result.touched > 200, "字が描けていない (\(result.touched))")
        #expect(result.dependent == 0, "\(result.dependent) 画素が下地と混ざった")
        #expect(result.brightest <= 1 + 1.0 / 255, "字の縁で値が 1 を越えた: \(result.brightest)")
    }

    /// **単色の字と色を持つ字形が 1 回の `text()` に交互に並んでも、それぞれの読みが守られる** (#3111)。
    /// 種類が替わるたびに列を閉じる (``Canvas/openBatchGlyphColored``) ので、先送りした字の列の途中で列が
    /// 閉じる。見るのは字ごとの範囲: 単色の字は不透明な字を不透明な下地へ置くと重ねる混ぜ方の絵と同じ
    /// (縁で下地を残す)、絵文字は下地 2 色で同じ絵 (透けた画素をそのまま写す)。
    @Test("単色の字と絵文字が交互に並んでも、単色の縁は下地を残し、絵文字は透けた画素を写す")
    func monochromeAndColoredGlyphsInOneRun() throws {
        let string = "a\u{1F600}b\u{1F600}c"
        let (width, height) = (320, 100)
        func render(on ground: LinearRGBA, mode: BlendMode) throws -> (PixelBuffer, Canvas) {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
            try canvas.draw {
                canvas.background(ground)
                canvas.noStroke()
                canvas.fill(white)
                canvas.textSize(40)
                canvas.blendMode(mode)
                canvas.text(string, 10, 70)
            }
            return (try canvas.target.readPixels(), canvas)
        }
        let (onRed, canvas) = try render(on: red, mode: .replace)
        let onBlue = try render(on: blue, mode: .replace).0
        let blended = try render(on: red, mode: .blend).0
        // 字ごとの範囲 (送り幅から。内側へ 3 画素寄せて、隣の字の張り出しを避ける)
        func range(_ from: String, _ to: String) -> Range<Int> {
            let lower = 10 + Int(canvas.textWidth(from)) + 3
            let upper = 10 + Int(canvas.textWidth(to)) - 3
            return lower..<upper
        }
        let emoji = [range("a", "a\u{1F600}"), range("a\u{1F600}b", "a\u{1F600}b\u{1F600}")]
        let mono = [range("", "a"), range("a\u{1F600}", "a\u{1F600}b"), range("a\u{1F600}b\u{1F600}", string)]
        for columns in emoji {
            var touched = 0
            var dependent = 0
            for y in 0..<height {
                for x in columns {
                    let (p, q) = (onRed[x, y], onBlue[x, y])
                    if !differs(p, red) || !differs(q, blue) { continue }
                    touched += 1
                    if differs(p, q) { dependent += 1 }
                }
            }
            try #require(touched > 100, "絵文字が描けていない (\(touched))")
            #expect(dependent == 0, "絵文字の範囲 \(columns) の \(dependent) 画素が下地と混ざった")
        }
        for columns in mono {
            var edge = 0
            var wrong = 0
            for y in 0..<height {
                for x in columns {
                    let b = blended[x, y]
                    if differs(b, red) && differs(b, white) { edge += 1 }
                    let r = onRed[x, y]
                    let gap = max(
                        abs(r.red - b.red), abs(r.green - b.green), abs(r.blue - b.blue),
                        abs(r.alpha - b.alpha))
                    if gap > 1.0 / 255 { wrong += 1 }
                }
            }
            try #require(edge > 5, "字の縁の画素が少ない (\(edge))")
            #expect(wrong == 0, "単色の字の範囲 \(columns) の \(wrong) 画素が重ねる絵と違う。縁が下地を消している")
        }
    }
}
