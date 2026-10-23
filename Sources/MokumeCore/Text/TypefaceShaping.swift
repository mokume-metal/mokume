// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation

/// 組版した 1 行の字形の並び (``Typeface/shape(_:)``)。[#2404]
///
/// **描く・幅・整列・墨の範囲は、どれもこの 1 つの結果から出す。** 別々に数えると、整列や墨の枠が
/// 数画素ずれる形で食い違う (``Typeface/advance(of:)`` と同じ理由)。
///
/// [#2404]: https://github.com/mokume-metal/mokume/issues/2404
final class ShapedLine {
    /// 1 つの字形。`x`・`y` は行の書き始めと基準線から測った位置 (画素。`y` は上向き)。
    struct Glyph {
        var resolved: ResolvedGlyph
        var x: Float
        var y: Float
    }

    let glyphs: [Glyph]
    /// 行の送り幅 (画素)。カーニング・合字を含む。
    let width: Float
    /// 字形ごとに焼き場で引いた結果の控え。頁の通し番号が一致する間だけ使える (``Typeface/placed`` と同じ約束)。
    var placed: [PlacedGlyph?]

    init(glyphs: [Glyph], width: Float) {
        self.glyphs = glyphs
        self.width = width
        self.placed = Array(repeating: nil, count: glyphs.count)
    }
}

/// 組版した 1 行の控えの鍵。**スカラ列そのもの**で比べる。
///
/// Swift の `String` は等価もハッシュも**正準等価**で取るので、字形の違う文字列 (`\u{4FAE}` と互換漢字
/// `\u{FA30}`・`\u{03A9}` (Ω) とオーム記号 `\u{2126}`・`\u{00C5}` (Å) とオングストローム記号
/// `\u{212B}`) が同じ鍵になり、先に組んだほうの結果が返ってしまう。`text()` の控えは
/// `Unicode.Scalar` が鍵で起きない ([#2404])。UTF-8 の列は、スカラ列と 1 対 1 に対応する。
///
/// [#2404]: https://github.com/mokume-metal/mokume/issues/2404
struct ShapedLineKey: Hashable {
    let line: String

    static func == (lhs: ShapedLineKey, rhs: ShapedLineKey) -> Bool {
        lhs.line.utf8.elementsEqual(rhs.line.utf8)
    }

    func hash(into hasher: inout Hasher) {
        var copy = line
        copy.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}

/// 組版した字形の墨の控えの鍵。
struct ShapedInkKey: Hashable {
    var fontKey: String
    var glyph: CGGlyph
}

extension Typeface {
    /// 控える組版結果の重さ (字形の数) の合計の上限。毎フレーム違う文字列 (数の表示など) を渡しても控えが
    /// 育ちきらない。**件数ではなく字形の数で切る** — 長い文字列 1 本が、短い文字列何本ぶんも抱えるため。
    /// 超えたら、古い順に 1 件ずつ捨てる (``BoundedCache``。[ADR-0023] 決定 5)。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    static let shapedBudget = 16384

    /// 1 行を組版する。**改行は含まない** (行の分け方は呼ぶ側 (`Canvas`) が決める)。
    ///
    /// CoreText が文字列を字形の列へ変える (`CTLine`)。複数のスカラでできた絵文字 (肌色の修飾子・国旗・
    /// ZWJ で繋いだ家族・異体字セレクタ・囲み) は 1 つの字形に、結合文字は基の字の字形と、位置をずらした
    /// 結合記号の字形になり、ラテンの字はカーニングが掛かる。書体が覆えない字は、CoreText が行の中で
    /// 別の書体を選ぶが、その書体は ``glyph(for:)`` と同じに扱う — 頼んだ太さ・傾きの面を持つなら
    /// その面へ引き直し、持たなければ知らせる ([#2561]・[#2770])。**幅は部品の幅の和にならない**
    /// (``advance(of:)`` の加法性を持たない)。
    ///
    /// 同じ文字列は控えから返す。**鍵はスカラ列そのもの**で、Swift の `String` の等価 (正準等価) では
    /// 比べない — `\u{212B}` (オングストローム記号) と `\u{00C5}` (Å) のように、字形の違う字が
    /// 同じ鍵にならない ([#2404])。
    ///
    /// [#2404]: https://github.com/mokume-metal/mokume/issues/2404
    /// [#2561]: https://github.com/mokume-metal/mokume/issues/2561
    /// [#2770]: https://github.com/mokume-metal/mokume/issues/2770
    func shape(_ line: String) -> ShapedLine {
        let key = ShapedLineKey(line: line)
        if let found = shaped[key] { return found }
        let made = makeShaped(line)
        shaped.insert(made, for: key)
        return made
    }

