// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import Metal
import Testing

@testable import MokumeCore

/// 文字の検査。GPU を要する。
///
/// ## 何を物差しにするか
///
/// **幅は 1 文字ずつの送り幅の合計**という規約そのものを見る。保存した絵と比べるのでは
/// なく、規約から導ける性質 (部分の和が全体に一致する・描画の前進が計測と一致する) を
/// 突き合わせるので、書体が変わっても検査は生き続ける。
///
/// 位置の検査は**この環境の書体の寸法**を独立に引いて突き合わせる。同じ計算を 2 度
/// 通しても「両方同じだけずれている」ことは見つからないため。
@Suite(
    "文字",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct TextTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 検査で使う書体。**版が変わりにくいものを選ぶ** — 環境の既定の書体は
    /// 更新で字形が動きうるので、位置の検査の土台には使わない。
    private let fontName = "Helvetica"

    private func makeCanvas(width: Int = 160, height: Int = 96) throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        canvas.textFont(fontName)
        canvas.textSize(32)
        return canvas
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    /// 墨の乗っている画素の外接矩形。何も描かれていなければ `nil`。
    private func inkBounds(_ image: DisplayImage, width: Int, height: Int) -> (
        left: Int, top: Int, right: Int, bottom: Int
    )? {
        var left = Int.max
        var top = Int.max
        var right = Int.min
        var bottom = Int.min
        for y in 0..<height {
            for x in 0..<width where image[x, y].red > 8 {
                left = min(left, x)
                top = min(top, y)
                right = max(right, x)
                bottom = max(bottom, y)
            }
        }
        guard left <= right else { return nil }
        return (left, top, right, bottom)
    }

    // MARK: - 幅の規約

    @Test("部分文字列の幅を足すと、全体の幅にそのまま一致する")
    func widthIsAdditive() throws {
        let canvas = try makeCanvas()
        #expect(canvas.textWidth("AB") == canvas.textWidth("A") + canvas.textWidth("B"))
        #expect(
            canvas.textWidth("Wave") == canvas.textWidth("Wa") + canvas.textWidth("ve"))
    }

    @Test("末尾の空白も幅に数える")
    func trailingSpaceCounts() throws {
        let canvas = try makeCanvas()
        #expect(canvas.textWidth("A ") > canvas.textWidth("A"))
        #expect(canvas.textWidth("A ") == canvas.textWidth("A") + canvas.textWidth(" "))
    }

    @Test("空文字列の幅は 0")
    func emptyStringHasNoWidth() throws {
        #expect(try makeCanvas().textWidth("") == 0)
    }

    @Test("改行を含む文字列の幅は、いちばん長い行の幅")
    func widthOfMultipleLinesIsTheWidest() throws {
        let canvas = try makeCanvas()
        #expect(canvas.textWidth("A\nAAA") == canvas.textWidth("AAA"))
    }

    @Test("改行が CRLF でも、幅はいちばん長い行の幅")
    func widthTreatsCarriageReturnsAsNewlines() throws {
        let canvas = try makeCanvas()
        #expect(canvas.textWidth("A\r\nAAA") == canvas.textWidth("AAA"))
        #expect(canvas.textWidth("A\rAAA") == canvas.textWidth("AAA"))
    }

    @Test("大きさを変えると幅も変わる")
    func widthFollowsSize() throws {
        let canvas = try makeCanvas()
        let small = canvas.textWidth("mokume")
        canvas.textSize(64)
        #expect(canvas.textWidth("mokume") > small)
    }

    // MARK: - 描画と計測の一致

    @Test("描画の前進は、計測した送り幅と同じ")
    func drawingAdvancesByTheMeasuredWidth() throws {
        let together = try makeCanvas()
        try together.draw {
            together.background(black)
            together.fill(white)
            together.text("AV", 20, 60)
        }

        let apart = try makeCanvas()
        try apart.draw {
            apart.background(black)
            apart.fill(white)
            apart.text("A", 20, 60)
            apart.text("V", 20 + apart.textWidth("A"), 60)
        }

        #expect(try pixels(of: together).bytes == pixels(of: apart).bytes)
    }

    @Test("字形の絵に付けた余白は、送り位置に混ざらない")
    func glyphPaddingDoesNotShiftThePen() throws {
        let canvas = try makeCanvas()
        let x: Float = 24
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.text("L", x, 60)
        }

        // この環境の書体から独立に引いた、字形の絵の左端
        let font = CTFontCreateWithName(fontName as CFString, 32, nil)
        var units = Array("L".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: 1)
        CTFontGetGlyphsForCharacters(font, &units, &glyphs, 1)
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, nil, 1)
        let expected = x + Float(bounds.minX)

        let ink = try #require(inkBounds(pixels(of: canvas), width: 160, height: 96))
        // 縁を滑らかにする分の 1 画素だけ許す。焼くときの余白 (2 画素) が
        // 混ざっていれば、この幅では収まらない
        #expect(abs(Float(ink.left) - expected) <= 1)
    }

    @Test("基準線に字が乗る")
    func baselineSitsWhereAsked() throws {
        let canvas = try makeCanvas()
        let baseline: Float = 60
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.text("L", 24, baseline)
        }

        // 「L」は基準線より下へ出ない字なので、墨の下端が基準線のすぐ上に来る
        let ink = try #require(inkBounds(pixels(of: canvas), width: 160, height: 96))
        #expect(abs(Float(ink.bottom) - (baseline - 1)) <= 1)
    }

    @Test("字形が上下逆さまに置かれていない")
    func glyphsAreNotUpsideDown() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.text("L", 24, 70)
        }

        // 「L」は下端に横棒があり、上は細い縦棒だけ。上下が入れ替わると重心も入れ替わる
        let image = try pixels(of: canvas)
        let ink = try #require(inkBounds(image, width: 160, height: 96))
        let middle = (ink.top + ink.bottom) / 2
        var upper = 0
        var lower = 0
        for y in ink.top...ink.bottom {
            for x in ink.left...ink.right where image[x, y].red > 8 {
                if y < middle { upper += 1 } else { lower += 1 }
            }
        }
        #expect(lower > upper)
    }

    // MARK: - 整列

    @Test("中央揃えは、指定した位置が文字列の中央になる")
    func centerAlignmentCentersOnThePoint() throws {
        let left = try makeCanvas()
        try left.draw {
            left.background(black)
            left.fill(white)
            left.text("mokume", 30, 60)
        }
        let centered = try makeCanvas()
        try centered.draw {
            centered.background(black)
            centered.fill(white)
            centered.textAlign(.center)
            centered.text("mokume", 30 + centered.textWidth("mokume") / 2, 60)
        }
        #expect(try pixels(of: left).bytes == pixels(of: centered).bytes)
    }

    @Test("右揃えは、指定した位置で文字列が終わる")
    func rightAlignmentEndsAtThePoint() throws {
        let left = try makeCanvas()
        try left.draw {
            left.background(black)
            left.fill(white)
            left.text("mokume", 30, 60)
        }
        let right = try makeCanvas()
        try right.draw {
            right.background(black)
            right.fill(white)
            right.textAlign(.right)
            right.text("mokume", 30 + right.textWidth("mokume"), 60)
        }
        #expect(try pixels(of: left).bytes == pixels(of: right).bytes)
    }

    @Test("上揃えは、基準線を字の高さのぶん下げたのと同じ")
    func topAlignmentDropsByTheAscent() throws {
        let baseline = try makeCanvas()
        try baseline.draw {
            baseline.background(black)
            baseline.fill(white)
            baseline.text("Ag", 24, 20 + baseline.textAscent())
        }
        let top = try makeCanvas()
        try top.draw {
            top.background(black)
            top.fill(white)
            top.textAlign(.left, .top)
            top.text("Ag", 24, 20)
        }
        #expect(try pixels(of: baseline).bytes == pixels(of: top).bytes)
    }

    @Test("下揃えは、基準線を字の深さのぶん上げたのと同じ")
    func bottomAlignmentLiftsByTheDescent() throws {
        let baseline = try makeCanvas()
        try baseline.draw {
            baseline.background(black)
            baseline.fill(white)
            baseline.text("Ag", 24, 70 - baseline.textDescent())
        }
        let bottom = try makeCanvas()
        try bottom.draw {
            bottom.background(black)
            bottom.fill(white)
            bottom.textAlign(.left, .bottom)
            bottom.text("Ag", 24, 70)
        }
        #expect(try pixels(of: baseline).bytes == pixels(of: bottom).bytes)
    }

    // MARK: - 行

    @Test("改行で行が分かれ、間隔は指定した行送りになる")
    func newlineStartsALineAtTheGivenLeading() throws {
        let canvas = try makeCanvas(width: 96, height: 128)
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textLeading(40)
            canvas.text("L\nL", 20, 40)
        }

        let image = try pixels(of: canvas)
        // 各行の墨がある行番号を集め、2 つの塊に分かれることと、その間隔を見る
        var rows: [Int] = []
        for y in 0..<128 where (0..<96).contains(where: { image[$0, y].red > 8 }) {
            rows.append(y)
        }
        let gaps = zip(rows, rows.dropFirst()).filter { $1 - $0 > 1 }
        #expect(gaps.count == 1)
        let first = try #require(rows.first)
        #expect(rows.contains(first + 40))
    }

    /// **CRLF は 1 書記素なので、`"\n"` では割れない。** 割れないと外から読んだ字幕などが
    /// 1 行に重ならず横へ伸びるだけで、落ちも警告も出ない。
    @Test("CRLF でも行が分かれ、絵は LF と 1 画素も違わない")
    func carriageReturnsStartALineToo() throws {
        func drawn(_ string: String) throws -> [UInt8] {
            let canvas = try makeCanvas(width: 96, height: 128)
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textLeading(40)
                canvas.text(string, 20, 40)
            }
            return try pixels(of: canvas).bytes
        }
        #expect(try drawn("L\r\nL") == drawn("L\nL"))
        #expect(try drawn("L\rL") == drawn("L\nL"))
    }

    @Test("行送りを指定しなければ、大きさから決まる")
    func leadingDefaultsToTheSize() throws {
        let canvas = try makeCanvas()
        canvas.textSize(40)
        #expect(canvas.resolvedTextLeading == 40 * Canvas.leadingRatio)
        canvas.textLeading(12)
        #expect(canvas.resolvedTextLeading == 12)
    }

    // MARK: - 書体

    @Test("この環境に無い書体を指定しても、いま使っている書体は変わらない")
    func unknownFontIsIgnored() throws {
        let canvas = try makeCanvas()
        let before = canvas.textWidth("mokume")
        canvas.textFont("ThisFontDoesNotExistAnywhere")
        #expect(canvas.textWidth("mokume") == before)
    }

    // 名前の判定 (#2444)。**表は macOS に同梱の書体だけで組む。** 引いた書体は PostScript 名で
    // 見るので、その名前を CoreText がこの環境で何に引くかを、各検査の頭で前提として確かめる
    // (前提が崩れたら黙って飛ばさず、前提の行で赤くなる)。

    /// CoreText が、この名前でこの環境から引く書体の PostScript 名。被検査の `Typeface` を通さない。
    nonisolated private static func postScriptName(resolving name: String) -> String {
        CTFontCopyPostScriptName(CTFontCreateWithName(name as CFString, 12, nil)) as String
    }

    /// 在る書体の、いろいろな呼び方と、CoreText がそれで引く書体。上の 4 つは直す前に断っていた
    /// 呼び方 (日本語の名前・フルネーム)、下の 4 つは直す前から通っていた呼び方。
    nonisolated static var namesOfPresentTypefaces: [(name: String, postScript: String)] {
        [
            ("ヒラギノ角ゴシック W3", "HiraginoSans-W3"),
            ("Hiragino Sans W6", "HiraginoSans-W6"),
            ("游明朝体", "YuMin-Medium"),
            ("Helvetica Neue Bold", "HelveticaNeue-Bold"),
            ("HiraginoSans-W6", "HiraginoSans-W6"),
            ("Hiragino Sans", "HiraginoSans-W3"),
            ("YuMincho", "YuMin-Medium"),
            ("helvetica", "Helvetica"),
        ]
    }

    @Test(
        "この環境で引ける書体は、日本語の名前・フルネームでも指定でき、警告が出ない",
        arguments: namesOfPresentTypefaces)
    func aPresentTypefaceIsTakenByAnyOfItsNames(_ face: (name: String, postScript: String)) throws {
        try #require(
            Self.postScriptName(resolving: face.name) == face.postScript,
            "前提: この環境の CoreText は \(face.name) を \(face.postScript) に引く")
        let canvas = try makeCanvas()
        canvas.textFont(face.name)
        #expect(CTFontCopyPostScriptName(canvas.typeface.base) as String == face.postScript)
        #expect(!canvas.warnings.hasWarned(.missingFont), "\(face.name) を無いと断った")
    }

    /// 濁点を分けて綴った名前 (NFD。ファイル名やコピーした文字列で起きる) を、CoreText は
    /// 引けない。合わせた綴り (NFC) に直してから引く。
    @Test("濁点を分けて綴った名前でも、合わせた綴りと同じ書体を引く", arguments: [
        "ヒラギノ角ゴシック W3".precomposedStringWithCanonicalMapping,
        "ヒラギノ角ゴシック W3".decomposedStringWithCanonicalMapping,
    ])
    func aDecomposedNameIsTakenLikeItsComposedSpelling(_ name: String) throws {
        let composed = name.precomposedStringWithCanonicalMapping
        try #require(
            Self.postScriptName(resolving: composed) == "HiraginoSans-W3",
            "前提: この環境の CoreText は合わせた綴りを HiraginoSans-W3 に引く")
        let canvas = try makeCanvas()
        canvas.textFont(name)
        #expect(CTFontCopyPostScriptName(canvas.typeface.base) as String == "HiraginoSans-W3")
        #expect(!canvas.warnings.hasWarned(.missingFont), "\(name.unicodeScalars.count) スカラの綴りを断った")
    }

    /// 無い名前。CoreText はどれも黙って `Helvetica` へ倒す — 判定はそれを見抜かなければならない。
    /// `游明朝`・`Hiragino` は在る書体の名前の一部で、それだけでは書体を指さない。
    @Test("無い名前は、いまどおり警告して書体を変えない", arguments: ["NoSuchFont", "游明朝", "Hiragino"])
    func aMissingNameIsStillRefused(_ name: String) throws {
        try #require(
            Self.postScriptName(resolving: name) == "Helvetica",
            "前提: この環境の CoreText は \(name) を別の書体 (Helvetica) へ倒す")
        let canvas = try makeCanvas()
        canvas.textFont("Courier")
        canvas.textFont(name)
        #expect(canvas.warnings.hasWarned(.missingFont), "\(name) を受けた")
        #expect(CTFontCopyPostScriptName(canvas.typeface.base) as String == "Courier")
    }

    /// システムの内部名 (`.` で始まる名前) は、CoreText が別の書体へ差し替えたうえで「その名前の
    /// 書体が見つかった」と答える。名前で書体を探させる判定に回すと、別の書体で描くことになる。
    @Test("システムの内部名は、CoreText が別の書体へ差し替えるので断る")
    func aPrivateSystemNameIsRefused() throws {
        let name = ".SFNS-Regular"
        try #require(
            Self.postScriptName(resolving: name) != name,
            "前提: この環境の CoreText は \(name) を別の書体へ差し替える")
        let canvas = try makeCanvas()
        canvas.textFont(name)
        #expect(canvas.warnings.hasWarned(.missingFont))
        #expect(CTFontCopyPostScriptName(canvas.typeface.base) as String == "Helvetica")
    }

    /// CoreText の名前の索引に載らない名前 (書体の `name` 表にある別の言語の名前) も、`textFont` は
    /// 面に解く (#2563)。macOS 同梱の Verdana の太字が持つスペイン語の名前で、前提は頭で確かめる。
    /// 表示言語に依る例 (`ヒラギノ角ゴ 簡体中文 W3`) は、英語表示の機械で赤くなるので使わない。
    @Test("索引に載らない各言語の名前でも、書体を指定でき、警告が出ない")
    func aNameMissingFromTheIndexIsTakenByTextFont() throws {
        let name = "Verdana Negrita"
        try #require(
            Self.postScriptName(resolving: name) != "Verdana-Bold",
            "前提: この環境の CoreText の索引は \(name) を Verdana-Bold に引かない")
        try #require(
            Self.postScriptName(resolving: "Verdana-Bold") == "Verdana-Bold", "前提: この環境に Verdana-Bold がある")
        let canvas = try makeCanvas()
        canvas.textFont("Courier")
        canvas.textFont(name)
        #expect(CTFontCopyPostScriptName(canvas.typeface.base) as String == "Verdana-Bold")
        #expect(!canvas.warnings.hasWarned(.missingFont), "\(name) を無いと断った")
    }

    // MARK: - 書体を作る時の名前の確かめ (#2772)
    //
    // `textFont()` が確かめた名前でも、書体を作る時にはもう引けないことがある (実行中に書体を外す)。
    // その状況は手元で再現できないので、`style.fontName` に引けない名前を直に入れて代わりにする。

    @Test("書体を作る時に名前が引けなければ、返った書体の名前を添えて 1 度だけ知らせ、指定も絵も変えない")
    func anUnavailableNameIsWarnedOnceWhenTheTypefaceIsBuilt() throws {
        let name = "NoSuchTypeface-2772"
        try #require(
            Self.postScriptName(resolving: name) == "Helvetica",
            "前提: この環境の CoreText は \(name) を別の書体 (Helvetica) へ倒す")
        let canvas = try makeCanvas()
        canvas.style.fontName = name
        try canvas.draw { canvas.text("a", 10, 20) }
        let message = try #require(canvas.warnings.message(for: .unavailableFont))
        #expect(message.contains("\"\(name)\""), "\(message)")
        #expect(message.contains("\"Helvetica\" is used instead"), "\(message)")
        // 指定は変えず、字は CoreText が返した書体で描く
        #expect(canvas.style.fontName == name)
        #expect(CTFontCopyPostScriptName(canvas.typeface.base) as String == "Helvetica")
        // 大きさを変えて作り直しても、言い直さない (最初の文面のまま)
        canvas.textSize(31)
        _ = canvas.textWidth("a")
        #expect(canvas.warnings.message(for: .unavailableFont) == message)
        // `textFont()` で断られた名前の知らせとは別の鍵
        #expect(!canvas.warnings.hasWarned(.missingFont))
    }

    /// 代わりに描く書体が `.` で始まる内部名のとき (既定の書体)、渡し直せないその名前は名乗らない。
    @Test("書体を作る時の知らせは、代わりに描く書体の内部名を名乗らない")
    func theUnavailableNameWarningDoesNotNameAnInternalFace() throws {
        let system = try #require(CTFontCreateUIFontForLanguage(.system, 32, nil))
        try #require(
            (CTFontCopyPostScriptName(system) as String).hasPrefix("."), "前提: 既定の書体は内部名を持つ")
        let message = Canvas.unavailableFontMessage(name: "Futura", used: system)
        #expect(message.contains("\"Futura\""), "\(message)")
        #expect(message.contains("so a system typeface is used instead"), "\(message)")
        #expect(!message.contains("\"."), "内部名を名乗った: \(message)")
        let named = Canvas.unavailableFontMessage(
            name: "Futura", used: CTFontCreateWithName("Helvetica" as CFString, 12, nil))
        #expect(named.contains("so \"Helvetica\" is used instead"), "\(named)")
    }

    @Test("無い名前を textFont() に渡した知らせと、書体を作る時の知らせは、どちらが先でも互いを黙らせない")
    func theTwoMissingNameWarningsAreIndependent() throws {
        let vanished = "NoSuchTypeface-2772"
        // textFont() の知らせが先
        let refusedFirst = try makeCanvas()
        refusedFirst.textFont("Typo")
        #expect(refusedFirst.warnings.hasWarned(.missingFont))
        #expect(!refusedFirst.warnings.hasWarned(.unavailableFont))
        refusedFirst.style.fontName = vanished
        _ = refusedFirst.textWidth("a")
        #expect(refusedFirst.warnings.hasWarned(.unavailableFont), "textFont() の知らせが、後の知らせを黙らせた")
        // 書体を作る時の知らせが先
        let vanishedFirst = try makeCanvas()
        vanishedFirst.style.fontName = vanished
        _ = vanishedFirst.textWidth("a")
        #expect(vanishedFirst.warnings.hasWarned(.unavailableFont))
        vanishedFirst.textFont("Typo")
        #expect(vanishedFirst.warnings.hasWarned(.missingFont), "書体を作る時の知らせが、textFont() の知らせを黙らせた")
    }

    /// 引ける名前では鳴らない。フルネーム・日本語の名前・表で解いた名前 (#2563) は、`textFont()` が
    /// 解いた PostScript 名で書体を作るので、大きさと太さを変えて作り直しても鳴らない。
    @Test(
        "引ける名前 (フルネーム・日本語の名前・表で解いた名前・既定の書体) では、作り直しても知らせない",
        arguments: [
            "Helvetica", "ヒラギノ角ゴシック W3", "Helvetica Neue Bold", "Verdana Negrita", "",
        ])
    func anAvailableNameIsNeverWarnedWhenRebuilt(_ name: String) throws {
        let canvas = try makeCanvas()
        if name.isEmpty { canvas.noTextFont() } else { canvas.textFont(name) }
        for style: TextStyle in [.normal, .bold, .italic, .boldItalic] {
            canvas.textStyle(style)
            for size: Float in [12, 20, 33] {
                canvas.textSize(size)
                _ = canvas.textWidth("aあ")
            }
        }
        #expect(!canvas.warnings.hasWarned(.unavailableFont), "「\(name)」で鳴った")
        #expect(!canvas.warnings.hasWarned(.missingFont), "「\(name)」を無いと断った")
    }

    /// その書体が、その太さ・傾きの面を持っているか。被検査の `Typeface` を通さない。
    ///
    /// **写しが返っても、面があるとは限らない。** `CTFontCreateCopyWithSymbolicTraits` は、
    /// 頼んだ面が無いとき nil を返すこともあれば、元の面や片方の性質だけの面を返すこともある
    /// (Kefa III の斜体は `KefaIII-Regular`、太斜体は `KefaIII-Bold`)。返った面の性質で見る。
    nonisolated private static func hasFace(_ name: String, _ traits: CTFontSymbolicTraits) -> Bool {
        let base = CTFontCreateWithName(name as CFString, 12, nil)
        guard let styled = CTFontCreateCopyWithSymbolicTraits(base, 12, nil, traits, traits) else {
            return false
        }
        return CTFontGetSymbolicTraits(styled).contains(traits)
    }

    /// 面を持たない組。上は写しが nil で返る書体、下 3 つは写しが面を持たないまま返る書体
    /// (元の面か、片方の性質だけの面)。どれも macOS に同梱 (`/System/Library/Fonts/Supplemental`)。
    nonisolated static var missingFaces: [(font: String, style: TextStyle, drawn: String)] {
        [
            ("HiraginoSans-W3", .italic, "HiraginoSans-W3"),
            ("Kefa III", .italic, "KefaIII-Regular"),
            ("Kefa III", .boldItalic, "KefaIII-Bold"),
            ("Noto Sans Syriac", .italic, "NotoSansSyriac-Regular"),
        ]
    }

    @Test("太さ・傾きの面を持たない書体は、引けた面で描き、そのことを警告する", arguments: missingFaces)
    func aMissingFaceIsWarned(_ item: (font: String, style: TextStyle, drawn: String)) throws {
        let traits: CTFontSymbolicTraits =
            switch item.style {
            case .normal: []
            case .bold: .traitBold
            case .italic: .traitItalic
            case .boldItalic: [.traitBold, .traitItalic]
            }
        try #require(
            Self.postScriptName(resolving: item.font) != "Helvetica",
            "前提: この環境に \(item.font) がある")
        try #require(!Self.hasFace(item.font, traits), "前提: \(item.font) は \(item.style) の面を持たない")
        let canvas = try makeCanvas()
        canvas.textFont(item.font)
        canvas.textStyle(item.style)
        #expect(CTFontCopyPostScriptName(canvas.typeface.base) as String == item.drawn)
        #expect(canvas.warnings.hasWarned(.missingTypefaceStyle), "\(item.font) \(item.style) で鳴らない")
        #expect(
            canvas.warnings.message(for: .missingTypefaceStyle)?.contains(item.drawn) == true,
            "\(canvas.warnings.message(for: .missingTypefaceStyle) ?? "")")
    }

    /// 太斜体の面を持たない書体の警告は、描いた面の性質を名乗る (#2562)。**書体は名指しせず、この環境から
    /// 拾う** (面の構成は macOS の版・資産で機械ごとに違う)。拾えない構成は、その検査が何も走らない。
    /// 期待の面は CoreText への独立な問い合わせで決める (``FamilySurvey``)。
    ///
    /// 太字だけが引ける家族 (斜体は無い: ヒラギノ角ゴシックなど) は太字の立体、太字も斜体もあるが太斜体だけ
    /// 無い家族 (Futura など) も太字の立体、斜体だけが引ける家族 (Bodoni 72 Oldstyle など) は斜体。
    nonisolated static var partialBoldItalicFamilies: [(font: String, traits: String)] {
        let kinds: [(String, (Bool, Bool, Bool) -> Bool)] = [
            ("bold, upright", { full, bold, italic in !full && bold && !italic }),
            ("bold, upright", { full, bold, italic in !full && bold && italic }),
            ("regular weight, italic", { full, bold, italic in !full && !bold && italic }),
        ]
        return kinds.flatMap { kind in
            FamilySurvey.examples(where: kind.1).map { ($0, kind.0) }
        }
    }

    @Test("太斜体の面が無い書体は、引ける面で描き、警告が描いた面の性質を名乗る", arguments: partialBoldItalicFamilies)
    func theWarningNamesThePartialFaceDrawn(_ font: String, _ traits: String) throws {
        let expected = try #require(FamilySurvey.expectedBoldItalic(of: font))
        let canvas = try makeCanvas()
        canvas.textFont(font)
        canvas.textStyle(.boldItalic)
        #expect(CTFontCopyPostScriptName(canvas.typeface.base) as String == expected.postScript)
        let message = canvas.warnings.message(for: .missingTypefaceStyle) ?? ""
        #expect(message.contains("\"\(expected.postScript)\" (\(traits))"), "\(message)")
    }

    @Test("面を持つ書体の太さと傾きは、その面で描き、警告しない", arguments: [
        ("Helvetica", TextStyle.italic, "Helvetica-Oblique"),
        ("Helvetica", TextStyle.boldItalic, "Helvetica-BoldOblique"),
        ("HiraginoSans-W3", TextStyle.bold, "HiraginoSans-W6"),
        ("Kefa III", TextStyle.bold, "KefaIII-Bold"),
    ])
    func aPresentFaceIsUsedWithoutWarning(_ name: String, _ style: TextStyle, _ face: String) throws {
        try #require(
            Self.postScriptName(resolving: face) == face, "前提: この環境に \(face) がある")
        let canvas = try makeCanvas()
        canvas.textFont(name)
        canvas.textStyle(style)
        #expect(CTFontCopyPostScriptName(canvas.typeface.base) as String == face)
        #expect(!canvas.warnings.hasWarned(.missingTypefaceStyle))
    }

    // 代わりの書体から引いた字の面 (#2561)。指定した書体が覆えない字は CoreText が別の書体から
    // 引き、その面が頼んだ太さ・傾きを持つとは限らない (欧文の斜体に混ぜた日本語は立ったまま)。
    // 描く絵は変えずに、そのことを 1 度知らせる。**代わりの書体は CoreText への独立な問い合わせで
    // 確かめ、前提の行で赤くする** (この環境にヒラギノ角ゴシックがあること)。

    /// CoreText が、その書体のその性質の面に無い字を、どの書体から引くか。被検査の `Typeface` を通さない。
    nonisolated private static func fallbackPostScriptName(
        of string: String, in name: String, _ traits: CTFontSymbolicTraits
    ) -> String {
        let plain = CTFontCreateWithName(name as CFString, 32, nil)
        let base =
            traits.isEmpty ? plain : CTFontCreateCopyWithSymbolicTraits(plain, 32, nil, traits, traits) ?? plain
        let text = string as CFString
        let fallback = CTFontCreateForString(base, text, CFRangeMake(0, CFStringGetLength(text)))
        return CTFontCopyPostScriptName(fallback) as String
    }

    /// 欧文の斜体に混ぜた「あ」が、ヒラギノ角ゴシックの立体から引かれること。
    private static func requireHiraginoFallback() throws {
        try #require(
            fallbackPostScriptName(of: "あ", in: "Helvetica", .traitItalic) == "HiraginoSans-W3",
            "前提: この環境の CoreText は、Helvetica の斜体に無い「あ」を HiraginoSans-W3 から引く")
    }

    @Test("欧文の斜体に混ぜた日本語は、代わりの書体の立体で描き、そのことを 1 度だけ警告する")
    func aFallbackWithoutTheStyleIsWarnedOnce() throws {
        try Self.requireHiraginoFallback()
        let canvas = try makeCanvas()
        canvas.textStyle(.italic)
        try canvas.draw {
            canvas.text("aあ", 20, 50)
            canvas.text("aあ", 20, 80)
        }
        #expect(canvas.warnings.hasWarned(.missingFallbackTypefaceStyle))
        let message = canvas.warnings.message(for: .missingFallbackTypefaceStyle) ?? ""
        // 字はコードポイントを添えて、持たなかったのは頼んだ面 (家族ではない) と言う
        #expect(message.contains("\"あ\" (U+3042)"), "\(message)")
        #expect(message.contains("\"Helvetica-Oblique\", the face drawn for .italic"), "\(message)")
        #expect(message.contains("\"HiraginoSans-W3\" (regular weight, upright)"), "\(message)")
        #expect(!message.contains("family"), "\(message)")
        // 次のフレームで別の字が代わりの書体へ落ちても、2 度目は言わない (最初の文面のまま)
        try canvas.draw { canvas.text("もくめ", 20, 50) }
        #expect(canvas.warnings.message(for: .missingFallbackTypefaceStyle) == message)
        // 欧文の書体の斜体は面を持つので、指定した書体の面の警告は出ない
        #expect(!canvas.warnings.hasWarned(.missingTypefaceStyle))
    }

    /// 墨を持たない字 (異体字セレクタ U+FE0E・私用領域 U+E000 の豆腐) が先に代わりの書体へ落ちても、
    /// 1 度きりの知らせを使い切らない。後の和文が知らされる。
    @Test("墨を持たない字が先にあっても、後の和文の面の警告が出る", arguments: ["\u{FE0E}", "\u{E000}"])
    func anInklessCharacterDoesNotUseUpTheWarning(_ lead: String) throws {
        try Self.requireHiraginoFallback()
        let canvas = try makeCanvas()
        canvas.textStyle(.italic)
        try canvas.draw { canvas.text("a\(lead) もくめ", 20, 50) }
        let message = canvas.warnings.message(for: .missingFallbackTypefaceStyle) ?? ""
        #expect(message.contains("\"も\" (U+3082)"), "\(message)")
    }

    /// 既定の書体では、面も代わりの書体も `.` で始まる内部名を持つ。`textFont()` が断る名前なので、
    /// 文面は名乗らず「system typeface」と言う。
    @Test("既定の書体の警告は、textFont() に渡せない内部名を名乗らない")
    func theSystemTypefaceIsNotNamedByItsInternalName() throws {
        let system = try #require(CTFontCreateUIFontForLanguage(.system, 32, nil))
        let italic = try #require(
            CTFontCreateCopyWithSymbolicTraits(system, 32, nil, .traitItalic, .traitItalic))
        let fallback = CTFontCreateForString(italic, "も" as CFString, CFRangeMake(0, 1))
        try #require(
            (CTFontCopyPostScriptName(fallback) as String).hasPrefix("."),
            "前提: 既定の書体の斜体に無い「も」を、内部名の書体から引く")
        let canvas = try makeCanvas()
        canvas.noTextFont()
        canvas.textStyle(.italic)
        _ = canvas.textWidth("もくめ")
        let message = canvas.warnings.message(for: .missingFallbackTypefaceStyle) ?? ""
        #expect(message.contains("the system typeface's face for .italic"), "\(message)")
        #expect(message.contains("from a system typeface (regular weight, upright)"), "\(message)")
        #expect(message.contains("\"も\" (U+3082)"), "\(message)")
        #expect(!message.contains("\"."), "内部名を名乗った: \(message)")
    }

    /// 判定は書体の印で、絵文字かどうかではない。❤ (U+2764) は単色の Zapf Dingbats から引かれ、
    /// 太字の面を持たないので知らせる (後ろの U+FE0F は色の書体から引く印で、知らせない)。
    @Test("単色の書体から引く ❤ は、太字の面を持たないことを警告する")
    func aMonochromeHeartIsWarned() throws {
        let fallback = Self.fallbackPostScriptName(of: "\u{2764}", in: fontName, .traitBold)
        try #require(
            fallback == "ZapfDingbatsITC", "前提: Helvetica の太字に無い ❤ を ZapfDingbatsITC から引く")
        let canvas = try makeCanvas()
        canvas.textStyle(.bold)
        _ = canvas.textWidth("\u{2764}\u{FE0F}")
        let message = canvas.warnings.message(for: .missingFallbackTypefaceStyle) ?? ""
        #expect(message.contains("\"\u{2764}\" (U+2764)"), "\(message)")
        #expect(message.contains("\"ZapfDingbatsITC\" (regular weight, upright)"), "\(message)")
    }

    /// 字を持たないのは頼んだ面で、家族の別の面が持つ字もある (Euphemia UCAS の斜体に無く、立体にある
    /// U+1400)。文面は面を名乗り、家族に無いとは言わない。
    @Test("家族の別の面が持つ字でも、文面は頼んだ面に無いと言う")
    func theWarningNamesTheFaceNotTheFamily() throws {
        let italic = try #require(
            CTFontCreateCopyWithSymbolicTraits(
                CTFontCreateWithName("EuphemiaUCAS" as CFString, 32, nil), 32, nil, .traitItalic,
                .traitItalic))
        try #require(
            CTFontCopyPostScriptName(italic) as String == "EuphemiaUCAS-Italic",
            "前提: Euphemia UCAS の斜体がある")
        try #require(
            Self.fallbackPostScriptName(of: "\u{1400}", in: "EuphemiaUCAS", .traitItalic) == "EuphemiaUCAS",
            "前提: 斜体に無い U+1400 を、同じ家族の立体から引く")
        let canvas = try makeCanvas()
        canvas.textFont("EuphemiaUCAS")
        canvas.textStyle(.italic)
        _ = canvas.textWidth("\u{1400}")
        let message = canvas.warnings.message(for: .missingFallbackTypefaceStyle) ?? ""
        #expect(message.contains("\"EuphemiaUCAS-Italic\", the face drawn for .italic, has no"), "\(message)")
        #expect(message.contains("drawn from \"EuphemiaUCAS\" (regular weight, upright)"), "\(message)")
    }

    @Test("警告しても、代わりの書体から引いた字の絵は変わらない (傾けて描かない)")
    func aFallbackWithoutTheStyleDrawsTheSameUprightFace() throws {
        try Self.requireHiraginoFallback()
        func drawn(_ style: TextStyle) throws -> [UInt8] {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textStyle(style)
                canvas.text("あ", 30, 60)
            }
            return try pixels(of: canvas).bytes
        }
        #expect(try drawn(.italic) == drawn(.normal), "斜体の「あ」が、立体の「あ」と違う絵になった")
    }

    @Test("太斜体に混ぜた日本語は、代わりの書体の太字の立体で描き、警告がそう名乗る")
    func aFallbackWithOnlyTheBoldFaceNamesIt() throws {
        let fallback = Self.fallbackPostScriptName(of: "あ", in: "Helvetica", [.traitBold, .traitItalic])
        try #require(
            fallback == "HiraginoSans-W6",
            "前提: この環境の CoreText は、Helvetica の太斜体に無い「あ」を HiraginoSans-W6 から引く")
        let canvas = try makeCanvas()
        canvas.textStyle(.boldItalic)
        _ = canvas.textWidth("あ")
        let message = canvas.warnings.message(for: .missingFallbackTypefaceStyle) ?? ""
        #expect(message.contains("\"HiraginoSans-W6\" (bold, upright)"), "\(message)")
    }

    /// 指定した書体に太字が無くても、混ぜた日本語は代わりの書体の太字の面で引ける (#2770)。指定した書体
    /// の警告は今までどおり 1 度鳴り、代わりの書体の警告は (太字で描けたので) 鳴らない。
    @Test("太字の無い書体に混ぜた日本語が太字で描けたなら、指定した書体の警告だけが出る")
    func aRestyledFallbackIsNotWarned() throws {
        try #require(
            CTFontCopyPostScriptName(CTFontCreateWithName("Apple Chancery" as CFString, 12, nil)) as String
                == "Apple-Chancery",
            "前提: この環境に Apple Chancery がある")
        let canvas = try makeCanvas()
        canvas.textFont("Apple Chancery")
        canvas.textStyle(.bold)
        _ = canvas.textWidth("aあ")
        #expect(canvas.warnings.hasWarned(.missingTypefaceStyle))
        let message = canvas.warnings.message(for: .missingFallbackTypefaceStyle)
        #expect(message == nil, "「あ」は太字で描けたのに鳴った: \(message ?? "")")
    }

    /// 太斜体は Apple Chancery が斜体を欠くので、太字だけの面で描いて 1 度知らせ、文面がその面を名乗る (#2770)。
    @Test("太字の無い書体の太斜体に混ぜた日本語は、引き直した太字の面を名乗って警告する")
    func aRestyledBoldItalicFallbackNamesTheBoldFace() throws {
        try #require(
            CTFontCopyPostScriptName(CTFontCreateWithName("Apple Chancery" as CFString, 12, nil)) as String
                == "Apple-Chancery",
            "前提: この環境に Apple Chancery がある")
        let canvas = try makeCanvas()
        canvas.textFont("Apple Chancery")
        canvas.textStyle(.boldItalic)
        _ = canvas.textWidth("あ")
        let message = canvas.warnings.message(for: .missingFallbackTypefaceStyle) ?? ""
        // 代わりの家族は機械の言語の設定で変わる (手元はヒラギノ明朝・CI 機は宋体)。名乗る面は、CoreText が
        // 劣化した base から選んだ代わりの、太字の面のもの
        let plain = CTFontCreateForString(canvas.typeface.base, "あ" as CFString, CFRangeMake(0, 1))
        let bold = try #require(
            CTFontCreateCopyWithSymbolicTraits(plain, 32, nil, .traitBold, .traitBold),
            "前提: 代わりの書体に太字の面がある")
        try #require(
            CTFontGetSymbolicTraits(bold).contains(.traitBold), "前提: 太字の面が引ける")
        #expect(
            message.contains("\"\(CTFontCopyPostScriptName(bold) as String)\" (bold, upright)"), "\(message)")
    }

    @Test("指定した書体の面の警告と、代わりの書体の面の警告は、どちらが先でも互いを黙らせない")
    func theTwoStyleWarningsAreIndependent() throws {
        try Self.requireHiraginoFallback()
        try #require(
            Self.postScriptName(resolving: "HiraginoSans-W3") == "HiraginoSans-W3",
            "前提: この環境に HiraginoSans-W3 がある")
        try #require(
            !Self.hasFace("HiraginoSans-W3", .traitItalic), "前提: ヒラギノ角ゴシックは斜体の面を持たない")
        // 文面で見分ける — 鍵を共有すると、後の側の鍵にも先の側の文面が入っている
        func styleMessage(_ canvas: Canvas) -> String {
            canvas.warnings.message(for: .missingTypefaceStyle) ?? ""
        }
        func fallbackMessage(_ canvas: Canvas) -> String {
            canvas.warnings.message(for: .missingFallbackTypefaceStyle) ?? ""
        }

        // 代わりの書体の警告が先
        let fallbackFirst = try makeCanvas()
        fallbackFirst.textStyle(.italic)
        _ = fallbackFirst.textWidth("あ")
        #expect(fallbackMessage(fallbackFirst).contains("\"あ\""), "\(fallbackMessage(fallbackFirst))")
        #expect(!fallbackFirst.warnings.hasWarned(.missingTypefaceStyle))
        fallbackFirst.textFont("HiraginoSans-W3")
        _ = fallbackFirst.textWidth("あ")
        #expect(
            styleMessage(fallbackFirst).contains("has no italic face"),
            "代わりの書体の警告が、指定した書体の警告を黙らせた: \(styleMessage(fallbackFirst))")

        // 指定した書体の警告が先
        let styleFirst = try makeCanvas()
        styleFirst.textFont("HiraginoSans-W3")
        styleFirst.textStyle(.italic)
        _ = styleFirst.textWidth("あ")
        #expect(styleMessage(styleFirst).contains("has no italic face"), "\(styleMessage(styleFirst))")
        #expect(
            !styleFirst.warnings.hasWarned(.missingFallbackTypefaceStyle),
            "ヒラギノ角ゴシックが覆う字を、代わりの書体から引いたと数えた")
        styleFirst.textFont(fontName)
        _ = styleFirst.textWidth("あ")
        #expect(
            fallbackMessage(styleFirst).contains("\"あ\""),
            "指定した書体の警告が、代わりの書体の警告を黙らせた: \(fallbackMessage(styleFirst))")
    }

    /// 代わりの書体から引いても警告しない組。代わりの書体が頼んだ面を持つ (太字のあ)・何も頼んでいない
    /// (標準のあ)・色の字形を持つ書体 (Apple Color Emoji。太さ・傾きの面を持たない。太字と斜体の 2 つ)。
    nonisolated static var fallbacksWithoutWarning: [(style: TextStyle, string: String)] {
        [(.bold, "あ"), (.normal, "あ"), (.bold, "😀"), (.italic, "😀")]
    }

    @Test(
        "代わりの書体が頼んだ面を持つとき・何も頼んでいないとき・絵文字は警告しない",
        arguments: fallbacksWithoutWarning)
    func aFallbackWithTheStyleOrColourGlyphsIsNotWarned(_ item: (style: TextStyle, string: String)) throws {
        let traits: CTFontSymbolicTraits =
            switch item.style {
            case .normal: []
            case .bold: .traitBold
            case .italic: .traitItalic
            case .boldItalic: [.traitBold, .traitItalic]
            }
        let fallback = Self.fallbackPostScriptName(of: item.string, in: fontName, traits)
        try #require(
            !fallback.hasPrefix("Helvetica"), "前提: Helvetica は「\(item.string)」を持たず、代わりの書体から引く")
        let canvas = try makeCanvas()
        canvas.textStyle(item.style)
        try canvas.draw { canvas.text(item.string, 20, 60) }
        let message = canvas.warnings.message(for: .missingFallbackTypefaceStyle)
        #expect(message == nil, "\(item.style) の「\(item.string)」(\(fallback)) で鳴った: \(message ?? "")")
    }

    /// 代わりの書体から字を引く口。どれも同じ `Typeface.glyph(for:)` を通る。
    nonisolated static var glyphReadingEntries: [String] { ["text", "textWidth", "textBounds", "textOutline"] }

    @Test("どの口から先に引いても、代わりの書体の面の警告は 1 度出る", arguments: glyphReadingEntries)
    func theFallbackWarningComesFromEveryEntry(_ entry: String) throws {
        try Self.requireHiraginoFallback()
        let canvas = try makeCanvas()
        canvas.textStyle(.italic)
        func read(_ entry: String) throws {
            switch entry {
            case "text": try canvas.draw { canvas.text("aあ", 20, 50) }
            case "textWidth": _ = canvas.textWidth("aあ")
            case "textBounds": _ = canvas.textBounds("aあ", 20, 50)
            case "textOutline": _ = canvas.textOutline("aあ", 20, 50)
            default: Issue.record("知らない口 \(entry)")
            }
        }
        try read(entry)
        let message = canvas.warnings.message(for: .missingFallbackTypefaceStyle) ?? ""
        #expect(
            message.contains("\"HiraginoSans-W3\" (regular weight, upright)"), "\(entry) から引いて鳴らない: \(message)")
        // 残りの口から引いても、言い直さない
        for other in Self.glyphReadingEntries where other != entry { try read(other) }
        #expect(canvas.warnings.message(for: .missingFallbackTypefaceStyle) == message)
    }

    @Test("指定した書体が覆えない文字も描ける")
    func charactersOutsideTheFontStillDraw() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            // 欧文の書体には無い字。環境の別の書体から引ける
            canvas.text("あ", 30, 60)
        }
        #expect(inkBounds(try pixels(of: canvas), width: 160, height: 96) != nil)
    }

    @Test("太さと傾きを変えると絵が変わる")
    func styleChangesTheDrawing() throws {
        let plain = try makeCanvas()
        try plain.draw {
            plain.background(black)
            plain.fill(white)
            plain.text("mokume", 20, 60)
        }
        let bold = try makeCanvas()
        try bold.draw {
            bold.background(black)
            bold.fill(white)
            bold.textStyle(.bold)
            bold.text("mokume", 20, 60)
        }
        #expect(try pixels(of: plain).bytes != pixels(of: bold).bytes)
    }

    // 書体の控え (#1431)。鍵に大きさ (連続値) が入るので、`textSize` を毎フレーム変える
    // 書き方 (脈打つ字) ではフレームごとに鍵が 1 つ増える。描かずに `textWidth` で引けば
    // GPU を回さずに済む

    @Test("大きさを 1 回ずつ変えて書体を 1000 回引いても、控えの件数は上限以下に収まる")
    func typefacesStayWithinTheLimit() throws {
        let canvas = try makeCanvas()
        #expect(Canvas.typefaceCacheLimit == 64)
        for index in 0..<1000 {
            canvas.textSize(8 + Float(index) * 0.01)
            _ = canvas.textWidth("mokume")
        }
        #expect(
            canvas.typefaces.count <= Canvas.typefaceCacheLimit,
            """
            大きさを変えて 1000 回引いた後の書体の控えが \(canvas.typefaces.count) 件で、
            上限 \(Canvas.typefaceCacheLimit) を超えている。脈打つ字で footprint が増え続ける (#1431)。
            """)
    }

    @Test("使い続けている大きさの書体は、別の大きさを上限より多く引いても追い出されない")
    func aTypefaceInUseIsKept() throws {
        let canvas = try makeCanvas()
        canvas.textSize(20)
        let kept = canvas.typeface
        for index in 0..<(Canvas.typefaceCacheLimit * 3) {
            canvas.textSize(20)
            _ = canvas.textWidth("mokume")
            canvas.textSize(21 + Float(index) * 0.1)
            _ = canvas.textWidth("mokume")
        }
        #expect(canvas.typefaces.count <= Canvas.typefaceCacheLimit)
        canvas.textSize(20)
        #expect(canvas.typeface === kept, "1 回おきに使っていた書体が追い出された (入れた順に捨てている)")
    }

    @Test("追い出した書体で描き直しても、絵と幅は変わらない")
    func anEvictedTypefaceDrawsTheSame() throws {
        let canvas = try makeCanvas()
        // 欧文と、書体を渡って引く字 (欧文の書体に無い) を混ぜる
        let string = "mokume あ"
        func drawn() throws -> [UInt8] {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textSize(20)
                canvas.text(string, 10, 60)
            }
            return try pixels(of: canvas).bytes
        }
        let before = try drawn()
        canvas.textSize(20)
        let width = canvas.textWidth(string)
        let first = canvas.typeface

        for index in 0..<(Canvas.typefaceCacheLimit * 2) {
            canvas.textSize(21 + Float(index) * 0.25)
            _ = canvas.textWidth(string)
        }
        canvas.textSize(20)
        #expect(canvas.typeface !== first, "上限を超えて引いたのに、最初の書体が追い出されていない")
        #expect(canvas.textWidth(string) == width)
        #expect(try drawn() == before, "書体を作り直すと、絵が変わった")
    }

    // MARK: - 描かないとき

    @Test("塗りを止めていると何も描かない")
    func noFillDrawsNothing() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.text("mokume", 20, 60)
        }
        #expect(inkBounds(try pixels(of: canvas), width: 160, height: 96) == nil)
    }

    @Test("大きさが 0 なら何も描かない")
    func zeroSizeDrawsNothing() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(0)
            canvas.text("mokume", 20, 60)
        }
        #expect(inkBounds(try pixels(of: canvas), width: 160, height: 96) == nil)
    }

    // MARK: - 状態の積み降ろし

    @Test("文字の設定はスタイルと一緒に積み降ろしされる")
    func textSettingsRideOnTheStyleStack() throws {
        // **積み降ろしはフレームの中で行う。** 積んだ履歴はフレームを越えないので
        // (ADR-0021 決定 4 の追補・[#925])、フレームの外での `pushStyle()` は警告して
        // 無視される。この検査が見たいのは「文字の設定が `Style` に載っているか」で、
        // そこはフレームの中でも変わらない
        //
        // [#925]: https://github.com/mokume-metal/mokume/issues/925
        let canvas = try makeCanvas()
        try canvas.draw {
            let before = canvas.textWidth("mokume")
            canvas.pushStyle()
            canvas.textSize(64)
            canvas.textAlign(.right, .top)
            canvas.textLeading(99)
            #expect(canvas.textWidth("mokume") != before)
            canvas.popStyle()
            #expect(canvas.textWidth("mokume") == before)
            #expect(canvas.style.horizontalTextAlign == .left)
            #expect(canvas.style.verticalTextAlign == .baseline)
            #expect(canvas.style.textLeading == nil)
        }
    }

    // MARK: - 折り返し

    @Test("幅に収まらない語は次の行へ送られる")
    func wordsMoveToTheNextLine() throws {
        let canvas = try makeCanvas()
        canvas.textSize(16)
        let lines = canvas.wrapped("aa bb cc dd", face: canvas.typeface, within: canvas.textWidth("aa bb"))
        #expect(lines.map(String.init) == ["aa bb", "cc dd"])
    }

    @Test("折るために消費するのは、切れ目の空白だけ")
    func onlyTheBreakingSpaceIsConsumed() throws {
        let canvas = try makeCanvas()
        canvas.textSize(16)
        let source = "alpha beta gamma delta"
        let lines = canvas.wrapped(
            source, face: canvas.typeface, within: canvas.textWidth("alpha beta"))
        #expect(lines.map(String.init).joined(separator: " ") == source)
        for line in lines {
            #expect(canvas.textWidth(String(line)) <= canvas.textWidth("alpha beta"))
        }
    }

    @Test("幅より長い 1 語は、その語の中で折る")
    func aWordWiderThanTheBoxBreaksInside() throws {
        let canvas = try makeCanvas()
        canvas.textSize(16)
        let lines = canvas.wrapped(
            "supercalifragilistic", face: canvas.typeface, within: canvas.textWidth("super"))
        #expect(lines.count > 1)
        #expect(lines.map(String.init).joined() == "supercalifragilistic")
    }

    @Test("文字の切れ目で折るときは、語の途中でも折る")
    func characterWrapBreaksInsideWords() throws {
        let canvas = try makeCanvas()
        canvas.textSize(16)
        canvas.textWrap(.character)
        let source = "aaaa bbbb"
        let lines = canvas.wrapped(source, face: canvas.typeface, within: canvas.textWidth("aaaa b"))
        // 語の切れ目を待たないので、2 つ目の語の 1 字目まで入れて、語の途中で折る
        #expect(lines.map(String.init) == ["aaaa b", "bbb"])
        // 行と行の隙間には空白しか無い — 切れ目の空白は消費しても、字は落とさない ([#1424])
        let gaps = zip(lines, lines.dropFirst()).map { source[$0.endIndex..<$1.startIndex] }
        #expect(gaps.allSatisfy { $0.allSatisfy(\.isWhitespace) })
        #expect(lines.first?.startIndex == source.startIndex)
        #expect(lines.last?.endIndex == source.endIndex)
    }

    @Test("改行は幅に関わらず必ず行を分ける")
    func newlineAlwaysBreaks() throws {
        let canvas = try makeCanvas()
        canvas.textSize(16)
        let lines = canvas.wrapped("a\nb", face: canvas.typeface, within: 1000)
        #expect(lines.map(String.init) == ["a", "b"])
    }

    @Test("CRLF も幅に関わらず行を分ける")
    func carriageReturnsAlwaysBreak() throws {
        let canvas = try makeCanvas()
        canvas.textSize(16)
        let face = canvas.typeface
        #expect(canvas.wrapped("a\r\nb", face: face, within: 1000).map(String.init) == ["a", "b"])
        #expect(canvas.wrapped("a\rb", face: face, within: 1000).map(String.init) == ["a", "b"])
    }

    // MARK: - 矩形への流し込み

    @Test("収まりきらなかった続きが返り、次の矩形へ流せる")
    func theRemainderCanBePouredIntoTheNextBox() throws {
        let canvas = try makeCanvas(width: 200, height: 200)
        canvas.textSize(16)
        let source = "alpha beta gamma delta epsilon zeta"
        var short = TextFlow(lineCount: 0, height: 0, remainder: "")
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            // 1 行ぶんしか入らない高さ
            short = canvas.text(source, 10, 10, 80, canvas.textAscent() + canvas.textDescent())
        }
        #expect(short.lineCount == 1)
        #expect(short.isTruncated)

        let rest = try makeCanvas(width: 200, height: 200)
        rest.textSize(16)
        var all = TextFlow(lineCount: 0, height: 0, remainder: "")
        try rest.draw {
            rest.background(black)
            rest.fill(white)
            all = rest.text(source, 10, 10, 80, 180)
        }
        #expect(!all.isTruncated)
        // 続きだけを流し直すと、全体から 1 行ぶん減る。流し直すのもフレームの中で行う —
        // フレームの外で置いた字は断られる (#1672)
        var continued = TextFlow(lineCount: 0, height: 0, remainder: "")
        try rest.draw { continued = rest.text(short.remainder, 10, 10, 80, 180) }
        #expect(continued.lineCount == all.lineCount - 1)
        #expect(!continued.isTruncated)
    }

    @Test("返る高さは、置いた行数から決まる")
    func theReturnedHeightFollowsTheLineCount() throws {
        let canvas = try makeCanvas(width: 200, height: 200)
        canvas.textSize(16)
        canvas.textLeading(24)
        let block = canvas.textAscent() + canvas.textDescent()
        var flow = TextFlow(lineCount: 0, height: 0, remainder: "")
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            flow = canvas.text("aa\nbb\ncc", 10, 10, 100, 180)
        }
        #expect(flow.lineCount == 3)
        #expect(flow.height == block + 2 * 24)
    }

    @Test("矩形の 4 つの数は、矩形を描くときと同じ読み方をする")
    func theBoxFollowsRectMode() throws {
        let corner = try makeCanvas(width: 200, height: 120)
        corner.textSize(16)
        try corner.draw {
            corner.background(black)
            corner.fill(white)
            corner.text("alpha beta gamma", 20, 20, 80, 80)
        }
        let center = try makeCanvas(width: 200, height: 120)
        center.textSize(16)
        try center.draw {
            center.background(black)
            center.fill(white)
            center.rectMode(.center)
            center.text("alpha beta gamma", 60, 60, 80, 80)
        }
        #expect(try pixels(of: corner).bytes == pixels(of: center).bytes)
    }

    @Test("幅か高さが無い矩形へは、何も置かない")
    func anEmptyBoxPlacesNothing() throws {
        let canvas = try makeCanvas()
        var flow = TextFlow(lineCount: 1, height: 1, remainder: "")
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            flow = canvas.text("mokume", 10, 10, 0, 50)
        }
        #expect(flow.lineCount == 0)
        #expect(flow.remainder == "mokume")
        #expect(inkBounds(try pixels(of: canvas), width: 160, height: 96) == nil)
    }

    // MARK: - 輪郭

    @Test("輪郭は、描いた字と同じ場所に出る")
    func theOutlineLandsWhereTheTextIsDrawn() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.text("Agj", 24, 60)
        }
        let ink = try #require(inkBounds(try pixels(of: canvas), width: 160, height: 96))

        let contours = canvas.textOutline("Agj", 24, 60)
        let points = contours.flatMap(\.points)
        let left = points.map(\.x).min()!
        let right = points.map(\.x).max()!
        let top = points.map(\.y).min()!
        let bottom = points.map(\.y).max()!

        #expect(abs(left - Float(ink.left)) <= 2)
        #expect(abs(right - Float(ink.right)) <= 2)
        #expect(abs(top - Float(ink.top)) <= 2)
        #expect(abs(bottom - Float(ink.bottom)) <= 2)
    }

    @Test("穴のある字は、外側の周と穴に分かれる")
    func glyphsWithHolesReportThem() throws {
        let canvas = try makeCanvas()
        let o = canvas.textOutline("o", 10, 50)
        #expect(o.count == 2)
        #expect(o.filter(\.isHole).count == 1)
        // 外側が先に並ぶ
        #expect(o.first?.isHole == false)

        #expect(canvas.textOutline("L", 10, 50).allSatisfy { !$0.isHole })
    }

    /// 説明文が名乗る「周の分かれ方は書体による」を押さえる ([#1149])。
    ///
    /// **この検査だけは既定の書体を土台にする** — 既定の書体の持ち方そのものが
    /// 説明文の主張だからである。更新で字形が変わってここが赤くなったら、実装ではなく
    /// `textOutline` と `TextContour.isHole` の説明文の言い切りを見直す。
    ///
    /// [#1149]: https://github.com/mokume-metal/mokume/issues/1149
    @Test("周の分かれ方は書体による — 既定の書体の A は重なった外周で返り、穴が立たない")
    func howGlyphsSplitIntoRingsDependsOnTheTypeface() throws {
        let canvas = try makeCanvas()
        canvas.noTextFont()
        let systemA = canvas.textOutline("A", 10, 50)
        #expect(systemA.count > 1)
        #expect(systemA.allSatisfy { !$0.isHole })

        // 書体を指定すれば「外周 + 穴」として読める
        canvas.textFont(fontName)
        let namedA = canvas.textOutline("A", 10, 50)
        #expect(namedA.count == 2)
        #expect(namedA.filter(\.isHole).count == 1)
    }

    @Test("輪郭も CRLF で行が分かれる")
    func outlineBreaksOnCarriageReturns() throws {
        let canvas = try makeCanvas()
        let lf = canvas.textOutline("L\nL", 20, 40)
        #expect(!lf.isEmpty)
        #expect(canvas.textOutline("L\r\nL", 20, 40) == lf)
        #expect(canvas.textOutline("L\rL", 20, 40) == lf)
    }

    @Test("周を持たない字は輪郭を出さない")
    func blankGlyphsHaveNoContours() throws {
        #expect(try makeCanvas().textOutline("   ", 10, 50).isEmpty)
    }

    @Test("輪郭も整列に従う")
    func theOutlineFollowsAlignment() throws {
        let canvas = try makeCanvas()
        canvas.textAlign(.right)
        let contours = canvas.textOutline("mokume", 120, 60)
        let right = contours.flatMap(\.points).map(\.x).max()!
        // 送りの終わりが 120。最後の字の右端はそれより左に来る
        #expect(right <= 120)
        #expect(right > 120 - canvas.textWidth("mokume"))
    }

    // MARK: - 墨の範囲 (#1284)
    //
    // `textBounds` は、同じ引数で描いた墨を、左上原点・いまの座標で囲む。`textOutline` の約束
    // (描くときと同じ送り・いまの座標のまま・整列に従う) と同じなので、返る枠は「同じ引数の
    // `textOutline` の全点の外接」と言い換えられる。

    /// 輪郭の全点の外接 (左・上・右・下)。点が無ければ `nil`。
    private func outlineExtent(
        _ canvas: Canvas, _ string: String, _ x: Float, _ y: Float
    ) -> (left: Float, top: Float, right: Float, bottom: Float)? {
        let points = canvas.textOutline(string, x, y).flatMap(\.points)
        guard !points.isEmpty else { return nil }
        return (
            points.map(\.x).min()!, points.map(\.y).min()!, points.map(\.x).max()!,
            points.map(\.y).max()!
        )
    }

    /// 枠と輪郭の外接が、各辺 `tolerance` 以内で一致することを見る。
    private func expectBounds(
        _ bounds: TextBounds?, hug extent: (left: Float, top: Float, right: Float, bottom: Float)?,
        within tolerance: Float, _ note: String
    ) throws {
        let bounds = try #require(bounds, "\(note): 枠が返らない")
        let extent = try #require(extent, "\(note): 輪郭が無い")
        #expect(abs(bounds.x - extent.left) <= tolerance, "\(note): 左 \(bounds.x) / 輪郭 \(extent.left)")
        #expect(abs(bounds.y - extent.top) <= tolerance, "\(note): 上 \(bounds.y) / 輪郭 \(extent.top)")
        #expect(
            abs(bounds.x + bounds.width - extent.right) <= tolerance,
            "\(note): 右 \(bounds.x + bounds.width) / 輪郭 \(extent.right)")
        #expect(
            abs(bounds.y + bounds.height - extent.bottom) <= tolerance,
            "\(note): 下 \(bounds.y + bounds.height) / 輪郭 \(extent.bottom)")
    }

    /// 横 3 通り × 縦 4 通りの整列。
    nonisolated static var alignments: [(HorizontalTextAlign, VerticalTextAlign)] {
        HorizontalTextAlign.allCases.flatMap { h in VerticalTextAlign.allCases.map { (h, $0) } }
    }

    @Test("墨の枠は、どの整列でも同じ引数の輪郭の外接と一致する", arguments: alignments)
    func theBoundsHugTheOutlineInEveryAlignment(
        _ alignment: (HorizontalTextAlign, VerticalTextAlign)
    ) throws {
        let canvas = try makeCanvas()
        canvas.textAlign(alignment.0, alignment.1)
        try expectBounds(
            canvas.textBounds("Agj 1", 80, 48), hug: outlineExtent(canvas, "Agj 1", 80, 48),
            within: 0.5, "\(alignment)")
    }

    /// 改行 (`\n` / `\r\n`) と傾き。2 行目は行送りだけ下がり、整列は行ごとに効く。
    nonisolated static var lineAndStyleCases: [(String, TextStyle)] {
        ["Ag\nj1", "Ag\r\nj1", "T\n\n1"].flatMap { s in [(s, TextStyle.normal), (s, .italic)] }
    }

    @Test("墨の枠は、改行と傾きを含む文字列でも同じ引数の輪郭の外接と一致する", arguments: lineAndStyleCases)
    func theBoundsHugTheOutlineAcrossLinesAndStyles(_ string: String, _ style: TextStyle) throws {
        let canvas = try makeCanvas()
        canvas.textStyle(style)
        canvas.textAlign(.center, .center)
        try expectBounds(
            canvas.textBounds(string, 80, 48), hug: outlineExtent(canvas, string, 80, 48),
            within: 0.5, "\(string.debugDescription) \(style)")
    }

    @Test("墨の枠は、同じ引数で描いた字の墨と重なる")
    func theBoundsLandWhereTheTextIsDrawn() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.text("Agj 1", 24, 60)
        }
        let ink = try #require(inkBounds(try pixels(of: canvas), width: 160, height: 96))
        let bounds = try #require(canvas.textBounds("Agj 1", 24, 60))
        // 墨の画素は番号で、右端・下端はその画素の番号。許しは輪郭と同じ 2 画素
        #expect(abs(bounds.x - Float(ink.left)) <= 2)
        #expect(abs(bounds.y - Float(ink.top)) <= 2)
        #expect(abs(bounds.x + bounds.width - Float(ink.right)) <= 2)
        #expect(abs(bounds.y + bounds.height - Float(ink.bottom)) <= 2)
    }

    /// **1 字ずつ切って送りを足す持ち方と、語をまとめて測った値が食い違わない。** mokume は
    /// 字詰めをしないので (``Typeface`` の「組版はしない」)、字ごとの位置は送り幅の足し算
    /// そのものである。字詰めや合字を始めたらここが赤くなって知らせる。
    ///
    /// 語の中の空白は墨に数えず、端の空白は枠を広げない。
    @Test("語の枠は、1 字ずつ送り幅を足した位置で取った字ごとの枠の和と一致する")
    func theWordBoundsAreTheUnionOfTheCharacters() throws {
        let canvas = try makeCanvas(width: 240, height: 96)
        let word = "TIME 1"
        var cursor: Float = 10
        var union: (left: Float, top: Float, right: Float, bottom: Float)?
        for character in word {
            let piece = String(character)
            if let b = canvas.textBounds(piece, cursor, 60) {
                let (l, t, r, bt) = (b.x, b.y, b.x + b.width, b.y + b.height)
                union = union.map { (min($0.left, l), min($0.top, t), max($0.right, r), max($0.bottom, bt)) }
                    ?? (l, t, r, bt)
            }
            cursor += canvas.textWidth(piece)
        }
        try expectBounds(canvas.textBounds(word, 10, 60), hug: union, within: 0.01, word)

        // 端の空白は送りだけを進める
        let padded = try #require(canvas.textBounds(" \(word) ", 10, 60))
        let shifted = try #require(canvas.textBounds(word, 10 + canvas.textWidth(" "), 60))
        #expect(abs(padded.x - shifted.x) <= 0.01)
        #expect(abs(padded.width - shifted.width) <= 0.01)
        #expect(padded.y == shifted.y && padded.height == shifted.height)
    }

    @Test("墨が無ければ枠は nil で、落ちない", arguments: ["", "   ", "\n", "\r\n\n"])
    func noInkHasNoBounds(_ string: String) throws {
        let canvas = try makeCanvas()
        #expect(canvas.textBounds(string, 10, 50) == nil)
    }

    @Test("大きさ 0 では、字があっても枠は nil")
    func aZeroSizeHasNoBounds() throws {
        let canvas = try makeCanvas()
        canvas.textSize(0)
        #expect(canvas.textBounds("mokume", 10, 50) == nil)
    }

    @Test("墨の枠の位置に数でない値か無限を渡しても、落ちずに nil を返す", arguments: nonFinitePositions)
    func aNonFinitePositionHasNoBounds(_ position: (x: Float, y: Float)) throws {
        let canvas = try makeCanvas()
        #expect(canvas.textBounds("o", position.x, position.y) == nil)
    }

    /// 返る値は**いまの座標のまま** (`textOutline` と同じ)。変換も `rectMode` も効かない。
    @Test("墨の枠は、変換と rectMode に依らない")
    func theBoundsIgnoreTransformsAndRectMode() throws {
        let canvas = try makeCanvas()
        let plain = try #require(canvas.textBounds("Agj 1", 24, 60))
        var transformed: TextBounds?
        var centred: TextBounds?
        try canvas.draw {
            canvas.translate(13, -7)
            canvas.rotate(0.6)
            canvas.scale(1.5, 0.75)
            transformed = canvas.textBounds("Agj 1", 24, 60)
            canvas.resetMatrix()
            canvas.rectMode(.center)
            centred = canvas.textBounds("Agj 1", 24, 60)
        }
        #expect(transformed == plain)
        #expect(centred == plain)
    }

    // MARK: - 数でない値・巨大な大きさ (#1587)

    /// 数でない位置と無限の位置。
    nonisolated static var nonFinitePositions: [(x: Float, y: Float)] {
        [(.nan, 100), (50, .nan), (.infinity, 100), (-.infinity, 100)]
    }

    /// 輪郭は読み取りの口なので、決して落ちずに空を返す ([ADR-0020] 決定 5)。直す前は、数でない
    /// 位置から曲線を割る数が NaN になり、Int へ直す所でプロセスごと落ちた ([#1587])。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#1587]: https://github.com/mokume-metal/mokume/issues/1587
    @Test("輪郭の位置に数でない値か無限を渡しても、落ちずに空を返す", arguments: nonFinitePositions)
    func aNonFinitePositionHasNoOutline(_ position: (x: Float, y: Float)) throws {
        let canvas = try makeCanvas()
        #expect(canvas.textOutline("o", position.x, position.y).isEmpty)
    }

    /// 曲線を割る数の上限に張り付く大きさ。**有限だが、点どうしの距離の 2 乗が `Float` から
    /// あふれる** (`1e20` 以上)。
    nonisolated static var hugeOutlineSizes: [Float] { [1e20, 1e21, .greatestFiniteMagnitude] }

    /// 大きい字の輪郭は、曲線ごとに割る数の上限 (24) まで割る。巨大な大きさでもそれ以上には
    /// 割らないので、周の数と各周の点の数は大きい字と同じになる。直す前は、曲線の長さが
    /// 無限大か `2 × Int.max` を越えて、割る数を Int へ直す所でプロセスごと落ちた ([#1587])。
    ///
    /// [#1587]: https://github.com/mokume-metal/mokume/issues/1587
    @Test("巨大な大きさの輪郭も落ちず、周と点の数は大きい字の輪郭と揃う", arguments: hugeOutlineSizes)
    func aHugeSizeOutlinesLikeALargeOne(size: Float) throws {
        let canvas = try makeCanvas()
        // 周ごとに、点の数と穴かどうか。**穴の判定も揃う** — 面積を `Float` で積むと、大きな字
        // では座標の積が溢れて NaN になり、穴がすべて外周と読まれていた (#1587 の反証 4)
        func shape(at position: Float = 0) -> [String] {
            canvas.textOutline("o", position, position)
                .map { "\($0.points.count)\($0.isHole ? " hole" : "")" }
        }
        canvas.textSize(400)
        let large = shape()
        try #require(large.contains { $0.hasSuffix("hole") }, "検査の前提: 400 の「o」に穴が無い")
        canvas.textSize(4000)
        try #require(
            shape() == large, "検査の前提: 400 の「o」の曲線が、どれも割る数の上限に張り付いていない")

        canvas.textSize(size)
        #expect(shape() == large)
        // 原点から遠い位置でも同じ。座標どうしの積は大きさだけでなく位置でも溢れる
        #expect(shape(at: 1e20) == large)
        #expect(canvas.textOutline("o", 0, 0).allSatisfy { $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } })
    }

    /// 無限の大きさは、NaN と負の値と同じく 0 に倒れる ([#1587])。直す前は +∞ だけが素通りして
    /// 書体へ渡り、字は描かれず輪郭も空だったが、測る口は無限を返していた。
    ///
    /// [#1587]: https://github.com/mokume-metal/mokume/issues/1587
    @Test("大きさに無限を渡すと、0 と同じく何も描かず、輪郭も空")
    func anInfiniteSizeActsAsZero() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(Float.infinity)
            canvas.text("M", 10, 80)
        }
        #expect(inkBounds(try pixels(of: canvas), width: 160, height: 96) == nil)
        #expect(canvas.textOutline("o", 0, 0).isEmpty)
        // 測る口と矩形へ流す口も、大きさ 0 と同じ答えを返す。直す前は上端と下端が無限、
        // 矩形へ流すと高さ NaN の行を 1 行置いたと答えていた
        #expect(canvas.textWidth("M") == 0)
        #expect(canvas.textAscent() == 0)
        #expect(canvas.textDescent() == 0)
        let flow = canvas.text("M", 0, 0, 100, 100)
        #expect(flow.lineCount == 0 && flow.height == 0)
        #expect(canvas.warnings.hasWarned(.unusableTextMeasure))
    }

    /// 字の寸法から作る量が有限に収まる大きさの上限 ([#1587] の反証 2・5)。上限を越える有限の
    /// 大きさは上限として扱うので、測る口も流し込みも上限の大きさと同じ答えを返し、無限を
    /// 返さない。直す前は、大きさ × 1.25 の行送りや送り幅の合計が溢れて無限になり、流し込みは
    /// 高さ NaN の行を置いたと答えた。
    ///
    /// [#1587]: https://github.com/mokume-metal/mokume/issues/1587
    @Test("上限を越える有限の大きさは上限として測られ、測る口も流し込みも有限を返す", arguments: [Float(1e30), .greatestFiniteMagnitude])
    func aSizeAboveTheLimitMeasuresAsTheLimit(size: Float) throws {
        let canvas = try makeCanvas()
        let text = String(repeating: "M", count: 64) + "\nM"
        func measures() -> [Float] {
            let flow = canvas.text(text, 0, 0, 1e38, 1e38)
            return [
                canvas.textWidth(text), canvas.textAscent(), canvas.textDescent(),
                canvas.resolvedTextLeading, Float(flow.lineCount), flow.height,
            ]
        }
        canvas.textSize(Canvas.largestTextMeasure)
        let limit = measures()
        try #require(limit.allSatisfy { $0.isFinite }, "検査の前提: 上限の大きさで測った値 \(limit) が有限でない")
        #expect(!canvas.warnings.hasWarned(.unusableTextMeasure), "上限ちょうどで知らせた")

        canvas.textSize(size)
        #expect(measures() == limit)
        #expect(canvas.warnings.hasWarned(.unusableTextMeasure))
    }

    /// 行送りにも同じ受け口を通す ([#1587] の反証 1)。直す前は `max(0, leading)` が +∞ を
    /// 素通しし、流し込みは `0 × ∞` の NaN から高さ NaN の行を置いたと答えた。
    ///
    /// [#1587]: https://github.com/mokume-metal/mokume/issues/1587
    @Test("行送りに数でない値・無限を渡すと 0 として流し込む", arguments: [Float.infinity, .nan])
    func anUnusableLeadingActsAsZero(leading: Float) throws {
        let canvas = try makeCanvas()
        canvas.textLeading(0)
        let zero = canvas.text("M\nM", 0, 0, 100, 1000)
        canvas.textLeading(leading)
        let flow = canvas.text("M\nM", 0, 0, 100, 1000)
        #expect(flow.lineCount == zero.lineCount && flow.height == zero.height)
        #expect(canvas.warnings.hasWarned(.unusableTextMeasure))
    }

    /// 縦の揃えが行の広がり (行数 - 1) × 行送りを使っても、輪郭の点は有限 ([#1587] の反証 3)。
    /// 直す前は、1 行でも `0 × ∞` が NaN になり、下揃え・中央揃えの基準線が NaN になっていた。
    ///
    /// [#1587]: https://github.com/mokume-metal/mokume/issues/1587
    @Test("下揃え・中央揃えの輪郭は、大きな大きさと無限の行送りでも有限の点を返す", arguments: [VerticalTextAlign.bottom, .center])
    func aVerticallyAlignedOutlineStaysFinite(align: VerticalTextAlign) throws {
        let canvas = try makeCanvas()
        canvas.textAlign(.left, align)
        for (size, leading) in [(Float.greatestFiniteMagnitude, nil), (32, Float.infinity)] as [(Float, Float?)] {
            canvas.textSize(size)
            if let leading { canvas.textLeading(leading) }
            for text in ["o", "o\no"] {
                let points = canvas.textOutline(text, 0, 0).flatMap(\.points)
                #expect(!points.isEmpty)
                #expect(
                    points.allSatisfy { $0.x.isFinite && $0.y.isFinite },
                    "大きさ \(size)・行送り \(String(describing: leading)) の「\(text)」の輪郭に有限でない点がある")
            }
        }
    }

    // MARK: - 焼き場

    @Test("焼き場を広げても、それまでに置いた字は元のまま描かれる")
    func growingTheAtlasKeepsEarlierGlyphsIntact() throws {
        let alone = try makeCanvas(width: 160, height: 128)
        try alone.draw {
            alone.background(black)
            alone.fill(white)
            alone.textSize(96)
            alone.text("A", 10, 100)
        }
        #expect(alone.atlas.size == GlyphAtlas.initialSize)

        // 同じ「A」を置いたあと、面に収まらないだけの字を焼かせる。面は差し替わるが、
        // 先に置いた字は前の面を指したまま描かれなければならない
        let crowded = try makeCanvas(width: 160, height: 128)
        try crowded.draw {
            crowded.background(black)
            crowded.fill(white)
            crowded.textSize(96)
            crowded.text("A", 10, 100)
            crowded.text("BCDEFGHIJKLMNOPQRSTUVWXYZ", 10, 4096)
        }
        #expect(crowded.atlas.size > GlyphAtlas.initialSize)

        #expect(try pixels(of: alone).bytes == pixels(of: crowded).bytes)
    }

    /// 字形の外接矩形 (画素・送り位置と基準線から測る)。**焼き場を通さず、この環境の
    /// 書体から引く** — 検査の前提 (どの大きさの面なら入るか・どこに置けば窓に入るか) を、
    /// 焼き場の外で決めるため。
    private func glyphBounds(of character: String, size: Float) -> CGRect {
        let font = CTFontCreateWithName(fontName as CFString, CGFloat(size), nil)
        var units = Array(character.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: 1)
        CTFontGetGlyphsForCharacters(font, &units, &glyphs, 1)
        return CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, nil, 1)
    }

    /// 検査で使う書体が、その字を**自分で**持っているか。
    ///
    /// 代わりの書体へ落ちる字では、``glyphBounds(of:size:)`` が引く寸法と、焼き場が焼く字形が
    /// 別物になる。書体から寸法を引く検査は、前提としてこれを確かめる。
    private func fontOwns(_ character: String) -> Bool {
        let font = CTFontCreateWithName(fontName as CFString, 12, nil)
        var units = Array(character.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
    }

    /// 余白込みの字形の大きさ (画素)。焼き場が場所を取る大きさと同じ数え方をする。
    private func paddedExtent(of character: String, size: Float) -> (width: Int, height: Int) {
        let bounds = glyphBounds(of: character, size: size)
        let pad = GlyphAtlas.padding
        let width = Int(bounds.maxX.rounded(.up)) - Int(bounds.minX.rounded(.down)) + 2 * pad
        let height = Int(bounds.maxY.rounded(.up)) - Int(bounds.minY.rounded(.down)) + 2 * pad
        return (width, height)
    }

    /// 「M」を 1 字だけ置いたフレームを描いて、その絵を返す。
    ///
    /// **字の左端を窓の中 (x = 8) に合わせる。** 大きい字ほど送り位置から絵の左端までが
    /// 離れる (4096 では 300 画素を越える) ので、送り位置を固定すると窓の外に出る。基準線は
    /// 窓の下端近くに置くので、左の縦棒が窓を上から下まで通る。
    private func drawLargeM(size: Float, on canvas: Canvas) throws -> DisplayImage {
        let x = 8 - Float(glyphBounds(of: "M", size: size).minX)
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(size)
            canvas.text("M", x, 120)
        }
        return try pixels(of: canvas)
    }

    /// 作りたての面を 1 度広げただけでは入らない字も、**最初のフレームから**描かれる ([#1460])。
    ///
    /// 焼き場は面が足りないと 1 段ずつ倍に広げる。引き直しを 1 度で打ち切ると、1 度広げた面
    /// にも入らない字はそのフレームで欠け、次のフレームでもう一段広がってから出る。動かして
    /// いる窓ではほぼ見えないが、1 フレームだけ描く使い方では欠けたまま残る。
    ///
    /// **比べる相手は、面が育ちきった後のフレーム**である。直す前のコードでも何フレームか
    /// 描けば字は出るので、「最初のフレームだけが欠ける」という事象そのものを見られる。
    ///
    /// **入った大きさで止まる**ことも見る。上限まで広げれば必ず入るが、上限の面は 1 枚で
    /// 128 MiB ある。
    ///
    /// [#1460]: https://github.com/mokume-metal/mokume/issues/1460
    @Test(
        "作りたての面を何段か広げないと入らない字も、最初のフレームから描かれる",
        // 引数は main actor の外で組まれるので、面の一辺は数で書く (上限は中で突き合わせる)
        arguments: [
            // 256 → 512 → 1024。1 度広げた 512 にも入らない
            (size: Float(1200), side: 1024),
            // 256 → … → 4096。上限の面でしか入らない
            (size: Float(4096), side: 4096),
        ])
    func aGlyphNeedingSeveralGrowthsIsDrawnInTheFirstFrame(size: Float, side: Int) throws {
        try #require(side <= GlyphAtlas.maximumSize, "検査の前提: 一辺 \(side) の面は上限を越える")
        // 検査の前提: 1 度広げた面には入らず、`side` の面には入る
        let extent = paddedExtent(of: "M", size: size)
        try #require(
            max(extent.width, extent.height) > GlyphAtlas.initialSize * 2,
            "検査の前提: \(size) の「M」(\(extent)) が、1 度広げた面に入ってしまう")
        try #require(
            max(extent.width, extent.height) > side / 2
                && max(extent.width, extent.height) <= side,
            "検査の前提: \(size) の「M」(\(extent)) が、一辺 \(side) の面でちょうど入る大きさでない")

        let canvas = try makeCanvas(width: 128, height: 128)
        #expect(canvas.atlas.size == GlyphAtlas.initialSize, "検査の前提: 面が作りたてでない")
        let first = try drawLargeM(size: size, on: canvas)
        #expect(
            canvas.atlas.size == side,
            "\(size) の「M」を描いた後の面が \(canvas.atlas.size) — 入る大きさ \(side) で止まっていない")

        // 字が出るまで描き足す。256 から上限までは 4 段なので、それより多くは要らない
        var settled = try drawLargeM(size: size, on: canvas)
        var framesDrawn = 2
        while inkBounds(settled, width: 128, height: 128) == nil, framesDrawn < 8 {
            settled = try drawLargeM(size: size, on: canvas)
            framesDrawn += 1
        }
        try #require(
            inkBounds(settled, width: 128, height: 128) != nil,
            "検査の前提: \(framesDrawn) フレーム描いても、\(size) の「M」が 1 度も描かれない")

        // 絵の並びをそのまま #expect に渡すと、外れたときに 6 万余りの数が並ぶ
        let firstInked = inkBounds(first, width: 128, height: 128) != nil
        let sameAsSettled = first.bytes == settled.bytes
        #expect(
            sameAsSettled,
            """
            作りたての面で描いた \(size) の「M」が、面が育ちきった後のフレームと違う絵に\
            なった (最初のフレームに墨が\(firstInked ? "乗ってはいる" : "乗っていない"))。

            1 度広げた面にも入らない字は、入るまで広げなければそのフレームで欠ける
            ([#1460](https://github.com/mokume-metal/mokume/issues/1460))。
            """)
    }

    /// 上限の面にも収まらない大きさの並び。
    ///
    /// 先頭の `8192` は上限の面の一辺 (``GlyphAtlas/maximumSize`` の 4096) の倍で、丸めや余白では
    /// 届かない側へ振った大きさ。**残りは外接矩形が Int に収まらない所まで振る** ([#1587])。
    /// 焼き場は外接矩形を Int へ直してから上限と比べていたので、大きさ `1e20` の「M」(`maxX` が
    /// 約 7e19 で、`Int.max` の 9.2e18 を越える) ではその変換でプロセスごと落ちた。`1e18` は
    /// Int に収まる対照で、直す前から通る。
    ///
    /// [#1587]: https://github.com/mokume-metal/mokume/issues/1587
    nonisolated static var overwhelmingSizes: [Float] {
        [8192, 1e18, 1e20, .greatestFiniteMagnitude]
    }

    @Test("待てなかったら、字形を焼かない")
    func doesNotBakeAGlyphWhenTheWaitFails() throws {
        let canvas = try makeCanvas()
        let resolved = try #require(canvas.typeface.glyph(for: "M"))
        let key = GlyphAtlas.Key(
            fontKey: resolved.fontKey, size: 32, style: .normal, glyph: resolved.glyph)

        canvas.gpu.failSettleForTesting = .timedOut(seconds: 5)
        let refused = canvas.atlas.entry(for: key, font: resolved.font)
        canvas.gpu.failSettleForTesting = nil
        guard case .unbakeable = refused else {
            Issue.record(
                """
                GPU の完了を待てなかったのに、面は「\(refused)」と答えた。

                焼いていない場所を字形として返すと、前のフレームがまだ読んでいるかも
                しれない面へ書いたうえ、その領域をそのまま描くことになる
                ([#934](https://github.com/mokume-metal/mokume/issues/934))。
                """)
            return
        }

        // 引けなかった字形は控えに残らないので、次の機会に焼き直せる
        guard case .found = canvas.atlas.entry(for: key, font: resolved.font) else {
            Issue.record("待てるようになった後も焼けていない")
            return
        }
    }

    @Test("焼き場に入りきらない字形は、理由を『大きすぎる』として名乗る", arguments: overwhelmingSizes)
    func anOversizedGlyphNamesItsReason(size: Float) throws {
        let canvas = try makeCanvas()
        // **書体は `textSize` を通さずに作る。** `textSize` は 1e18 を越える大きさを 1e18 に締める
        // (#1587 の反証 2) ので、通すと焼き場へ Int に収まらない外接矩形が届かない。焼き場は
        // 締めの有無によらず、頼まれた字形を Int へ直す前に比べる
        let font = CTFontCreateWithName(fontName as CFString, CGFloat(size), nil)
        var units = Array("M".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: 1)
        try #require(CTFontGetGlyphsForCharacters(font, &units, &glyphs, 1))
        let key = GlyphAtlas.Key(fontKey: fontName, size: size, style: .normal, glyph: glyphs[0])

        let lookup = canvas.atlas.entry(for: key, font: font)
        guard case .tooLarge = lookup else {
            Issue.record(
                """
                上限の面より大きい字形を頼んだのに、面は「\(lookup)」と答えた。

                引けなかった理由が「満杯」と「字形が面より大きい」で分かれていないと、
                受け取る側は広げれば入ると読んで、入らないものを追って広げ続ける
                ([#738](https://github.com/mokume-metal/mokume/issues/738))。
                """)
            return
        }
    }

    /// 描く口は、入らない字を投げずに何も置かず、「大きすぎる」を 1 度知らせる ([ADR-0020] 決定 5)。
    /// 大きさが Int に収まらない外接矩形を生む所まで振っても同じ ([#1587])。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#1587]: https://github.com/mokume-metal/mokume/issues/1587
    @Test("上限の面にも入らない字形を頼んでも、焼き場は広がらない", arguments: overwhelmingSizes)
    func anOversizedGlyphDoesNotGrowTheAtlas(size: Float) throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(self.black)
            canvas.fill(self.white)
            canvas.textSize(size)
            canvas.text("M", 10, 100)
        }
        #expect(
            inkBounds(try pixels(of: canvas), width: 160, height: 96) == nil,
            "入らない大きさ \(size) の「M」を描いたのに、面に墨が乗った")
        #expect(
            canvas.atlas.warnings.hasWarned(.tooLarge),
            "入らない大きさ \(size) の「M」を描いたのに、「大きすぎる」を知らせていない")
        #expect(
            canvas.atlas.size == GlyphAtlas.initialSize,
            """
            広げても入らない字形のために、焼き場が \(canvas.atlas.size) まで広がった。

            広げるたびに焼いた字形は全部捨てられるので、これは入らない 1 字のために
            他の字を焼き直させ続ける形になる。上限まで行っても入らないので、回復もしない
            ([#738](https://github.com/mokume-metal/mokume/issues/738))。
            """)
    }

    /// 作りたての頁で、字形の短いほうの辺に使える長さ (画素)。長いほうの辺は、面の一辺まで使える。
    ///
    /// **焼き場の寸法の定数から組み直す。** 頁の左上の隅には白い区画とその余白があるので、棚の
    /// 1 段目はその右から、2 段目はその下から始まる。上限の頁でも、両辺を上限いっぱいには使えない。
    private var shorterSideLimit: Int {
        GlyphAtlas.maximumSize - GlyphAtlas.whiteBlock - GlyphAtlas.padding
    }

    /// 「大きすぎる」の文面。**実装とは別の場所に写して突き合わせる** (``WarningLogTests`` と
    /// 同じ形)。
    ///
    /// 上限の数だけを並べる文面では、4091×4091 の字形が「4096×4096 の上限に入らない」と
    /// 言われ、食い違って読める ([#1492])。長いほうと短いほうの辺の、2 つの上限を言う。
    ///
    /// [#1492]: https://github.com/mokume-metal/mokume/issues/1492
    private func tooLargeNotice(width: Int, height: Int) -> String {
        "text(): one glyph is \(width)x\(height) pixels, which does not fit the baking area: it "
            + "takes glyphs of at most 4096 pixels on the longer side and 4090 on the shorter. "
            + "This character will not be drawn — lower textSize()"
    }

    /// 「●」の字形を 1 つだけ頼んで、焼き場の答えを返す。
    private func lookUpDisc(size: Float, in canvas: Canvas) throws -> GlyphAtlas.Lookup {
        canvas.textSize(size)
        let resolved = try #require(canvas.typeface.glyph(for: "●"))
        let key = GlyphAtlas.Key(
            fontKey: resolved.fontKey, size: size, style: .normal, glyph: resolved.glyph)
        return canvas.atlas.entry(for: key, font: resolved.font)
    }

    /// 作りたての上限の頁にも、左上の白い区画のぶん入らない字形 ([#1492])。**両辺とも上限以下**
    /// なので、上限と比べるだけの判定を通ってしまう。
    ///
    /// 通ると、棚に場所が取れずに「満杯」を名乗る。受け取る側は、広げるか焼き直せば入ると
    /// 読む — 入らないまま、上限の頁を毎フレーム作り直すことになる。
    ///
    /// **作りたての上限の頁に頼む。** 「焼き直せば入る」が本当に成り立たない場所で、答えを見る。
    ///
    /// [#1492]: https://github.com/mokume-metal/mokume/issues/1492
    @Test(
        "作りたての上限の頁に白い区画のぶん入らない字形も、理由を『大きすぎる』として名乗る",
        arguments: [
            // 余白込み 4091×4091。両辺とも、短いほうの辺に使える長さを 1 画素だけ越える
            Float(9508),
            // 余白込み 4096×4096。両辺とも上限ちょうど
            Float(9520),
        ])
    func aGlyphBlockedByTheWhiteBlockNamesItselfTooLarge(size: Float) throws {
        try #require(fontOwns("●"), "検査の前提: \(fontName) が「●」を持っていない")
        let extent = paddedExtent(of: "●", size: size)
        try #require(
            max(extent.width, extent.height) <= GlyphAtlas.maximumSize
                && min(extent.width, extent.height) > shorterSideLimit,
            """
            検査の前提: \(size) の「●」(\(extent)) が、両辺とも \(shorterSideLimit) を越え \
            \(GlyphAtlas.maximumSize) 以下の大きさでない
            """)

        let canvas = try makeCanvas()
        while canvas.atlas.canGrow { try canvas.atlas.grow(gpu: canvas.gpu) }
        let lookup = try lookUpDisc(size: size, in: canvas)
        guard case .tooLarge(let width, let height) = lookup else {
            Issue.record(
                """
                作りたての上限の頁にも入らない \(extent.width)×\(extent.height) の字形を頼んだのに、\
                面は「\(lookup)」と答えた。

                「満杯」は、広げるか焼き直せば入るという意味である。入らない字形がそう名乗ると、
                受け取る側は上限の頁を毎フレーム作り直し、ほかの字も全部焼き直させる
                ([#1492](https://github.com/mokume-metal/mokume/issues/1492))。
                """)
            return
        }
        #expect(
            width == extent.width && height == extent.height,
            "「大きすぎる」が名乗った大きさ \(width)×\(height) が、書体から引いた \(extent) と違う")
    }

    /// 条件 2・3 ([#1492] の完了条件)。**上限の面にも入らない字形と同じ扱い**になる —
    /// 焼き場は広がらず、頁も替わらない (``anOversizedGlyphDoesNotGrowTheAtlas()``)。
    ///
    /// 小さい「A」を一緒に描くのは、頁が替わると焼いた控えが捨てられ、**入らない 1 字が
    /// ほかの字まで焼き直させる**からである。数フレーム続けるのは、直す前は上限の頁に着いた
    /// 後に毎フレーム頁を作り直していたからである。
    ///
    /// [#1492]: https://github.com/mokume-metal/mokume/issues/1492
    @Test("白い区画のぶん入らない字形を何フレーム描いても、頁は替わらず、『大きすぎる』を知らせる")
    func aGlyphBlockedByTheWhiteBlockNeverTurnsThePage() throws {
        let size: Float = 9508
        try #require(fontOwns("●"), "検査の前提: \(fontName) が「●」を持っていない")
        let extent = paddedExtent(of: "●", size: size)
        try #require(
            max(extent.width, extent.height) <= GlyphAtlas.maximumSize
                && min(extent.width, extent.height) > shorterSideLimit,
            "検査の前提: \(size) の「●」(\(extent)) が、白い区画のぶん入らない大きさでない")

        let canvas = try makeCanvas(width: 128, height: 128)
        let page = canvas.atlas.texture
        for frame in 0..<4 {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textSize(32)
                canvas.text("A", 8, 40)
                canvas.textSize(size)
                canvas.text("●", 8, 120)
            }
            guard canvas.atlas.texture === page, canvas.atlas.size == GlyphAtlas.initialSize else {
                Issue.record(
                    """
                    入らない \(extent.width)×\(extent.height) の「●」を描いた \(frame) フレーム目に、\
                    焼き場の頁が替わった (面は \(canvas.atlas.size))。

                    頁を替えるたびに焼いた字形の控えは捨てられるので、同じフレームのほかの字も
                    全部焼き直しになる。入らない字は替えても入らない
                    ([#1492](https://github.com/mokume-metal/mokume/issues/1492))。
                    """)
                return
            }
        }

        #expect(
            canvas.atlas.warnings.message(for: .tooLarge)
                == tooLargeNotice(width: extent.width, height: extent.height),
            "入らない字形を描いたのに、「大きすぎる」の知らせがその文面で出ていない")
        #expect(
            canvas.warnings.message(for: .atlasFullInOneFrame) == nil,
            """
            入らない字形を 1 つ描いただけなのに、「1 フレームで要る字が収まらない」と知らせた。
            利用者は字の種類を減らそうとするが、減らしても入らない
            """)
    }

    /// 字を 1 つだけ置いたフレームを描いて、その絵を返す。
    ///
    /// **字の左端を窓の中 (x = 8) に、字の高さの中ほどを窓の中ほど (y = 64) に合わせる。**
    /// 「●」の左端も「—」の棒も、字の高さの中ほどにしか墨が無い。
    private func drawLeftMiddle(_ character: String, size: Float, on canvas: Canvas) throws
        -> DisplayImage
    {
        let bounds = glyphBounds(of: character, size: size)
        let x = 8 - Float(bounds.minX)
        // 書体の座標は上へ測るので、字の中ほどは基準線から `midY` だけ上に在る
        let baseline = 64 + Float(bounds.midY)
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(size)
            canvas.text(character, x, baseline)
        }
        return try pixels(of: canvas)
    }

    /// 条件 4 ([#1492] の完了条件) — **境界の内側は変わらない。** 片方の辺が短いほうの辺に
    /// 使える長さに収まれば、もう片方は上限まで使える。
    ///
    /// 判定を厳しくしすぎる (両辺とも短いほうの長さに収める) と、ここに挙げた縦長・横長の字が
    /// 描かれなくなる。
    ///
    /// [#1492]: https://github.com/mokume-metal/mokume/issues/1492
    @Test(
        "片方の辺が白い区画を避けられる字形は、上限の頁に最初のフレームから描かれる",
        arguments: [
            // 余白込み 4090×4090。両辺とも、短いほうの辺に使える長さちょうど。1 段目に置かれる
            (character: "●", size: Float(9507)),
            // 余白込み 3924×4094。縦長なので、白い区画の右の 1 段目に置かれる
            (character: "M", size: Float(5701)),
            // 余白込み 4094×389。横長なので、白い区画の下の 2 段目に置かれる
            (character: "—", size: Float(5351)),
        ])
    func aGlyphWithOneSideClearOfTheWhiteBlockIsDrawn(character: String, size: Float) throws {
        try #require(fontOwns(character), "検査の前提: \(fontName) が「\(character)」を持っていない")
        let extent = paddedExtent(of: character, size: size)
        let longer = max(extent.width, extent.height)
        let shorter = min(extent.width, extent.height)
        try #require(
            longer <= GlyphAtlas.maximumSize && shorter <= shorterSideLimit,
            "検査の前提: \(size) の「\(character)」(\(extent)) が、上限の頁に入る大きさでない")
        try #require(
            longer > GlyphAtlas.maximumSize / 2,
            "検査の前提: \(size) の「\(character)」(\(extent)) が、上限より小さい面に入ってしまう")

        let canvas = try makeCanvas(width: 128, height: 128)
        let image = try drawLeftMiddle(character, size: size, on: canvas)
        #expect(
            canvas.atlas.size == GlyphAtlas.maximumSize,
            "\(size) の「\(character)」を描いた後の面が \(canvas.atlas.size) — 上限まで広がっていない")
        #expect(
            inkBounds(image, width: 128, height: 128) != nil,
            """
            上限の頁に入る \(extent.width)×\(extent.height) の「\(character)」が、最初のフレームで\
            描かれなかった。

            作りたての上限の頁は、長いほうの辺を \(GlyphAtlas.maximumSize) まで、短いほうの辺を \
            \(shorterSideLimit) まで受け取る
            ([#1492](https://github.com/mokume-metal/mokume/issues/1492))。
            """)
    }

    /// 0 埋めが面全体を覆う。
    ///
    /// 焼く前の場所が透明であることは、面を作るときの 0 埋めだけが担っている ([#796])。
    /// **作りたての面を読んでも確かめられない** — Metal は 0 で返すので、埋めたのか
    /// 初めからそうだったのかが分からない。だから**面を不透明で汚してから埋めさせて**、
    /// 覆い残しが出ないことを見る。帯の分割を誤れば、覆えなかった行がここに出る。
    ///
    /// [#796]: https://github.com/mokume-metal/mokume/issues/796
    @Test("0 埋めは、面のどの行も覆い残さない")
    func fillingTransparentCoversEveryRow() throws {
        let gpu = try RenderDevice()
        let atlas = try GlyphAtlas(gpu: gpu)

        // 一辺ごとに帯の分割が変わるので、上限まで含めて見る
        for _ in 0...2 {
            let side = atlas.size
            paintOpaque(atlas.texture, side: side)
            #expect(
                opaquePixels(of: atlas.texture, side: side) == side * side,
                "汚し切れていないなら、この後の判定が意味を持たない")

            GlyphAtlas.fillTransparent(atlas.texture, side: side)
            #expect(
                opaquePixels(of: atlas.texture, side: side) == 0,
                "一辺 \(side) の面に、0 埋めが覆えなかった画素が残った")

            try atlas.grow(gpu: gpu)
        }
    }

    /// 面全体を不透明で塗る。
    private func paintOpaque(_ texture: any MTLTexture, side: Int) {
        let opaque = [SIMD4<Float16>](repeating: SIMD4(1, 1, 1, 1), count: side * side)
        texture.replace(
            region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: opaque,
            bytesPerRow: side * GlyphAtlas.bytesPerPixel)
    }

    /// 面を読み戻して、不透明な画素がいくつ在るかを数える。
    ///
    /// **読み戻す先を 1 で埋めてから渡す。** 0 で埋めると、読み戻しが何も書かなくても
    /// 「全部透明」に見えてしまう。
    private func opaquePixels(of texture: any MTLTexture, side: Int) -> Int {
        var pixels = [SIMD4<Float16>](repeating: SIMD4(1, 1, 1, 1), count: side * side)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: side * GlyphAtlas.bytesPerPixel,
                from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        }
        return pixels.count { $0.w != 0 }
    }

    // MARK: - 色を持つ字形

    /// 色を持つ字形を検査に使う。**その字が無い環境なら見送る** — 検査の対象は
    /// 「色が失われないこと」であって、この環境に絵文字があることではない。
    nonisolated private static let coloredScalar: Unicode.Scalar = "\u{1F534}"  // 🔴
    private var coloredScalar: Unicode.Scalar { Self.coloredScalar }

    /// この環境に、色を持つ字形の書体があるか。**被検査の ``Typeface`` を通さず、CoreText に
    /// 直に問う** — 見送りを被検査コードで決めていた頃は、字形を引く側が壊れると 4 本とも
    /// 黙って合格した (#2292)。見送りは `.enabled(if:)` に出し、記録にスキップとして残す。
    nonisolated static let hasColoredGlyphs: Bool = {
        let base = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        let text = String(coloredScalar) as CFString
        let font = CTFontCreateForString(base, text, CFRangeMake(0, CFStringGetLength(text)))
        var units = Array(String(coloredScalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) && glyphs[0] != 0
    }()

    /// 描いた絵の中で、いちばん彩度の高い画素。
    private func mostSaturated(_ image: DisplayImage, width: Int, height: Int) -> (
        red: Int, green: Int, blue: Int, saturation: Int
    ) {
        var best = (red: 0, green: 0, blue: 0, saturation: -1)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = image[x, y]
                let high = Int(max(pixel.red, max(pixel.green, pixel.blue)))
                let low = Int(min(pixel.red, min(pixel.green, pixel.blue)))
                if high - low > best.saturation {
                    best = (Int(pixel.red), Int(pixel.green), Int(pixel.blue), high - low)
                }
            }
        }
        return best
    }

    /// 色を持つ字を 1 つ描いて読み戻す。**引けなければ落とす** (環境に無いときは
    /// ``hasColoredGlyphs`` が先に見送っている)。
    private func drawColoredGlyph(fill: LinearRGBA, background: LinearRGBA = .linear(
        red: 0, green: 0, blue: 0)) throws -> DisplayImage {
        let canvas = try makeCanvas(width: 64, height: 64)
        canvas.noTextFont()
        canvas.textSize(40)
        _ = try #require(canvas.typeface.glyph(for: coloredScalar), "色を持つ字形を引けない")
        try canvas.draw {
            canvas.background(background)
            canvas.fill(fill)
            canvas.text(String(self.coloredScalar), 8, 48)
        }
        return try pixels(of: canvas)
    }

    @Test(
        "色を持つ字形は、色のまま描かれる",
        .enabled(if: TextTests.hasColoredGlyphs, "この環境には色を持つ字形の書体が無い"))
    func aColoredGlyphKeepsItsColor() throws {
        let image = try drawColoredGlyph(fill: white)
        let brightest = mostSaturated(image, width: 64, height: 64)
        // 塗りは白なので、色が出ているなら字形の側が持っていた色である
        #expect(brightest.saturation > 64)
        #expect(brightest.red > brightest.green)
        #expect(brightest.red > brightest.blue)
    }

    @Test(
        "色を持つ字形に、塗りの色は掛からない",
        .enabled(if: TextTests.hasColoredGlyphs, "この環境には色を持つ字形の書体が無い"))
    func theFillColorDoesNotTintAColoredGlyph() throws {
        let onWhite = try drawColoredGlyph(fill: white)
        let onBlue = try drawColoredGlyph(fill: .linear(red: 0, green: 0, blue: 1))
        // 塗りを青にしても、字形の色は動かない。
        // **画素の並びごとではなく代表の 1 点で比べる** — 食い違ったときに、
        // 面いっぱいのバイト列ではなく色そのものが表示に出る
        #expect(
            mostSaturated(onWhite, width: 64, height: 64)
                == mostSaturated(onBlue, width: 64, height: 64))
        #expect(onWhite == onBlue)
    }

    @Test(
        "色を持つ字形にも、塗りの透明度は効く",
        .enabled(if: TextTests.hasColoredGlyphs, "この環境には色を持つ字形の書体が無い"))
    func theFillAlphaStillReachesAColoredGlyph() throws {
        let half = LinearRGBA(straightRed: 1, green: 1, blue: 1, alpha: 0.5)
        let opaque = try drawColoredGlyph(fill: white)
        let faded = try drawColoredGlyph(fill: half)
        let solid = mostSaturated(opaque, width: 64, height: 64)
        let thin = mostSaturated(faded, width: 64, height: 64)
        // 黒地の上なので、薄くすれば色も彩度も引く
        #expect(thin.saturation < solid.saturation)
        #expect(thin.red < solid.red)
    }

    @Test("単色の字は、いままでどおり塗りの色で出る")
    func aMonochromeGlyphStillTakesTheFillColor() throws {
        let canvas = try makeCanvas(width: 64, height: 64)
        try canvas.draw {
            canvas.background(self.black)
            canvas.fill(.linear(red: 0, green: 1, blue: 0))
            canvas.text("A", 8, 48)
        }
        let image = try pixels(of: canvas)
        let brightest = mostSaturated(image, width: 64, height: 64)
        #expect(brightest.green > 200)
        #expect(brightest.red < 32)
        #expect(brightest.blue < 32)
    }

    @Test(
        "焼き場は、色を持つ字形だけを色つきと見分ける",
        .enabled(if: TextTests.hasColoredGlyphs, "この環境には色を持つ字形の書体が無い"))
    func theAtlasMarksOnlyColoredGlyphs() throws {
        let canvas = try makeCanvas(width: 64, height: 64)
        canvas.noTextFont()
        canvas.textSize(40)
        let face = canvas.typeface
        let colored = try #require(face.glyph(for: coloredScalar), "色を持つ字形を引けない")
        let plain = try #require(face.glyph(for: "A"))
        #expect(canvas.glyphEntry(for: colored)?.isColored == true)
        #expect(canvas.glyphEntry(for: plain)?.isColored == false)
    }

    // MARK: - 色を持つ字形の墨の範囲 (#2308)
    //
    // 色を持つ字形 (絵文字) はビットマップで描かれ、道筋を持たないか、持っていても描く絵と別の
    // 仮の形 (国旗の部品 🇯 の矩形) である。墨は**検査の側で CoreText に同じ字形を CPU で描かせ、
    // 不透明な画素の範囲を取ったもの**とする。焼き場も字形を 1 つずつ整数の升目で CPU に描いて
    // 面へ写すだけなので、`text()` の墨は同じ升目に乗る。描き方 (8bit の sRGB) は焼き場 (16bit の
    // 浮動小数・線形) と変えてあり、被検査の描く関数も字形の引き当ても通さない。

    /// 検査で使う書体。`nil` は既定の書体 (`noTextFont()`)。既定の書体の絵文字は
    /// `.AppleColorEmojiUI` から引かれ、名前で引いた Apple Color Emoji と升目が 2 画素ずれる。
    nonisolated private static func referenceFont(_ name: String?, size: CGFloat) -> CTFont {
        guard let name else { return CTFontCreateUIFontForLanguage(.system, size, nil)! }
        return CTFontCreateWithName(name as CFString, size, nil)
    }

    /// 字を 1 つ引く。書体に無ければ、CoreText に代わりの書体を選ばせる。
    nonisolated private static func referenceGlyph(_ scalar: Unicode.Scalar, in base: CTFont)
        -> (font: CTFont, glyph: CGGlyph)?
    {
        func glyph(in font: CTFont) -> CGGlyph? {
            var units = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            let found = CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
            return found && glyphs[0] != 0 ? glyphs[0] : nil
        }
        if let found = glyph(in: base) { return (base, found) }
        let text = String(scalar) as CFString
        let font = CTFontCreateForString(base, text, CFRangeMake(0, CFStringGetLength(text)))
        return glyph(in: font).map { (font, $0) }
    }

    /// 字形 1 つを描いた墨の範囲を、書き始めと基準線から測った値 (x は右・y は上へ) で返す。
    nonisolated private static func referenceInk(of glyph: CGGlyph, in font: CTFont, size: CGFloat)
        -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat)?
    {
        // 字形が十分収まる升目に、書き始めと基準線を (margin, margin) に置いて描く
        let margin = Int(size) * 2
        let side = margin * 3
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            var glyph = glyph
            var position = CGPoint(x: margin, y: margin)
            CTFontDrawGlyphs(font, &glyph, &position, 1, context)
        }
        var (left, right, top, bottom) = (Int.max, Int.min, Int.max, Int.min)
        for row in 0..<side {
            for column in 0..<side where pixels[(row * side + column) * 4 + 3] > 0 {
                (left, right) = (min(left, column), max(right, column + 1))
                (top, bottom) = (min(top, row), max(bottom, row + 1))
            }
        }
        guard left <= right else { return nil }
        // 並びの先頭は絵の上端。基準線は下から margin の行
        return (
            CGFloat(left - margin), CGFloat(right - margin), CGFloat(side - margin - top),
            CGFloat(side - margin - bottom)
        )
    }

    /// 1 行の文字列を `(x, baseline)` から描いた墨の外接 (左・上・右・下、面の座標)。字は
    /// スカラ 1 つずつ、CoreText の送り幅で並べる (mokume は組版をしない)。
    nonisolated private static func referenceExtent(
        _ string: String, font name: String?, size: CGFloat, x: CGFloat, baseline: CGFloat
    ) -> (left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat)? {
        let base = referenceFont(name, size: size)
        var pen = x
        var extent: (left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat)?
        for scalar in string.unicodeScalars {
            guard let (font, glyph) = referenceGlyph(scalar, in: base) else { continue }
            if let ink = referenceInk(of: glyph, in: font, size: size) {
                let piece = (pen + ink.left, baseline - ink.top, pen + ink.right, baseline - ink.bottom)
                extent = extent.map {
                    (min($0.left, piece.0), min($0.top, piece.1), max($0.right, piece.2), max($0.bottom, piece.3))
                } ?? piece
            }
            var index = glyph
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &index, &advance, 1)
            pen += advance.width
        }
        return extent
    }

    /// 墨の枠を照合する組 (文字列・書体)。
    ///
    /// - 🔴 は墨が送り幅の升目いっぱいに載り、🌲 は升目より左右に 3 画素ずつ狭い (40 で実測)。
    ///   🌲 があるので、外接矩形 (升目) を枠にする直し方では赤くなる
    /// - 🇯 🇵 (国旗 🇯🇵 の部品) は、CoreText が中身の無い仮の矩形を道筋として返すが、描かれるのは
    ///   色の絵で、道筋より右と下へはみ出す。「道筋が無ければ描いて測る」の振り分けでは赤くなる
    /// - `1`・`#`・U+20E3 は、Apple Color Emoji を指定すると同じく仮の道筋を持つ
    /// - 既定の書体 (`nil`) の絵文字は `.AppleColorEmojiUI` から引かれ、升目が 2 画素ずれる
    nonisolated static var colorGlyphCases: [(string: String, font: String?)] {
        let singles: [String] = ["\u{1F534}", "\u{1F332}", "\u{1F1EF}", "\u{1F1F5}"]
        return singles.flatMap { [($0, "Helvetica"), ($0, nil)] } + [
            ("A\u{1F534}", "Helvetica"),
            ("A \u{1F534} ", "Helvetica"),
            ("A\u{1F534}", nil),
            ("\u{1F1EF}\u{1F1F5}", nil),
            ("1\u{20E3}", "Apple Color Emoji"),
            ("#", "Apple Color Emoji"),
        ]
    }

    @Test(
        "色の字形を持つ書体の字と道筋の無い字の墨の枠は、nil でなく、CPU で描いた墨の外接から各辺 1 画素以内",
        .enabled(if: TextTests.hasColoredGlyphs, "この環境には色を持つ字形の書体が無い"),
        arguments: colorGlyphCases)
    func theBoundsHugTheDrawnInkOfColorGlyphs(_ item: (string: String, font: String?)) throws {
        let note = "\(item.string.debugDescription) \(item.font ?? "既定の書体")"
        let canvas = try makeCanvas()
        if let font = item.font { canvas.textFont(font) } else { canvas.noTextFont() }
        canvas.textSize(40)
        let ink = try #require(
            Self.referenceExtent(item.string, font: item.font, size: 40, x: 20, baseline: 80),
            "前提: \(note) を描くと墨が出る")
        let bounds = try #require(canvas.textBounds(item.string, 20, 80), "\(note): 枠が nil")
        #expect(abs(CGFloat(bounds.x) - ink.left) <= 1, "\(note): 左 \(bounds.x) / 墨 \(ink.left)")
        #expect(abs(CGFloat(bounds.y) - ink.top) <= 1, "\(note): 上 \(bounds.y) / 墨 \(ink.top)")
        #expect(
            abs(CGFloat(bounds.x + bounds.width) - ink.right) <= 1,
            "\(note): 右 \(bounds.x + bounds.width) / 墨 \(ink.right)")
        #expect(
            abs(CGFloat(bounds.y + bounds.height) - ink.bottom) <= 1,
            "\(note): 下 \(bounds.y + bounds.height) / 墨 \(ink.bottom)")
    }

    /// 国旗の部品は道筋 (仮の矩形) を持つが、描かれるのは Apple Color Emoji の絵である。輪郭は
    /// 描く絵の形ではないので返さない。並べた字の輪郭はそのまま残る。
    @Test(
        "色の字形を持つ書体の字は、道筋を持っていても輪郭を返さない",
        .enabled(if: TextTests.hasColoredGlyphs, "この環境には色を持つ字形の書体が無い"),
        arguments: ["\u{1F1EF}", "\u{1F1F5}"] as [Unicode.Scalar], ["Helvetica", nil] as [String?])
    func aColorGlyphWithAPlaceholderPathHasNoOutline(_ scalar: Unicode.Scalar, _ font: String?)
        throws
    {
        let (face, glyph) = try #require(
            Self.referenceGlyph(scalar, in: Self.referenceFont(font, size: 40)))
        try #require(
            CTFontCreatePathForGlyph(face, glyph, nil) != nil,
            "前提: CoreText は \(scalar) に道筋を返す")
        try #require(
            CTFontGetSymbolicTraits(face).contains(.traitColorGlyphs),
            "前提: \(scalar) は色の字形を持つ書体から引かれる")
        let canvas = try makeCanvas()
        if let font { canvas.textFont(font) } else { canvas.noTextFont() }
        canvas.textSize(40)
        #expect(canvas.textOutline(String(scalar), 20, 80).isEmpty)
        #expect(canvas.textOutline("A\(scalar)", 20, 80) == canvas.textOutline("A", 20, 80))
    }

    /// 焼き場の上限 (4096) に入らない大きさでは、字形を描いて測らない (巨大な絵を CPU に描かせ
    /// ない)。枠は CoreText の外接矩形になり、道筋を持つ字と同じく枠を返す。
    @Test(
        "焼き場に入らない大きさの色を持つ字形は、描かずに外接矩形を枠にする",
        .enabled(if: TextTests.hasColoredGlyphs, "この環境には色を持つ字形の書体が無い"))
    func aHugeColoredGlyphFallsBackToItsBoundingRect() throws {
        let size: CGFloat = 6000
        let canvas = try makeCanvas()
        canvas.textSize(Float(size))
        let base = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let text = String(coloredScalar) as CFString
        let font = CTFontCreateForString(base, text, CFRangeMake(0, CFStringGetLength(text)))
        var units = Array(String(coloredScalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        try #require(CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count))
        let rect = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, nil, 1)
        try #require(rect.width > 4096, "前提: \(size) の 🔴 は焼き場の上限より大きい")
        let bounds = try #require(canvas.textBounds(String(coloredScalar), 0, 0))
        #expect(abs(CGFloat(bounds.x) - rect.minX) <= 0.5)
        #expect(abs(CGFloat(bounds.width) - rect.width) <= 0.5)
        #expect(abs(CGFloat(bounds.y) + rect.maxY) <= 0.5)
        #expect(abs(CGFloat(bounds.height) - rect.height) <= 0.5)
    }
}
