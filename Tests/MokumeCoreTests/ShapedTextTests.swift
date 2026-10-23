// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import Testing

@testable import MokumeCore

/// 組版した文字列を描く・測る入口 (`shapedText`・`shapedTextWidth`・`shapedTextBounds`・#2404)。
///
/// 既存の `text()`・`textWidth()` (スカラ 1 つずつ・幅の加法性) は変えない。**新しい口は、描く・幅・整列・
/// 墨の範囲が 1 つの組版結果から出る。** 物差しは、書体の版に依らない性質 — 1 字で出る (字形の数・描いた画素の
/// かたまりの数)・墨の枠が描いた画素と合う・整列が幅だけずれる — に置く。
@Suite("組版した文字列")
struct ShapedTextTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 絵文字の列 (#2311 の例)。肌色の修飾子・国旗・ZWJ の家族・異体字セレクタ・囲み。
    private static let emoji = ["👍🏽", "🇯🇵", "👨‍👩‍👧", "❤️", "1️⃣"]

    private func face(size: Float = 40) -> Typeface {
        Typeface(
            request: TypefaceRequest(name: "Helvetica", size: size, style: .normal),
            onFallbackLackingStyle: { _, _, _ in })
    }

    /// 代わりの書体の知らせを数える書体。`notes` に、知らせた字を積む。
    private final class Notes { var scalars: [Unicode.Scalar] = [] }

    private func face(
        name: String? = "Helvetica", file: Font? = nil, size: Float = 40, style: TextStyle,
        notes: Notes = Notes()
    ) -> Typeface {
        Typeface(
            request: TypefaceRequest(name: name, file: file, size: size, style: style),
            onFallbackLackingStyle: { _, scalar, _ in notes.scalars.append(scalar) })
    }

    /// 字形の列の見分け (書体の鍵と字形の番号)。
    private func identities(_ line: ShapedLine) -> [String] {
        line.glyphs.map { "\($0.resolved.fontKey)#\($0.resolved.glyph)" }
    }

    // MARK: - 組版の結果 (GPU を要らない)

    @Test(
        "複数のスカラでできた絵文字は、組版すると 1 つの字形になり、幅は 1 字ぶん。スカラ 1 つずつでは部品に分かれる",
        .enabled(if: TextTests.hasColoredGlyphs, "この環境には色を持つ字形の書体が無い"))
    func composedEmojiAreOneGlyph() {
        let face = face()
        for string in Self.emoji {
            let line = face.shape(string)
            #expect(line.glyphs.count == 1, "\(string): 字形 \(line.glyphs.count) 個")
            // 1 字ぶん (大きさと同じ幅の升目)。部品の幅の和にならない
            #expect(abs(line.width - 40) < 1, "\(string): 幅 \(line.width)")
        }
        // スカラ 1 つずつの幅は、修飾子・国旗・家族では 2 字・3 字ぶんになる
        #expect(face.advance(of: "👍🏽") > face.shape("👍🏽").width + 1)
        #expect(face.advance(of: "👨‍👩‍👧") > face.shape("👨‍👩‍👧").width + 1)
    }

    @Test("結合文字は、基の字と 1 つの位置に重なる (幅は基の字の幅のまま、分かれた字形は基の上に載る)")
    func combiningMarkOverlapsItsBase() {
        let face = face()
        let line = face.shape("e\u{0301}")
        let base = face.shape("e")
        #expect(abs(line.width - base.width) < 0.01, "幅 \(line.width) / e の幅 \(base.width)")
        // 字形が分かれる書体でも、結合記号は基の字の送りの内に置かれる (右へ送らない)
        for glyph in line.glyphs { #expect(glyph.x < base.width, "字形が \(glyph.x) に置かれた") }
    }

    @Test("組版した幅は部分の和にならない (カーニング) が、text() の幅は和のまま")
    func shapedWidthIsNotAdditiveButTheOldOneIs() {
        let face = face()
        let kerned = face.shape("AV").width
        let apart = face.shape("A").width + face.shape("V").width
        #expect(kerned < apart - 0.5, "AV: 組版 \(kerned) / 部品の和 \(apart)")
        // 既存の口は動かない
        #expect(face.advance(of: "AV") == face.advance(of: "A") + face.advance(of: "V"))
        #expect(face.advance(of: "👍🏽") == face.advance(of: "👍") + face.advance(of: "🏽"))
    }

    @Test("同じ文字列の組版は控えから返る")
    func shapedLinesAreCached() {
        let face = face()
        #expect(face.shape("mokume") === face.shape("mokume"))
        #expect(face.shaped.made == 1)
    }

    /// 控えは字形の数で上限を持ち、超えたら古い順に 1 件ずつ捨てる (ADR-0023 決定 5)。全部は捨てない。
    @Test("控えは字形の数で上限を持ち、超えたら古い順に 1 件ずつ捨てる (全部は捨てない)")
    func shapedLinesAreBoundedByWeightAndEvictedOneByOne() {
        let face = face()
        face.shaped.budget = 25
        let first = face.shape("0123456789")  // 重さ 10
        let second = face.shape("abcdefghij")  // 重さ 10 (合計 20)
        _ = face.shape("0123456789")  // first を使い直す: 古いのは second になる
        let third = face.shape("ABCDEFGHIJ")  // 合計 30 が 25 を超える → second だけが落ちる
        #expect(face.shaped.count == 2, "1 件ずつ捨てるので 2 件が残る: \(face.shaped.count)")
        #expect(face.shape("0123456789") === first)
        #expect(face.shape("ABCDEFGHIJ") === third)
        #expect(face.shape("abcdefghij") !== second, "最後に使ったのが古い second が落ちる")
        // 重さは字形の数 — 長い文字列 1 本は、短い文字列何本ぶんかを押し出す
        face.shaped.budget = 12
        for number in 0..<100 { _ = face.shape("n\(number)") }
        #expect(face.shaped.total <= 12, "重さの合計 \(face.shaped.total)")
    }

    @Test("300 本の違う文字列を毎フレーム組んでも、2 回目からは組み直さない")
    func manyLinesAreNotReshapedEveryFrame() {
        let face = face()
        let lines = (0..<300).map { "mokume \($0) AV" }
        for line in lines { _ = face.shape(line) }
        let made = face.shaped.made
        let kept = lines.map { face.shape($0) }
        for _ in 0..<3 { for line in lines { _ = face.shape(line) } }
        #expect(face.shaped.made == made, "2 回目から組み直した: \(face.shaped.made - made) 回")
        #expect(face.shape(lines[0]) === kept[0] && face.shape(lines[299]) === kept[299])
    }

    /// Swift の `String` は等価を正準等価で取る。字形の違う文字列が同じ鍵になって、先に組んだほうの結果が
    /// 返らない (`text()` の控えは `Unicode.Scalar` が鍵で起きない)。
    /// 書体は名指す — 代わりの書体に任せると、機械によって 2 つを同じ字形で描く書体 (PingFang) が選ばれ、
    /// 前提が崩れる (CI の機械で起きた)。Hiragino Sans と Helvetica は macOS に標準で入る。
    nonisolated static let canonicallyEquivalent: [(typeface: String, a: String, b: String)] = [
        ("Hiragino Sans", "\u{4FAE}", "\u{FA30}"),
        ("Helvetica", "\u{03A9}", "\u{2126}"),
        ("Helvetica", "\u{00C5}", "\u{212B}"),
    ]

    @Test("正準等価な 2 つの文字列は、別の鍵で別の字形のまま、組む順に依らない", arguments: canonicallyEquivalent)
    func canonicallyEquivalentLinesStayApart(_ pair: (typeface: String, a: String, b: String)) throws {
        let (name, a, b) = pair
        let face = { self.face(name: name, style: .normal) }
        try #require(a == b, "前提: Swift の String では等しい")
        #expect(ShapedLineKey(line: a) != ShapedLineKey(line: b))
        let alone = identities(face().shape(b))
        try #require(alone != identities(face().shape(a)), "前提: \(name) で字形が違う")
        let order = face()
        _ = order.shape(a)
        #expect(identities(order.shape(b)) == alone, "先に組んだ \(a.unicodeScalars.first!) の結果が返った")
        let reverse = face()
        _ = reverse.shape(b)
        #expect(identities(reverse.shape(a)) == identities(face().shape(a)))
    }

    // MARK: - 代わりの書体 (text() と揃える)

    @Test("代わりの書体の区間は、頼んだ太さの面へ引き直す: Apple Chancery の太字の「あ」は、text() と同じ太字の面")
    func aFallbackRunIsRestyledToTheRequestedFace() throws {
        let typeface = face(name: "Apple Chancery", style: .bold)
        // 前提: CoreText は、太字を持てなかった (劣化した) base に合わせて細い代わりを選び、その家族に太字の面がある
        let picked = CTFontCreateForString(typeface.base, "あ" as CFString, CFRangeMake(0, 1))
        let boldFace = CTFontCreateCopyWithSymbolicTraits(picked, 40, nil, .traitBold, .traitBold)
        try #require(!CTFontGetSymbolicTraits(picked).contains(.traitBold), "前提: 細い面が選ばれる")
        try #require(
            boldFace.map { CTFontGetSymbolicTraits($0).contains(.traitBold) } == true,
            "前提: 代わりの書体の家族に太字の面がある")
        let shaped = typeface.shape("aあb")
        let kana = try #require(shaped.glyphs.dropFirst().first)
        let read = try #require(typeface.glyph(for: "あ"))
        #expect(CTFontGetSymbolicTraits(kana.resolved.font).contains(.traitBold), "\(kana.resolved.fontKey)")
        #expect(kana.resolved.fontKey == read.fontKey && kana.resolved.glyph == read.glyph)
        // 基の字の側は動かない
        #expect(shaped.glyphs.first?.resolved.fontKey == typeface.glyph(for: "a")?.fontKey)
    }

    @Test("頼んだ面が引けない代わりの書体の区間は、text() と同じに 1 度知らせる")
    func aFallbackRunLackingTheStyleIsNotified() throws {
        let notes = Notes()
        let line = face(style: .italic, notes: notes).shape("aあb")
        let kana = try #require(line.glyphs.dropFirst().first)
        let read = try #require(face(style: .italic).glyph(for: "あ"), "前提: text() が「あ」を引く")
        #expect(kana.resolved.fontKey == read.fontKey, "text() が引く面と違う: \(kana.resolved.fontKey)")
        #expect(notes.scalars == ["あ"], "知らせた字: \(notes.scalars)")
        // 何も頼まなければ知らせない
        let quiet = Notes()
        _ = face(style: .normal, notes: quiet).shape("aあb")
        #expect(quiet.scalars.isEmpty)
    }

    @Test("区間の中の字ごとに頼んだ面で引き直し、面が覆えない字だけ元の面に残して知らせる (text() と同じ)")
    func aFallbackRunIsRestyledPerCharacter() throws {
        let notes = Notes()
        let typeface = face(name: "Apple Chancery", style: .bold, notes: notes)
        let reader = face(name: "Apple Chancery", style: .bold)
        let (c, a) = ("\u{0108}", "\u{0200}")
        let (readC, readA) = (
            try #require(reader.glyph(for: Unicode.Scalar(c.unicodeScalars.first!.value)!)),
            try #require(reader.glyph(for: Unicode.Scalar(a.unicodeScalars.first!.value)!))
        )
        try #require(readC.fontKey != readA.fontKey, "前提: text() は 2 字を別の面で引く (一方は頼んだ面を持たない)")
        let line = typeface.shape(c + a)
        try #require(line.glyphs.count == 2)
        #expect(line.glyphs[0].resolved.fontKey == readC.fontKey, "\(line.glyphs[0].resolved.fontKey)")
        #expect(line.glyphs[1].resolved.fontKey == readA.fontKey, "\(line.glyphs[1].resolved.fontKey)")
        #expect(notes.scalars == [Unicode.Scalar(0x0200)!], "\(notes.scalars)")
    }

    @Test("知らせる字は、書体が持たない字 (書記素の先頭ではない): Helvetica の斜体の 1 + 囲み記号は囲み記号")
    func theNotifiedScalarIsTheOneTheTypefaceLacks() throws {
        let notes = Notes()
        _ = face(style: .italic, notes: notes).shape("1\u{20E3}")
        #expect(notes.scalars == [Unicode.Scalar(0x20E3)!], "\(notes.scalars)")
    }

    @Test("ファイルから読んだ書体の字は、ファイルの同一性を鍵に持ち、代わりの書体の字は持たない (text() と同じ)")
    func fileFontKeysFollowTheSameStructure() throws {
        let file = try Font.load(FontFileTests.staticFile)
        let typeface = face(name: nil, file: file, style: .normal)
        let line = typeface.shape("aあb")
        try #require(line.glyphs.count == 3)
        let latin = try #require(typeface.glyph(for: "a"))
        let kana = try #require(typeface.glyph(for: "あ"))
        #expect(line.glyphs[0].resolved.fontKey == latin.fontKey)
        #expect(line.glyphs[0].resolved.fontKey.hasSuffix("#" + file.identity))
        #expect(line.glyphs[1].resolved.fontKey == kana.fontKey)
        #expect(!line.glyphs[1].resolved.fontKey.contains("#"))
    }

    // MARK: - 基の字の書体 (書記素の移し)

    /// 基の字 `a` の後ろに付けると、書体が持たなければ CoreText が書記素ごと別の書体へ移す印・修飾 (反証役の
    /// 43 字)。移されても `a` は書体に残る。
    nonisolated static let marks: [UInt32] = [
        0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B, 0x180C, 0x180D, 0x180E, 0x180F, 0x200B,
        0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202C, 0x202E, 0x2060, 0x2061, 0x2064, 0x2066, 0x2069,
        0x206A, 0x206F, 0x3164, 0xFE00, 0xFE01, 0xFE0E, 0xFE0F, 0xFEFF, 0xFFA0, 0x1BCA0, 0x1D173, 0xE0001,
        0xE0020, 0xE0067, 0xE007F, 0xE0100, 0xE01EF, 0x1F3FB, 0x20E3,
    ]
    /// 空の名前はシステムの書体。
    nonisolated static let baseFonts = [
        "Helvetica", "Apple Chancery", "Georgia", "Menlo", "Times New Roman", "Avenir Next", "Futura",
        "Hiragino Mincho ProN", "Optima", "Didot", "",
    ]

    @Test("書体が覆える字は、後ろに付く印や修飾の書体が違っても書体を替えない", arguments: baseFonts)
    func aLetterStaysInItsTypefaceBesideMarks(_ name: String) throws {
        let typeface = face(name: name.isEmpty ? nil : name, style: .normal)
        let plain = try #require(typeface.glyph(for: "a"))
        var moved: [String] = []
        for mark in Self.marks {
            let scalar = try #require(Unicode.Scalar(mark))
            let line = typeface.shape("a" + String(scalar))
            let first = try #require(line.glyphs.first, "U+\(String(mark, radix: 16))")
            if !CFEqual(first.resolved.font, typeface.base) || first.resolved.glyph != plain.glyph {
                moved.append("U+\(String(mark, radix: 16)) → \(first.resolved.fontKey)")
            }
        }
        #expect(moved.isEmpty, "\(name): \(moved)")
        // 印は幅を変えない (字形を持たない印) か、別の書体の字として後ろへ並ぶ
        #expect(typeface.shape("a\u{FE0F}").width == typeface.shape("a").width)
    }

    @Test("絵文字から始まる書記素 (合成絵文字) は、CoreText のまま 1 字になる")
    func emojiSequencesStayOneGlyph() throws {
        try #require(TextTests.hasColoredGlyphs, "この環境には色を持つ字形の書体が無い")
        let typeface = face()
        for string in [
            "👨\u{200D}👩\u{200D}👧", "👍🏽", "🇯🇵", "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
            "\u{2764}\u{FE0F}", "1\u{FE0F}\u{20E3}", "1\u{20E3}\u{FE0F}", "\u{00A9}\u{FE0F}",
        ] {
            let line = typeface.shape(string)
            #expect(line.glyphs.count == 1, "\(string.unicodeScalars.map(\.value)): \(identities(line))")
            #expect(line.glyphs.first?.resolved.fontKey == "AppleColorEmoji")
        }
    }

    @Test("絵文字を持たない字の後ろの肌色の修飾子は、字の隣に色の四角として並び、字の書体を替えない")
    func aModifierAfterALetterStandsBesideIt() throws {
        try #require(TextTests.hasColoredGlyphs, "この環境には色を持つ字形の書体が無い")
        let line = face().shape("a\u{1F3FD}b")
        #expect(line.glyphs.count == 3)
        #expect(line.glyphs.map(\.resolved.fontKey) == ["Helvetica", "AppleColorEmoji", "Helvetica"])
    }

    // MARK: - タブ

    @Test("タブは text() と同じ送り幅: 大きな字でもつぶれない", arguments: [12 as Float, 40, 200])
    func tabsAdvanceLikeTheOldEntry(size: Float) throws {
        let typeface = face(size: size, style: .normal)
        let tab = typeface.advance(of: "\t")
        try #require(tab > 1, "前提: タブの字形は送りを持つ")
        for string in ["a\tb", "\ta", "a\t", "a\t\tb", "\t"] {
            let shaped = typeface.shape(string).width
            #expect(abs(shaped - typeface.advance(of: string)) < 0.01, "\(string.debugDescription): 組版 \(shaped)")
        }
        let b = try #require(typeface.shape("a\tb").glyphs.last)
        #expect(abs(b.x - typeface.advance(of: "a\t")) < 0.01)
    }

    // MARK: - 描く・測る (GPU を要する)

    @Suite(
        "描く・測る",
        .enabled(
            if: RenderDevice.isAvailable,
            "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
    )
    struct Drawing {
        private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
        private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
        private static let width = 400
        private static let height = 100

        private func makeCanvas(size: Float = 40) throws -> Canvas {
            let canvas = try CanvasFixture.make(
                gpu: RenderDevice(), width: Self.width, height: Self.height)
            canvas.textFont("Helvetica")
            canvas.textSize(size)
            return canvas
        }

        /// 1 フレーム描いて読み戻す。
        private func render(_ canvas: Canvas, _ body: () -> Void) throws -> DisplayImage {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                body()
            }
            return try canvas.target.encodeForDisplay()
        }

        private func isInk(_ image: DisplayImage, _ x: Int, _ y: Int) -> Bool {
            let pixel = image[x, y]
            return pixel.red > 8 || pixel.green > 8 || pixel.blue > 8
        }

        /// 墨の外接矩形。何も描かれていなければ `nil`。
        private func inkBounds(_ image: DisplayImage) -> (left: Int, top: Int, right: Int, bottom: Int)? {
            var (left, top, right, bottom) = (Int.max, Int.max, Int.min, Int.min)
            for y in 0..<Self.height {
                for x in 0..<Self.width where isInk(image, x, y) {
                    left = min(left, x)
                    top = min(top, y)
                    right = max(right, x)
                    bottom = max(bottom, y)
                }
            }
            return left <= right ? (left, top, right, bottom) : nil
        }

        /// 横に並んだ墨のかたまりの数。墨の列が `gap` 画素より離れたら別のかたまり。
        private func inkClusters(_ image: DisplayImage, gap: Int = 3) -> Int {
            var clusters = 0
            var lastInkColumn = -gap - 1
            for x in 0..<Self.width {
                guard (0..<Self.height).contains(where: { isInk(image, x, $0) }) else { continue }
                if x - lastInkColumn > gap { clusters += 1 }
                lastInkColumn = x
            }
            return clusters
        }

        @Test(
            "#2311 の 5 つの絵文字は、組版すると 5 つのかたまりで描かれ、墨の枠が描いた画素と合う",
            .enabled(if: TextTests.hasColoredGlyphs, "この環境には色を持つ字形の書体が無い"))
        func fiveEmojiAreFiveShapes() throws {
            let string = ShapedTextTests.emoji.joined(separator: " ")
            let canvas = try makeCanvas()
            let image = try render(canvas) { canvas.shapedText(string, 10, 70) }
            #expect(inkClusters(image) == 5)
            let ink = try #require(inkBounds(image))
            let bounds = try #require(canvas.shapedTextBounds(string, 10, 70))
            #expect(abs(bounds.x - Float(ink.left)) <= 2)
            #expect(abs(bounds.y - Float(ink.top)) <= 2)
            #expect(abs(bounds.x + bounds.width - Float(ink.right)) <= 2)
            #expect(abs(bounds.y + bounds.height - Float(ink.bottom)) <= 2)
            // 幅は 5 字と 4 つの空白
            let expected = 5 * 40 + 4 * canvas.shapedTextWidth(" ")
            #expect(abs(canvas.shapedTextWidth(string) - expected) < 1)

            // 同じ文字列をスカラ 1 つずつで描くと、5 つより広く、部品に分かれる
            let old = try render(canvas) { canvas.text(string, 10, 70) }
            let oldInk = try #require(inkBounds(old))
            #expect(oldInk.right > ink.right + 20, "スカラ 1 つずつの墨 \(oldInk.right) / 組版 \(ink.right)")
        }

        /// `e` + 結合アクセントは、この書体では合成済みの字形 1 つになる。`x` + 結合アクセントは合成済みの
        /// 字形が無く、結合記号の字形を基の字の上へずらして置く (字形の位置の `y` が 0 でない)。
        @Test("結合文字は、組版すると 1 つの位置に重なって描かれ、アクセントは基の字の上に載る", arguments: ["e", "x"])
        func combiningAccentSitsOnTheLetter(base: String) throws {
            let canvas = try makeCanvas(size: 60)
            let accented = base + "\u{0301}"
            let image = try render(canvas) { canvas.shapedText(accented, 40, 70) }
            let plain = try render(canvas) { canvas.shapedText(base, 40, 70) }
            let ink = try #require(inkBounds(image))
            let plainInk = try #require(inkBounds(plain))
            // アクセントの分だけ上に伸び、横には基の字の墨より外へ出ない
            #expect(ink.top < plainInk.top - 3, "アクセントの上端 \(ink.top) / 基の字の上端 \(plainInk.top)")
            #expect(ink.left >= plainInk.left - 2 && ink.right <= plainInk.right + 2)
            #expect(ink.bottom == plainInk.bottom)
            let bounds = try #require(canvas.shapedTextBounds(accented, 40, 70))
            #expect(abs(bounds.y - Float(ink.top)) <= 2)
            #expect(abs(bounds.x + bounds.width - Float(ink.right)) <= 2)
            #expect(abs(bounds.x - Float(ink.left)) <= 2)
        }

        @Test("重ねた結合記号は、字形ごとの縦の位置 (y) で積み上がる: o + 分音記号 + アクセントは、ö より高い")
        func stackedMarksRiseByTheirOwnOffsets() throws {
            let canvas = try makeCanvas(size: 60)
            let stacked = try render(canvas) { canvas.shapedText("o\u{0308}\u{0301}", 40, 70) }
            let single = try render(canvas) { canvas.shapedText("\u{00F6}", 40, 70) }
            let stackedInk = try #require(inkBounds(stacked))
            let singleInk = try #require(inkBounds(single))
            #expect(
                stackedInk.top < singleInk.top - 5,
                "積んだ記号の上端 \(stackedInk.top) / ö の上端 \(singleInk.top)")
            let bounds = try #require(canvas.shapedTextBounds("o\u{0308}\u{0301}", 40, 70))
            #expect(abs(bounds.y - Float(stackedInk.top)) <= 2)
        }

        @Test("横の整列は、組版した行の幅だけ書き始めをずらし、墨の枠も同じだけずれる")
        func alignmentUsesTheShapedWidth() throws {
            let canvas = try makeCanvas()
            let string = "AV Wave"
            let width = canvas.shapedTextWidth(string)
            canvas.textAlign(.left, .baseline)
            let left = try #require(canvas.shapedTextBounds(string, 200, 60))
            canvas.textAlign(.center, .baseline)
            let center = try #require(canvas.shapedTextBounds(string, 200, 60))
            canvas.textAlign(.right, .baseline)
            let right = try #require(canvas.shapedTextBounds(string, 200, 60))
            #expect(abs(center.x - (left.x - width / 2)) < 0.01)
            #expect(abs(right.x - (left.x - width)) < 0.01)
            #expect(center.width == left.width && center.y == left.y)
        }

        @Test("墨の枠は、描いた画素と合う。改行は行を分け、縦の整列は行数で決まる")
        func boundsMatchTheDrawnInk() throws {
            let canvas = try makeCanvas()
            for string in ["Agj 1", "AV", "Wave\nfi"] {
                let image = try render(canvas) { canvas.shapedText(string, 20, 40) }
                let ink = try #require(inkBounds(image))
                let bounds = try #require(canvas.shapedTextBounds(string, 20, 40))
                #expect(abs(bounds.x - Float(ink.left)) <= 2, "\(string.debugDescription)")
                #expect(abs(bounds.y - Float(ink.top)) <= 2, "\(string.debugDescription)")
                #expect(abs(bounds.x + bounds.width - Float(ink.right)) <= 2, "\(string.debugDescription)")
                #expect(abs(bounds.y + bounds.height - Float(ink.bottom)) <= 2, "\(string.debugDescription)")
            }
        }

        @Test("ラテンの詰め: AV は組版すると、スカラ 1 つずつより狭い")
        func latinPairsAreKerned() throws {
            let canvas = try makeCanvas(size: 80)
            #expect(canvas.shapedTextWidth("AV") < canvas.textWidth("AV") - 1)
            let shaped = try render(canvas) { canvas.shapedText("AV", 20, 80) }
            let apart = try render(canvas) { canvas.text("AV", 20, 80) }
            let shapedInk = try #require(inkBounds(shaped))
            let apartInk = try #require(inkBounds(apart))
            #expect(shapedInk.right < apartInk.right - 1)
        }

        @Test("代わりの書体の区間は text() と同じ面で描く: Apple Chancery の太字の「あ」は、text() と同じ絵")
        func aFallbackRunDrawsLikeTheOldEntry() throws {
            let canvas = try makeCanvas()
            canvas.textFont("Apple Chancery")
            canvas.textStyle(.bold)
            let shaped = try render(canvas) { canvas.shapedText("あ", 20, 70) }
            let old = try render(canvas) { canvas.text("あ", 20, 70) }
            #expect(shaped.bytes == old.bytes, "shapedText の「あ」が text() の「あ」と違う面になった")
        }

        @Test("タブを含む文字列は、text() と同じ位置に字を置く (大きな字でもタブが潰れない)")
        func tabsPlaceGlyphsLikeTheOldEntry() throws {
            let canvas = try makeCanvas(size: 60)
            let shaped = try render(canvas) { canvas.shapedText("a\tb", 10, 70) }
            let old = try render(canvas) { canvas.text("a\tb", 10, 70) }
            #expect(shaped.bytes == old.bytes, "タブの送りが text() と違う")
        }

        @Test("300 本の違う文字列を毎フレーム描いても、組み直しは 2 フレーム目から 0 で、焼き場の引き当ても残る")
        func manyLinesAreNotReshapedPerFrame() throws {
            let canvas = try makeCanvas(size: 12)
            let lines = (0..<300).map { "mokume \($0) AV" }
            func frame() throws {
                try canvas.draw {
                    canvas.background(black)
                    canvas.fill(white)
                    for (index, line) in lines.enumerated() {
                        canvas.shapedText(line, Float(index % 4) * 100, 10 + Float((index / 4) % 80))
                    }
                }
            }
            try frame()
            let made = canvas.typeface.shaped.made
            let kept = lines.map { canvas.typeface.shape($0) }
            try frame()
            try frame()
            #expect(canvas.typeface.shaped.made == made, "2 フレーム目から組み直した: \(canvas.typeface.shaped.made - made) 回")
            #expect(lines.indices.allSatisfy { canvas.typeface.shape(lines[$0]) === kept[$0] })
            let glyphs = canvas.typeface.shape(lines[0]).glyphs.count
            #expect(
                canvas.typeface.shape(lines[0]).placed.prefix(glyphs).allSatisfy { $0 != nil },
                "焼き場の控え (placed) が消えた")
        }

        @Test("墨の無い文字列・大きさ 0・数でない位置は、幅 0 と枠なし。大きさ 0 では何も描かない")
        func emptyInputs() throws {
            let canvas = try makeCanvas()
            #expect(canvas.shapedTextWidth("") == 0)
            #expect(canvas.shapedTextBounds("", 10, 10) == nil)
            #expect(canvas.shapedTextBounds("  \n ", 10, 10) == nil)
            #expect(canvas.shapedTextBounds("A", Float.nan, 10) == nil)
            #expect(canvas.shapedTextBounds("A", 10, Float.infinity) == nil)
            canvas.textSize(0)
            #expect(canvas.shapedTextWidth("A") == 0)
            #expect(canvas.shapedTextBounds("A", 10, 10) == nil)
            let image = try render(canvas) { canvas.shapedText("A", 10, 40) }
            #expect(inkBounds(image) == nil)
        }

        @Test("既存の text()・textWidth() は組版を始めない: 加法性が保たれ、描く絵が変わらない")
        func theOldEntryIsUnchanged() throws {
            let canvas = try makeCanvas()
            #expect(canvas.textWidth("AV") == canvas.textWidth("A") + canvas.textWidth("V"))
            // 同じ文字列の text() の絵は、shapedText() を呼んだ後も同じ
            let before = try render(canvas) { canvas.text("AV Wave", 10, 60) }
            _ = try render(canvas) { canvas.shapedText("AV Wave", 10, 60) }
            let after = try render(canvas) { canvas.text("AV Wave", 10, 60) }
            #expect(before.bytes == after.bytes)
        }
    }
}