    /// 1 つの行を、書体とその上書き (範囲ごとの書体) で `CTLine` にする。
    private static func makeLine(
        _ line: String, base: CTFont, overrides: [(range: CFRange, font: CTFont)]
    ) -> CTLine? {
        guard let text = CFAttributedStringCreateMutable(nil, 0) else { return nil }
        CFAttributedStringReplaceString(text, CFRangeMake(0, 0), line as CFString)
        let length = CFAttributedStringGetLength(text)
        CFAttributedStringSetAttribute(text, CFRangeMake(0, length), kCTFontAttributeName, base)
        for (range, font) in overrides {
            CFAttributedStringSetAttribute(text, range, kCTFontAttributeName, font)
        }
        return CTLineCreateWithAttributedString(text)
    }

    /// 異体字セレクタ 16 (U+FE0F。絵文字の見た目を求める印) を、**絵文字になれない字の後では落とす**。
    ///
    /// `a\u{FE0F}` の `a` は絵文字を持たない。書体が U+FE0F の字形を持たないと、CoreText は印を覆える別の
    /// 書体を選び、**書体が覆える `a` ごと別の書体 (LucidaGrande) へ替えてしまう**。印は絵文字を持つ字の
    /// 見た目を選ぶもので、持たない字には効かないので、落として書体を替えない。絵文字を持つ字 (`❤`・`1`・
    /// `©`) の後の印は、そのまま渡す。
    static func droppingIdleEmojiSelectors(_ line: String) -> String {
        guard line.unicodeScalars.contains("\u{FE0F}") else { return line }
        var kept = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        for scalar in line.unicodeScalars {
            if scalar == "\u{FE0F}", let previous, !previous.properties.isEmoji { continue }
            kept.append(scalar)
            previous = scalar
        }
        return String(kept)
    }

    /// 文字列の、UTF-16 の位置にあるスカラ。
    private static func scalar(at unit: Int, in units: [UInt16]) -> Unicode.Scalar? {
        guard units.indices.contains(unit) else { return nil }
        let end = min(unit + 2, units.count)
        return String(decoding: units[unit..<end], as: UTF16.self).unicodeScalars.first
    }

    /// その書体が、範囲の字を全部覆うか (結合記号や ZWJ のような、字形を持たない印は問わない)。
    private static func covers(_ units: ArraySlice<UInt16>, in font: CTFont) -> Bool {
        for scalar in String(decoding: units, as: UTF16.self).unicodeScalars
        where !scalar.properties.isDefaultIgnorableCodePoint {
            if glyphIndex(of: scalar, in: font) == 0 { return false }
        }
        return true
    }

    private func makeShaped(_ source: String) -> ShapedLine {
        let line = Self.droppingIdleEmojiSelectors(source)
        let units = Array(line.utf16)
        guard var ctLine = Self.makeLine(line, base: base, overrides: []) else {
            return ShapedLine(glyphs: [], width: 0)
        }

        // 代わりの書体 (CoreText が行の中で選んだ、``base`` と違う書体) の区間を、``glyph(for:)`` と同じに扱う:
        // 頼んだ太さ・傾きの面へ引き直し、引き直しても面が頼んだ性質を欠くなら知らせる ([#2561]・[#2770])。
        // 引き直した面は、その区間の書体として組み直す (カーニングや結合記号の位置も、その面で決まる)
        let requested = Self.traits(of: request.style)
        var overrides: [(range: CFRange, font: CTFont)] = []
        for run in CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [] {
            let font = Self.font(of: run, default: base)
            guard !CFEqual(font, base), CTRunGetGlyphCount(run) > 0 else { continue }
            let (indices, _) = Self.glyphs(of: run)
            guard
                let first = indices.indices.first(where: {
                    indices[$0] != 0 && Self.lacksStyle(fallback: font, glyph: indices[$0], requested: requested)
                })
            else { continue }
            let range = CTRunGetStringRange(run)
            var stringIndices = [CFIndex](repeating: 0, count: indices.count)
            CTRunGetStringIndices(run, CFRangeMake(0, 0), &stringIndices)
            guard
                range.location >= 0, range.location + range.length <= units.count,
                let scalar = Self.scalar(at: stringIndices[first], in: units)
            else { continue }
            let covered = units[range.location..<(range.location + range.length)]
            let (face, _, lacksStyle) = Self.restyledFallback(
                font, glyph: indices[first], requested: requested,
                copy: { CTFontCreateCopyWithSymbolicTraits(font, CTFontGetSize(font), nil, $0, $0) },
                glyphIndex: { Self.covers(covered, in: $0) ? Self.glyphIndex(of: scalar, in: $0) : 0 })
            if !CFEqual(face, font) { overrides.append((range, face)) }
            if lacksStyle { onFallbackLackingStyle(self, scalar, face) }
        }
        if !overrides.isEmpty, let restyled = Self.makeLine(line, base: base, overrides: overrides) {
            ctLine = restyled
        }

        let width = Float(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        var glyphs: [ShapedLine.Glyph] = []
        for run in CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [] {
            guard CTRunGetGlyphCount(run) > 0 else { continue }
            let font = Self.font(of: run, default: base)
            let (indices, positions) = Self.glyphs(of: run)
            // 鍵は ``glyph(for:)`` と同じ作り方。ファイルから読んだ書体の字は、同じ PostScript 名の
            // インストール済みの書体と焼き場で混ざらないよう、ファイルの同一性を鍵に含める (#2445)。
            // 代わりの書体 (``base`` と違う書体) はこの環境の書体で、名前だけ。見分けは名前ではなく構造で行う
            var fontKey = (CTFontCopyPostScriptName(font) as String?) ?? ""
            if let file = request.file, CFEqual(font, base) { fontKey += "#" + file.identity }
            for index in indices.indices where indices[index] != 0 {
                let resolved = ResolvedGlyph(font: font, glyph: indices[index], advance: 0, fontKey: fontKey)
                glyphs.append(
                    ShapedLine.Glyph(
                        resolved: resolved, x: Float(positions[index].x), y: Float(positions[index].y)))
            }
        }
        return ShapedLine(glyphs: glyphs, width: width)
    }

    private static func font(of run: CTRun, default fallback: CTFont) -> CTFont {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        return (attributes[kCTFontAttributeName] as! CTFont?) ?? fallback
    }

    private static func glyphs(of run: CTRun) -> (indices: [CGGlyph], positions: [CGPoint]) {
        let count = CTRunGetGlyphCount(run)
        var indices = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRangeMake(0, 0), &indices)
        CTRunGetPositions(run, CFRangeMake(0, 0), &positions)
        return (indices, positions)
    }

    /// 組版した字形の墨の範囲 ([#2308] と同じ測り方)。字形の座標 (書き始めと基準線から測り、上向き) で返す。
    ///
    /// 道筋で描く字形は道筋の外接、色やビットマップの字形・道筋を持たない字形は焼き場と同じ描き方で描いた墨。
    /// 控えは (書体・字形の番号) ごとで、描くのは字形の種類ごとに 1 度だけである。
    ///
    /// [#2308]: https://github.com/mokume-metal/mokume/issues/2308
    func ink(
        of glyph: ResolvedGlyph, keeping atlas: GlyphAtlas, as key: GlyphAtlas.Key
    ) -> CGRect? {
        let path = CTFontCreatePathForGlyph(glyph.font, glyph.glyph, nil)
        guard Self.measuresByDrawing(glyph, path: path) else { return path?.boundingBoxOfPath }
        let inkKey = ShapedInkKey(fontKey: glyph.fontKey, glyph: glyph.glyph)
        if let cached = shapedInks[inkKey] { return cached }
        switch Self.draw(glyph, on: atlas) {
        case .ink(let ink, let rendered):
            shapedInks[inkKey] = ink
            if let rendered { atlas.keepRendered(rendered, for: key) }
            return ink
        case .failed:
            return nil
        }
    }
}
